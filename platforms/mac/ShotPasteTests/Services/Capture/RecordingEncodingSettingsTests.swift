//
//  RecordingEncodingSettingsTests.swift
//  ShotPasteTests
//
//  Unit tests for RecordingVideoEncodingSettings and RecordingAudioEncodingSettings.
//

import AVFoundation
@testable import ShotPaste
import XCTest

final class RecordingEncodingSettingsTests: XCTestCase {
  // MARK: - VideoQuality

  func testVideoQuality_bitRatesOrdered() {
    XCTAssertGreaterThan(VideoQuality.high.minBitrate, VideoQuality.medium.minBitrate)
    XCTAssertGreaterThan(VideoQuality.medium.minBitrate, VideoQuality.low.minBitrate)
    XCTAssertGreaterThan(VideoQuality.high.maxBitrate, VideoQuality.medium.maxBitrate)
    XCTAssertGreaterThan(VideoQuality.medium.maxBitrate, VideoQuality.low.maxBitrate)
  }

  func testVideoQuality_bitsPerPixelPerFrameOrdered() {
    XCTAssertGreaterThan(VideoQuality.high.bitsPerPixelPerFrame, VideoQuality.medium.bitsPerPixelPerFrame)
    XCTAssertGreaterThan(VideoQuality.medium.bitsPerPixelPerFrame, VideoQuality.low.bitsPerPixelPerFrame)
  }

  // MARK: - calculatedBitrate

  func testCalculatedBitrate_clampedByMin() {
    let bitrate = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 100, height: 100, fps: 1, quality: .low, codec: .h264
    )
    XCTAssertGreaterThanOrEqual(bitrate, VideoQuality.low.minBitrate)
  }

  func testCalculatedBitrate_clampedByMax() {
    let bitrate = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 5000, height: 5000, fps: 60, quality: .high, codec: .h264
    )
    XCTAssertLessThanOrEqual(bitrate, VideoQuality.high.maxBitrate)
  }

  func testCalculatedBitrate_hevcLowerThanH264() {
    let hevc = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 1920, height: 1080, fps: 30, quality: .high, codec: .hevc
    )
    let h264 = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 1920, height: 1080, fps: 30, quality: .high, codec: .h264
    )
    XCTAssertLessThan(hevc, h264)
  }

  // MARK: - makeVideoSettings

  func testMakeVideoSettings_containsRequiredKeys() {
    let settings = RecordingVideoEncodingSettings.makeVideoSettings(
      width: 1920, height: 1080, fps: 30, quality: .high, codec: .h264, bitrate: 5_000_000
    )
    XCTAssertNotNil(settings[AVVideoCodecKey])
    XCTAssertNotNil(settings[AVVideoWidthKey])
    XCTAssertNotNil(settings[AVVideoHeightKey])
    XCTAssertNotNil(settings[AVVideoCompressionPropertiesKey])
    XCTAssertNotNil(settings[AVVideoColorPropertiesKey])
  }

  func testMakeVideoSettings_h264IncludesProfile() {
    let settings = RecordingVideoEncodingSettings.makeVideoSettings(
      width: 1920, height: 1080, fps: 30, quality: .high, codec: .h264, bitrate: 5_000_000
    )
    let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
    XCTAssertNotNil(compression?[AVVideoProfileLevelKey])
  }

  func testMakeVideoSettings_hevcExcludesProfile() {
    let settings = RecordingVideoEncodingSettings.makeVideoSettings(
      width: 1920, height: 1080, fps: 30, quality: .high, codec: .hevc, bitrate: 5_000_000
    )
    let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
    XCTAssertNil(compression?[AVVideoProfileLevelKey])
  }

  // MARK: - Audio Settings

  func testMakeSystemAudioSettings_containsFormatAndSampleRate() {
    let settings = RecordingAudioEncodingSettings.makeSystemAudioSettings()
    XCTAssertNotNil(settings[AVFormatIDKey])
    XCTAssertNotNil(settings[AVSampleRateKey])
    XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
  }

  func testMakeMicrophoneAudioSettings_containsFormatAndSampleRate() {
    let settings = RecordingAudioEncodingSettings.makeMicrophoneAudioSettings()
    XCTAssertNotNil(settings[AVFormatIDKey])
    XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
  }

  func testMakeMixedAudioSettings_containsFormatAndSampleRate() {
    let settings = RecordingAudioEncodingSettings.makeMixedAudioSettings()
    XCTAssertNotNil(settings[AVFormatIDKey])
    XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
  }
}
