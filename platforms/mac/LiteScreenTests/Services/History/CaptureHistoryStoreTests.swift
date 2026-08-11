//
//  CaptureHistoryStoreTests.swift
//  LiteScreenTests
//
//  Integration tests for CaptureHistoryStore GRDB persistence.
//

import Foundation
@testable import LiteScreen
import XCTest

@MainActor
final class CaptureHistoryStoreTests: XCTestCase {
  private var testDirectory: URL!
  private var defaults: UserDefaults!
  private var defaultsSuiteName: String!

  override func setUp() {
    super.setUp()
    defaultsSuiteName = "LiteScreenTests.CaptureHistoryStoreTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: defaultsSuiteName)
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    CaptureHistoryStore.shared.userDefaults = defaults

    testDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiteScreenTests_CaptureHistoryStore_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
  }

  override func tearDown() {
    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
    try? FileManager.default.removeItem(at: testDirectory)
    UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    CaptureHistoryStore.shared.userDefaults = .standard
    super.tearDown()
  }

  // MARK: - add

  func testAdd_noOpWhenHistoryDisabled() {
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    let record = makeRecord()

    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.records.isEmpty)
  }

  func testAdd_insertsRecordWhenEnabled() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 1)
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
  }

  // MARK: - remove

  func testRemoveId_deletesRecord() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.remove(id: record.id)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.records.isEmpty)
  }

  func testRemoveIds_deduplicatesInput() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.remove(ids: [record.id, record.id, record.id])
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.records.isEmpty)
  }

  func testRemoveIds_emptyArray_noOp() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.remove(ids: [])
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 1)
  }

  func testRemoveByFilePath_removesMatchingRecords() {
    let path = testDirectory.appendingPathComponent("a.png").path
    let r1 = makeRecord(filePath: path)
    let r2 = makeRecord(filePath: testDirectory.appendingPathComponent("b.png").path)
    CaptureHistoryStore.shared.add(r1)
    CaptureHistoryStore.shared.add(r2)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.removeByFilePath(path)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 1)
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: path))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: r2.filePath))
  }

  func testRemoveAll_wipesAllRecords() {
    CaptureHistoryStore.shared.add(makeRecord())
    CaptureHistoryStore.shared.add(makeRecord())
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.records.isEmpty)
  }

  // MARK: - updateThumbnailPath

  func testUpdateThumbnailPath_setsPath() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.updateThumbnailPath(id: record.id, path: "/tmp/thumb.png")
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertEqual(CaptureHistoryStore.shared.records.first?.thumbnailPath, "/tmp/thumb.png")
  }

  func testUpdateThumbnailPath_nilClearsPath() {
    let record = makeRecord(thumbnailPath: "/tmp/thumb.png")
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.updateThumbnailPath(id: record.id, path: nil)
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertNil(CaptureHistoryStore.shared.records.first?.thumbnailPath)
  }

  // MARK: - updateFilePath

  func testUpdateFilePathId_updatesPathAndFileName() {
    let record = makeRecord(filePath: "/tmp/old.png")
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.updateFilePath(id: record.id, newPath: "/tmp/new.jpg")
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertEqual(CaptureHistoryStore.shared.records.first?.filePath, "/tmp/new.jpg")
    XCTAssertEqual(CaptureHistoryStore.shared.records.first?.fileName, "new.jpg")
  }

  func testUpdateFilePathBulk_updatesMatchingRecords() {
    let oldPath = "/tmp/shared.png"
    let r1 = makeRecord(filePath: oldPath)
    let r2 = makeRecord(filePath: oldPath)
    let r3 = makeRecord(filePath: "/tmp/other.png")
    CaptureHistoryStore.shared.add(r1)
    CaptureHistoryStore.shared.add(r2)
    CaptureHistoryStore.shared.add(r3)
    CaptureHistoryStore.shared.refreshRecords()

    let count = CaptureHistoryStore.shared.updateFilePath(from: oldPath, to: "/tmp/moved.png")
    XCTAssertEqual(count, 2)

    CaptureHistoryStore.shared.refreshRecords()
    let updatedPaths = CaptureHistoryStore.shared.records.map(\.filePath)
    XCTAssertEqual(updatedPaths.filter { $0 == "/tmp/moved.png" }.count, 2)
    XCTAssertTrue(updatedPaths.contains("/tmp/other.png"))
  }

  // MARK: - markFileChanged

  func testMarkFileChanged_setsThumbnailNilAndUpdatesFileSize() {
    let fileURL = testDirectory.appendingPathComponent("changed.png")
    try? Data("pngdata".utf8).write(to: fileURL)
    let record = makeRecord(filePath: fileURL.path, thumbnailPath: "/tmp/thumb.png")
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    let expectation = expectation(forNotification: .captureHistoryFileDidChange,
                                  object: CaptureHistoryStore.shared) { notification in
      guard let ids = notification.userInfo?["recordIDs"] as? [UUID] else { return false }
      return ids.contains(record.id)
    }

    let updatedIds = CaptureHistoryStore.shared.markFileChanged(at: fileURL)
    XCTAssertEqual(updatedIds, [record.id])

    wait(for: [expectation], timeout: 2.0)

    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertNil(CaptureHistoryStore.shared.records.first?.thumbnailPath)
    XCTAssertEqual(CaptureHistoryStore.shared.records.first?.fileSize, 7)
    XCTAssertEqual(CaptureHistoryStore.shared.records.first?.fileName, "changed.png")
  }

  func testMarkFileChanged_returnsEmptyForUnknownFile() {
    let fileURL = testDirectory.appendingPathComponent("unknown.png")
    let updatedIds = CaptureHistoryStore.shared.markFileChanged(at: fileURL)
    XCTAssertTrue(updatedIds.isEmpty)
  }

  // MARK: - hasRecord

  func testHasRecord_trueForExistingPath() {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
  }

  func testHasRecord_falseForMissingPath() {
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: "/tmp/nonexistent.png"))
  }

  // MARK: - removeOlderThan

  func testRemoveOlderThan_zeroDays_noOp() {
    let oldRecord = makeRecord(capturedAt: Date().addingTimeInterval(-86400 * 10))
    CaptureHistoryStore.shared.add(oldRecord)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.removeOlderThan(days: 0)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 1)
  }

  func testRemoveOlderThan_removesOldRecords() {
    let old = makeRecord(capturedAt: Date().addingTimeInterval(-86400 * 10))
    let recent = makeRecord(capturedAt: Date())
    CaptureHistoryStore.shared.add(old)
    CaptureHistoryStore.shared.add(recent)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.removeOlderThan(days: 7)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 1)
    XCTAssertEqual(CaptureHistoryStore.shared.records.first?.id, recent.id)
  }

  // MARK: - trimToMaxCount

  func testTrimToMaxCount_zero_noOp() {
    CaptureHistoryStore.shared.add(makeRecord())
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.trimToMaxCount(0)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 1)
  }

  func testTrimToMaxCount_keepsNewest() {
    let r1 = makeRecord(capturedAt: Date().addingTimeInterval(-10))
    let r2 = makeRecord(capturedAt: Date().addingTimeInterval(-5))
    let r3 = makeRecord(capturedAt: Date())
    CaptureHistoryStore.shared.add(r1)
    CaptureHistoryStore.shared.add(r2)
    CaptureHistoryStore.shared.add(r3)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.trimToMaxCount(2)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertEqual(CaptureHistoryStore.shared.records.count, 2)
    let ids = Set(CaptureHistoryStore.shared.records.map(\.id))
    XCTAssertTrue(ids.contains(r2.id))
    XCTAssertTrue(ids.contains(r3.id))
    XCTAssertFalse(ids.contains(r1.id))
  }

  // MARK: - addCapture

  func testAddCapture_readsFileSize() throws {
    let fileURL = testDirectory.appendingPathComponent("capture.png")
    let data = Data("hello capture".utf8)
    try data.write(to: fileURL)

    CaptureHistoryStore.shared.addCapture(
      url: fileURL,
      captureType: .screenshot,
      duration: nil,
      width: 100,
      height: 200
    )
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: fileURL.path))
    let record = CaptureHistoryStore.shared.records.first { $0.filePath == fileURL.path }
    XCTAssertEqual(record?.fileSize, Int64(data.count))
    XCTAssertEqual(record?.width, 100)
    XCTAssertEqual(record?.height, 200)
  }

  // MARK: - clearAllThumbnailPaths

  func testClearAllThumbnailPaths_nullifiesPaths() {
    let r1 = makeRecord(thumbnailPath: "/tmp/t1.png")
    let r2 = makeRecord(thumbnailPath: "/tmp/t2.png")
    CaptureHistoryStore.shared.add(r1)
    CaptureHistoryStore.shared.add(r2)
    CaptureHistoryStore.shared.refreshRecords()

    CaptureHistoryStore.shared.clearAllThumbnailPaths()
    CaptureHistoryStore.shared.refreshRecords()

    XCTAssertNil(CaptureHistoryStore.shared.records.first?.thumbnailPath)
    XCTAssertNil(CaptureHistoryStore.shared.records.last?.thumbnailPath)
  }

  // MARK: - recentRecords

  func testRecentReturnsPrefix() {
    for i in 0 ..< 5 {
      CaptureHistoryStore.shared.add(makeRecord(capturedAt: Date().addingTimeInterval(-Double(i))))
    }
    CaptureHistoryStore.shared.refreshRecords()

    let recent = CaptureHistoryStore.shared.recentRecords(limit: 3)
    XCTAssertEqual(recent.count, 3)
  }

  // MARK: - Helpers

  private func makeRecord(
    filePath: String? = nil,
    thumbnailPath: String? = nil,
    capturedAt: Date = Date()
  ) -> CaptureHistoryRecord {
    let path = filePath ?? testDirectory.appendingPathComponent("\(UUID().uuidString).png").path
    return CaptureHistoryRecord(
      id: UUID(),
      filePath: path,
      fileName: (path as NSString).lastPathComponent,
      captureType: .screenshot,
      fileSize: 1024,
      capturedAt: capturedAt,
      width: 100,
      height: 100,
      duration: nil,
      thumbnailPath: thumbnailPath,
      isDeleted: false
    )
  }
}
