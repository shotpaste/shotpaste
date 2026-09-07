import AVFoundation
import Foundation
@testable import ShotPaste
import XCTest

final class VolcengineAudioPreparationTests: XCTestCase {
  func testNativeAudioExportAndQuietBoundaryWithinHardLimit() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("asr-fixture-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
      buffer.frameLength = 24000
      for i in 0..<24000 {
        let time = Double(i) / 8000
        buffer.floatChannelData![0][i] = (time > 1.2 && time < 1.4) ? 0 : Float(sin(time * 440 * 2 * .pi) * 0.3)
      }
      try file.write(from: buffer)
    }
    let duration = try await VolcengineAudioPreparation.duration(url)
    XCTAssertEqual(duration, 3, accuracy: 0.01)
    XCTAssertEqual(try VolcengineAudioPreparation.checksum(url).count, 64)
    let part = try await VolcengineAudioPreparation.prepare(url, start: 0, totalDuration: duration, maximumPartDuration: 1.5)
    defer { try? FileManager.default.removeItem(at: part.url) }
    XCTAssertTrue(part.temporary)
    XCTAssertGreaterThan(part.duration, 1.1)
    XCTAssertLessThan(part.duration, 1.5)
    let exported = try await VolcengineAudioPreparation.duration(part.url)
    XCTAssertEqual(exported, part.duration, accuracy: 0.15)
    let video = try await AVURLAsset(url: part.url).loadTracks(withMediaType: .video)
    XCTAssertTrue(video.isEmpty)
    let reused = try await VolcengineAudioPreparation.prepare(part.url, start: 0, totalDuration: exported)
    XCTAssertFalse(reused.temporary)
    XCTAssertEqual(reused.url, part.url)
  }
  func testEmptyAndSymlinkInputsAreRejectedBeforeUpload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("asr-invalid-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("empty.m4a")
    try Data().write(to: empty)
    do { _ = try await VolcengineAudioPreparation.duration(empty); XCTFail("Expected invalid media") } catch { }
    let link = root.appendingPathComponent("link.m4a")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)
    XCTAssertThrowsError(try VolcengineAudioPreparation.checksum(link))
  }
}
