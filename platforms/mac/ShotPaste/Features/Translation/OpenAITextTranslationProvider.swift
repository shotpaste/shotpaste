//
//  OpenAITextTranslationProvider.swift
//  ShotPaste
//
//  OpenAI-compatible Chat Completions adapter for local-OCR text.
//

import Foundation

typealias TranslationTextResponseParser = @Sendable (
  Data,
  TranslationTextRequest
) throws -> TranslationTextResponse

/// OpenAI-compatible text-only translation provider.
///
/// The request contains a JSON data string with ids and OCR text.  It never
/// creates an image content part and never accepts provider geometry.
nonisolated struct OpenAITextTranslationProvider: TranslationTextProvider, Sendable {
  private let httpClient: TranslationTextHTTPClient
  private let responseParser: TranslationTextResponseParser

  init(
    session: any URLSessionProtocol = URLSession.shared,
    retryDelayNanoseconds: UInt64 = 250_000_000,
    responseParser: @escaping TranslationTextResponseParser = { data, request in
      try OpenAITextTranslationProvider.parseResponse(data, request: request)
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
    guard configuration.apiProtocol == .openAICompatible else {
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
    if let key = AgentCredentialStore.normalizedKey(apiKey) {
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
      // deadline or caller cancellation won while parsing.  The parser runs
      // in an independent task, so this catch is reached promptly even when
      // the injected parser itself is non-cooperative.
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
      "messages": [
        [
          "role": "system",
          "content": TranslationTextPrompt.systemConstraints,
        ],
        [
          "role": "user",
          "content": dataJSONString,
        ],
      ],
      "tools": [Self.toolDefinition],
      "tool_choice": [
        "type": "function",
        "function": ["name": TranslationTextPrompt.toolName],
      ],
      "max_tokens": 4_096,
      "stream": false,
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
          let choices = root["choices"] as? [[String: Any]],
          choices.count == 1,
          let message = choices[0]["message"] as? [String: Any]
    else {
      throw TranslationTextProviderError.invalidResponse
    }

    if let rawCalls = message["tool_calls"], !(rawCalls is NSNull) {
      guard let calls = rawCalls as? [[String: Any]] else {
        throw TranslationTextProviderError.invalidResponse
      }
      if !calls.isEmpty {
        guard calls.count == 1,
            let call = calls.first,
            Self.hasOnlyKnownToolCallKeys(call),
            let function = call["function"] as? [String: Any],
            Self.hasOnlyKnownFunctionKeys(function),
            function["name"] as? String == TranslationTextPrompt.toolName,
            let arguments = function["arguments"] as? String
        else {
          throw TranslationTextProviderError.invalidResponse
        }
        guard Self.hasOnlyKnownMessageKeys(message),
              Self.hasNoNonEmptyToolCompanionContent(message),
              !Self.hasNonEmptyRefusal(message)
        else {
          throw TranslationTextProviderError.invalidResponse
        }
        return try TranslationTextResponseValidator.decodeToolArguments(
          arguments,
          against: request
        )
      }
    }

    // Some compatible gateways ignore tool_choice.  The fallback remains
    // strict: no prose, no Markdown fence, no extraction from a paragraph.
    guard Self.hasOnlyKnownMessageKeys(message),
          !Self.hasNonEmptyRefusal(message),
          let content = message["content"] as? String else {
      throw TranslationTextProviderError.invalidResponse
    }
    return try TranslationTextResponseValidator.decodeStrictJSON(content, against: request)
  }

  private static func hasOnlyKnownMessageKeys(_ message: [String: Any]) -> Bool {
    Set(message.keys).isSubset(of: ["role", "content", "tool_calls", "refusal"])
  }

  private static func hasNoNonEmptyToolCompanionContent(_ message: [String: Any]) -> Bool {
    guard let content = message["content"], !(content is NSNull) else { return true }
    guard let text = content as? String else { return false }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func hasNonEmptyRefusal(_ message: [String: Any]) -> Bool {
    guard let refusal = message["refusal"], !(refusal is NSNull) else { return false }
    guard let text = refusal as? String else { return true }
    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func hasOnlyKnownToolCallKeys(_ call: [String: Any]) -> Bool {
    guard Set(call.keys).isSubset(of: ["id", "type", "function"]),
          call["type"] as? String == "function"
    else {
      return false
    }
    if let id = call["id"], !(id is String) {
      return false
    }
    return true
  }

  private static func hasOnlyKnownFunctionKeys(_ function: [String: Any]) -> Bool {
    Set(function.keys).isSubset(of: ["name", "arguments"])
  }

  private static func checkCancellationAndDeadline(_ deadline: Date) throws {
    try TranslationTextDeadline.check(deadline)
  }

  private static let toolDefinition: [String: Any] = [
    "type": "function",
    "function": [
      "name": TranslationTextPrompt.toolName,
      "description": TranslationTextPrompt.toolDescription,
      "parameters": [
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
    ],
  ]
}
