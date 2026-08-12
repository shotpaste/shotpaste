//
//  ShotPasteConfigurationServiceTests.swift
//  ShotPasteTests
//
//  Tests for configuration file materialization.
//

@testable import ShotPaste
import XCTest

@MainActor
final class ShotPasteConfigurationServiceTests: XCTestCase {
  func testConfigFileURLAppendsConfigTomlToSelectedDirectory() {
    let directory = URL(fileURLWithPath: "/Users/example/.config/shotpaste", isDirectory: true)

    let url = ShotPasteConfigurationService.shared.configFileURL(inDirectory: directory)

    XCTAssertEqual(url.path, "/Users/example/.config/shotpaste/config.toml")
  }

  func testSuggestedConfigDirectoryMatchingUsesCanonicalPath() {
    let expectedDirectory = ShotPasteConfigurationPaths.suggestedConfigDirectoryURL

    XCTAssertTrue(ShotPasteConfigurationService.shared.isSuggestedConfigDirectory(expectedDirectory))
    XCTAssertFalse(
      ShotPasteConfigurationService.shared.isSuggestedConfigDirectory(
        expectedDirectory.deletingLastPathComponent()
      )
    )
  }

  func testSuggestedConfigParentDirectoryMatchingUsesCanonicalPath() {
    let expectedParentDirectory = ShotPasteConfigurationPaths.suggestedConfigDirectoryURL
      .deletingLastPathComponent()

    XCTAssertTrue(ShotPasteConfigurationService.shared.isSuggestedConfigParentDirectory(expectedParentDirectory))
    XCTAssertFalse(
      ShotPasteConfigurationService.shared.isSuggestedConfigParentDirectory(
        expectedParentDirectory.appendingPathComponent("shotpaste")
      )
    )
  }

  func testSuggestedConfigRootDirectoryMatchingUsesCanonicalPath() {
    let expectedRootDirectory = ShotPasteConfigurationPaths.userHomeDirectory

    XCTAssertTrue(ShotPasteConfigurationService.shared.isSuggestedConfigRootDirectory(expectedRootDirectory))
    XCTAssertFalse(
      ShotPasteConfigurationService.shared.isSuggestedConfigRootDirectory(
        expectedRootDirectory.appendingPathComponent(".config", isDirectory: true)
      )
    )
  }

  func testEnsureConfigExistsCreatesParentDirectoryAndFile() throws {
    let homeDirectory = temporaryHomeDirectory()
    defer { try? FileManager.default.removeItem(at: homeDirectory) }
    let url = ShotPasteConfigurationPaths.suggestedConfigURL(homeDirectory: homeDirectory)

    let returnedURL = try ShotPasteConfigurationService.shared.ensureConfigExists(at: url)

    XCTAssertEqual(returnedURL.path, url.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    let source = try String(contentsOf: url, encoding: .utf8)
    let document = try SimpleTOMLParser.parse(source)
    XCTAssertEqual(document.value(at: "schema_version")?.intValue, 1)
    XCTAssertEqual(document.value(at: "quick_access", "two_finger_swipe_to_dismiss")?.boolValue, true)
  }

  func testExportIncludesQuickAccessTwoFingerSwipeSetting() throws {
    let manager = QuickAccessManager.shared
    let original = manager.twoFingerSwipeToDismissEnabled
    manager.twoFingerSwipeToDismissEnabled = false
    defer { manager.twoFingerSwipeToDismissEnabled = original }

    let source = ShotPasteConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make())
    let document = try SimpleTOMLParser.parse(source)

    XCTAssertEqual(document.value(at: "quick_access", "two_finger_swipe_to_dismiss")?.boolValue, false)
  }

  func testExportUsesBoundedHistoryDefaultsWhenUnset() throws {
    let source = ShotPasteConfigurationExporter.exportTOML(defaults: UserDefaultsFactory.make())
    let document = try SimpleTOMLParser.parse(source)

    XCTAssertEqual(
      document.value(at: "history", "retention_days")?.intValue,
      PreferencesKeys.defaultHistoryRetentionDays
    )
    XCTAssertEqual(
      document.value(at: "history", "max_count")?.intValue,
      PreferencesKeys.defaultHistoryMaxCount
    )
  }

