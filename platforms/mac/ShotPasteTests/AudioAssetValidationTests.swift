//
//  AudioAssetValidationTests.swift
//  ShotPasteTests
//
//  Real AVFoundation fixtures and shared validator coverage.
//

import AVFoundation
import CoreVideo
import Foundation
@testable import ShotPaste
import XCTest

/// Creates small, valid media files for audio history/post-capture tests.
/// Keeping this stream-based avoids teaching tests that arbitrary bytes with
/// an `.m4a` suffix are a valid capture.
enum AudioTestMediaFactory {
  static func writeM4A(
    to url: URL,
    duration: TimeInterval = 0.25
  ) throws {
    try writeAudio(to: url, fileType: .m4a, duration: duration)
  }

  static func writeQuickTimeAudioOnlyMOV(
    to url: URL,
    duration: TimeInterval = 0.25
  ) throws {
    try writeAudio(to: url, fileType: .mov, duration: duration)
  }

  /// Replaces only the four-byte major brand in a complete ftyp box. This is
  /// intentionally limited to test fixtures so AVFoundation still validates
  /// the resulting audio asset before the validator accepts it.
  static func patchMajorBrand(of url: URL, to brand: String) throws {
    guard brand.utf8.count == 4 else {
      throw AudioTestMediaFactoryError.invalidBrand
    }
    var bytes = [UInt8](try Data(contentsOf: url))
    guard bytes.count >= 16,
          String(decoding: bytes[4 ..< 8], as: UTF8.self) == "ftyp"
    else {
      throw AudioTestMediaFactoryError.invalidFileTypeBox
    }
    let boxSize = Int(UInt32(bytes[0]) << 24
      | UInt32(bytes[1]) << 16
      | UInt32(bytes[2]) << 8
      | UInt32(bytes[3]))
    guard boxSize >= 16, boxSize <= bytes.count else {
      throw AudioTestMediaFactoryError.invalidFileTypeBox
    }
    bytes.replaceSubrange(8 ..< 12, with: brand.utf8)
    try Data(bytes).write(to: url, options: .atomic)
  }

