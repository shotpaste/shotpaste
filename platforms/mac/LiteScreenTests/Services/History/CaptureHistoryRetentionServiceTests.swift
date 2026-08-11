//
//  CaptureHistoryRetentionServiceTests.swift
//  LiteScreenTests
//
//  Unit tests for retention service scheduling and sweep logic.
//  Verifies via synchronous DB reads to avoid observation timing issues.
//

import Foundation
@testable import LiteScreen
import XCTest

@MainActor
final class CaptureHistoryRetentionServiceTests: XCTestCase {
  private var service: CaptureHistoryRetentionService!
  private var defaults: UserDefaults!
  private var defaultsSuiteName: String!

  override func setUp() {
    super.setUp()
    service = CaptureHistoryRetentionService.shared
    defaultsSuiteName = "LiteScreenTests.CaptureHistoryRetentionServiceTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: defaultsSuiteName)
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    defaults.set(0, forKey: PreferencesKeys.historyRetentionDays)
    defaults.set(0, forKey: PreferencesKeys.historyMaxCount)
    CaptureHistoryStore.shared.userDefaults = defaults
    service.userDefaults = defaults

    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
  }

  override func tearDown() {
    service.stop()
    CaptureHistoryStore.shared.removeAll()
    CaptureHistoryStore.shared.refreshRecords()
    UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    CaptureHistoryStore.shared.userDefaults = .standard
    service.userDefaults = .standard
    super.tearDown()
  }

  // MARK: - sweep

  func testSweep_skipsWhenHistoryDisabled() async {
    defaults.set(false, forKey: PreferencesKeys.historyEnabled)
    await service.sweep()
  }

  func testSweep_noOpWhenRetentionDaysZeroAndMaxCountZero() async {
    let record = makeRecord()
    CaptureHistoryStore.shared.add(record)
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))

    await service.sweep()
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: record.filePath))
  }

  func testSweep_removesOldRecordsWhenRetentionDaysSet() async {
    defaults.set(7, forKey: PreferencesKeys.historyRetentionDays)
    let old = makeRecord(capturedAt: Date().addingTimeInterval(-86400 * 10))
    let recent = makeRecord(capturedAt: Date())
    CaptureHistoryStore.shared.add(old)
    CaptureHistoryStore.shared.add(recent)
    CaptureHistoryStore.shared.refreshRecords()

    await service.sweep()
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertFalse(CaptureHistoryStore.shared.hasRecord(forFilePath: old.filePath))
    XCTAssertTrue(CaptureHistoryStore.shared.hasRecord(forFilePath: recent.filePath))
  }

  func testSweep_trimsToMaxCount() async {
    defaults.set(2, forKey: PreferencesKeys.historyMaxCount)
    let r1 = makeRecord(capturedAt: Date().addingTimeInterval(-10))
    let r2 = makeRecord(capturedAt: Date().addingTimeInterval(-5))
    let r3 = makeRecord(capturedAt: Date())
    CaptureHistoryStore.shared.add(r1)
    CaptureHistoryStore.shared.add(r2)
    CaptureHistoryStore.shared.add(r3)
    CaptureHistoryStore.shared.refreshRecords()

    await service.sweep()
    CaptureHistoryStore.shared.refreshRecords()
    let ids = Set(CaptureHistoryStore.shared.records.map(\.id))
    XCTAssertEqual(ids.count, 2)
    XCTAssertTrue(ids.contains(r2.id))
    XCTAssertTrue(ids.contains(r3.id))
  }

  // MARK: - clearAllHistory

  func testClearAllHistory_removesAllRecordsAndThumbnails() {
    CaptureHistoryStore.shared.add(makeRecord())
    CaptureHistoryStore.shared.refreshRecords()

    service.clearAllHistory()
    CaptureHistoryStore.shared.refreshRecords()
    XCTAssertTrue(CaptureHistoryStore.shared.records.isEmpty)
  }

  // MARK: - start / stop

  func testStartStop_lifecycleDoesNotCrash() {
    service.start()
    service.stop()
    service.start()
    service.stop()
  }

  // MARK: - Helpers

  private func makeRecord(capturedAt: Date = Date()) -> CaptureHistoryRecord {
    let path = "/tmp/\(UUID().uuidString).png"
    return makeRecord(filePath: path, capturedAt: capturedAt)
  }

  private func makeRecord(filePath path: String, capturedAt: Date = Date()) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(),
      filePath: path,
      fileName: (path as NSString).lastPathComponent,
      captureType: .screenshot,
      fileSize: 1024,
      capturedAt: capturedAt,
      width: 100,
      height: 100,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false
    )
  }
}
