//
//  ShotPasteConfigurationAutoImporterTests.swift
//  ShotPasteTests
//
//  Unit tests for applying user-edited TOML configuration at startup.
//

@testable import ShotPaste
import XCTest

@MainActor
final class ShotPasteConfigurationAutoImporterTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteConfigurationAutoImporterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    tempDirectory = nil
    try super.tearDownWithError()
  }

  func testAutoImportAppliesChangedConfigFileAndStoresSignature() throws {
    let defaults = UserDefaultsFactory.make()
    let fileURL = tempDirectory.appendingPathComponent("config.toml")
    let source = """
    schema_version = 1

    [capture.screenshot]
    format = "webp"
    show_cursor = true
    """
    try source.write(to: fileURL, atomically: true, encoding: .utf8)

    let result = ShotPasteConfigurationAutoImporter.applyIfNeeded(from: fileURL, defaults: defaults)

    XCTAssertEqual(result.status, .applied)
    XCTAssertFalse(result.importResult?.hasErrors ?? true)
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.screenshotFormat), "webp")
    XCTAssertEqual(defaults.object(forKey: PreferencesKeys.screenshotShowCursor) as? Bool, true)
    XCTAssertNotNil(defaults.string(forKey: PreferencesKeys.configurationLastAppliedSignature))

    let secondResult = ShotPasteConfigurationAutoImporter.applyIfNeeded(from: fileURL, defaults: defaults)

    XCTAssertEqual(secondResult.status, .skippedUnchanged)
  }

  func testAutoImportDoesNotStoreSignatureWhenConfigHasErrors() throws {
    let defaults = UserDefaultsFactory.make()
    defaults.set("png", forKey: PreferencesKeys.screenshotFormat)
    let fileURL = tempDirectory.appendingPathComponent("config.toml")
    let source = """
    schema_version = 1

    [capture.screenshot]
    format = "bmp"
    """
    try source.write(to: fileURL, atomically: true, encoding: .utf8)

    let result = ShotPasteConfigurationAutoImporter.applyIfNeeded(from: fileURL, defaults: defaults)

    XCTAssertEqual(result.status, .failed)
    XCTAssertTrue(result.importResult?.hasErrors ?? false)
    XCTAssertEqual(defaults.string(forKey: PreferencesKeys.screenshotFormat), "png")
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.configurationLastAppliedSignature))
  }

  func testAutoImportSkipsMissingConfigFile() {
    let defaults = UserDefaultsFactory.make()
    let fileURL = tempDirectory.appendingPathComponent("config.toml")

    let result = ShotPasteConfigurationAutoImporter.applyIfNeeded(from: fileURL, defaults: defaults)

    XCTAssertEqual(result.status, .skippedMissingFile)
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.configurationLastAppliedSignature))
  }
}
