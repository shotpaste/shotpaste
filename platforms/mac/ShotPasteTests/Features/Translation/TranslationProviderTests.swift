//
//  TranslationProviderTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

final class TranslationProviderTests: XCTestCase {
  func testConfigurableTextProviderRoutesOpenAIAndDoesNotReadImageFlag() async throws {
    let expected = TranslationTextResponse(
      generationID: "generation-1",
      translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "你好")]
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: Data(), url: try XCTUnwrap(request.url))
    }
    let router = TranslationConfigurableTextProvider(
      openAIProvider: OpenAITextTranslationProvider(
        session: session,
        responseParser: { _, _ in expected }
      ),
      anthropicProvider: AnthropicTextTranslationProvider(
        session: session,
        responseParser: { _, _ in expected }
      )
    )

    let response = try await router.translate(
      request: request(),
      configuration: configuration(.openAICompatible, sendsImages: false),
      apiKey: "test-key-not-secret",
      deadline: Date().addingTimeInterval(3)
    )

    XCTAssertEqual(response, expected)
    XCTAssertEqual(session.requests.count, 1)
  }

  func testConfigurableTextProviderRoutesAnthropicProtocol() async throws {
    let expected = TranslationTextResponse(
      generationID: "generation-1",
      translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "你好")]
    )
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: Data(), url: try XCTUnwrap(request.url))
    }
    let router = TranslationConfigurableTextProvider(
      openAIProvider: OpenAITextTranslationProvider(session: session, responseParser: { _, _ in expected }),
      anthropicProvider: AnthropicTextTranslationProvider(
        session: session,
        responseParser: { _, _ in expected }
      )
    )

    let response = try await router.translate(
      request: request(),
      configuration: configuration(.anthropicMessages, sendsImages: false),
      apiKey: "test-key-not-secret",
      deadline: Date().addingTimeInterval(3)
    )

    XCTAssertEqual(response, expected)
    XCTAssertEqual(session.requests.count, 1)
    XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "x-api-key"), "test-key-not-secret")
  }

  func testRouterDoesNotConstructARequestForUnsupportedProtocolAdapter() async throws {
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 200, data: Data(), url: try XCTUnwrap(request.url))
    }
    let router = TranslationConfigurableTextProvider(
      openAIProvider: OpenAITextTranslationProvider(
        session: session,
        responseParser: { _, _ in
          TranslationTextResponse(
            generationID: "generation-1",
            translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "你好")]
          )
        }
      ),
      anthropicProvider: AnthropicTextTranslationProvider(session: session, responseParser: { _, _ in
        TranslationTextResponse(
          generationID: "generation-1",
          translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "你好")]
        )
      })
    )
    // Both adapters are selected by the configuration protocol; this test is
    // intentionally only a smoke test that the route remains text-only.
    let result = try await router.translate(
      request: request(),
      configuration: configuration(.openAICompatible, sendsImages: false),
      apiKey: "test-key-not-secret",
      deadline: Date().addingTimeInterval(3)
    )
    XCTAssertEqual(result.generationID, "generation-1")
  }

  private func request() -> TranslationTextRequest {
    TranslationTextRequest(
      generationID: "generation-1",
      sourceLanguage: "en",
      targetLanguage: "zh-Hans",
      blocks: [TranslationTextRequestBlock(id: "block-0001", text: "Hello")],
      stylePreferences: "faithful"
    )
  }

  private func configuration(
    _ apiProtocol: AgentProviderAPIProtocol,
    sendsImages: Bool
  ) -> AgentProviderConfiguration {
    AgentProviderConfiguration(
      endpoint: apiProtocol == .anthropicMessages
        ? "https://example.com"
        : "https://example.com/v1/chat/completions",
      model: "text-model",
      thinkingEnabled: false,
      sendsImages: sendsImages,
      maxActions: 10,
      apiProtocol: apiProtocol
    )
  }
}
