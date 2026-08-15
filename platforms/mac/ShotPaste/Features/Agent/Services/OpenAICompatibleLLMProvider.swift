//
//  OpenAICompatibleLLMProvider.swift
//  ShotPaste
//
//  Vendor-neutral OpenAI-compatible Chat Completions adapter.
//

import CoreGraphics
import Foundation

struct OpenAICompatibleLLMProvider: LLMProvider, Sendable {
  let capabilities = AgentProviderCapabilities(
    acceptsImages: true,
    supportsToolCalls: true
  )

  private let httpClient: AgentLLMHTTPClient

  init(
    session: any URLSessionProtocol = URLSession.shared,
    retryDelaysNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000]
  ) {
    httpClient = AgentLLMHTTPClient(
      session: session,
      retryDelaysNanoseconds: retryDelaysNanoseconds
    )
  }

  func nextAction(
    request: AgentProviderRequest,
    configuration: AgentProviderConfiguration,
    apiKey: String?
  ) async throws -> AgentProviderDecision {
    guard configuration.isValid, let endpointURL = configuration.endpointURL else {
      throw AgentProviderError.invalidConfiguration
    }
    if !configuration.isLocalEndpoint, AgentCredentialStore.normalizedKey(apiKey) == nil {
      throw AgentProviderError.missingAPIKey
    }

    let body = try requestBody(for: request, configuration: configuration)
    var urlRequest = URLRequest(
      url: endpointURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 90
    )
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("ShotPaste-AgentMode/1", forHTTPHeaderField: "User-Agent")
    if let apiKey = AgentCredentialStore.normalizedKey(apiKey) {
      urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data = try await httpClient.responseData(for: urlRequest)

    let payload: ChatCompletionResponse
    do {
      payload = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    } catch {
      throw AgentProviderError.invalidResponse
    }
    guard let message = payload.choices.first?.message else {
      throw AgentProviderError.invalidResponse
    }

    if let call = message.toolCalls?.first {
      return AgentProviderDecision(
        action: try parseToolCall(call),
        model: payload.model ?? configuration.model
      )
    }

    let fallbackQuestion = message.content?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let fallbackQuestion, !fallbackQuestion.isEmpty else {
      throw AgentProviderError.invalidResponse
    }
    return AgentProviderDecision(
      action: .askUser(question: String(fallbackQuestion.prefix(1_000))),
      model: payload.model ?? configuration.model
    )
  }

  private func requestBody(
    for request: AgentProviderRequest,
    configuration: AgentProviderConfiguration
  ) throws -> [String: Any] {
    let includesImage = configuration.sendsImages
    let contextText = AgentLLMPromptBuilder.contextText(
      for: request,
      imageIncluded: includesImage
    )
    let userContent: Any
    if includesImage {
      guard let encodedImage = AgentProviderImageEncoder.dataURL(
        for: request.observation.screenshot
      ) else {
        throw AgentProviderError.invalidResponse
      }
      userContent = [
        ["type": "text", "text": contextText],
        [
          "type": "image_url",
          "image_url": ["url": encodedImage, "detail": "high"],
        ],
      ]
    } else {
      userContent = contextText
    }

    var body: [String: Any] = [
      "model": configuration.model,
      "messages": [
        ["role": "system", "content": AgentLLMPromptBuilder.systemPrompt],
        ["role": "user", "content": userContent],
      ],
      "tools": AgentLLMToolCatalog.openAIToolDefinitions(),
      "tool_choice": "auto",
      "max_tokens": 1_024,
      "stream": false,
    ]
    if configuration.thinkingEnabled {
      body["reasoning_effort"] = "high"
    }
    return body
  }

  /// Chat Completions 的工具参数是 JSON 字符串，先解码再交给共享解析器。
  private func parseToolCall(_ call: ChatCompletionResponse.ToolCall) throws -> AgentToolAction {
    guard let data = call.function.arguments.data(using: .utf8),
          let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw AgentProviderError.invalidToolArguments(call.function.name)
    }
    return try AgentToolCallParser.parse(
      toolName: call.function.name,
      arguments: arguments
    )
  }
}

private struct ChatCompletionResponse: Decodable {
  struct Choice: Decodable {
    let message: Message
  }

  struct Message: Decodable {
    let content: String?
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
      case content
      case toolCalls = "tool_calls"
    }
  }

  struct ToolCall: Decodable {
    struct Function: Decodable {
      let name: String
      let arguments: String
    }

    let function: Function
  }

  let model: String?
  let choices: [Choice]
}
