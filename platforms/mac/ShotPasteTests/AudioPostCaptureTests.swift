//
//  AudioPostCaptureTests.swift
//  ShotPasteTests
//
//  Audio post-capture routing and format rejection coverage.
//

import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class AudioPostCaptureTests: XCTestCase {
  private var defaults: UserDefaults!
  private var preferences: PreferencesManager!
  private var temporaryDirectory: URL!
  private var pasteboardSnapshot: [PasteboardItemSnapshot] = []

  override func setUp() async throws {
    try await super.setUp()
    pasteboardSnapshot = Self.capturePasteboard()
    defaults = UserDefaultsFactory.make()
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    preferences = PreferencesManager(defaults: defaults)
    CaptureHistoryStore.shared.userDefaults = defaults

    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteTests_AudioPostCapture_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    Self.restorePasteboard(pasteboardSnapshot)
    CaptureHistoryStore.shared.userDefaults = .standard
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    try await super.tearDown()
  }

  private struct PasteboardItemSnapshot {
    let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
  }

  private static func capturePasteboard() -> [PasteboardItemSnapshot] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
      let representations = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
        if let data = item.data(forType: type) {
          return (type, data)
        }
        guard let string = item.string(forType: type),
              let data = string.data(using: .utf8)
        else {
          return nil
        }
        return (type, data)
      }
      return PasteboardItemSnapshot(representations: representations)
    }
  }

  private static func restorePasteboard(_ snapshot: [PasteboardItemSnapshot]) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let items = snapshot.map { savedItem in
      let item = NSPasteboardItem()
      for representation in savedItem.representations {
        item.setData(representation.data, forType: representation.type)
      }
      return item
    }
    if !items.isEmpty {
      _ = pasteboard.writeObjects(items)
    }
  }

  func testHandleAudioCaptureRejectsMOVAndMP4BeforeQuickAccessOrHistory() async throws {
    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)

    for extensionName in ["mov", "mp4"] {
      let url = temporaryDirectory.appendingPathComponent("internal-audio.\(extensionName)")
      try Data([0x00, 0x01]).write(to: url)

      let result = await handler.handleAudioCapture(url: url)

      XCTAssertFalse(result.accepted)
      XCTAssertFalse(result.historyPersisted)
      XCTAssertFalse(result.transcriptionCanContinue)
      XCTAssertEqual(result.rejection, .unsupportedFormat)
    }

    XCTAssertTrue(quickAccess.audioURLs.isEmpty)
    XCTAssertTrue(quickAccess.videoURLs.isEmpty)
    XCTAssertEqual(pasteboard.string(forType: .string), "stale clipboard value")
    XCTAssertFalse(CaptureHistoryStore.shared.records.contains { $0.fileName == "internal-audio.mov" })
    XCTAssertFalse(CaptureHistoryStore.shared.records.contains { $0.fileName == "internal-audio.mp4" })
  }

  func testHandleAudioCaptureUsesAudioQuickAccessAndPersistsM4A() async throws {
    preferences.setAction(.copyFile, for: .recording, enabled: false)
    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
    let url = temporaryDirectory.appendingPathComponent("meeting.m4a")
    try AudioTestMediaFactory.writeM4A(to: url)

    let result = await handler.handleAudioCapture(url: url)
    defer {
      _ = CaptureHistoryStore.shared.removeByFilePath(url.path)
    }

    XCTAssertTrue(result.accepted)
    XCTAssertTrue(result.transcriptionCanContinue)
    XCTAssertTrue(result.historyPersisted)
    XCTAssertNotNil(result.historyRecordID)
    XCTAssertNil(result.rejection)
    XCTAssertEqual(quickAccess.audioURLs, [url])
    XCTAssertTrue(quickAccess.videoURLs.isEmpty)
    XCTAssertEqual(
      CaptureHistoryStore.shared.records.first(where: { $0.filePath == url.path })?.captureType,
      .audio
    )
  }

  func testHandleAudioCaptureCopiesM4AAsFileURL() async throws {
    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
    let url = temporaryDirectory.appendingPathComponent("memo.m4a")
    try AudioTestMediaFactory.writeM4A(to: url)
    defer { _ = CaptureHistoryStore.shared.removeByFilePath(url.path) }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let result = await handler.handleAudioCapture(url: url)

    XCTAssertTrue(result.accepted)
    XCTAssertTrue(pasteboard.pasteboardItems?.first?.types.contains(.fileURL) ?? false)
    XCTAssertEqual(
      (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?
        .standardizedFileURL,
      url.standardizedFileURL
    )
  }

  func testHandleAudioCaptureRejectsDamagedM4AWithoutAnySideEffects() async throws {
    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
    let url = temporaryDirectory.appendingPathComponent("damaged.m4a")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)
    let result = await handler.handleAudioCapture(url: url)

    XCTAssertFalse(result.accepted)
    XCTAssertFalse(result.historyPersisted)
    XCTAssertFalse(result.transcriptionCanContinue)
    XCTAssertEqual(result.rejection, .assetUnreadable)
    XCTAssertTrue(quickAccess.audioURLs.isEmpty)
    XCTAssertTrue(quickAccess.videoURLs.isEmpty)
    XCTAssertEqual(pasteboard.string(forType: .string), "stale clipboard value")
    XCTAssertFalse(CaptureHistoryStore.shared.records.contains { $0.filePath == url.path })
  }

  func testHandleAudioCaptureRejectsVideoRenamedToM4AWithoutAnySideEffects() async throws {
    let sourceURL = temporaryDirectory.appendingPathComponent("video.mp4")
    let url = temporaryDirectory.appendingPathComponent("video.m4a")
    try AudioTestMediaFactory.writeVideoOnlyMP4(to: sourceURL)
    try FileManager.default.copyItem(at: sourceURL, to: url)

    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("stale clipboard value", forType: .string)
    let result = await handler.handleAudioCapture(url: url)

    XCTAssertFalse(result.accepted)
    XCTAssertFalse(result.historyPersisted)
    XCTAssertFalse(result.transcriptionCanContinue)
    XCTAssertEqual(result.rejection, .containsVideoTrack)
    XCTAssertTrue(quickAccess.audioURLs.isEmpty)
    XCTAssertEqual(pasteboard.string(forType: .string), "stale clipboard value")
    XCTAssertFalse(CaptureHistoryStore.shared.records.contains { $0.filePath == url.path })
  }

  func testHandleAudioCaptureHistoryDisabledDoesNotAllowTranscription() async throws {
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    preferences.setAction(.copyFile, for: .recording, enabled: false)
    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
    let url = temporaryDirectory.appendingPathComponent("history-disabled.m4a")
    try AudioTestMediaFactory.writeM4A(to: url)

    let result = await handler.handleAudioCapture(url: url)

    XCTAssertTrue(result.accepted)
    XCTAssertFalse(result.historyPersisted)
    XCTAssertNil(result.historyRecordID)
    XCTAssertFalse(result.transcriptionCanContinue)
    XCTAssertTrue(quickAccess.audioURLs.isEmpty == false)
    XCTAssertFalse(CaptureHistoryStore.shared.records.contains { $0.filePath == url.path })
  }

  func testHandleAudioCaptureSkipQuickAccessStillPersistsValidatedHistory() async throws {
    preferences.setAction(.copyFile, for: .recording, enabled: false)
    let quickAccess = AudioQuickAccessSpy()
    let handler = PostCaptureActionHandler(
      preferences: preferences,
      quickAccess: quickAccess,
      fileAccess: SandboxFileAccessManager.shared
    )
    let url = temporaryDirectory.appendingPathComponent("skip-quick-access.m4a")
    try AudioTestMediaFactory.writeM4A(to: url)
    defer { _ = CaptureHistoryStore.shared.removeByFilePath(url.path) }

    let result = await handler.handleAudioCapture(url: url, skipQuickAccess: true)

    XCTAssertTrue(result.accepted)
    XCTAssertTrue(result.historyPersisted)
    XCTAssertTrue(result.transcriptionCanContinue)
    XCTAssertTrue(quickAccess.audioURLs.isEmpty)
    let persistedDuration = CaptureHistoryStore.shared.records
      .first(where: { $0.filePath == url.path })?.duration
    XCTAssertNotNil(persistedDuration)
    XCTAssertTrue((persistedDuration ?? 0) > 0)
  }

  func testAudioURLPolicyAcceptsM4AAndRejectsInternalVideoContainers() {
    let m4a = temporaryDirectory.appendingPathComponent("voice.M4A")
    let mov = temporaryDirectory.appendingPathComponent("voice.MOV")
    let mp4 = temporaryDirectory.appendingPathComponent("voice.MP4")

    XCTAssertTrue(CaptureHistoryAudioURLPolicy.accepts(m4a))
    XCTAssertFalse(CaptureHistoryAudioURLPolicy.accepts(mov))
    XCTAssertFalse(CaptureHistoryAudioURLPolicy.accepts(mp4))
  }
}

@MainActor
private final class AudioQuickAccessSpy: QuickAccessManaging {
  private(set) var audioURLs: [URL] = []
  private(set) var videoURLs: [URL] = []

  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem? {
    QuickAccessItem(url: url, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
  }

  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem? {
    videoURLs.append(url)
    return QuickAccessItem(
      url: url,
      thumbnail: NSImage(size: NSSize(width: 1, height: 1)),
      duration: 0
    )
  }

  @discardableResult
  func addAudio(url: URL) async -> QuickAccessItem? {
    audioURLs.append(url)
    return QuickAccessItem(
      id: UUID(),
      url: url,
      thumbnail: NSImage(size: NSSize(width: 1, height: 1)),
      capturedAt: Date(),
      itemType: .audio,
      duration: 0
    )
  }

  func pinScreenshot(id _: UUID) {}

  @discardableResult
  func pinScreenshot(url: URL) async -> QuickAccessItem? {
    QuickAccessItem(url: url, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
  }
}
