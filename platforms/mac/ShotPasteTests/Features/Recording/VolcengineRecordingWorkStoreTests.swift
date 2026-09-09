import Foundation
@testable import ShotPaste
import XCTest

final class VolcengineRecordingWorkStoreTests: XCTestCase {
  func testParentReceiptPersistsOriginalMediaAndCompletedTimelineAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-store-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VolcengineRecordingWorkStore(root: root)
    let configuration = RecordingTranscriptionConfiguration(account: .init(), sourceLanguage: .auto)
    let url = root.appendingPathComponent("original.m4a")
    let work = try await store.begin(url: url, configuration: configuration, checksum: "checksum")
    let transcript = RecordingTranscript(text: "both parts", segments: [
      .init(text: "first", startTime: 0.5, duration: 2),
      .init(text: "second", startTime: 14001, duration: 2)])
    try await store.finish(work.id, transcript: transcript)
    let restored = VolcengineRecordingWorkStore(root: root)
    let saved = try await restored.begin(url: url, configuration: configuration, checksum: "checksum")
    XCTAssertEqual(saved.transcript, transcript)
    XCTAssertEqual(saved.recordingURL, url)
    XCTAssertEqual(saved.state, .completed)
    let retained = await restored.profilesToRetain()
    XCTAssertTrue(retained.isEmpty)
  }
  func testCancelledParentDoesNotRestartAndFailedParentRetainsItsProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("work-store-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = VolcengineRecordingWorkStore(root: root)
    let configuration = RecordingTranscriptionConfiguration(account: .init(), sourceLanguage: .auto)
    let url = root.appendingPathComponent("original.m4a")
    let work = try await store.begin(url: url, configuration: configuration, checksum: "checksum")
    try await store.finish(work.id, transcript: nil)
    let retained = await store.profilesToRetain()
    XCTAssertEqual(retained, [configuration.account.id])
    try await store.finish(work.id, transcript: nil, cancelled: true)
    do { _ = try await store.begin(url: url, configuration: configuration, checksum: "checksum"); XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
  }
}
