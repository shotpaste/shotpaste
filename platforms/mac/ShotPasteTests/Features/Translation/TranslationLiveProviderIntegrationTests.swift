//
//  TranslationLiveProviderIntegrationTests.swift
//  ShotPasteTests
//
//  Opt-in text-only verification. It never creates, captures, or uploads a
//  screenshot; the only payload is the literal HELLO text below.
//

import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class TranslationLiveProviderIntegrationTests: XCTestCase {
  func testConfiguredProviderTranslatesTextOnlyHello() async throws {
    guard ProcessInfo.processInfo.environment["SHOTPASTE_LIVE_TRANSLATION"] == "1" else {
      throw XCTSkip("Set SHOTPASTE_LIVE_TRANSLATION=1 to run the opt-in text-only provider check.")
    }

    let defaults = UserDefaults.standard
    let apiProtocol = defaults.string(forKey: PreferencesKeys.agentProviderProtocol)
      .flatMap(AgentProviderAPIProtocol.init(rawValue:)) ?? .openAICompatible
    let configuration = AgentProviderConfiguration(
      endpoint: defaults.string(forKey: PreferencesKeys.agentProviderEndpoint)
        ?? AgentProviderConfiguration.defaultEndpoint(for: apiProtocol),
      model: defaults.string(forKey: PreferencesKeys.agentProviderModel)
        ?? AgentProviderConfiguration.defaultModel(for: apiProtocol),
      thinkingEnabled: false,
      sendsImages: defaults.object(forKey: PreferencesKeys.agentProviderSendsImages) as? Bool ?? true,
      maxActions: 1,
      apiProtocol: apiProtocol
    )
    let apiKey = try AgentCredentialStore.shared.resolvedAPIKey()
    guard TranslationSettingsMigration.sendRecognizedText(defaults: defaults) else {
      throw XCTSkip("Recognized-text sharing is disabled in Translation settings.")
    }
    guard case .available = TranslationAvailability.evaluate(
      configuration: configuration,
      apiKey: apiKey,
      sendRecognizedText: true
    ) else {
      throw XCTSkip("No usable configured text provider is available for the opt-in check.")
    }

    let request = TranslationTextRequest(
      generationID: UUID().uuidString,
      sourceLanguage: "auto",
      targetLanguage: "zh-Hans",
      blocks: [TranslationTextRequestBlock(id: "block-0001", text: "HELLO")],
      stylePreferences: "faithful translation"
    )
    let response = try await TranslationConfigurableTextProvider().translate(
      request: request,
      configuration: configuration,
      apiKey: apiKey,
      deadline: Date().addingTimeInterval(15)
    )

    XCTAssertEqual(response.generationID, request.generationID)
    XCTAssertEqual(response.translations.map(\.id), ["block-0001"])
    XCTAssertFalse(response.translations.first?.translatedText.isEmpty ?? true)
  }
}