  private static func writeAudio(
    to url: URL,
    fileType: AVFileType,
    duration: TimeInterval
  ) throws {
    let sampleRate = 44_100.0
    let frameCount = max(Int(sampleRate * duration), 1)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
          )
    else {
      throw AudioTestMediaFactoryError.cannotCreatePCM
    }

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]

    buffer.frameLength = AVAudioFrameCount(frameCount)
    if let channel = buffer.floatChannelData?[0] {
      let angularFrequency = 2 * Float.pi * 440 / Float(sampleRate)
      for index in 0 ..< frameCount {
        channel[index] = 0.1 * sin(angularFrequency * Float(index))
      }
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw AudioTestMediaFactoryError.cannotAddAudioInput
    }
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error ?? AudioTestMediaFactoryError.writerStartFailed
    }
    writer.startSession(atSourceTime: .zero)

    guard let sampleBuffer = makeAudioSampleBuffer(from: buffer) else {
      writer.cancelWriting()
      throw AudioTestMediaFactoryError.cannotCreateAudioSample
    }
    try waitUntilReady(input, writer: writer)
    guard input.append(sampleBuffer) else {
      writer.cancelWriting()
      throw writer.error ?? AudioTestMediaFactoryError.audioAppendFailed
    }
    input.markAsFinished()

    try finishWriting(writer)
  }

  private static let writerTimeout: TimeInterval = 10

  private static func waitUntilReady(
    _ input: AVAssetWriterInput,
    writer: AVAssetWriter
  ) throws {
    let deadline = Date().addingTimeInterval(writerTimeout)
    while !input.isReadyForMoreMediaData {
      guard writer.status == .writing else {
        writer.cancelWriting()
        throw writer.error ?? AudioTestMediaFactoryError.writerFailed
      }
      guard Date() < deadline else {
        writer.cancelWriting()
        throw AudioTestMediaFactoryError.writerTimedOut
      }
      let nextPoll = Date().addingTimeInterval(0.005)
      RunLoop.current.run(until: min(nextPoll, deadline))
    }
  }

  private static func finishWriting(_ writer: AVAssetWriter) throws {
    let completion = DispatchSemaphore(value: 0)
    writer.finishWriting {
      completion.signal()
    }
    guard completion.wait(timeout: .now() + writerTimeout) == .success else {
      writer.cancelWriting()
      throw AudioTestMediaFactoryError.writerFinishTimedOut
    }
    guard writer.status == .completed else {
      throw writer.error ?? AudioTestMediaFactoryError.writerFinishFailed
    }
  }

  private static func makeAudioSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: false,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: pcm.format.formatDescription,
      sampleCount: CMItemCount(pcm.frameLength),
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    ) == noErr,
    let sampleBuffer,
    CMSampleBufferSetDataBufferFromAudioBufferList(
      sampleBuffer,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      bufferList: pcm.mutableAudioBufferList
    ) == noErr
    else {
      return nil
    }
    return sampleBuffer
  }

  /// Writes a short video-only MP4. Copying it to an `.m4a` path exercises the
  /// container/track check rather than relying on the filename extension.
  static func writeVideoOnlyMP4(to url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 64,
        AVVideoHeightKey: 64,
      ]
    )
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw AudioTestMediaFactoryError.cannotAddVideoInput
    }
    writer.add(input)

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 64,
      ]
    )

    guard writer.startWriting() else {
      throw writer.error ?? AudioTestMediaFactoryError.writerStartFailed
    }
    writer.startSession(atSourceTime: .zero)

    guard let pixelBuffer = makePixelBuffer() else {
      writer.cancelWriting()
      throw AudioTestMediaFactoryError.cannotCreatePixelBuffer
    }

    try waitUntilReady(input, writer: writer)
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
      writer.cancelWriting()
      throw writer.error ?? AudioTestMediaFactoryError.videoAppendFailed
    }

    input.markAsFinished()
    try finishWriting(writer)
  }

  private static func makePixelBuffer() -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      64,
      64,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &pixelBuffer
    ) == kCVReturnSuccess,
    let pixelBuffer
    else {
      return nil
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return nil
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0 ..< 64 {
      let rowAddress = baseAddress.advanced(by: row * bytesPerRow)
      memset(rowAddress, 0x40, bytesPerRow)
    }
    return pixelBuffer
  }
}

enum AudioTestMediaFactoryError: Error {
  case cannotCreatePCM
  case cannotAddAudioInput
  case cannotCreateAudioSample
  case audioAppendFailed
  case cannotAddVideoInput
  case writerStartFailed
  case cannotCreatePixelBuffer
  case videoAppendFailed
  case invalidBrand
  case invalidFileTypeBox
  case writerFailed
  case writerTimedOut
  case writerFinishTimedOut
  case writerFinishFailed
}

@MainActor
final class AudioAssetValidationTests: XCTestCase {
  private var temporaryDirectory: URL!

  override func setUp() async throws {
    try await super.setUp()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteTests_AudioAssetValidation_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    try await super.tearDown()
  }

