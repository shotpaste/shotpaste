//
//  OpenAICompatibleLLMProviderTests.swift
//  ShotPasteTests
//

import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class OpenAICompatibleLLMProviderTests: XCTestCase {
  func testCredentialStorePersistsDirectlyAndMasksStoredToken() throws {
    let suiteName = "AgentCredentialStoreTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AgentCredentialStore(
      defaults: defaults,
      environment: {
        ["SHOTPASTE_LLM_API_KEY": "test-generic-key"]
      }
    )

    XCTAssertEqual(try store.resolvedAPIKey(), "test-generic-key")
    XCTAssertEqual(AgentCredentialStore.environmentVariableName, "SHOTPASTE_LLM_API_KEY")

    try store.saveAPIKey("sk-direct-preferences-1234")

    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentProviderAPIKey),
      "sk-direct-preferences-1234"
    )
    XCTAssertEqual(try store.resolvedAPIKey(), "sk-direct-preferences-1234")
    XCTAssertEqual(store.maskedStoredAPIKey(), "sk-••••••1234")

    store.deleteAPIKey()

    XCTAssertNil(defaults.string(forKey: PreferencesKeys.agentProviderAPIKey))
    XCTAssertNil(store.maskedStoredAPIKey())
    XCTAssertEqual(try store.resolvedAPIKey(), "test-generic-key")
  }

  func testCredentialMaskNeverReturnsShortTokenCharacters() {
    XCTAssertEqual(AgentCredentialStore.maskedKey("abcd"), "••••")
    XCTAssertNil(AgentCredentialStore.maskedKey(" abc def "))
    XCTAssertNil(AgentCredentialStore.maskedKey("   "))
  }

  func testCredentialStoreFallsBackToLocalDefaultToken() throws {
    let suiteName = "AgentCredentialStoreDefaultTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AgentCredentialStore(defaults: defaults, environment: { [:] })

    XCTAssertEqual(try store.resolvedAPIKey(), "123456")
    XCTAssertNil(store.maskedStoredAPIKey())
  }

  func testTextOnlyRequestUsesConfiguredModelAndToolCalling() async throws {
    let responseData = Data(
      #"{"model":"gpt-5.6-luna","choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"click","arguments":"{\"element_id\":\"ax:1\",\"button\":\"left\",\"click_count\":1}"}}]}}]}"#
        .utf8
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = OpenAICompatibleLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: AgentProviderConfiguration.defaultEndpoint,
      model: AgentProviderConfiguration.defaultModel,
      thinkingEnabled: true,
      sendsImages: false,
      maxActions: 30
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
    XCTAssertEqual(decision.model, "gpt-5.6-luna")

    let request = try XCTUnwrap(session.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "http://192.168.31.67:8317/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-not-secret")
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let userContent = try XCTUnwrap(messages.last?["content"] as? String)
    XCTAssertTrue(userContent.contains("local OCR and Accessibility context"))
    XCTAssertFalse(userContent.contains("data:image"))
    XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, 9)
  }

  func testEndpointValidationAllowsHTTPSAndLocalHTTPOnly() {
    XCTAssertTrue(configuration(endpoint: "https://example.com/v1/chat/completions").isValid)
    XCTAssertTrue(configuration(endpoint: "http://localhost:11434/v1").isValid)
    XCTAssertTrue(configuration(endpoint: "http://192.168.31.67:8317/v1").isValid)
    XCTAssertEqual(
      configuration(endpoint: "http://localhost:11434/v1").endpointURL?.absoluteString,
      "http://localhost:11434/v1/chat/completions"
    )
    XCTAssertFalse(configuration(endpoint: "http://example.com/v1").isValid)
    XCTAssertFalse(configuration(endpoint: "http://192.168.31.68:8317/v1").isValid)
    XCTAssertFalse(configuration(endpoint: "https://user:secret@example.com/v1").isValid)
    XCTAssertFalse(configuration(endpoint: "file:///tmp/provider").isValid)
  }

  func testDefaultConfigurationUsesCustomGatewayModelAndVision() throws {
    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: "OpenAICompatibleLLMProviderTests-\(UUID().uuidString)")
    )
    let configuration = AgentProviderConfiguration.current(defaults: defaults)

    XCTAssertEqual(configuration.endpoint, "http://192.168.31.67:8317/v1")
    XCTAssertEqual(
      configuration.endpointURL?.absoluteString,
      "http://192.168.31.67:8317/v1/chat/completions"
    )
    XCTAssertEqual(configuration.model, "gpt-5.6-luna")
    XCTAssertTrue(configuration.sendsImages)
  }

  func testCurrentConfigurationMigratesPreviousKnownDefaultPair() throws {
    let suiteName = "OpenAICompatibleLegacyDefaultsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    for endpoint in AgentProviderConfiguration.legacyOpenAIEndpoints {
      defaults.set(endpoint, forKey: PreferencesKeys.agentProviderEndpoint)
      defaults.set(
        AgentProviderConfiguration.defaultModel,
        forKey: PreferencesKeys.agentProviderModel
      )

      let configuration = AgentProviderConfiguration.current(defaults: defaults)

      XCTAssertEqual(configuration.endpoint, AgentProviderConfiguration.defaultEndpoint)
      XCTAssertEqual(configuration.model, AgentProviderConfiguration.defaultModel)
    }
  }

  func testVisionRequestAttachesOnlyTheCleanObservationImage() async throws {
    let responseData = Data(
      #"{"model":"vision-model","choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"report_complete","arguments":"{\"summary\":\"Done\"}"}}]}}]}"#
        .utf8
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = OpenAICompatibleLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://vision.example.com/v1/chat/completions",
      model: "vision-model",
      thinkingEnabled: false,
      sendsImages: true,
      maxActions: 10
    )

    _ = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration,
      apiKey: "test-key-not-secret"
    )

    let request = try XCTUnwrap(session.requests.first)
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
    let userContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
    XCTAssertEqual(userContent.count, 2)
    XCTAssertEqual(userContent.first?["type"] as? String, "text")
    let imagePart = try XCTUnwrap(userContent.last)
    XCTAssertEqual(imagePart["type"] as? String, "image_url")
    let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
    XCTAssertTrue((imageURL["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    XCTAssertTrue((userContent.first?["text"] as? String)?.contains(
      "It contains no ShotPaste annotation UI"
    ) == true)
  }

  func testThinkingDisabledOmitsOptionalReasoningField() async throws {
    let responseData = Data(
      #"{"model":"custom-model","choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"report_complete","arguments":"{\"summary\":\"Done\"}"}}]}}]}"#
        .utf8
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = OpenAICompatibleLLMProvider(session: session)
    let configuration = AgentProviderConfiguration(
      endpoint: "https://example.com/v1/chat/completions",
      model: "custom-model",
      thinkingEnabled: false,
      sendsImages: false,
      maxActions: 10
    )

    _ = try await provider.nextAction(
      request: try providerRequest(),
      configuration: configuration,
      apiKey: "test-key-not-secret"
    )

    let request = try XCTUnwrap(session.requests.first)
    let bodyData = try XCTUnwrap(request.httpBody)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    XCTAssertNil(body["reasoning_effort"])
  }

  func testTransientRateLimitRetriesThenReturnsToolDecision() async throws {
    let attempts = AttemptCounter()
    let responseData = Data(
      #"{"model":"gpt-5.6-luna","choices":[{"message":{"content":null,"tool_calls":[{"function":{"name":"report_complete","arguments":"{\"summary\":\"Recovered\"}"}}]}}]}"#
        .utf8
    )
    let session = MockURLSession { request in
      let attempt = await attempts.next()
      if attempt == 1 {
        return MockURLSession.makeResponse(
          statusCode: 429,
          data: Data(#"{"error":{"message":"Busy"}}"#.utf8),
          url: request.url!
        )
      }
      return MockURLSession.makeResponse(statusCode: 200, data: responseData, url: request.url!)
    }
    let provider = OpenAICompatibleLLMProvider(
      session: session,
      retryDelaysNanoseconds: [0]
    )

    let decision = try await provider.nextAction(
      request: try providerRequest(),
      configuration: AgentProviderConfiguration(
        endpoint: AgentProviderConfiguration.defaultEndpoint,
        model: AgentProviderConfiguration.defaultModel,
        thinkingEnabled: true,
        sendsImages: false,
        maxActions: 10
      ),
      apiKey: "test-key-not-secret"
    )

    XCTAssertEqual(decision.action, .complete(summary: "Recovered"))
    XCTAssertEqual(session.requests.count, 2)
  }

  func testRootEndpointGetsChatCompletionsPath() {
    let configuration = configuration(endpoint: "https://example.com")
    XCTAssertEqual(configuration.endpointURL?.absoluteString, "https://example.com/chat/completions")
  }

  func testTypeTextAuditSummaryNeverContainsTypedContent() {
    let action = AgentToolAction.typeText(
      AgentTypeTextAction(text: "sensitive-test-content", elementID: nil)
    )
    XCTAssertFalse(action.safeSummary.contains("sensitive-test-content"))
    XCTAssertTrue(action.safeSummary.contains("22 character"))
  }

  private func configuration(endpoint: String) -> AgentProviderConfiguration {
    AgentProviderConfiguration(
      endpoint: endpoint,
      model: "model",
      thinkingEnabled: false,
      sendsImages: false,
      maxActions: 10
    )
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
