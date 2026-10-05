import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class LLMConnectionTesterTests: XCTestCase {
  func testAllProtocolsSendOnlyFixedTextAndValidateInference() async throws {
    for apiProtocol in AgentProviderAPIProtocol.allCases {
      let session = MockURLSession { request in
        MockURLSession.makeResponse(statusCode: 200, data: Self.response(for: apiProtocol), url: request.url!)
      }
      try await LLMConnectionTester(session: session).test(configuration: configuration(apiProtocol),
                                                          apiKey: "test-key")
      XCTAssertEqual(session.requests.count, 1)
      let request = try XCTUnwrap(session.requests.first)
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, "test-model")
      XCTAssertEqual(body["stream"] as? Bool, false)
      XCTAssertNil(body["tools"])
      XCTAssertNil(body["thinking"])
      XCTAssertNil(body["temperature"])
      XCTAssertEqual(request.timeoutInterval, 15)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
      let messages = try XCTUnwrap(body[apiProtocol == .openAIResponses ? "input" : "messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 1)
      XCTAssertEqual(messages.first?["content"] as? String, LLMConnectionTester.prompt)
      if apiProtocol == .openAIResponses {
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertTrue(request.url!.path.hasSuffix("/responses"))
      } else if apiProtocol == .anthropicMessages {
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      }
    }
  }

  func testInvalidConfigurationAndMissingKeyDoNotSendRequests() async {
    let session = MockURLSession { _ in throw URLError(.badURL) }
    await assertFailure(.invalidConfiguration, tester: LLMConnectionTester(session: session),
                        configuration: configuration(.openAIResponses, endpoint: "http://public.example/v1"))
    await assertFailure(.missingKey, tester: LLMConnectionTester(session: session),
                        configuration: configuration(.openAIResponses), apiKey: nil)
    XCTAssertTrue(session.requests.isEmpty)
  }

  func testHTTPFailuresAreClassifiedWithoutRetryOrResponseBody() async {
    for (status, expected) in [(401, LLMConnectionTestError.authenticationFailed), (403, .authenticationFailed),
                               (429, .rateLimited), (408, .timedOut), (504, .timedOut), (500, .providerFailed)] {
      let session = MockURLSession { request in
        MockURLSession.makeResponse(statusCode: status, data: Data("echoed-secret".utf8), url: request.url!)
      }
      await assertFailure(expected, tester: LLMConnectionTester(session: session))
      XCTAssertEqual(session.requests.count, 1)
    }
  }

  func testEmptyMalformedAndUnfinishedResponsesNeverReportSuccess() async {
    let fixtures: [AgentProviderAPIProtocol: [String]] = [
      .openAICompatible: ["{}", #"{"choices":[{"message":{"content":"  "}}]}"#,
                          #"{"choices":[{"finish_reason":"tool_calls","message":{"content":"OK","tool_calls":[{}]}}]}"#,
                          #"{"choices":[{"finish_reason":"length","message":{"content":"OK"}}]}"#],
      .openAIResponses: [#"{"status":"incomplete","output":[]}"#,
                         #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}"#],
      .anthropicMessages: [#"{"content":[]}"#,
                           #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"OK"}]}"#],
    ]
    for (apiProtocol, bodies) in fixtures {
      for body in bodies {
        let session = MockURLSession { request in
          MockURLSession.makeResponse(statusCode: 200, data: Data(body.utf8), url: request.url!)
        }
        await assertFailure(.invalidResponse, tester: LLMConnectionTester(session: session),
                            configuration: configuration(apiProtocol))
      }
    }
  }

  func testDeadlineCancelsTheRequestAndDoesNotRetry() async {
    let session = MockURLSession { _ in
      try await Task.sleep(nanoseconds: 2_000_000_000)
      throw URLError(.timedOut)
    }
    let started = Date()
    await assertFailure(.timedOut, tester: LLMConnectionTester(session: session, timeoutSeconds: 0.03))
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    XCTAssertEqual(session.requests.count, 1)
  }

  func testTransportErrorsUseFixedCategories() async {
    for (code, expected) in [(URLError.Code.timedOut, LLMConnectionTestError.timedOut),
                              (.cannotConnectToHost, .networkFailed), (.cancelled, .networkFailed)] {
      let session = MockURLSession { _ in throw URLError(code) }
      await assertFailure(expected, tester: LLMConnectionTester(session: session))
      XCTAssertEqual(session.requests.count, 1)
    }
  }

  func testCallerCancellationIsPreserved() async {
    let session = MockURLSession { _ in
      try await Task.sleep(nanoseconds: 2_000_000_000)
      throw URLError(.cancelled)
    }
    let config = configuration(.openAIResponses)
    let task = Task { try await LLMConnectionTester(session: session).test(configuration: config, apiKey: "test-key") }
    await Task.yield()
    task.cancel()
    do {
      try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  private func assertFailure(_ expected: LLMConnectionTestError, tester: LLMConnectionTester,
                             configuration: AgentProviderConfiguration? = nil, apiKey: String? = "test-key") async {
    do {
      try await tester.test(configuration: configuration ?? self.configuration(.openAIResponses), apiKey: apiKey)
      XCTFail("Expected \(expected)")
    } catch {
      XCTAssertEqual(error as? LLMConnectionTestError, expected)
    }
  }

  private func configuration(_ apiProtocol: AgentProviderAPIProtocol,
                             endpoint: String = "https://provider.example/v1") -> AgentProviderConfiguration {
    AgentProviderConfiguration(endpoint: endpoint, model: "test-model", thinkingEnabled: true,
                               sendsImages: true, maxActions: 30, apiProtocol: apiProtocol)
  }

  nonisolated private static func response(for apiProtocol: AgentProviderAPIProtocol) -> Data {
    let body: String
    switch apiProtocol {
    case .openAICompatible: body = #"{"choices":[{"message":{"content":"OK"}}]}"#
    case .openAIResponses: body = #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"OK"}]}]}"#
    case .anthropicMessages: body = #"{"content":[{"type":"text","text":"OK"}]}"#
    }
    return Data(body.utf8)
  }
}