  func testEnsureConfigExistsDoesNotOverwriteExistingFile() throws {
    let homeDirectory = temporaryHomeDirectory()
    defer { try? FileManager.default.removeItem(at: homeDirectory) }
    let url = ShotPasteConfigurationPaths.suggestedConfigURL(homeDirectory: homeDirectory)
    let existingSource = """
    schema_version = 1

    [general]
    language = "system"
    """

    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try existingSource.write(to: url, atomically: true, encoding: .utf8)

    try ShotPasteConfigurationService.shared.ensureConfigExists(at: url)

    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existingSource)
  }

  func testImportBackupReplacingManagedConfigWritesSelectedTomlToManagedFile() throws {
    let directory = temporaryHomeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backupURL = directory.appendingPathComponent("backup.toml")
    let managedURL = directory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("shotpaste", isDirectory: true)
      .appendingPathComponent("config.toml")
    let source = "schema_version = 1\n"

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try source.write(to: backupURL, atomically: true, encoding: .utf8)

    let result = try ShotPasteConfigurationService.shared.importBackupReplacingManagedConfig(
      from: backupURL,
      managedConfigURL: managedURL
    )

    XCTAssertFalse(result.hasErrors)
    XCTAssertEqual(try String(contentsOf: managedURL, encoding: .utf8), source)
  }

  func testImportBackupReplacingManagedConfigDoesNotOverwriteWhenInvalid() throws {
    let directory = temporaryHomeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backupURL = directory.appendingPathComponent("invalid.toml")
    let managedURL = directory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("shotpaste", isDirectory: true)
      .appendingPathComponent("config.toml")
    let existingSource = "schema_version = 1\n"
    let invalidSource = """
    schema_version = 99

    [capture.screenshot]
    format = "webp"
    """

    try FileManager.default.createDirectory(
      at: managedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try existingSource.write(to: managedURL, atomically: true, encoding: .utf8)
    try invalidSource.write(to: backupURL, atomically: true, encoding: .utf8)

    let result = try ShotPasteConfigurationService.shared.importBackupReplacingManagedConfig(
      from: backupURL,
      managedConfigURL: managedURL
    )

    XCTAssertTrue(result.hasErrors)
    XCTAssertEqual(try String(contentsOf: managedURL, encoding: .utf8), existingSource)
  }

  func testSyncDecisionAlreadyCurrentWhenSourcesMatch() {
    let defaults = UserDefaultsFactory.make()
    let source = "schema_version = 1\n"

    let decision = ShotPasteConfigurationService.syncDecision(
      fileSource: source,
      currentSource: source,
      defaults: defaults
    )

    XCTAssertEqual(decision, .alreadyCurrent)
  }

  func testSyncDecisionAutoSyncsWhenFileMatchesLastAppliedSignature() {
    let defaults = UserDefaultsFactory.make()
    let fileSource = "schema_version = 1\n"
    let currentSource = "schema_version = 1\n\n[general]\nplay_sounds = false\n"
    ShotPasteConfigurationAutoImporter.markCurrentFileApplied(fileSource, defaults: defaults)

    let decision = ShotPasteConfigurationService.syncDecision(
      fileSource: fileSource,
      currentSource: currentSource,
      defaults: defaults
    )

    XCTAssertEqual(decision, .syncAutomatically)
  }

  func testSyncDecisionAsksBeforeReplacingExternallyChangedFile() {
    let defaults = UserDefaultsFactory.make()
    let fileSource = "schema_version = 1\n\n[general]\nplay_sounds = true\n"
    let currentSource = "schema_version = 1\n\n[general]\nplay_sounds = false\n"

    let decision = ShotPasteConfigurationService.syncDecision(
      fileSource: fileSource,
      currentSource: currentSource,
      defaults: defaults
    )

    XCTAssertEqual(decision, .askBeforeReplacing)
  }

  func testPrepareManagedConfigForOpeningCreatesMissingFileFromCurrentSettings() throws {
    try withRestoredLastAppliedSignature {
      let directory = temporaryHomeDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let managedURL = directory.appendingPathComponent("config.toml")

      let result = try ShotPasteConfigurationService.shared.prepareManagedConfigForOpening(at: managedURL)

      XCTAssertEqual(result.status, .synced)
      XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
      let source = try String(contentsOf: managedURL, encoding: .utf8)
      XCTAssertTrue(ShotPasteConfigurationAutoImporter.isCurrentFileApplied(source))
    }
  }

  func testPrepareManagedConfigForOpeningAutoSyncsStaleAppOwnedFile() throws {
    try withRestoredLastAppliedSignature {
      let directory = temporaryHomeDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let managedURL = directory.appendingPathComponent("config.toml")
      let staleSource = "schema_version = 1\n"

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try staleSource.write(to: managedURL, atomically: true, encoding: .utf8)
      ShotPasteConfigurationAutoImporter.markCurrentFileApplied(staleSource)

      let result = try ShotPasteConfigurationService.shared.prepareManagedConfigForOpening(at: managedURL)
      let syncedSource = try String(contentsOf: managedURL, encoding: .utf8)

      XCTAssertEqual(result.status, .synced)
      XCTAssertNotEqual(syncedSource, staleSource)
      XCTAssertTrue(ShotPasteConfigurationAutoImporter.isCurrentFileApplied(syncedSource))
    }
  }

  func testPrepareManagedConfigForOpeningDoesNotOverwriteExternalChangesWithoutConfirmation() throws {
    try withRestoredLastAppliedSignature {
      let directory = temporaryHomeDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let managedURL = directory.appendingPathComponent("config.toml")
      let externalSource = "schema_version = 1\n\n[general]\nplay_sounds = false\n"

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try externalSource.write(to: managedURL, atomically: true, encoding: .utf8)

      let result = try ShotPasteConfigurationService.shared.prepareManagedConfigForOpening(at: managedURL)

      XCTAssertEqual(result.status, .needsConfirmation)
      XCTAssertEqual(try String(contentsOf: managedURL, encoding: .utf8), externalSource)
    }
  }

  func testSyncManagedConfigToCurrentSettingsOverwritesAfterConfirmation() throws {
    try withRestoredLastAppliedSignature {
      let directory = temporaryHomeDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let managedURL = directory.appendingPathComponent("config.toml")
      let externalSource = "schema_version = 1\n\n[general]\nplay_sounds = false\n"

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try externalSource.write(to: managedURL, atomically: true, encoding: .utf8)

      try ShotPasteConfigurationService.shared.syncManagedConfigToCurrentSettings(at: managedURL)
      let syncedSource = try String(contentsOf: managedURL, encoding: .utf8)

      XCTAssertNotEqual(syncedSource, externalSource)
      XCTAssertTrue(ShotPasteConfigurationAutoImporter.isCurrentFileApplied(syncedSource))
    }
  }

  func testSyncManagedConfigToCurrentSettingsIfUnchangedOverwritesApprovedFile() throws {
    try withRestoredLastAppliedSignature {
      let directory = temporaryHomeDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let managedURL = directory.appendingPathComponent("config.toml")
      let externalSource = "schema_version = 1\n\n[general]\nplay_sounds = false\n"

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try externalSource.write(to: managedURL, atomically: true, encoding: .utf8)

      let result = try ShotPasteConfigurationService.shared.prepareManagedConfigForOpening(at: managedURL)
      try ShotPasteConfigurationService.shared.syncManagedConfigToCurrentSettingsIfUnchanged(
        at: managedURL,
        expectedFileSignature: result.observedFileSignature
      )

      let syncedSource = try String(contentsOf: managedURL, encoding: .utf8)
      XCTAssertNotEqual(syncedSource, externalSource)
      XCTAssertTrue(ShotPasteConfigurationAutoImporter.isCurrentFileApplied(syncedSource))
    }
  }

  func testSyncManagedConfigToCurrentSettingsIfUnchangedDoesNotOverwriteChangedFile() throws {
    try withRestoredLastAppliedSignature {
      let directory = temporaryHomeDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let managedURL = directory.appendingPathComponent("config.toml")
      let approvedSource = "schema_version = 1\n\n[general]\nplay_sounds = false\n"
      let changedSource = "schema_version = 1\n\n[general]\nplay_sounds = true\n"

      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try approvedSource.write(to: managedURL, atomically: true, encoding: .utf8)

      let result = try ShotPasteConfigurationService.shared.prepareManagedConfigForOpening(at: managedURL)
      try changedSource.write(to: managedURL, atomically: true, encoding: .utf8)

      XCTAssertThrowsError(
        try ShotPasteConfigurationService.shared.syncManagedConfigToCurrentSettingsIfUnchanged(
          at: managedURL,
          expectedFileSignature: result.observedFileSignature
        )
      ) { error in
        XCTAssertTrue(error is ShotPasteConfigurationSyncError)
      }
      XCTAssertEqual(try String(contentsOf: managedURL, encoding: .utf8), changedSource)
    }
  }

  func testExportIncludesNewConfigurationFields() throws {
    let defaults = UserDefaultsFactory.make()
    defaults.set(false, forKey: PreferencesKeys.showMenuBarIcon)

    let manager = QuickAccessManager.shared
    let originalHide = manager.hideCardWhenWindowOpen
    let originalStyle = manager.animationStyle
    let originalLeftAction = QuickAccessSwipeActionStore.shared.swipeLeftAction
    let originalRightAction = QuickAccessSwipeActionStore.shared.swipeRightAction
    let originalTrackpadMode = QuickAccessTrackpadSwipeModeStore.shared.mode

    manager.hideCardWhenWindowOpen = false
    manager.animationStyle = .scale
    QuickAccessSwipeActionStore.shared.setAction(.left, action: .pinToScreen)
    QuickAccessSwipeActionStore.shared.setAction(.right, action: nil)
    QuickAccessTrackpadSwipeModeStore.shared.setMode(.natural)

    defer {
      manager.hideCardWhenWindowOpen = originalHide
      manager.animationStyle = originalStyle
      QuickAccessSwipeActionStore.shared.setAction(.left, action: originalLeftAction)
      QuickAccessSwipeActionStore.shared.setAction(.right, action: originalRightAction)
      QuickAccessTrackpadSwipeModeStore.shared.setMode(originalTrackpadMode)
    }

    let source = ShotPasteConfigurationExporter.exportTOML(defaults: defaults)
    let document = try SimpleTOMLParser.parse(source)

    XCTAssertEqual(document.value(at: "general", "show_menu_bar_icon")?.boolValue, false)
    XCTAssertNil(document.value(at: "capture", "screenshot", "freeze_area"))
    XCTAssertNil(document.value(at: "capture", "screenshot", "live_passthrough"))
    XCTAssertNil(document.value(at: "capture", "screenshot", "show_selection_area_overlay"))
    XCTAssertNil(document.value(at: "capture", "screenshot", "reverse_magnifier_zoom_direction"))
    XCTAssertNil(document.value(at: "annotate", "close_after_drag"))
    XCTAssertNil(document.value(at: "annotate", "bring_forward_after_drag"))
    XCTAssertNil(document.value(at: "annotate", "combine_save_as_edit"))
    XCTAssertNil(document.value(at: "shortcuts", "annotate_tools"))
    for removedKind in ["fullscreen", "area", "scrolling", "ocr", "recording"] {
      XCTAssertNil(document.value(at: "shortcuts", "global", removedKind))
    }
    XCTAssertEqual(document.value(at: "quick_access", "trackpad_swipe_mode")?.stringValue, "natural")
    XCTAssertEqual(document.value(at: "quick_access", "swipe_left_action")?.stringValue, "pinToScreen")
    XCTAssertEqual(document.value(at: "quick_access", "swipe_right_action")?.stringValue, "none")
    XCTAssertEqual(document.value(at: "quick_access", "hide_card_when_window_open")?.boolValue, false)
    XCTAssertEqual(document.value(at: "quick_access", "animation_style")?.stringValue, "scale")
  }

  private func temporaryHomeDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("shotpaste-config-service-\(UUID().uuidString)", isDirectory: true)
  }

  private func withRestoredLastAppliedSignature(_ body: () throws -> Void) rethrows {
    let defaults = UserDefaults.standard
    let key = PreferencesKeys.configurationLastAppliedSignature
    let previousValue = defaults.object(forKey: key)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
    try body()
  }
}
