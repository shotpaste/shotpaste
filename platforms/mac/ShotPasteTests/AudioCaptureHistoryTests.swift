//
//  AudioCaptureHistoryTests.swift
//  ShotPasteTests
//
//  Audio history type, category, metadata, and thumbnail coverage.
//

import AppKit
import GRDB
@testable import ShotPaste
import XCTest

@MainActor
final class AudioCaptureHistoryTests: XCTestCase {
  func testAudioRawValueAndCategoryAreStable() {
    XCTAssertEqual(CaptureHistoryType.audio.rawValue, "audio")
    XCTAssertEqual(CaptureHistoryType(rawValue: "audio"), .audio)
    XCTAssertEqual(CaptureHistoryType(rawValue: "video"), .video)

    let captureRecord = makeRecord(origin: .capture)
    let clipboardOriginRecord = makeRecord(origin: .clipboard)
    XCTAssertEqual(captureRecord.category, .recording)
    XCTAssertEqual(clipboardOriginRecord.category, .recording)
    XCTAssertTrue(CaptureHistoryCategory.recording != .clipboard)
  }

  func testExistingHistoryTypesStillDecodeAndKeepTheirCategories() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for type in [CaptureHistoryType.screenshot, .video, .gif, .text, .file] {
      let record = makeRecord(type: type)
      let decoded = try decoder.decode(
        CaptureHistoryRecord.self,
        from: encoder.encode(record)
      )
      XCTAssertEqual(decoded.captureType, type)
      XCTAssertEqual(decoded.filePath, record.filePath)
    }
  }

  func testResilientHistoryRowsSkipUnknownEnumsAndKeepKnownOrder() throws {
    let database = try DatabaseQueue()
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let audio = makeRecord(
      type: .audio,
      capturedAt: baseDate.addingTimeInterval(500),
      fileName: "audio.m4a"
    )
    let unknownCaptureType = makeRecord(
      type: .screenshot,
      capturedAt: baseDate.addingTimeInterval(450),
      fileName: "future-capture.png"
    )
    let screenshot = makeRecord(
      type: .screenshot,
      capturedAt: baseDate.addingTimeInterval(400),
      fileName: "screenshot.png"
    )
    let unknownOrigin = makeRecord(
      type: .audio,
      capturedAt: baseDate.addingTimeInterval(350),
      fileName: "future-origin.m4a"
    )
    let oldRecords = [
      makeRecord(
        type: .video,
        capturedAt: baseDate.addingTimeInterval(300),
        fileName: "video.mp4"
      ),
      makeRecord(
        type: .gif,
        capturedAt: baseDate.addingTimeInterval(200),
        fileName: "animation.gif"
      ),
      makeRecord(
        type: .text,
        origin: .clipboard,
        capturedAt: baseDate.addingTimeInterval(100),
        fileName: "text.txt"
      ),
      makeRecord(
        type: .file,
        origin: .clipboard,
        capturedAt: baseDate.addingTimeInterval(50),
        fileName: "document.pdf"
      ),
    ]

    try database.write { db in
      try db.create(table: "captureHistoryRecord") { table in
        table.column("id", .text).primaryKey()
        table.column("filePath", .text).notNull()
        table.column("fileName", .text).notNull()
        table.column("captureType", .text).notNull()
        table.column("fileSize", .integer).notNull()
        table.column("capturedAt", .datetime).notNull()
        table.column("width", .integer)
        table.column("height", .integer)
        table.column("duration", .double)
        table.column("thumbnailPath", .text)
        table.column("isDeleted", .boolean).notNull().defaults(to: false)
        table.column("origin", .text).notNull().defaults(to: "capture")
      }
      try audio.insert(db)
      try unknownCaptureType.insert(db)
      try screenshot.insert(db)
      try unknownOrigin.insert(db)
      for record in oldRecords {
        try record.insert(db)
      }
      try db.execute(
        sql: "UPDATE captureHistoryRecord SET captureType = ? WHERE id = ?",
        arguments: ["future-capture-type", unknownCaptureType.id]
      )
      try db.execute(
        sql: "UPDATE captureHistoryRecord SET origin = ? WHERE id = ?",
        arguments: ["future-origin", unknownOrigin.id]
      )
    }

    let rows = try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM captureHistoryRecord ORDER BY capturedAt DESC"
      )
    }
    let decoded = CaptureHistoryRecordResilientDecoder.decode(rows: rows)

    XCTAssertEqual(
      decoded.map(\.fileName),
      [
        "audio.m4a",
        "screenshot.png",
        "video.mp4",
        "animation.gif",
        "text.txt",
        "document.pdf",
      ]
    )
    XCTAssertEqual(decoded.map(\.captureType), [.audio, .screenshot, .video, .gif, .text, .file])
    XCTAssertEqual(decoded.map(\.origin), [.capture, .capture, .capture, .capture, .clipboard, .clipboard])

    let remainingRows = try database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM captureHistoryRecord")
    }
    XCTAssertEqual(remainingRows.count, 8)
    XCTAssertTrue(remainingRows.contains {
      let value: String? = $0["captureType"]
      return value == "future-capture-type"
    })
    XCTAssertTrue(remainingRows.contains {
      let value: String? = $0["origin"]
      return value == "future-origin"
    })
  }

  func testAudioDurationFormattingAndProcessingPlaceholderAreOptional() {
    let record = makeRecord()
    XCTAssertEqual(record.formattedDuration, nil)
    XCTAssertEqual(
      CaptureHistoryRecord.formattedDuration(for: 61.9),
      "01:01s"
    )
    XCTAssertEqual(record.audioProcessingStatus, .notStarted)
    XCTAssertEqual(record.audioProcessingStatus?.displayName, L10n.AudioRecording.notStarted)
  }

  func testAudioQuickAccessCardUsesRecordingTypeForActionsAndAccessibility() {
    XCTAssertEqual(QuickAccessCardView.captureType(for: .audio), .recording)
    XCTAssertEqual(QuickAccessCardView.captureType(for: .video), .recording)
    XCTAssertEqual(QuickAccessCardView.captureType(for: .screenshot), .screenshot)
  }

  func testAudioHistoryThumbnailNeverReadsVideoFrames() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteTests_AudioHistoryThumbnail_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let audioURL = directory.appendingPathComponent("voice.m4a")
    try AudioTestMediaFactory.writeM4A(to: audioURL)
    let staleVideoThumbnail = directory.appendingPathComponent("stale.jpg")
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: staleVideoThumbnail)

    var record = makeRecord()
    record.filePath = audioURL.path
    record.fileName = audioURL.lastPathComponent
    let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
    record.fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    record.thumbnailPath = staleVideoThumbnail.path

    let generator = HistoryThumbnailGenerator(
      thumbnailsDirectory: directory.appendingPathComponent("cache", isDirectory: true)
    )
    let image = await generator.loadThumbnailImage(for: record)
    XCTAssertNil(image)
  }

  private func makeRecord(
    type: CaptureHistoryType = .audio,
    origin: CaptureHistoryOrigin = .capture,
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    fileName: String = "voice.m4a"
  ) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(),
      filePath: "/tmp/\(fileName)",
      fileName: fileName,
      captureType: type,
      fileSize: 1,
      capturedAt: capturedAt,
      width: nil,
      height: nil,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false,
      origin: origin
    )
  }
}
