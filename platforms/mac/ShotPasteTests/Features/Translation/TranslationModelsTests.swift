//
//  TranslationModelsTests.swift
//  ShotPasteTests
//

import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

final class TranslationModelsTests: XCTestCase {
  func testSupportedTargetLanguageCatalogContainsCurrentAndAllAppLanguages() {
    let targets = TranslationLanguageCatalog.targetOptions

    XCTAssertEqual(targets.count, AppLanguageOption.supported.count + 1)
    XCTAssertEqual(targets.first, .currentLanguage)
    XCTAssertEqual(
      Set(targets.compactMap {
        if case .language(let identifier) = $0 { return identifier }
        return nil
      }),
      Set(AppLanguageOption.supported.map(\.identifier))
    )
  }

  func testAvailabilityUsesRecognizedTextGateIndependentlyOfAgentImageFlag() {
    let imageOff = configuration(sendsImages: false)
    XCTAssertEqual(
      TranslationAvailability.evaluate(
        configuration: imageOff,
        apiKey: "test-key-not-secret",
        sendRecognizedText: true
      ),
      .available
    )
    XCTAssertEqual(
      TranslationAvailability.evaluate(
        configuration: configuration(sendsImages: true),
        apiKey: "test-key-not-secret",
        sendRecognizedText: false
      ),
      .unavailable(.recognizedTextSharingDisabled)
    )
  }

  func testTwoArgumentAvailabilityUsesTheMigratedTextSharingGate() {
    let defaults = UserDefaults.standard
    let textKey = PreferencesKeys.agentTranslationSendsRecognizedText
    let imageKey = PreferencesKeys.agentProviderSendsImages
    let previousText = defaults.object(forKey: textKey)
    let previousImages = defaults.object(forKey: imageKey)
    defer {
      if let previousText {
        defaults.set(previousText, forKey: textKey)
      } else {
        defaults.removeObject(forKey: textKey)
      }
      if let previousImages {
        defaults.set(previousImages, forKey: imageKey)
      } else {
        defaults.removeObject(forKey: imageKey)
      }
    }

    defaults.set(true, forKey: imageKey)
    defaults.set(false, forKey: textKey)
    XCTAssertEqual(
      TranslationAvailability.evaluate(configuration: configuration(sendsImages: true), apiKey: "test-key-not-secret"),
      .unavailable(.recognizedTextSharingDisabled)
    )

    defaults.set(false, forKey: imageKey)
    defaults.set(true, forKey: textKey)
    XCTAssertEqual(
      TranslationAvailability.evaluate(configuration: configuration(sendsImages: false), apiKey: "test-key-not-secret"),
      .available
    )
  }

  func testSettingsMigrationCopiesLegacyValueOnlyWhenNewValueIsAbsent() throws {
    let suiteName = "TranslationModelsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(false, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertTrue(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertFalse(TranslationSettingsMigration.sendRecognizedText(defaults: defaults))

    // Once migrated, changing the Agent Mode screenshot flag cannot affect the
    // independent text-sharing preference.
    defaults.set(true, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertFalse(TranslationSettingsMigration.sendRecognizedText(defaults: defaults))

    defaults.set(true, forKey: PreferencesKeys.agentTranslationSendsRecognizedText)
    defaults.set(false, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertFalse(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertTrue(TranslationSettingsMigration.sendRecognizedText(defaults: defaults))
  }

  func testSettingsMigrationDefaultsToTrueWhenLegacyValueIsMissing() throws {
    let suiteName = "TranslationModelsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertTrue(TranslationSettingsMigration.sendRecognizedText(defaults: defaults))
    XCTAssertEqual(
      defaults.object(forKey: PreferencesKeys.agentTranslationSendsRecognizedText) as? Bool,
      true
    )
  }

  func testSettingsMigrationCopiesLegacyTrueAndKeepsTheSwitchesIndependent() throws {
    let suiteName = "TranslationModelsTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertTrue(TranslationSettingsMigration.sendRecognizedText(defaults: defaults))
    defaults.set(false, forKey: PreferencesKeys.agentTranslationSendsRecognizedText)
    defaults.set(true, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertFalse(TranslationSettingsMigration.sendRecognizedText(defaults: defaults))
  }

  func testFrozenInputAndOverlayLayoutKeepNegativeGlobalCoordinatesLocal() throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 100, height: 80))
    let input = TranslationInput(
      image: image,
      screenRect: CGRect(x: -120, y: 50, width: 100, height: 80)
    )

    XCTAssertEqual(
      TranslationOverlayLayout.localFrame(
        for: CGRect(x: -110, y: 70, width: 30, height: 20),
        inside: input.screenRect
      ),
      CGRect(x: 10, y: 20, width: 30, height: 20)
    )
  }

  func testPromptIsConstrainedAndSeparateFromOCRText() {
    let preferences = TranslationPreferences(
      timeoutSeconds: 999,
      promptMode: .custom,
      prompt: "  use terminology only  \n"
    )
    XCTAssertEqual(preferences.timeoutSeconds, 120)
    XCTAssertEqual(preferences.stylePreferences, "use terminology only")
    XCTAssertFalse(preferences.stylePreferences?.contains("source_language") == true)
  }

  private func configuration(sendsImages: Bool) -> AgentProviderConfiguration {
    AgentProviderConfiguration(
      endpoint: "https://example.com/v1/chat/completions",
      model: "text-model",
      thinkingEnabled: false,
      sendsImages: sendsImages,
      maxActions: 10
    )
  }
}