  func testValidM4AHasFiniteDurationAndOnlyAudioTracks() async throws {
    let url = temporaryDirectory.appendingPathComponent("valid.m4a")
    try AudioTestMediaFactory.writeM4A(to: url)

    let result = await AudioAssetValidator.validate(url: url)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.rejection, nil)
    XCTAssertEqual(result.audioTrackCount, 1)
    XCTAssertEqual(result.videoTrackCount, 0)
    XCTAssertNotNil(result.duration)
    XCTAssertTrue(result.duration?.isFinite == true)
    XCTAssertTrue((result.duration ?? 0) > 0)
  }

  func testAudioOnlyM4AWithGenericISOBrandsRemainsValid() async throws {
    for brand in ["mp42", "isom"] {
      let url = temporaryDirectory.appendingPathComponent("audio-\(brand).m4a")
      try AudioTestMediaFactory.writeM4A(to: url)
      try AudioTestMediaFactory.patchMajorBrand(of: url, to: brand)

      let result = await AudioAssetValidator.validate(url: url)

      XCTAssertTrue(result.isValid, "\(brand) audio-only M4A should remain valid")
      XCTAssertEqual(result.rejection, nil)
      XCTAssertEqual(result.audioTrackCount, 1)
      XCTAssertEqual(result.videoTrackCount, 0)
      XCTAssertTrue((result.duration ?? 0) > 0)
    }
  }

  func testAudioOnlyQuickTimeMOVRenamedToM4AIsRejectedByBrand() async throws {
    let movURL = temporaryDirectory.appendingPathComponent("quicktime.mov")
    let disguisedURL = temporaryDirectory.appendingPathComponent("quicktime.m4a")
    try AudioTestMediaFactory.writeQuickTimeAudioOnlyMOV(to: movURL)
    try FileManager.default.copyItem(at: movURL, to: disguisedURL)

    let result = await AudioAssetValidator.validate(url: disguisedURL)

    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.rejection, .unsupportedContainer)
    XCTAssertEqual(result.audioTrackCount, 1)
    XCTAssertEqual(result.videoTrackCount, 0)
    XCTAssertTrue((result.duration ?? 0) > 0)
  }

  func testDamagedM4AIsRejected() async throws {
    let url = temporaryDirectory.appendingPathComponent("damaged.m4a")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)

    let result = await AudioAssetValidator.validate(url: url)

    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.rejection, .assetUnreadable)
    XCTAssertEqual(result.audioTrackCount, 0)
    XCTAssertEqual(result.videoTrackCount, 0)
  }

  func testEmptyM4AIsRejectedBeforeAssetMetadataIsUsed() async throws {
    let url = temporaryDirectory.appendingPathComponent("empty.m4a")
    try Data().write(to: url)

    let result = await AudioAssetValidator.validate(url: url)

    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.rejection, .emptyFile)
    XCTAssertNil(result.duration)
    XCTAssertEqual(result.audioTrackCount, 0)
    XCTAssertEqual(result.videoTrackCount, 0)
  }

  func testVideoContainerRenamedToM4AIsRejectedByTrackCount() async throws {
    let sourceURL = temporaryDirectory.appendingPathComponent("video.mp4")
    let disguisedURL = temporaryDirectory.appendingPathComponent("video.m4a")
    try AudioTestMediaFactory.writeVideoOnlyMP4(to: sourceURL)
    try FileManager.default.copyItem(at: sourceURL, to: disguisedURL)

    let result = await AudioAssetValidator.validate(url: disguisedURL)

    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.rejection, .containsVideoTrack)
    XCTAssertEqual(result.audioTrackCount, 0)
    XCTAssertGreaterThan(result.videoTrackCount, 0)
  }

  func testQuickAccessAudioAddAndRestoreRejectInvalidAssets() async throws {
    let manager = QuickAccessManager.shared
    let previousEnabled = manager.isEnabled
    manager.dismissAll()
    manager.isEnabled = true
    defer {
      manager.dismissAll()
      manager.isEnabled = previousEnabled
    }

    let damagedURL = temporaryDirectory.appendingPathComponent("damaged.m4a")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: damagedURL)
    let beforeAddCount = manager.items.count
    let addedItem = await manager.addAudio(url: damagedURL)
    XCTAssertNil(addedItem)
    XCTAssertEqual(manager.items.count, beforeAddCount)

    let record = CaptureHistoryRecord(
      id: UUID(),
      filePath: damagedURL.path,
      fileName: damagedURL.lastPathComponent,
      captureType: .audio,
      fileSize: 4,
      capturedAt: Date(),
      width: nil,
      height: nil,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false,
      origin: .capture
    )
    let restoredItem = await manager.restoreHistoryItem(record)
    XCTAssertNil(restoredItem)
    XCTAssertEqual(manager.items.count, beforeAddCount)
  }
}
