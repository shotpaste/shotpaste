import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class OpenAIResponsesLLMProviderTests: XCTestCase {
  func testConfiguredPrivateIPv4EndpointsAreAcceptedAndPublicHTTPIsRejected() {
    for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.11"] {
      let value = configuration(endpoint: "http://\(host):8317/v1")
      XCTAssertNotNil(value.endpointURL)
      XCTAssertTrue(value.isLocalEndpoint)
    }
    for host in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "172.016.0.1", "192.169.1.1", "192.168.999.1", "169.254.1.1"] {
      XCTAssertNil(configuration(endpoint: "http://\(host)/v1").endpointURL)
    }
  }

  func testResponsesEndpointsAndProtocolSwitchKeepGatewayPrefix() {
    for (base, expected) in [
      ("https://example.com", "https://example.com/v1/responses"),
      ("https://example.com/v1/", "https://example.com/v1/responses"),
      ("https://example.com/gateway", "https://example.com/gateway/responses"),
      ("https://example.com/gateway/v1/chat/completions", "https://example.com/gateway/v1/responses"),
      ("https://example.com/gateway/v1/messages", "https://example.com/gateway/v1/responses"),
      ("https://example.com/gateway/v1/responses", "https://example.com/gateway/v1/responses"),
    ] {
      XCTAssertEqual(configuration(endpoint: base).endpointURL?.absoluteString, expected)
    }
    XCTAssertEqual(configuration(endpoint: "https://example.com/gateway/v1/responses", apiProtocol: .openAICompatible)
      .endpointURL?.absoluteString, "https://example.com/gateway/v1/chat/completions")
    XCTAssertEqual(configuration(endpoint: "https://example.com/gateway/v1/responses", apiProtocol: .anthropicMessages)
      .endpointURL?.absoluteString, "https://example.com/gateway/v1/messages")
    XCTAssertNil(configuration(endpoint: "http://example.com/v1").endpointURL)
    XCTAssertEqual(AgentProviderAPIProtocol.openAIResponses.rawValue, "responses")
    XCTAssertEqual(AgentProviderConfiguration.defaultEndpoint(for: .openAIResponses), AgentProviderConfiguration.defaultEndpoint)
    XCTAssertEqual(AgentProviderConfiguration.defaultModel(for: .openAIResponses), AgentProviderConfiguration.defaultModel)
    let values = AgentProviderConfiguration.connectionValues(
      switchingFrom: .openAICompatible, to: .openAIResponses, endpoint: "https://custom.example/v1", model: "custom-model"
    )
    XCTAssertEqual(values.endpoint, "https://custom.example/v1")
    XCTAssertEqual(values.model, "custom-model")
  }

  func testResponsesConfigurationLoadsFromDefaults() throws {
    let suiteName = "ResponsesConfiguration-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("responses", forKey: PreferencesKeys.agentProviderProtocol)
    defaults.set("https://gateway.example/v1", forKey: PreferencesKeys.agentProviderEndpoint)
    defaults.set("custom-model", forKey: PreferencesKeys.agentProviderModel)
    let value = AgentProviderConfiguration.current(defaults: defaults)
    XCTAssertEqual(value.apiProtocol, .openAIResponses)
    XCTAssertEqual(value.endpointURL?.absoluteString, "https://gateway.example/v1/responses")
    XCTAssertEqual(value.model, "custom-model")
  }

  func testRouterUsesResponsesVisionToolsAndStatelessRequest() async throws {
    let response = try responseData(output: [
      ["type": "reasoning", "summary": []],
      message("Companion text must not hide the tool"),
      call(name: "click", arguments: #"{"element_id":"ax:1"}"#),
    ])
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: response, url: try XCTUnwrap(request.url))
    }
    let provider = AgentConfigurableLLMProvider(responsesProvider: OpenAIResponsesLLMProvider(session: session))
    let decision = try await provider.nextAction(request: providerRequest(), configuration: configuration(sendsImages: true),
                                               apiKey: " synthetic-key ")
    guard case .click(let click) = decision.action else { return XCTFail("Expected a click action") }
    XCTAssertEqual(click.elementID, "ax:1")
    XCTAssertEqual(decision.model, "returned-model")
    let request = try XCTUnwrap(session.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
    let body = try requestBody(request)
    XCTAssertNil(body["messages"])
    XCTAssertNil(body["max_tokens"])
    XCTAssertNil(body["temperature"])
    XCTAssertEqual(body["store"] as? Bool, false)
    XCTAssertEqual(body["stream"] as? Bool, false)
    XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
    XCTAssertEqual(body["max_output_tokens"] as? Int, 4_096)
    XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
    XCTAssertEqual(content.map { $0["type"] as? String }, ["input_text", "input_image"])
    XCTAssertTrue((content.last?["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    XCTAssertEqual(content.last?["detail"] as? String, "high")
    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, AgentLLMToolCatalog.tools.count)
    let clickTool = try XCTUnwrap(tools.first { $0["name"] as? String == "click" })
    XCTAssertNil(clickTool["function"])
    XCTAssertEqual(clickTool["strict"] as? Bool, false)
    XCTAssertEqual((clickTool["parameters"] as? [String: Any])?["required"] as? [String], [])
  }

  func testTextOnlyRequestOmitsImagesAndDisabledThinking() async throws {
    let response = try responseData(output: [message("Which window?")])
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: response, url: try XCTUnwrap(request.url))
    }
    let decision = try await OpenAIResponsesLLMProvider(session: session).nextAction(
      request: providerRequest(), configuration: configuration(thinkingEnabled: false), apiKey: "synthetic-key"
    )
    XCTAssertEqual(decision.action, .askUser(question: "Which window?"))
    let body = try requestBody(XCTUnwrap(session.requests.first))
    let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 1)
    XCTAssertEqual(content.first?["type"] as? String, "input_text")
    XCTAssertNil(body["reasoning"])
    XCTAssertEqual(body["max_output_tokens"] as? Int, 1_024)
  }

  func testRejectedPartialRefusalAndMalformedOutputCannotBecomeAction() async throws {
    let cases: [[String: Any]] = [
      ["status": "failed", "output": [message("Partial")]],
      ["status": "incomplete", "output": [call(name: "click", arguments: #"{"element_id":"ax:1"}"#)]],
      ["status": "completed", "output": []],
      ["status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "No"]]]]],
      ["status": "completed", "output": [["type": "function_call", "name": "click", "arguments": "{}"]]],
      ["status": "completed", "output": [["type": "reasoning", "summary": []]], "output_text": "SDK shortcut"],
      ["status": "completed", "output": [message("")]],
      ["status": "completed", "output": [call(name: "wait", arguments: #"{"milliseconds":1}"#),
                                              call(name: "wait", arguments: #"{"milliseconds":2}"#)]],
    ]
    for object in cases {
      let data = try JSONSerialization.data(withJSONObject: object)
      let session = MockURLSession { request in
        MockURLSession.makeResponse(statusCode: 200, data: data, url: try XCTUnwrap(request.url))
      }
      do {
        _ = try await OpenAIResponsesLLMProvider(session: session).nextAction(
          request: providerRequest(), configuration: configuration(), apiKey: "synthetic-key"
        )
        XCTFail("Invalid output must fail")
      } catch { XCTAssertEqual(error as? AgentProviderError, .invalidResponse) }
    }
  }

  func testUnsupportedAndInvalidToolArgumentsKeepSharedValidation() async throws {
    for (name, arguments, expected) in [
      ("shell", "{}", AgentProviderError.unsupportedTool("shell")),
      ("click", "{}", .invalidToolArguments("click")),
      ("wait", "invalid-json", .invalidToolArguments("wait")),
    ] {
      let data = try responseData(output: [call(name: name, arguments: arguments)])
      let session = MockURLSession { request in
        MockURLSession.makeResponse(statusCode: 200, data: data, url: try XCTUnwrap(request.url))
      }
      do {
        _ = try await OpenAIResponsesLLMProvider(session: session).nextAction(
          request: providerRequest(), configuration: configuration(), apiKey: "synthetic-key"
        )
        XCTFail("Invalid tool must fail")
      } catch { XCTAssertEqual(error as? AgentProviderError, expected) }
    }
  }

  private func configuration(
    endpoint: String = "https://example.com/v1", thinkingEnabled: Bool = true,
    sendsImages: Bool = false, apiProtocol: AgentProviderAPIProtocol = .openAIResponses
  ) -> AgentProviderConfiguration {
    AgentProviderConfiguration(endpoint: endpoint, model: "responses-model", thinkingEnabled: thinkingEnabled,
                               sendsImages: sendsImages, maxActions: 30, apiProtocol: apiProtocol)
  }

  private func message(_ text: String) -> [String: Any] {
    ["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]
  }

  private func call(name: String, arguments: String) -> [String: Any] {
    ["type": "function_call", "call_id": "call_1", "name": name, "arguments": arguments]
  }

  private func responseData(output: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["status": "completed", "model": "returned-model", "output": output])
  }

  private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
  }

  private func providerRequest() throws -> AgentProviderRequest {
    let application = AgentApplicationContext(processIdentifier: 1, bundleIdentifier: "com.example.app",
                                             applicationName: "Example", windowTitle: "Window")
    let intent = AgentIntent(sessionID: UUID(), userText: "Click next", anchor: AgentNormalizedPoint(x: 0.5, y: 0.5),
                             displayID: 1, initialApplication: application, createdAt: Date())
    let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let observation = AgentObservation(id: UUID(), capturedAt: Date(),
      display: AgentDisplayContext(displayID: 1, logicalWidth: 100, logicalHeight: 100, pixelWidth: 200, pixelHeight: 200, scaleFactor: 2),
      application: application, anchor: intent.anchor, accessibilityElements: [], ocrLines: [], screenshot: try XCTUnwrap(context.makeImage()))
    return AgentProviderRequest(intent: intent, observation: observation, auditTrail: [])
  }
}
