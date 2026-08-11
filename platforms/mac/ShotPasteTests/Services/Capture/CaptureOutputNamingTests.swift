//
//  CaptureOutputNamingTests.swift
//  ShotPasteTests
//
//  Unit tests for CaptureOutputNaming filename generation and sanitization.
//

@testable import ShotPaste
import XCTest

final class CaptureOutputNamingTests: XCTestCase {
  // Fixed date: 2026-01-15 14:30:45.123 UTC
  private let fixedDate = Date(timeIntervalSince1970: 1_768_512_645.123)
  private var tempDirectory: URL!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteTests_CaptureOutputNaming_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defaults = UserDefaultsFactory.make()
  }

  override func tearDown() {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    super.tearDown()
  }

  // MARK: - resolveBaseName with custom name

  func testResolveBaseName_withCustomName_returnsSanitizedName() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "My Screenshot",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "My Screenshot")
  }

  func testResolveBaseName_withNilCustomName_fallsBackToTemplate() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    // Default template: "ShotPaste_{datetime}_{ms}"
    XCTAssertTrue(result.hasPrefix("ShotPaste_"), "Expected template-based name, got: \(result)")
    XCTAssertTrue(result.contains("_"), "Expected datetime separators")
  }

  func testResolveBaseName_withEmptyCustomName_fallsBackToTemplate() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertTrue(result.hasPrefix("ShotPaste_"), "Expected template-based name, got: \(result)")
  }

  func testResolveBaseName_withWhitespaceOnlyCustomName_fallsBackToTemplate() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "   ",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertTrue(result.hasPrefix("ShotPaste_"))
  }

  // MARK: - Template Token Expansion

  func testResolveBaseName_typeToken_screenshot() {
    defaults.set("{type}_capture", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "screenshot_capture")
  }

  func testResolveBaseName_typeToken_recording() {
    defaults.set("{type}_file", forKey: PreferencesKeys.recordingFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .recording,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "recording_file")
  }

  func testResolveBaseName_datetimeToken() {
    defaults.set("Snap_{datetime}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    // datetime format: yyyy-MM-dd_HH-mm-ss
    // Verify it contains a date-like pattern
    let datePattern = #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#
    XCTAssertNotNil(
      result.range(of: datePattern, options: .regularExpression),
      "Expected datetime pattern in: \(result)"
    )
  }

  func testResolveBaseName_msToken() {
    defaults.set("file_{ms}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    // ms token should be 3 digits
    let msPattern = #"file_\d{3}"#
    XCTAssertNotNil(
      result.range(of: msPattern, options: .regularExpression),
      "Expected ms pattern in: \(result)"
    )
  }

  func testResolveBaseName_timestampToken() {
    defaults.set("ts_{timestamp}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    let expected = "ts_\(Int(fixedDate.timeIntervalSince1970))"
    XCTAssertEqual(result, expected)
  }

  func testResolveBaseName_yearMonthDayTokens() throws {
    defaults.set("{year}/{month}/{day}/shot", forKey: PreferencesKeys.screenshotFileNameTemplate)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let localDate = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 1,
      day: 15,
      hour: 14,
      minute: 30,
      second: 45
    )))

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "2026/01/15/shot")
  }

  func testResolveBaseName_yearShortTokens() throws {
    defaults.set("{year}/{yearShort}/{year_short}/{yy}/shot", forKey: PreferencesKeys.screenshotFileNameTemplate)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let localDate = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 1,
      day: 15,
      hour: 14,
      minute: 30,
      second: 45
    )))

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "2026/26/26/26/shot")
  }

  func testResolveBaseName_monthNameTokens() throws {
    defaults.set(
      "{year}/{monthName}/{monthShort}/{month_name}/{month_short}/shot",
      forKey: PreferencesKeys.screenshotFileNameTemplate
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let localDate = try XCTUnwrap(calendar.date(from: DateComponents(
      year: 2026,
      month: 1,
      day: 15,
      hour: 14,
      minute: 30,
      second: 45
    )))
    let monthName = CaptureOutputNaming.resolveBaseName(
      customName: Self.format(localDate, style: "MMMM"),
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )
    let monthShort = CaptureOutputNaming.resolveBaseName(
      customName: Self.format(localDate, style: "MMM"),
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: localDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "2026/\(monthName)/\(monthShort)/\(monthName)/\(monthShort)/shot")
  }

  func testResolveBaseName_templateWithSlash_returnsRelativeSubpath() {
    defaults.set("{type}/{timestamp}/shot_{ms}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    XCTAssertEqual(result, "screenshot/\(Int(fixedDate.timeIntervalSince1970))/shot_123")
  }

  func testResolveTemplateBaseName_returnsPreviewSubpath() {
    let result = CaptureOutputNaming.resolveTemplateBaseName(
      "Shots/{timestamp}/ShotPaste_{ms}",
      kind: .screenshot,
      date: fixedDate
    )

    XCTAssertEqual(result, "Shots/\(Int(fixedDate.timeIntervalSince1970))/ShotPaste_123")
  }

  private static func format(_ date: Date, style: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = style
    return formatter.string(from: date)
  }

  // MARK: - Sanitization

  func testSanitize_slashCreatesSubpathAndInvalidFilenameCharactersUseUnderscore() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "file/with\\bad:chars?test",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "file/with_bad_chars_test")
    XCTAssertTrue(result.contains("/"))
    XCTAssertFalse(result.contains("\\"))
    XCTAssertFalse(result.contains(":"))
    XCTAssertFalse(result.contains("?"))
  }

  func testSanitize_pathTraversalComponents_areDropped() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "../Shots//./2026:May/final.png",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "Shots/2026_May/final")
    XCTAssertFalse(result.contains(".."))
  }

  func testSanitize_consecutiveUnderscores_collapsed() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "file___name",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertFalse(result.contains("___"))
    XCTAssertTrue(result.contains("_"))
  }

  func testSanitize_knownExtension_stripped() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "myfile.png",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "myfile")
  }

  func testSanitize_knownExtension_jpegStripped() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "capture.jpeg",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "capture")
  }

  func testSanitize_knownExtension_strippedFromLeafOnly() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "Screenshots.png/capture.jpeg",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "Screenshots.png/capture")
  }

  func testSanitize_unknownExtension_preserved() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "document.pdf",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "document.pdf")
  }

  func testSanitize_trimmingDotsAndSpaces() {
    let result = CaptureOutputNaming.resolveBaseName(
      customName: "  .file. ",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )
    XCTAssertEqual(result, "file")
  }

  // MARK: - makeUniqueFileURL

  func testMakeUniqueFileURL_noCollision_returnsBaseURL() {
    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "test_capture",
      fileExtension: "png"
    )
    XCTAssertEqual(result.lastPathComponent, "test_capture.png")
  }

  func testMakeUniqueFileURL_withCollision_appendsSuffix() throws {
    // Create first file
    let firstFile = tempDirectory.appendingPathComponent("test_capture.png")
    try Data("test".utf8).write(to: firstFile)

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "test_capture",
      fileExtension: "png"
    )
    XCTAssertEqual(result.lastPathComponent, "test_capture_2.png")
  }

  func testMakeUniqueFileURL_withMultipleCollisions_incrementsSuffix() throws {
    // Create first two files
    try Data("test".utf8).write(to: tempDirectory.appendingPathComponent("shot.png"))
    try Data("test".utf8).write(to: tempDirectory.appendingPathComponent("shot_2.png"))

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "shot",
      fileExtension: "png"
    )
    XCTAssertEqual(result.lastPathComponent, "shot_3.png")
  }

  func testMakeUniqueFileURL_withNestedBaseName_returnsSubfolderURL() {
    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "Shots/May/shot",
      fileExtension: "png"
    )

    let expected = tempDirectory
      .appendingPathComponent("Shots/May/shot.png")
    XCTAssertEqual(result.path, expected.path)
  }

  func testMakeUniqueFileURL_withNestedCollision_appendsSuffixToLeaf() throws {
    let nestedDirectory = tempDirectory
      .appendingPathComponent("Shots/May", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
    try Data("test".utf8).write(to: nestedDirectory.appendingPathComponent("shot.png"))
    try Data("test".utf8).write(to: nestedDirectory.appendingPathComponent("shot_2.png"))

    let result = CaptureOutputNaming.makeUniqueFileURL(
      in: tempDirectory,
      baseName: "Shots/May/shot",
      fileExtension: "png"
    )

    XCTAssertEqual(result.lastPathComponent, "shot_3.png")
    XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent, "May")
  }

  @MainActor
  func testSaveProcessedImage_withNestedFileName_createsParentDirectory() async throws {
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 2, height: 2))
    let baseName = CaptureOutputNaming.resolveBaseName(
      customName: "Runtime/Subfolder/shot",
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      image,
      to: tempDirectory,
      fileName: baseName,
      format: .png
    )

    guard case .success(let url) = result else {
      XCTFail("Expected nested screenshot save to succeed, got \(result)")
      return
    }

    let expectedURL = tempDirectory.appendingPathComponent("Runtime/Subfolder/shot.png")
    XCTAssertEqual(url.path, expectedURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
  }

  // MARK: - resolvedTemplate

  func testResolvedTemplate_withSavedValue_returnsSavedValue() {
    defaults.set("Custom_{date}", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults)
    XCTAssertEqual(result, "Custom_{date}")
  }

  func testResolvedTemplate_withEmptyValue_returnsDefault() {
    defaults.set("", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults)
    XCTAssertEqual(result, CaptureOutputKind.screenshot.defaultTemplate)
  }

  func testResolvedTemplate_withMissingKey_returnsDefault() {
    defaults.removeObject(forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults)
    XCTAssertEqual(result, CaptureOutputKind.screenshot.defaultTemplate)
  }

  func testResolvedTemplate_recording_returnsRecordingDefault() {
    defaults.removeObject(forKey: PreferencesKeys.recordingFileNameTemplate)

    let result = CaptureOutputNaming.resolvedTemplate(for: .recording, defaults: defaults)
    XCTAssertEqual(result, CaptureOutputKind.recording.defaultTemplate)
  }

  // MARK: - CaptureOutputKind Properties

  func testCaptureOutputKind_defaultTemplates() {
    XCTAssertEqual(CaptureOutputKind.screenshot.defaultTemplate, "ShotPaste_{datetime}_{ms}")
    XCTAssertEqual(CaptureOutputKind.recording.defaultTemplate, "ShotPaste_Recording_{datetime}")
  }

  func testCaptureOutputKind_typeTokenValues() {
    XCTAssertEqual(CaptureOutputKind.screenshot.typeTokenValue, "screenshot")
    XCTAssertEqual(CaptureOutputKind.recording.typeTokenValue, "recording")
  }

  // MARK: - Fallback Name

  func testResolveBaseName_invalidTemplate_usesFallbackName() {
    // Template that resolves to empty after sanitization
    defaults.set("...", forKey: PreferencesKeys.screenshotFileNameTemplate)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      defaults: defaults
    )

    // Fallback format: "ShotPaste_{yyyy-MM-dd_HH-mm-ss-SSS}"
    XCTAssertTrue(result.hasPrefix("ShotPaste_"), "Expected fallback name, got: \(result)")
  }

  // MARK: - App Name Tokens

  func testResolveBaseName_appNameTokens() {
    defaults.set("App_{appName}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    let context = CaptureContext(appName: "Safari", windowTitle: nil)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      context: context,
      defaults: defaults
    )
    XCTAssertEqual(result, "App_Safari")
  }

  func testResolveBaseName_appNameTokens_aliases() {
    defaults.set("App_{app_name}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    let context = CaptureContext(appName: "Finder", windowTitle: nil)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      context: context,
      defaults: defaults
    )
    XCTAssertEqual(result, "App_Finder")
  }

  func testResolveBaseName_appNameTokens_missing() {
    defaults.set("App_{appName}", forKey: PreferencesKeys.screenshotFileNameTemplate)
    let context = CaptureContext(appName: nil, windowTitle: nil)

    let result = CaptureOutputNaming.resolveBaseName(
      customName: nil,
      kind: .screenshot,
      date: fixedDate,
      context: context,
      defaults: defaults
    )
    // When appName is missing, it should resolve to empty string
    // Resulting in App_
    XCTAssertEqual(result, "App_")
  }
}
