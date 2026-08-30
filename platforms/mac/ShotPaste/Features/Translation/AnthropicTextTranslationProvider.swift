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

    // Unknown fields in a known block are provider metadata and are ignored.
    // Unknown block kinds remain rejected so unrelated content is not silently
    // treated as translation output.
    guard content.allSatisfy({ Self.hasRequiredContentBlockShape($0) }) else {
      throw TranslationTextProviderError.invalidResponse
    }

    let toolUseBlocks = content.filter { $0["type"] as? String == "tool_use" }
    if !toolUseBlocks.isEmpty {
      guard toolUseBlocks.count == 1,
            let block = toolUseBlocks.first,
            Self.hasRequiredToolUseFields(block),
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

  private static func hasRequiredContentBlockShape(_ block: [String: Any]) -> Bool {
    guard let type = block["type"] as? String else { return false }
    switch type {
    case "tool_use":
      return Self.hasRequiredToolUseFields(block)
    case "thinking":
      return block["thinking"] is String
    case "redacted_thinking":
      // The opaque payload is not consumed by the translation client.
      return true
    case "text":
      // Text is only a strict-JSON fallback fragment.
      return block["text"] is String
    default:
      return false
    }
  }

  /// Required fields are validated; provider-specific response metadata is ignored.
  private static func hasRequiredToolUseFields(_ block: [String: Any]) -> Bool {
    guard block["type"] as? String == "tool_use" else { return false }
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
