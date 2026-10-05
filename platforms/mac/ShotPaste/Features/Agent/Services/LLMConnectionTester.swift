import Foundation

/// A single, text-only inference request. Never uses observations or user content.
nonisolated struct LLMConnectionTester: Sendable {
  static let prompt = "Reply with OK only."
  private static let defaultSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration, delegate: LLMConnectionTestRedirectDelegate(), delegateQueue: nil)
  }()
  private let session: any URLSessionProtocol
  private let timeoutSeconds: TimeInterval

  init(session: (any URLSessionProtocol)? = nil, timeoutSeconds: TimeInterval = 15) {
    self.session = session ?? Self.defaultSession
    self.timeoutSeconds = timeoutSeconds
  }

  func test(configuration: AgentProviderConfiguration, apiKey: String?) async throws {
    guard configuration.isValid, let url = configuration.endpointURL else {
      throw LLMConnectionTestError.invalidConfiguration
    }
    let key = AgentCredentialStore.normalizedKey(apiKey)
    guard configuration.isLocalEndpoint || key != nil else {
      throw LLMConnectionTestError.missingKey
    }
    try Task.checkCancellation()
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: timeoutSeconds)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("ShotPaste-LLMConnectionTest/1", forHTTPHeaderField: "User-Agent")
    if let key {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      if configuration.apiProtocol == .anthropicMessages {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
      }
    }
    if configuration.apiProtocol == .anthropicMessages {
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }
    let message: [String: Any] = ["role": "user", "content": Self.prompt]
    var body: [String: Any] = ["model": configuration.model, "stream": false]
    switch configuration.apiProtocol {
    case .openAICompatible:
      body["messages"] = [message]
    case .openAIResponses:
      body["input"] = [message]
      body["store"] = false
      body["max_output_tokens"] = 512
    case .anthropicMessages:
      body["messages"] = [message]
      body["max_tokens"] = 32
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let outgoingRequest = request
    let session = session
    let timeout = timeoutSeconds
    do {
      let data = try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
          let (data, response) = try await session.data(for: outgoingRequest)
          try Task.checkCancellation()
          guard let http = response as? HTTPURLResponse else {
            throw LLMConnectionTestError.invalidResponse
          }
          switch http.statusCode {
          case 200..<300: break
          case 401, 403: throw LLMConnectionTestError.authenticationFailed
          case 408, 504: throw LLMConnectionTestError.timedOut
          case 429: throw LLMConnectionTestError.rateLimited
          default: throw LLMConnectionTestError.providerFailed
          }
          guard data.count <= 65_536 else { throw LLMConnectionTestError.invalidResponse }
          return data
        }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000))
          throw LLMConnectionTestError.timedOut
        }
        defer { group.cancelAll() }
        guard let data = try await group.next() else { throw LLMConnectionTestError.invalidResponse }
        return data
      }
      try Task.checkCancellation()
      try Self.validateResponse(data, apiProtocol: configuration.apiProtocol)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as LLMConnectionTestError {
      throw error
    } catch let error as URLError {
      if Task.isCancelled { throw CancellationError() }
      throw error.code == .timedOut ? LLMConnectionTestError.timedOut : .networkFailed
    } catch {
      throw LLMConnectionTestError.networkFailed
    }
  }

  private static func validateResponse(_ data: Data, apiProtocol: AgentProviderAPIProtocol) throws {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          root["error"] == nil || root["error"] is NSNull else {
      throw LLMConnectionTestError.invalidResponse
    }
    let text: String
    switch apiProtocol {
    case .openAICompatible:
      guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first,
            choice["finish_reason"] == nil || choice["finish_reason"] as? String == "stop",
            let message = choice["message"] as? [String: Any],
            message["refusal"] == nil || message["refusal"] is NSNull,
            message["function_call"] == nil || message["function_call"] is NSNull,
            message["tool_calls"] == nil || message["tool_calls"] is NSNull
              || (message["tool_calls"] as? [[String: Any]])?.isEmpty == true,
            let content = message["content"] as? String else {
        throw LLMConnectionTestError.invalidResponse
      }
      text = content
    case .openAIResponses:
      guard let response = try? OpenAIResponsesResponse(object: root),
            response.functionCalls.isEmpty else {
        throw LLMConnectionTestError.invalidResponse
      }
      text = response.text
    case .anthropicMessages:
      guard root["stop_reason"] as? String != "max_tokens",
            let content = root["content"] as? [[String: Any]],
            content.allSatisfy({ $0["type"] as? String == "text" }) else {
        throw LLMConnectionTestError.invalidResponse
      }
      text = content.compactMap { $0["text"] as? String }.joined()
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LLMConnectionTestError.invalidResponse
    }
  }
}

private final nonisolated class LLMConnectionTestRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Only fixed categories reach the UI; upstream response bodies stay private.
nonisolated enum LLMConnectionTestError: Error, Equatable, Sendable {
  case invalidConfiguration, missingKey, authenticationFailed, rateLimited
  case timedOut, networkFailed, invalidResponse, providerFailed
}
