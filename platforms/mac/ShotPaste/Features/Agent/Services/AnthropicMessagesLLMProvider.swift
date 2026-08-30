//
//  AnthropicMessagesLLMProvider.swift
//  ShotPaste
//
//  Anthropic Messages API (POST /v1/messages) 适配器。
//  与 OpenAICompatibleLLMProvider 共享工具目录、提示词与参数解析。
//

import CoreGraphics
import Foundation

struct AnthropicMessagesLLMProvider: LLMProvider, Sendable {
  let capabilities = AgentProviderCapabilities(
    acceptsImages: true,
    supportsToolCalls: true
  )

  /// Anthropic 协议版本头；网关按该版本解析请求体。
  private static let anthropicVersion = "2023-06-01"
  private static let maximumThinkingOutputTokens = 4_096
  /// 仅用于明确不支持 adaptive thinking 的旧式兼容网关。
  private static let legacyThinkingBudgetTokens = 1_024

  private enum ThinkingStyle {
    case adaptive
    case legacy
    case disabled
  }

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

    let initialThinkingStyle: ThinkingStyle = configuration.thinkingEnabled
      ? .adaptive : .disabled
    let initialRequest = try urlRequest(
      for: request,
      configuration: configuration,
      apiKey: apiKey,
      thinkingStyle: initialThinkingStyle,
      endpointURL: endpointURL
    )

    let data: Data
    do {
      data = try await httpClient.responseData(for: initialRequest)
    } catch let error as AgentProviderError {
      guard initialThinkingStyle == .adaptive,
            Self.shouldRetryWithLegacyThinking(after: error)
      else { throw error }

      let legacyRequest = try urlRequest(
        for: request,
        configuration: configuration,
        apiKey: apiKey,
        thinkingStyle: .legacy,
        endpointURL: endpointURL
      )
      data = try await httpClient.responseData(for: legacyRequest)
    }

    return try parseDecision(from: data, configuration: configuration)
  }

  // MARK: - 请求构建

  private func urlRequest(
    for request: AgentProviderRequest,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    thinkingStyle: ThinkingStyle,
    endpointURL: URL
  ) throws -> URLRequest {
    let body = try requestBody(
      for: request,
      configuration: configuration,
      thinkingStyle: thinkingStyle
    )
    var urlRequest = URLRequest(
      url: endpointURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 90
    )
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("ShotPaste-AgentMode/1", forHTTPHeaderField: "User-Agent")
    urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
    if let apiKey = AgentCredentialStore.normalizedKey(apiKey) {
      // 同时发送 x-api-key 与 Bearer：官方 API 使用前者，
      // AUTH_TOKEN 风格网关（如 Claude Code 兼容代理）使用后者。
      urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
    return urlRequest
  }

  private func requestBody(
    for request: AgentProviderRequest,
    configuration: AgentProviderConfiguration,
    thinkingStyle: ThinkingStyle
  ) throws -> [String: Any] {
    let includesImage = configuration.sendsImages
    let contextText = AgentLLMPromptBuilder.contextText(
      for: request,
      imageIncluded: includesImage
    )

    var content: [[String: Any]] = [
      ["type": "text", "text": contextText],
    ]
    if includesImage {
      guard let base64 = AgentProviderImageEncoder.jpegBase64(
        for: request.observation.screenshot
      ) else {
        throw AgentProviderError.invalidResponse
      }
      content.append([
        "type": "image",
        "source": [
          "type": "base64",
          "media_type": "image/jpeg",
          "data": base64,
        ],
      ])
    }

    var body: [String: Any] = [
      "model": configuration.model,
      "max_tokens": thinkingStyle == .disabled ? 1_024 : Self.maximumThinkingOutputTokens,
      "system": AgentLLMPromptBuilder.systemPrompt,
      "messages": [
        ["role": "user", "content": content],
      ],
      "tools": AgentLLMToolCatalog.anthropicToolDefinitions(),
      "tool_choice": [
        "type": "auto",
        "disable_parallel_tool_use": true,
      ],
    ]
    switch thinkingStyle {
    case .adaptive:
      body["thinking"] = ["type": "adaptive"]
      body["output_config"] = ["effort": "high"]
    case .legacy:
      body["thinking"] = [
        "type": "enabled",
        "budget_tokens": Self.legacyThinkingBudgetTokens,
      ]
    case .disabled:
      body["thinking"] = ["type": "disabled"]
    }
    return body
  }

  /// 只有 400 明确说明 modern thinking 字段不受支持时，才降级一次。
  /// 认证、限流以及普通参数错误均保留原错误，不做协议猜测。
  private static func shouldRetryWithLegacyThinking(
    after error: AgentProviderError
  ) -> Bool {
    guard case .unsuccessfulStatusCode(400, let message) = error,
          let message
    else { return false }
    let normalized = message.lowercased()
    let rejectsField = [
      "unsupported", "not supported", "invalid", "not allowed", "not permitted",
      "unknown", "unrecognized", "unexpected", "must be", "expected",
    ].contains(where: normalized.contains)
    if rejectsField,
       normalized.contains("adaptive")
       || normalized.contains("output_config")
       || normalized.contains("output config")
       || normalized.contains("effort") {
      return true
    }
    return normalized.contains("budget_tokens")
      && ["required", "missing", "must"].contains(where: normalized.contains)
  }

  // MARK: - 响应解析

  /// 解析 Messages API 响应：每轮只允许一个 tool_use 块；
  /// thinking/redacted_thinking 块被忽略；仅剩文本时降级为向用户提问。
  private func parseDecision(
    from data: Data,
    configuration: AgentProviderConfiguration
  ) throws -> AgentProviderDecision {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let blocks = root["content"] as? [[String: Any]]
    else {
      throw AgentProviderError.invalidResponse
    }
    let model = root["model"] as? String ?? configuration.model

    let toolUseBlocks = blocks.filter { $0["type"] as? String == "tool_use" }
    guard toolUseBlocks.count <= 1 else {
      throw AgentProviderError.invalidResponse
    }
    if let block = toolUseBlocks.first {
      guard let name = block["name"] as? String,
            let arguments = block["input"] as? [String: Any]
      else {
        throw AgentProviderError.invalidResponse
      }
      return AgentProviderDecision(
        action: try AgentToolCallParser.parse(toolName: name, arguments: arguments),
        model: model
      )
    }

    let fallbackQuestion = blocks
      .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fallbackQuestion.isEmpty else {
      throw AgentProviderError.invalidResponse
    }
    return AgentProviderDecision(
      action: .askUser(question: String(fallbackQuestion.prefix(1_000))),
      model: model
    )
  }
}
