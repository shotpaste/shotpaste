//
//  AnthropicMessagesLLMProviderTests.swift
//  ShotPasteTests
//

import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class AnthropicMessagesLLMProviderTests: XCTestCase {
  // MARK: - 端点路径解析

  func testAnthropicEndpointResolvesMessagesPath() {
    // 裸域名、版本段、任意网关前缀和完整路径都规范到 Messages 端点。
    XCTAssertEqual(
      configuration(endpoint: "https://api.anthropic.com").endpointURL?.absoluteString,
      "https://api.anthropic.com/v1/messages"
    )
    XCTAssertEqual(
      configuration(endpoint: "https://api.pateway.ai/v1").endpointURL?.absoluteString,
      "https://api.pateway.ai/v1/messages"
    )
    XCTAssertEqual(
      configuration(endpoint: "https://gw.example.com/v1/messages").endpointURL?.absoluteString,
      "https://gw.example.com/v1/messages"
    )
    XCTAssertEqual(
      configuration(endpoint: "https://api.kimi.com/coding/").endpointURL?.absoluteString,
      "https://api.kimi.com/coding/v1/messages"
    )
    XCTAssertEqual(
      configuration(endpoint: "https://api.kimi.com/coding/v1").endpointURL?.absoluteString,
      "https://api.kimi.com/coding/v1/messages"
    )
    XCTAssertEqual(
      configuration(endpoint: "https://api.kimi.com/coding/v1/messages").endpointURL?.absoluteString,
      "https://api.kimi.com/coding/v1/messages"
    )
    XCTAssertEqual(
      configuration(endpoint: "https://gw.example.com/coding/v1/chat/completions").endpointURL?.absoluteString,
      "https://gw.example.com/coding/v1/messages"
    )
    XCTAssertTrue(configuration(endpoint: "http://localhost:8787").isValid)
    XCTAssertNil(configuration(endpoint: "http://example.com/v1").endpointURL)
  }

  func testDefaultEndpointForProtocolMatchesPickerPlaceholder() {
    XCTAssertEqual(
      AgentProviderConfiguration.defaultEndpoint(for: .openAICompatible),
      AgentProviderConfiguration.defaultEndpoint
    )
    XCTAssertEqual(
      AgentProviderConfiguration.defaultEndpoint(for: .anthropicMessages),
      "https://api.anthropic.com"
    )
    XCTAssertEqual(
      AgentProviderConfiguration.defaultModel(for: .openAICompatible),
      AgentProviderConfiguration.defaultModel
    )
    XCTAssertEqual(
      AgentProviderConfiguration.defaultModel(for: .anthropicMessages),
      "claude-sonnet-5"
    )
  }

  // MARK: - 请求构建

  func testTextOnlyRequestUsesMessagesShapeAndAuthHeaders() async throws {
    let responseData = toolUseResponse(
      name: "click",
      input: ["element_id": "ax:1", "button": "left", "click_count": 1],
      model: "model-baize[1M]"
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://api.pateway.ai/v1",
      model: "model-baize[1M]",
      thinkingEnabled: false,
      sendsImages: false,
      maxActions: 30,
      apiProtocol: .anthropicMessages
    )

    let decision = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration,
      apiKey: "test-key-not-secret"
    )

    guard case .click(let click) = decision.action else {
      return XCTFail("Expected a click tool decision")
    }
    XCTAssertEqual(click.elementID, "ax:1")
    XCTAssertEqual(click.button, .left)
    XCTAssertEqual(decision.model, "model-baize[1M]")

    let request = try XCTUnwrap(session.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.pateway.ai/v1/messages")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key-not-secret")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization"),
      "Bearer test-key-not-secret"
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "anthropic-version"),
      "2023-06-01"
    )

    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "model-baize[1M]")
    XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
    let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "disabled")
    XCTAssertNil(body["output_config"])
    let toolChoice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
    XCTAssertEqual(toolChoice["type"] as? String, "auto")
    XCTAssertEqual(toolChoice["disable_parallel_tool_use"] as? Bool, true)
    let system = try XCTUnwrap(body["system"] as? String)
    XCTAssertTrue(system.contains("planning model for ShotPaste Agent Mode"))
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?["role"] as? String, "user")
    let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 1)
    XCTAssertEqual(content.first?["type"] as? String, "text")
    let text = try XCTUnwrap(content.first?["text"] as? String)
    XCTAssertTrue(text.contains("local OCR and Accessibility context"))
    XCTAssertFalse(text.contains("data:image"))
    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, 9)
    // Anthropic tools 是平铺结构：name + input_schema，无 function 包装。
    let clickTool = try XCTUnwrap(tools.first { $0["name"] as? String == "click" })
    XCTAssertNil(clickTool["function"])
    let schema = try XCTUnwrap(clickTool["input_schema"] as? [String: Any])
    XCTAssertEqual(schema["type"] as? String, "object")
    XCTAssertNotNil(schema["properties"] as? [String: Any])
  }

  func testVisionRequestAttachesBase64ImageSource() async throws {
    let responseData = toolUseResponse(name: "report_complete", input: ["summary": "Done"])
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://api.anthropic.com",
      model: "claude-model",
      thinkingEnabled: false,
      sendsImages: true,
      maxActions: 10,
      apiProtocol: .anthropicMessages
    )

    _ = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration,
      apiKey: "test-key-not-secret"
    )

    let request = try XCTUnwrap(session.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
    XCTAssertEqual(content.count, 2)
    let imageBlock = try XCTUnwrap(content.last)
    XCTAssertEqual(imageBlock["type"] as? String, "image")
    let source = try XCTUnwrap(imageBlock["source"] as? [String: Any])
    XCTAssertEqual(source["type"] as? String, "base64")
    XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
    let data = try XCTUnwrap(source["data"] as? String)
    XCTAssertFalse(data.hasPrefix("data:"))
    XCTAssertTrue((userText(content) ?? "").contains("It contains no ShotPaste annotation UI"))
  }

  func testThinkingEnabledUsesAdaptiveThinkingAndHighEffort() async throws {
    let responseData = toolUseResponse(name: "report_complete", input: ["summary": "Done"])
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://api.anthropic.com",
      model: "claude-model",
      thinkingEnabled: true,
      sendsImages: false,
      maxActions: 10,
      apiProtocol: .anthropicMessages
    )

    _ = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration,
      apiKey: "test-key-not-secret"
    )

    let request = try XCTUnwrap(session.requests.first)
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
    let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "adaptive")
    XCTAssertNil(thinking["budget_tokens"])
    let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
    XCTAssertEqual(outputConfig["effort"] as? String, "high")
  }

  func testExplicitAdaptiveRejectionRetriesOnceWithLegacyThinking() async throws {
    let attempts = AttemptCounter()
    let responseData = toolUseResponse(name: "report_complete", input: ["summary": "Done"])
    let session = MockURLSession { request in
      let attempt = await attempts.next()
      if attempt == 1 {
        return MockURLSession.makeResponse(
          statusCode: 400,
          data: Data(
            #"{"error":{"message":"thinking.type adaptive is not supported by this gateway"}}"#.utf8
          ),
          url: request.url!
        )
      }
      return MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://gateway.example.com",
      model: "legacy-model",
      thinkingEnabled: true,
      sendsImages: false,
      maxActions: 10,
      apiProtocol: .anthropicMessages
    )

    let decision = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration,
      apiKey: "test-key-not-secret"
    )

    XCTAssertEqual(decision.action, .complete(summary: "Done"))
    XCTAssertEqual(session.requests.count, 2)
    let firstBody = try requestBody(session.requests[0])
    XCTAssertEqual(
      (firstBody["thinking"] as? [String: Any])?["type"] as? String,
      "adaptive"
    )
    let secondBody = try requestBody(session.requests[1])
    let legacyThinking = try XCTUnwrap(secondBody["thinking"] as? [String: Any])
    XCTAssertEqual(legacyThinking["type"] as? String, "enabled")
    XCTAssertEqual(legacyThinking["budget_tokens"] as? Int, 1_024)
    XCTAssertNil(secondBody["output_config"])
  }

  func testOrdinaryBadRequestDoesNotRetryWithLegacyThinking() async throws {
    let session = MockURLSession { request in
      MockURLSession.makeResponse(
        statusCode: 400,
        data: Data(#"{"error":{"message":"messages must not be empty"}}"#.utf8),
        url: request.url!
      )
    }
    let provider = AnthropicMessagesLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://api.anthropic.com",
      model: "claude-model",
      thinkingEnabled: true,
      sendsImages: false,
      maxActions: 10,
      apiProtocol: .anthropicMessages
    )

    do {
      _ = try await provider.nextAction(
        request: try providerRequest(),
        configuration: configuration,
        apiKey: "test-key-not-secret"
      )
      XCTFail("Expected the original bad request to be returned")
    } catch {
      XCTAssertEqual(
        error as? AgentProviderError,
        .unsuccessfulStatusCode(400, "messages must not be empty")
      )
      XCTAssertEqual(session.requests.count, 1)
    }
  }

  // MARK: - 响应解析

  func testThinkingBlocksAreIgnoredAndTextFallsBackToAskUser() async throws {
    let responseData = Data(
      #"{"model":"claude-model","content":[{"type":"thinking","thinking":"internal reasoning"},{"type":"text","text":"Which file should I open?"}],"stop_reason":"end_turn"}"#
        .utf8
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)

    let decision = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration(endpoint: "https://api.anthropic.com"),
      apiKey: "test-key-not-secret"
    )

    XCTAssertEqual(decision.action, .askUser(question: "Which file should I open?"))
    XCTAssertEqual(decision.model, "claude-model")
  }

  func testMultipleToolUseBlocksAreRejected() async throws {
    let responseData = Data(
      #"{"model":"claude-model","content":[{"type":"tool_use","id":"toolu_1","name":"click","input":{"element_id":"ax:1"}},{"type":"tool_use","id":"toolu_2","name":"report_complete","input":{"summary":"Done"}}],"stop_reason":"tool_use"}"#
        .utf8
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)

    do {
      _ = try await provider.nextAction(
        request: try providerRequest(),
        configuration: configuration(endpoint: "https://api.anthropic.com"),
        apiKey: "test-key-not-secret"
      )
      XCTFail("Expected multiple tool calls to be rejected")
    } catch {
      XCTAssertEqual(error as? AgentProviderError, .invalidResponse)
    }
  }

  func testMissingAPIKeyFailsBeforeNetworkingForRemoteEndpoints() async {
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: Data(), url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session)

    do {
      _ = try await provider.nextAction(
        request: try providerRequest(),
        configuration: configuration(endpoint: "https://api.anthropic.com"),
        apiKey: nil
      )
      XCTFail("Expected missingAPIKey")
    } catch {
      XCTAssertEqual(error as? AgentProviderError, .missingAPIKey)
      XCTAssertTrue(session.requests.isEmpty)
    }
  }

  func testTransientRateLimitRetriesThenReturnsToolDecision() async throws {
    let attempts = AttemptCounter()
    let responseData = toolUseResponse(name: "report_complete", input: ["summary": "Recovered"])
    let session = MockURLSession { request in
      let attempt = await attempts.next()
      if attempt == 1 {
        return MockURLSession.makeResponse(
          statusCode: 429,
          data: Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Busy"}}"#.utf8),
          url: request.url!
        )
      }
      return MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = AnthropicMessagesLLMProvider(session: session, retryDelaysNanoseconds: [0])

    let decision = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration(endpoint: "https://api.anthropic.com"),
      apiKey: "test-key-not-secret"
    )

    XCTAssertEqual(decision.action, .complete(summary: "Recovered"))
    XCTAssertEqual(session.requests.count, 2)
  }

  // MARK: - 协议偏好与分发

  func testProtocolPreferenceRoundTripsThroughDefaults() throws {
    let suiteName = "AnthropicMessagesLLMProviderTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(AgentProviderConfiguration.current(defaults: defaults).apiProtocol, .openAICompatible)

    defaults.set("anthropic", forKey: PreferencesKeys.agentProviderProtocol)
    let configuration = AgentProviderConfiguration.current(defaults: defaults)
    XCTAssertEqual(configuration.apiProtocol, .anthropicMessages)
    XCTAssertEqual(configuration.endpoint, AgentProviderConfiguration.defaultAnthropicEndpoint)
    XCTAssertEqual(configuration.model, AgentProviderConfiguration.defaultAnthropicModel)

    // 未知值回落到默认协议，端点路径仍按 OpenAI 解析。
    defaults.set("bogus", forKey: PreferencesKeys.agentProviderProtocol)
    XCTAssertEqual(AgentProviderConfiguration.current(defaults: defaults).apiProtocol, .openAICompatible)
  }

  func testProtocolSwitchMigratesOnlyKnownDefaults() {
    let migrated = AgentProviderConfiguration.connectionValues(
      switchingFrom: .openAICompatible,
      to: .anthropicMessages,
      endpoint: AgentProviderConfiguration.defaultEndpoint,
      model: AgentProviderConfiguration.defaultModel
    )
    XCTAssertEqual(migrated.endpoint, AgentProviderConfiguration.defaultAnthropicEndpoint)
    XCTAssertEqual(migrated.model, AgentProviderConfiguration.defaultAnthropicModel)

    let custom = AgentProviderConfiguration.connectionValues(
      switchingFrom: .openAICompatible,
      to: .anthropicMessages,
      endpoint: "https://gateway.example.com/team",
      model: "team-model"
    )
    XCTAssertEqual(custom.endpoint, "https://gateway.example.com/team")
    XCTAssertEqual(custom.model, "team-model")

    let independentlyMigrated = AgentProviderConfiguration.connectionValues(
      switchingFrom: .anthropicMessages,
      to: .openAICompatible,
      endpoint: "https://gateway.example.com/team",
      model: AgentProviderConfiguration.defaultAnthropicModel
    )
    XCTAssertEqual(independentlyMigrated.endpoint, "https://gateway.example.com/team")
    XCTAssertEqual(independentlyMigrated.model, AgentProviderConfiguration.defaultModel)
  }

  func testCurrentConfigurationRepairsOnlyACompleteStaleDefaultPair() throws {
    let suiteName = "AnthropicStaleDefaultsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("anthropic", forKey: PreferencesKeys.agentProviderProtocol)
    defaults.set(
      AgentProviderConfiguration.defaultEndpoint,
      forKey: PreferencesKeys.agentProviderEndpoint
    )
    defaults.set(
      AgentProviderConfiguration.defaultModel,
      forKey: PreferencesKeys.agentProviderModel
    )

    var configuration = AgentProviderConfiguration.current(defaults: defaults)
    XCTAssertEqual(configuration.endpoint, AgentProviderConfiguration.defaultAnthropicEndpoint)
    XCTAssertEqual(configuration.model, AgentProviderConfiguration.defaultAnthropicModel)

    defaults.set("https://gateway.example.com/team", forKey: PreferencesKeys.agentProviderEndpoint)
    configuration = AgentProviderConfiguration.current(defaults: defaults)
    XCTAssertEqual(configuration.endpoint, "https://gateway.example.com/team")
    XCTAssertEqual(configuration.model, AgentProviderConfiguration.defaultModel)
  }

  func testConfigurableProviderDispatchesByConfiguredProtocol() async throws {
    let openAISession = MockURLSession { request in
      MockURLSession.makeResponse(
        statusCode: 200,
        data: Data(
          #"{"model":"gpt-model","choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"report_complete","arguments":"{\"summary\":\"openai\"}"}}]}}]}"#
            .utf8
        ),
        url: request.url!
      )
    }
    let anthropicResponseData = toolUseResponse(
      name: "report_complete",
      input: ["summary": "anthropic"]
    )
    let anthropicSession = MockURLSession { request in
      MockURLSession.makeResponse(
        statusCode: 200,
        data: anthropicResponseData,
        url: request.url!
      )
    }
    let provider = AgentConfigurableLLMProvider(
      openAIProvider: OpenAICompatibleLLMProvider(session: openAISession),
      anthropicProvider: AnthropicMessagesLLMProvider(session: anthropicSession)
    )
    let request = try providerRequest()

    let openAIDecision = try await provider.nextAction(
      request: request,
      configuration: configuration(
        endpoint: "https://openai.example.com",
        apiProtocol: .openAICompatible
      ),
      apiKey: "test-key-not-secret"
    )
    XCTAssertEqual(openAIDecision.action, .complete(summary: "openai"))
    XCTAssertTrue(anthropicSession.requests.isEmpty)

    let anthropicDecision = try await provider.nextAction(
      request: request,
      configuration: configuration(
        endpoint: "https://api.anthropic.com",
        apiProtocol: .anthropicMessages
      ),
      apiKey: "test-key-not-secret"
    )
    XCTAssertEqual(anthropicDecision.action, .complete(summary: "anthropic"))
    XCTAssertEqual(openAISession.requests.count, 1)
    XCTAssertEqual(
      anthropicSession.requests.first?.url?.absoluteString,
      "https://api.anthropic.com/v1/messages"
    )
  }

  // MARK: - TOML 导入

  func testImportAppliesAgentAPIProtocolAndRejectsUnknownValues() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [agent]
    api_protocol = "anthropic"
    """
    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)
    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderProtocol),
      "anthropic"
    )
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderEndpoint),
      AgentProviderConfiguration.defaultAnthropicEndpoint
    )
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderModel),
      AgentProviderConfiguration.defaultAnthropicModel
    )

    let invalidDefaults = UserDefaultsFactory.make()
    let invalidSource = """
    schema_version = 1

    [agent]
    api_protocol = "grpc"
    """
    let invalidResult = ShotPasteConfigurationImporter.importTOML(
      invalidSource,
      defaults: invalidDefaults
    )
    XCTAssertTrue(invalidResult.hasErrors)
    XCTAssertNil(invalidDefaults.string(forKey: PreferencesKeys.agentProviderProtocol))
  }

  func testImportProtocolPreservesExplicitCustomConnectionValues() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [agent]
    endpoint = "https://api.kimi.com/coding/"
    model = "k3"
    api_protocol = "anthropic"
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderEndpoint),
      "https://api.kimi.com/coding/"
    )
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.agentProviderModel), "k3")
    XCTAssertEqual(
      AgentProviderConfiguration.current(defaults: defaults).endpointURL?.absoluteString,
      "https://api.kimi.com/coding/v1/messages"
    )
  }

  func testImportTreatsExplicitKnownDefaultsAsAuthoritative() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [agent]
    endpoint = "\(AgentProviderConfiguration.defaultEndpoint)"
    model = "\(AgentProviderConfiguration.defaultModel)"
    api_protocol = "anthropic"
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderEndpoint),
      AgentProviderConfiguration.defaultEndpoint
    )
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderModel),
      AgentProviderConfiguration.defaultModel
    )
  }

  // MARK: - Helpers

  private func configuration(
    endpoint: String,
    apiProtocol: AgentProviderAPIProtocol = .anthropicMessages
  ) -> AgentProviderConfiguration {
    AgentProviderConfiguration(
      endpoint: endpoint,
      model: "claude-model",
      thinkingEnabled: false,
      sendsImages: false,
      maxActions: 10,
      apiProtocol: apiProtocol
    )
  }

  private func toolUseResponse(
    name: String,
    input: [String: Any],
    model: String = "claude-model"
  ) -> Data {
    let arguments = String(
      data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(),
      encoding: .utf8
    ) ?? "{}"
    return Data(
      #"{"model":"\#(model)","content":[{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":\#(arguments)}],"stop_reason":"tool_use"}"#
        .utf8
    )
  }

  private func userText(_ content: [[String: Any]]) -> String? {
    content.first { $0["type"] as? String == "text" }?["text"] as? String
  }

  private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func providerRequest() throws -> AgentProviderRequest {
    let application = AgentApplicationContext(
      processIdentifier: 1,
      bundleIdentifier: "com.example.app",
      applicationName: "Example",
      windowTitle: "Window"
    )
    let intent = AgentIntent(
      sessionID: UUID(),
      userText: "Click the next button",
      anchor: AgentNormalizedPoint(x: 0.5, y: 0.5),
      displayID: 1,
      initialApplication: application,
      createdAt: Date()
    )
    let observation = AgentObservation(
      id: UUID(),
      capturedAt: Date(),
      display: AgentDisplayContext(
        displayID: 1,
        logicalWidth: 100,
        logicalHeight: 100,
        pixelWidth: 200,
        pixelHeight: 200,
        scaleFactor: 2
      ),
      application: application,
      anchor: intent.anchor,
      accessibilityElements: [
        AgentAccessibilityElementSnapshot(
          id: "ax:1",
          role: "AXButton",
          subrole: nil,
          title: "Next",
          elementDescription: nil,
          value: nil,
          enabled: true,
          focused: false,
          normalizedFrame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1),
          isSecure: false
        ),
      ],
      ocrLines: [],
      screenshot: try makeImage()
    )
    return AgentProviderRequest(intent: intent, observation: observation, auditTrail: [])
  }

  private func makeImage() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try XCTUnwrap(context.makeImage())
  }
}

private actor AttemptCounter {
  private var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}
