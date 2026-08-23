//
//  AnthropicTextTranslationProvider.swift
//  ShotPaste
//
//  Anthropic Messages adapter for local-OCR text.
//

import Foundation

/// Anthropic Messages text-only translation provider.
nonisolated struct AnthropicTextTranslationProvider: TranslationTextProvider, Sendable {
  private static let anthropicVersion = "2023-06-01"
  private let httpClient: TranslationTextHTTPClient
  private let responseParser: TranslationTextResponseParser

  init(
    session: any URLSessionProtocol = URLSession.shared,
    retryDelayNanoseconds: UInt64 = 250_000_000,
    responseParser: @escaping TranslationTextResponseParser = { data, request in
      try AnthropicTextTranslationProvider.parseResponse(data, request: request)
    }
  ) {
    httpClient = TranslationTextHTTPClient(
      session: session,
      retryDelayNanoseconds: retryDelayNanoseconds
    )
    self.responseParser = responseParser
  }

  func translate(
    request: TranslationTextRequest,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    deadline: Date
  ) async throws -> TranslationTextResponse {
    guard configuration.apiProtocol == .anthropicMessages else {
      throw TranslationTextProviderError.invalidConfiguration
    }
    try TranslationTextProviderConfiguration.validate(
      configuration: configuration,
      apiKey: apiKey
    )
    try TranslationTextRequestValidator.validate(request)
    guard !request.blocks.isEmpty,
          request.blocks.count <= TranslationTextLimits.hardMaximumBlocksPerBatch
    else {
      throw TranslationTextProviderError.invalidRequest
    }
    guard Date() < deadline else { throw TranslationTextProviderError.timedOut }
    guard let endpointURL = configuration.endpointURL else {
      throw TranslationTextProviderError.invalidConfiguration
    }

    var urlRequest = URLRequest(
      url: endpointURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      // This is only a transport hint. The HTTP client races the actual
      // request against the shared absolute deadline and cancels its task;
      // there is intentionally no minimum timeout that can overrun it.
      timeoutInterval: max(0, deadline.timeIntervalSinceNow)
    )
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("ShotPaste-TextTranslation/1", forHTTPHeaderField: "User-Agent")
    urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
    if let key = AgentCredentialStore.normalizedKey(apiKey) {
      // Official Anthropic uses x-api-key; Bearer keeps configured compatible
      // gateways working and contains no additional data.
      urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
      urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONSerialization.data(
      withJSONObject: requestBody(for: request, model: configuration.model),
      options: [.sortedKeys]
    )

    let data = try await httpClient.responseData(for: urlRequest, deadline: deadline)
    do {
      let response = try await TranslationTextResponseParserRunner.parse(
        responseParser,
        data: data,
        request: request,
        deadline: deadline
      )
      try Self.checkCancellationAndDeadline(deadline)
      return response
    } catch {
      // Prefer timeout/cancellation over a parser error when the shared
      // deadline or caller cancellation won while parsing.  Parsing runs in
      // an independent task, so a non-cooperative parser cannot hold the
      // coordinator past the deadline.
      try Self.checkCancellationAndDeadline(deadline)
      throw error
    }
  }

  private func requestBody(
    for request: TranslationTextRequest,
    model: String
  ) throws -> [String: Any] {
    let dataJSONString = try TranslationTextRequestEncoding.dataJSONString(for: request)
    return [
      "model": model,
      "max_tokens": 4_096,
      "system": TranslationTextPrompt.systemConstraints,
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": dataJSONString],
          ],
        ],
      ],
      "tools": [Self.toolDefinition],
      "tool_choice": [
        "type": "tool",
        "name": TranslationTextPrompt.toolName,
        "disable_parallel_tool_use": true,
      ],
    ]
  }

  private static func parseResponse(
    _ data: Data,
    request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    guard data.count <= TranslationTextLimits.maximumResponseBytes else {
      throw TranslationTextProviderError.invalidResponse
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = root["content"] as? [[String: Any]]
    else {
      throw TranslationTextProviderError.invalidResponse
    }

    // The only non-translation blocks permitted next to a tool call are the
    // platform's thinking metadata. Unknown block kinds are rejected rather
    // than silently discarded.
    guard content.allSatisfy({ Self.isKnownContentBlock($0) }) else {
      throw TranslationTextProviderError.invalidResponse
    }

    let toolUseBlocks = content.filter { $0["type"] as? String == "tool_use" }
    if !toolUseBlocks.isEmpty {
      guard toolUseBlocks.count == 1,
            let block = toolUseBlocks.first,
            Self.hasOnlyKnownToolUseKeys(block),
            block["name"] as? String == TranslationTextPrompt.toolName,
            let input = block["input"] as? [String: Any]
      else {
        throw TranslationTextProviderError.invalidResponse
      }
      let companionText = content.compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
      }.joined()
      guard companionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TranslationTextProviderError.invalidResponse
      }
      return try TranslationTextResponseValidator.decodeToolArguments(
        input,
        against: request
      )
    }

    // Thinking blocks and other non-text content are not translation data.
    // Joining text blocks supports gateways that split one JSON object while
    // still requiring the final concatenation to be one strict JSON object.
    let text = content
      .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
      .joined()
    guard !text.isEmpty else { throw TranslationTextProviderError.invalidResponse }
    return try TranslationTextResponseValidator.decodeStrictJSON(text, against: request)
  }

  private static func isKnownContentBlock(_ block: [String: Any]) -> Bool {
    guard let type = block["type"] as? String else { return false }
    switch type {
    case "tool_use":
      return Self.hasOnlyKnownToolUseKeys(block)
    case "thinking":
      // Anthropic extended-thinking metadata is allowed next to the tool, but
      // only its documented fields and string values may be ignored.  An
      // arbitrary companion object must not be silently swallowed.
      guard Set(block.keys).isSubset(of: ["type", "thinking", "signature"]),
            block["thinking"] is String
      else {
        return false
      }
      if let signature = block["signature"], !(signature is String) {
        return false
      }
      return true
    case "redacted_thinking":
      // Some gateways omit the opaque data field; when present it is a
      // string.  No other metadata is accepted.
      guard Set(block.keys).isSubset(of: ["type", "data"]),
            block["data"].map({ $0 is String }) ?? true
      else {
        return false
      }
      return true
    case "text":
      // Text is only a strict-JSON fallback fragment.  Citations and other
      // ordinary explanatory metadata are intentionally rejected here.
      return Set(block.keys) == ["type", "text"] && block["text"] is String
    default:
      return false
    }
  }

  private static func hasOnlyKnownToolUseKeys(_ block: [String: Any]) -> Bool {
    guard Set(block.keys).isSubset(of: ["type", "id", "name", "input"]),
          block["type"] as? String == "tool_use"
    else {
      return false
    }
    if let id = block["id"], !(id is String) {
      return false
    }
    return true
  }

  private static func checkCancellationAndDeadline(_ deadline: Date) throws {
    try TranslationTextDeadline.check(deadline)
  }

  private static let toolDefinition: [String: Any] = [
    "name": TranslationTextPrompt.toolName,
    "description": TranslationTextPrompt.toolDescription,
    "input_schema": [
      "type": "object",
      "additionalProperties": false,
      "required": ["generation_id", "translations"],
      "properties": [
        "generation_id": [
          "type": "string",
          "maxLength": TranslationTextLimits.maximumGenerationIDCharacters,
        ],
        "translations": [
          "type": "array",
          "maxItems": TranslationTextLimits.hardMaximumBlocksPerBatch,
          "items": [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "translated_text"],
            "properties": [
              "id": ["type": "string", "maxLength": 256],
              "translated_text": [
                "type": "string",
                "minLength": 1,
                "maxLength": TranslationTextLimits.maximumTranslatedCharactersPerBlock,
              ],
            ],
          ],
        ],
      ],
    ],
  ]
}
