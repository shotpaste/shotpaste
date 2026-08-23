//
//  ShotPasteConfigurationImporterTests.swift
//  ShotPasteTests
//
//  Unit tests for TOML configuration import validation and application.
//

@testable import ShotPaste
import XCTest

@MainActor
final class ShotPasteConfigurationImporterTests: XCTestCase {
  func testImportAppliesCaptureAndRecordingSettingsToProvidedDefaults() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [capture.screenshot]
    format = "webp"
    show_cursor = true

    [recording]
    fps = 60
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertGreaterThanOrEqual(result.appliedChangeCount, 3)
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.screenshotFormat), "webp")
    XCTAssertEqual(defaults.object(forKey: PreferencesKeys.screenshotShowCursor) as? Bool, true)
    XCTAssertEqual(defaults.object(forKey: PreferencesKeys.recordingFPS) as? Int, 60)
  }

  func testImportRejectsUnsupportedSchemaBeforeMutatingDefaults() {
    let defaults = UserDefaultsFactory.make()
    defaults.set("png", forKey: PreferencesKeys.screenshotFormat)
    let source = """
    schema_version = 99

    [capture.screenshot]
    format = "webp"
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.screenshotFormat), "png")
  }

  func testImportRejectsInvalidEnumsBeforeApplyingAnyMutation() {
    let defaults = UserDefaultsFactory.make()
    defaults.set("png", forKey: PreferencesKeys.screenshotFormat)
    let source = """
    schema_version = 1

    [capture.screenshot]
    format = "bmp"
    show_cursor = true
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.screenshotFormat), "png")
    XCTAssertNil(defaults.object(forKey: PreferencesKeys.screenshotShowCursor))
  }

  func testImportRejectsUnknownShortcutModifiers() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [shortcuts.global.one_shot]
    key = "1"
    modifiers = ["command", "hyper"]
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
  }

  func testImportExpandsTildePathsAgainstUserHomeDirectory() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [general]
    export_location = "~/Desktop"
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertTrue(result.issues.isEmpty)
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.exportLocation),
      ShotPasteConfigurationPaths.expandedUserPath("~/Desktop")
    )
  }

  func testImportAppliesMCPServerSettings() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [general]
    mcp_server_enabled = true
    mcp_server_port = 49222
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(defaults.bool(forKey: PreferencesKeys.mcpServerEnabled), true)
    XCTAssertEqual(defaults.integer(forKey: PreferencesKeys.mcpServerPort), 49_222)
  }

  func testImportAppliesTranslationPreferencesWithoutAcceptingAnAPIKey() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [agent.translation]
    timeout_seconds = 24
    prompt_mode = "custom"
    prompt = "Keep {{target_language}} terminology concise."
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(defaults.integer(forKey: PreferencesKeys.agentTranslationTimeoutSeconds), 24)
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.agentTranslationPromptMode), "custom")
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentTranslationPrompt),
      "Keep {{target_language}} terminology concise."
    )
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.agentProviderAPIKey))
  }

  func testImportRejectsTranslationTimeoutOutsideHardLimit() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [agent.translation]
    timeout_seconds = 121
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
  }

  func testDefaultDocumentIncludesTextTranslationDefaults() throws {
    let document = try SimpleTOMLParser.parse(ShotPasteConfigurationDefaultDocument.toml())

    XCTAssertEqual(document.value(at: "agent", "translation", "engine")?.stringValue, "provider_text")
    XCTAssertEqual(
      document.value(at: "agent", "translation", "timeout_seconds")?.intValue,
      TranslationPreferences.defaultTimeoutSeconds
    )
    XCTAssertEqual(document.value(at: "agent", "translation", "prompt_mode")?.stringValue, "builtin")
    XCTAssertEqual(document.value(at: "agent", "translation", "prompt")?.stringValue, "")
    XCTAssertEqual(
      document.value(at: "agent", "translation", "send_recognized_text")?.boolValue,
      TranslationSettingsMigration.defaultSendRecognizedText
    )
  }

  func testDefaultDocumentRoundTripsThroughImporterWithoutApplyingAnAPIKey() {
    let defaults = UserDefaultsFactory.make()
    defaults.set("preserved-test-token", forKey: PreferencesKeys.agentProviderAPIKey)
    let result = ShotPasteConfigurationImporter.importTOML(
      ShotPasteConfigurationDefaultDocument.toml(),
      defaults: defaults
    )

    XCTAssertFalse(result.hasErrors, result.issues.map(\.message).joined(separator: "\n"))
    XCTAssertEqual(
      defaults.string(forKey: PreferencesKeys.agentTranslationPromptMode),
      TranslationPromptMode.builtin.rawValue
    )
    XCTAssertEqual(
      defaults.integer(forKey: PreferencesKeys.agentTranslationTimeoutSeconds),
      TranslationPreferences.defaultTimeoutSeconds
    )
    XCTAssertEqual(
      defaults.bool(forKey: PreferencesKeys.agentTranslationSendsRecognizedText),
      TranslationSettingsMigration.defaultSendRecognizedText
    )
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.agentProviderAPIKey), "preserved-test-token")
  }

  func testTranslationSettingsMigrationDefaultsToTrueWhenLegacyPreferenceIsUnsetAndIsIdempotent() {
    let defaults = UserDefaultsFactory.make()

    XCTAssertTrue(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertEqual(
      defaults.object(forKey: PreferencesKeys.agentTranslationSendsRecognizedText) as? Bool,
      true
    )
    XCTAssertFalse(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
  }

  func testTranslationSettingsMigrationMapsLegacyFalseAndDoesNotFollowLaterLegacyChanges() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(false, forKey: PreferencesKeys.agentProviderSendsImages)

    XCTAssertTrue(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertEqual(
      defaults.object(forKey: PreferencesKeys.agentTranslationSendsRecognizedText) as? Bool,
      false
    )

    defaults.set(true, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertFalse(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertEqual(
      defaults.object(forKey: PreferencesKeys.agentTranslationSendsRecognizedText) as? Bool,
      false
    )
  }

  func testTranslationSettingsMigrationPreservesExplicitNewTrueOrFalseValue() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(false, forKey: PreferencesKeys.agentTranslationSendsRecognizedText)
    defaults.set(true, forKey: PreferencesKeys.agentProviderSendsImages)

    XCTAssertFalse(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertFalse(defaults.bool(forKey: PreferencesKeys.agentTranslationSendsRecognizedText))

    defaults.removeObject(forKey: PreferencesKeys.agentTranslationSendsRecognizedText)
    defaults.set(true, forKey: PreferencesKeys.agentTranslationSendsRecognizedText)
    defaults.set(false, forKey: PreferencesKeys.agentProviderSendsImages)
    XCTAssertFalse(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
    XCTAssertTrue(defaults.bool(forKey: PreferencesKeys.agentTranslationSendsRecognizedText))
  }

  func testImportAppliesExplicitRecognizedTextPrivacyValue() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(false, forKey: PreferencesKeys.agentProviderSendsImages)
    let source = """
    schema_version = 1

    [agent.translation]
    engine = "provider_text"
    send_recognized_text = true
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertTrue(defaults.bool(forKey: PreferencesKeys.agentTranslationSendsRecognizedText))
    XCTAssertFalse(TranslationSettingsMigration.applyIfNeeded(defaults: defaults))
  }

  func testImportRejectsUnsupportedTranslationEngineBeforeMutating() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(15, forKey: PreferencesKeys.agentTranslationTimeoutSeconds)
    let source = """
    schema_version = 1

    [agent.translation]
    engine = "vision"
    timeout_seconds = 30
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
    XCTAssertEqual(defaults.integer(forKey: PreferencesKeys.agentTranslationTimeoutSeconds), 15)
  }

  func testImportRejectsInvalidTranslationEngineAndPrivacyTypes() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [agent.translation]
    engine = true
    send_recognized_text = "yes"
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
    XCTAssertNil(defaults.object(forKey: PreferencesKeys.agentTranslationSendsRecognizedText))
  }

  func testImportRejectsPrivilegedMCPServerPort() {
    let defaults = UserDefaultsFactory.make()
    let source = """
    schema_version = 1

    [general]
    mcp_server_port = 80
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(result.appliedChangeCount, 0)
  }

  func testImportAppliesQuickAccessTwoFingerSwipeSetting() {
    let defaults = UserDefaultsFactory.make()
    let manager = QuickAccessManager.shared
    let original = manager.twoFingerSwipeToDismissEnabled
    manager.twoFingerSwipeToDismissEnabled = true
    defer { manager.twoFingerSwipeToDismissEnabled = original }
    let source = """
    schema_version = 1

    [quick_access]
    two_finger_swipe_to_dismiss = false
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)
    XCTAssertFalse(manager.twoFingerSwipeToDismissEnabled)
  }

  func testImportAppliesSupportedFieldsAndIgnoresRemovedSelectionPreferences() {
    let defaults = UserDefaultsFactory.make()
    let manager = QuickAccessManager.shared

    let originalHide = manager.hideCardWhenWindowOpen
    let originalStyle = manager.animationStyle
    let originalLeftAction = QuickAccessSwipeActionStore.shared.swipeLeftAction
    let originalRightAction = QuickAccessSwipeActionStore.shared.swipeRightAction
    let originalTrackpadMode = QuickAccessTrackpadSwipeModeStore.shared.mode

    defer {
      manager.hideCardWhenWindowOpen = originalHide
      manager.animationStyle = originalStyle
      QuickAccessSwipeActionStore.shared.setAction(.left, action: originalLeftAction)
      QuickAccessSwipeActionStore.shared.setAction(.right, action: originalRightAction)
      QuickAccessTrackpadSwipeModeStore.shared.setMode(originalTrackpadMode)
    }

    let source = """
    schema_version = 1

    [general]
    show_menu_bar_icon = false

    [capture.screenshot]
    freeze_area = true
    show_selection_area_overlay = false
    reverse_magnifier_zoom_direction = true

    [quick_access]
    trackpad_swipe_mode = "natural"
    swipe_left_action = "pinToScreen"
    swipe_right_action = "none"
    hide_card_when_window_open = false
    animation_style = "scale"
    """

    let result = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)

    XCTAssertFalse(result.hasErrors)

    // general
    XCTAssertEqual(defaults.object(forKey: PreferencesKeys.showMenuBarIcon) as? Bool, false)

    XCTAssertNil(defaults.object(forKey: "screenshot.freezeArea"))
    XCTAssertNil(defaults.object(forKey: "screenshot.showSelectionAreaOverlay"))
    XCTAssertNil(defaults.object(forKey: "screenshot.reverseMagnifierZoomDirection"))

    // quick access
    XCTAssertEqual(QuickAccessTrackpadSwipeModeStore.shared.mode, .natural)
    XCTAssertEqual(QuickAccessSwipeActionStore.shared.swipeLeftAction, .pinToScreen)
    XCTAssertNil(QuickAccessSwipeActionStore.shared.swipeRightAction)
    XCTAssertFalse(manager.hideCardWhenWindowOpen)
    XCTAssertEqual(manager.animationStyle, .scale)
  }

  func testImportRejectsInvalidEnumValues() {
    let defaults = UserDefaultsFactory.make()

    let sourceInvalidTrackpad = """
    schema_version = 1
    [quick_access]
    trackpad_swipe_mode = "invalid_mode"
    """
    let result1 = ShotPasteConfigurationImporter.importTOML(sourceInvalidTrackpad, defaults: defaults)
    XCTAssertTrue(result1.hasErrors)

    let sourceInvalidLeftAction = """
    schema_version = 1
    [quick_access]
    swipe_left_action = "invalid_action"
    """
    let result2 = ShotPasteConfigurationImporter.importTOML(sourceInvalidLeftAction, defaults: defaults)
    XCTAssertTrue(result2.hasErrors)

    let sourceInvalidAnim = """
    schema_version = 1
    [quick_access]
    animation_style = "invalid_style"
    """
    let result3 = ShotPasteConfigurationImporter.importTOML(sourceInvalidAnim, defaults: defaults)
    XCTAssertTrue(result3.hasErrors)
  }
}
