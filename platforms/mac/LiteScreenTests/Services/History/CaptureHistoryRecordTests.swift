//
//  CaptureHistoryRecordTests.swift
//  LiteScreenTests
//
//  Unit tests for capture history record presentation helpers.
//

import Foundation
@testable import LiteScreen
import XCTest

final class CaptureHistoryRecordTests: XCTestCase {
  func testFormattedDuration_formatsFiniteNonNegativeDurations() {
    XCTAssertEqual(makeRecord(duration: 65.9).formattedDuration, "01:05s")
    XCTAssertEqual(makeRecord(duration: 0).formattedDuration, "00:00s")
  }

  func testFormattedDuration_omitsInvalidDurations() {
    XCTAssertNil(makeRecord(duration: nil).formattedDuration)
    XCTAssertNil(makeRecord(duration: -1).formattedDuration)
    XCTAssertNil(makeRecord(duration: .infinity).formattedDuration)
  }

  func testFileURLAndFileExistsReflectStoredPath() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiteScreenTests_HistoryRecord_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("capture.png")
    try Data("capture".utf8).write(to: fileURL)

    let record = makeRecord(filePath: fileURL.path)

    XCTAssertEqual(record.fileURL, fileURL)
    XCTAssertTrue(record.fileExists)
  }

  func testThumbnailURLRequiresExistingThumbnailFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiteScreenTests_HistoryThumbnail_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let thumbnailURL = directory.appendingPathComponent("thumb.png")
    let missingThumbnailURL = directory.appendingPathComponent("missing.png")
    try Data("thumb".utf8).write(to: thumbnailURL)

    XCTAssertEqual(makeRecord(thumbnailPath: thumbnailURL.path).thumbnailURL, thumbnailURL)
    XCTAssertNil(makeRecord(thumbnailPath: missingThumbnailURL.path).thumbnailURL)
    XCTAssertNil(makeRecord(thumbnailPath: nil).thumbnailURL)
  }

  func testTextRecordReadsPayloadAndUsesFirstLineAsTitle() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiteScreenTests_TextHistory_\(UUID().uuidString).txt")
    try Data("First line\nSecond line".utf8).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let record = makeRecord(filePath: fileURL.path, captureType: .text)

    XCTAssertEqual(record.textContent, "First line\nSecond line")
    XCTAssertEqual(record.textPreview, "First line\nSecond line")
    XCTAssertEqual(record.displayTitle, "First line")
    XCTAssertEqual(record.captureType.systemIconName, "doc.plaintext")
  }

  func testCategoryUsesCaptureOriginAndPayloadType() {
    XCTAssertEqual(makeRecord(captureType: .screenshot, origin: .capture).category, .screenshot)
    XCTAssertEqual(makeRecord(captureType: .screenshot, origin: .scrollingCapture).category, .scrollingScreenshot)
    XCTAssertEqual(makeRecord(captureType: .video, origin: .capture).category, .recording)
    XCTAssertEqual(makeRecord(captureType: .gif, origin: .capture).category, .recording)
    XCTAssertEqual(makeRecord(captureType: .text, origin: .clipboard).category, .clipboard)
    XCTAssertEqual(makeRecord(captureType: .file, origin: .clipboard).category, .clipboard)
  }

  private func makeRecord(
    filePath: String = "/tmp/capture.png",
    captureType: CaptureHistoryType = .video,
    duration: TimeInterval? = 12,
    thumbnailPath: String? = nil,
    origin: CaptureHistoryOrigin = .capture
  ) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(),
      filePath: filePath,
      fileName: URL(fileURLWithPath: filePath).lastPathComponent,
      captureType: captureType,
      fileSize: 1024,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      width: 640,
      height: 360,
      duration: duration,
      thumbnailPath: thumbnailPath,
      isDeleted: false,
      origin: origin
    )
  }
}
