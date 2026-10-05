//
//  OpenAIResponsesLLMProvider.swift
//  ShotPaste
//

import Foundation

/// Stateless Responses adapter. Each turn uses a fresh observation and the local audit trail.
struct OpenAIResponsesLLMProvider: LLMProvider, Sendable {
  let capabilities = AgentProviderCapabilities(acceptsImages: true, supportsToolCalls: true)
  private let httpClient: AgentLLMHTTPClient

  init(
    session: any URLSessionProtocol = URLSession.shared,
    retryDelaysNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000]
  ) {
    httpClient = AgentLLMHTTPClient(session: session, retryDelaysNanoseconds: retryDelaysNanoseconds)
  }

  func nextAction(
    request: AgentProviderRequest,
    configuration: AgentProviderConfiguration,
    apiKey: String?
  ) async throws -> AgentProviderDecision {
    guard configuration.apiProtocol == .openAIResponses,
          configuration.isValid, let endpoint = configuration.endpointURL else {
      throw AgentProviderError.invalidConfiguration
    }
    let key = AgentCredentialStore.normalizedKey(apiKey)
    guard configuration.isLocalEndpoint || key != nil else { throw AgentProviderError.missingAPIKey }
    var urlRequest = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                timeoutInterval: 90)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("ShotPaste-AgentMode/1", forHTTPHeaderField: "User-Agent")
    if let key { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    urlRequest.httpBody = try JSONSerialization.data(
      withJSONObject: requestBody(for: request, configuration: configuration)
    )
    let response = try OpenAIResponsesResponse(data: await httpClient.responseData(for: urlRequest))
    if !response.functionCalls.isEmpty {
      guard response.functionCalls.count == 1, let call = response.functionCalls.first else {
        throw AgentProviderError.invalidResponse
      }
      guard let data = call.arguments.data(using: .utf8),
            let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AgentProviderError.invalidToolArguments(call.name)
      }
      return AgentProviderDecision(
        action: try AgentToolCallParser.parse(toolName: call.name, arguments: arguments),
        model: response.model ?? configuration.model
      )
    }
    guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentProviderError.invalidResponse
    }
    return AgentProviderDecision(action: .askUser(question: String(response.text.prefix(1_000))),
                                 model: response.model ?? configuration.model)
  }

  private func requestBody(
    for request: AgentProviderRequest,
    configuration: AgentProviderConfiguration
  ) throws -> [String: Any] {
    var content: [[String: Any]] = [[
      "type": "input_text",
      "text": AgentLLMPromptBuilder.contextText(for: request, imageIncluded: configuration.sendsImages),
    ]]
    if configuration.sendsImages {
      guard let image = AgentProviderImageEncoder.dataURL(for: request.observation.screenshot) else {
        throw AgentProviderError.invalidResponse
      }
      content.append(["type": "input_image", "image_url": image, "detail": "high"])
    }
    var body: [String: Any] = [
      "model": configuration.model,
      "instructions": AgentLLMPromptBuilder.systemPrompt,
      "input": [["role": "user", "content": content]],
      "tools": AgentLLMToolCatalog.responsesToolDefinitions(),
      "tool_choice": "auto",
      "parallel_tool_calls": false,
      "max_output_tokens": configuration.thinkingEnabled ? 4_096 : 1_024,
      "store": false,
      "stream": false,
    ]
    if configuration.thinkingEnabled { body["reasoning"] = ["effort": "high"] }
    return body
  }
}

/// Parse the wire output items; SDK-only output_text convenience fields are not part of this contract.
nonisolated struct OpenAIResponsesResponse: Sendable {
  struct FunctionCall: Sendable {
    let callID: String
    let name: String
    let arguments: String
  }

  let model: String?
  let text: String
  let functionCalls: [FunctionCall]

  init(data: Data) throws {
    guard data.count <= 2_097_152,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AgentProviderError.invalidResponse
    }
    try self.init(object: root)
  }

  init(object: [String: Any]) throws {
    guard object["status"] as? String == "completed",
          object["error"] == nil || object["error"] is NSNull,
          let output = object["output"] as? [[String: Any]], !output.isEmpty else {
      throw AgentProviderError.invalidResponse
    }
    var texts: [String] = []
    var calls: [FunctionCall] = []
    for item in output {
      if let status = item["status"] as? String, status != "completed" {
        throw AgentProviderError.invalidResponse
      }
      switch item["type"] as? String {
      case "reasoning":
        continue
      case "function_call":
        guard let callID = item["call_id"] as? String, !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let name = item["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let arguments = item["arguments"] as? String else {
          throw AgentProviderError.invalidResponse
        }
        calls.append(FunctionCall(callID: callID, name: name, arguments: arguments))
      case "message":
        guard let content = item["content"] as? [[String: Any]] else {
          throw AgentProviderError.invalidResponse
        }
        for part in content {
          guard part["type"] as? String == "output_text", let value = part["text"] as? String else {
            // Refusals, unknown content and partial output must never become an action or translation.
            throw AgentProviderError.invalidResponse
          }
          texts.append(value)
        }
      default:
        throw AgentProviderError.invalidResponse
      }
    }
    model = object["model"] as? String
    text = texts.joined(separator: "\n")
    functionCalls = calls
    guard !calls.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentProviderError.invalidResponse
    }
  }
}
