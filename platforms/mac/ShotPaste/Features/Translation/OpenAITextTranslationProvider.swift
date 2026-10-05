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
  private let responseParser: TranslationTextResponseParser?

  init(
    session: any URLSessionProtocol = URLSession.shared,
    retryDelayNanoseconds: UInt64 = 250_000_000,
    responseParser: TranslationTextResponseParser? = nil
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
    guard configuration.apiProtocol == .openAICompatible || configuration.apiProtocol == .openAIResponses else {
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
      withJSONObject: requestBody(for: request, configuration: configuration),
      options: [.sortedKeys]
    )

    let data = try await httpClient.responseData(for: urlRequest, deadline: deadline)
    do {
      let response = try await TranslationTextResponseParserRunner.parse(
        responseParser ?? { data, request in
          if configuration.apiProtocol == .openAIResponses {
            return try Self.parseResponsesResponse(data, request: request)
          }
          return try Self.parseResponse(data, request: request)
        },
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
    configuration: AgentProviderConfiguration
  ) throws -> [String: Any] {
    let dataJSONString = try TranslationTextRequestEncoding.dataJSONString(for: request)
    if configuration.apiProtocol == .openAIResponses {
      var function = Self.toolDefinition["function"] as? [String: Any] ?? [:]
      function["type"] = "function"
      function["strict"] = false
      var body: [String: Any] = [
        "model": configuration.model,
        "instructions": TranslationTextPrompt.systemConstraints,
        "input": [["role": "user", "content": [["type": "input_text", "text": dataJSONString]]]],
        "tools": [function],
        "tool_choice": ["type": "function", "name": TranslationTextPrompt.toolName],
        "parallel_tool_calls": false,
        "max_output_tokens": configuration.thinkingEnabled ? 8_192 : 4_096,
        "store": false,
        "stream": false,
      ]
      if configuration.thinkingEnabled { body["reasoning"] = ["effort": "high"] }
      return body
    }
    return [
      "model": configuration.model,
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

  private static func parseResponsesResponse(
    _ data: Data,
    request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    guard data.count <= TranslationTextLimits.maximumResponseBytes,
          let response = try? OpenAIResponsesResponse(data: data) else {
      throw TranslationTextProviderError.invalidResponse
    }
    if !response.functionCalls.isEmpty {
      guard response.functionCalls.count == 1, let call = response.functionCalls.first,
            call.name == TranslationTextPrompt.toolName,
            response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TranslationTextProviderError.invalidResponse
      }
      return try TranslationTextResponseValidator.decodeToolArguments(call.arguments, against: request)
    }
    return try TranslationTextResponseValidator.decodeStrictJSON(response.text, against: request)
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
            Self.hasRequiredToolCallFields(call),
            let function = call["function"] as? [String: Any],
            function["name"] as? String == TranslationTextPrompt.toolName,
            let arguments = function["arguments"] as? String
        else {
          throw TranslationTextProviderError.invalidResponse
        }
        guard Self.hasNoNonEmptyToolCompanionContent(message),
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
    guard !Self.hasNonEmptyRefusal(message),
          let content = message["content"] as? String else {
      throw TranslationTextProviderError.invalidResponse
    }
    return try TranslationTextResponseValidator.decodeStrictJSON(content, against: request)
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

  /// Required fields are validated; provider-specific response metadata is ignored.
  private static func hasRequiredToolCallFields(_ call: [String: Any]) -> Bool {
    guard call["type"] as? String == "function" else { return false }
    if let id = call["id"], !(id is String) {
      return false
    }
    return true
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
