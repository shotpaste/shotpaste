//
//  PostCaptureActionHandlerTests.swift
//  ShotPasteTests
//
//  Unit tests for PostCaptureActionHandler routing logic.
//

import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class PostCaptureActionHandlerTests: XCTestCase {
  private var defaults: UserDefaults!
  private var preferences: PreferencesManager!
  private var tempDirectory: URL!
  private var tempFileURL: URL!

  override func setUp() async throws {
    try await super.setUp()
    defaults = UserDefaultsFactory.make()
    preferences = PreferencesManager(defaults: defaults)
    resetAfterCaptureActionsToDefaults()

    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteTests_PostCapture_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

    // Create a minimal test image file
    tempFileURL = tempDirectory.appendingPathComponent("test_capture.png")
    guard let image = TestImageFactory.solidColor(width: 10, height: 10) else {
      XCTFail("Failed to create test image")
      return
    }
    let bitmapRep = NSBitmapImageRep(cgImage: image)
    let pngData = bitmapRep.representation(using: .png, properties: [:])
    try pngData?.write(to: tempFileURL)
  }

  override func tearDown() async throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    try await super.tearDown()
  }

  private func resetAfterCaptureActionsToDefaults() {
    preferences.afterCaptureActions = Self.defaultAfterCaptureActions()
  }

  private static func defaultAfterCaptureActions() -> [AfterCaptureAction: [CaptureType: Bool]] {
    var defaults: [AfterCaptureAction: [CaptureType: Bool]] = [:]
    for action in AfterCaptureAction.allCases {
      defaults[action] = [:]
      for captureType in CaptureType.allCases {
        defaults[action]?[captureType] = defaultValue(for: action)
      }
    }
    return defaults
  }

  private static func defaultValue(for action: AfterCaptureAction) -> Bool {
    switch action {
    case .showQuickAccess, .save, .copyFile:
      true
    }
  }

  private func makeHandler(quickAccess: QuickAccessManaging) -> PostCaptureActionHandler {
    PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
  }

  // MARK: - PreferencesManager Routing Logic

  func testIsActionEnabled_defaultValues() {
    // Default: showQuickAccess and copyFile are ON for both types
    XCTAssertTrue(preferences.isActionEnabled(.showQuickAccess, for: .screenshot))
    XCTAssertTrue(preferences.isActionEnabled(.showQuickAccess, for: .recording))
    XCTAssertTrue(preferences.isActionEnabled(.copyFile, for: .screenshot))
    XCTAssertTrue(preferences.isActionEnabled(.copyFile, for: .recording))
    XCTAssertTrue(preferences.isActionEnabled(.save, for: .screenshot))
    XCTAssertTrue(preferences.isActionEnabled(.save, for: .recording))
  }

  func testSetAndCheckActionEnabled() {
    // Disable quickAccess for screenshots
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    XCTAssertFalse(preferences.isActionEnabled(.showQuickAccess, for: .screenshot))

    // Re-enable
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: true)
    XCTAssertTrue(preferences.isActionEnabled(.showQuickAccess, for: .screenshot))
  }

  // MARK: - Missing File Safety

  func testHandleScreenshotCapture_missingFile_doesNotAddToQuickAccess() async {
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)
    let nonexistentURL = tempDirectory.appendingPathComponent("does_not_exist.png")

    await handler.handleScreenshotCapture(url: nonexistentURL)

    XCTAssertEqual(fakeQuickAccess.addedScreenshots.count, 0)
  }

  func testHandleVideoCapture_missingFile_doesNotAddToQuickAccess() async {
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)
    let nonexistentURL = tempDirectory.appendingPathComponent("does_not_exist.mov")

    await handler.handleVideoCapture(url: nonexistentURL)

    XCTAssertEqual(fakeQuickAccess.addedVideos.count, 0)
  }

  func testHandleScreenshotCapture_copiesToClipboardBeforeQuickAccess() async throws {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)

    let expectedURL = try XCTUnwrap(tempFileURL)
    let fakeQuickAccess = FakeQuickAccessManager()
    fakeQuickAccess.onAddScreenshot = { url in
      XCTAssertEqual(url, expectedURL)
      let item = NSPasteboard.general.pasteboardItems?.first
      XCTAssertTrue(item?.types.contains(.fileURL) ?? false)
      XCTAssertTrue(item?.types.contains(.png) ?? false)
      XCTAssertEqual(
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?
          .standardizedFileURL,
        expectedURL.standardizedFileURL
      )
    }
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleScreenshotCapture(url: tempFileURL)

    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL])
  }

  func testHandleVideoCapture_copiesMediaFileToClipboardBeforeQuickAccess() async throws {
    let videoURL = tempDirectory.appendingPathComponent("test_recording.mp4")
    try Data([0, 1, 2, 3]).write(to: videoURL)

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)

    let fakeQuickAccess = FakeQuickAccessManager()
    fakeQuickAccess.onAddVideo = { url in
      XCTAssertEqual(url, videoURL)
      let item = NSPasteboard.general.pasteboardItems?.first
      XCTAssertTrue(item?.types.contains(.fileURL) ?? false)
      XCTAssertTrue(item?.types.contains(.URL) ?? false)
      XCTAssertTrue(item?.types.contains(.string) ?? false)
      XCTAssertEqual(item?.string(forType: .URL), videoURL.absoluteString)
      XCTAssertEqual(item?.string(forType: .string), videoURL.path)
      XCTAssertEqual(
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?
          .standardizedFileURL,
        videoURL.standardizedFileURL
      )
    }
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    await handler.handleVideoCapture(url: videoURL)

    XCTAssertEqual(fakeQuickAccess.addedVideos, [videoURL])
  }

  func testHandleScreenshotCapture_pinToScreenPinsCreatedQuickAccessItem() async throws {
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    let returnedItem = await handler.handleScreenshotCapture(url: tempFileURL, pinToScreen: true)

    let item = try XCTUnwrap(fakeQuickAccess.createdScreenshotItems.first)
    XCTAssertEqual(returnedItem?.id, item.id)
    XCTAssertEqual(fakeQuickAccess.addedScreenshots, [tempFileURL])
    XCTAssertEqual(fakeQuickAccess.pinnedScreenshotIDs, [item.id])
    XCTAssertTrue(fakeQuickAccess.pinnedScreenshotURLs.isEmpty)
  }

  func testHandleScreenshotCapture_pinToScreenPinsURLWhenQuickAccessActionDisabled() async {
    preferences.setAction(.showQuickAccess, for: .screenshot, enabled: false)
    preferences.setAction(.copyFile, for: .screenshot, enabled: false)
    let fakeQuickAccess = FakeQuickAccessManager()
    let handler = makeHandler(quickAccess: fakeQuickAccess)

    let returnedItem = await handler.handleScreenshotCapture(url: tempFileURL, pinToScreen: true)

    XCTAssertNotNil(returnedItem)
    XCTAssertTrue(fakeQuickAccess.addedScreenshots.isEmpty)
    XCTAssertTrue(fakeQuickAccess.pinnedScreenshotIDs.isEmpty)
    XCTAssertEqual(fakeQuickAccess.pinnedScreenshotURLs, [tempFileURL])
  }

  // MARK: - AfterCaptureAction Properties

  func testAfterCaptureAction_allCases() {
    let allCases = AfterCaptureAction.allCases
    XCTAssertEqual(allCases.count, 3)
    XCTAssertTrue(allCases.contains(.showQuickAccess))
    XCTAssertTrue(allCases.contains(.copyFile))
    XCTAssertTrue(allCases.contains(.save))
  }

  func testAfterCaptureAction_displayNames_nonEmpty() {
    for action in AfterCaptureAction.allCases {
      XCTAssertFalse(action.displayName.isEmpty, "\(action.rawValue) has empty displayName")
    }
  }

  // MARK: - CaptureType Properties

  func testCaptureType_allCases() {
    XCTAssertEqual(CaptureType.allCases.count, 2)
    XCTAssertTrue(CaptureType.allCases.contains(.screenshot))
    XCTAssertTrue(CaptureType.allCases.contains(.recording))
  }

  func testCaptureType_rawValues() {
    XCTAssertEqual(CaptureType.screenshot.rawValue, "screenshot")
    XCTAssertEqual(CaptureType.recording.rawValue, "recording")
  }

  func testCaptureType_displayNames_nonEmpty() {
    for type in CaptureType.allCases {
      XCTAssertFalse(type.displayName.isEmpty, "\(type.rawValue) has empty displayName")
    }
  }
}
