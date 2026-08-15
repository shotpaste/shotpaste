//
//  ScreenRecordingEncodingSettingsTests.swift
//  ShotPasteTests
//
//  Tests for deterministic screen-recording encoding decisions.
//

import AVFoundation
@testable import ShotPaste
import XCTest

@MainActor
final class ScreenRecordingEncodingSettingsTests: XCTestCase {
  func testVideoFormatProperties_mapToExpectedAVFileTypesAndExtensions() {
    XCTAssertEqual(VideoFormat.mov.fileType.rawValue, AVFileType.mov.rawValue)
    XCTAssertEqual(VideoFormat.mov.fileExtension, "mov")
    XCTAssertEqual(VideoFormat.mov.displayName, "MOV")

    XCTAssertEqual(VideoFormat.mp4.fileType.rawValue, AVFileType.mp4.rawValue)
    XCTAssertEqual(VideoFormat.mp4.fileExtension, "mp4")
    XCTAssertEqual(VideoFormat.mp4.displayName, "MP4")
  }

  func testCalculatedBitrate_smallCaptureClampsToQualityMinimum() {
    let bitrate = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 100,
      height: 100,
      fps: 30,
      quality: .high,
      codec: .h264
    )

    XCTAssertEqual(bitrate, VideoQuality.high.minBitrate)
  }

  func testCalculatedBitrate_hugeCaptureClampsToQualityMaximum() {
    let bitrate = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 7_680,
      height: 4_320,
      fps: 60,
      quality: .high,
      codec: .h264
    )

    XCTAssertEqual(bitrate, VideoQuality.high.maxBitrate)
  }

  func testCalculatedBitrate_appliesHEVCEfficiencyBeforeClamp() {
    let h264Bitrate = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 1_920,
      height: 1_080,
      fps: 30,
      quality: .low,
      codec: .h264
    )
    let hevcBitrate = RecordingVideoEncodingSettings.calculatedBitrate(
      width: 1_920,
      height: 1_080,
      fps: 30,
      quality: .low,
      codec: .hevc
    )

    XCTAssertEqual(h264Bitrate, 4_976_640)
    XCTAssertEqual(hevcBitrate, 4_478_976)
  }

  func testMakeVideoSettings_h264IncludesProfileFPSAndColorProperties() throws {
    let settings = RecordingVideoEncodingSettings.makeVideoSettings(
      width: 1_280,
      height: 720,
      fps: 60,
      quality: .medium,
      codec: .h264,
      bitrate: 7_200_000
    )

    XCTAssertEqual(codecRawValue(settings[AVVideoCodecKey]), AVVideoCodecType.h264.rawValue)
    XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1_280)
    XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 720)

    let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
    XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, 7_200_000)
    XCTAssertEqual(compression[AVVideoExpectedSourceFrameRateKey] as? Int, 60)
    XCTAssertEqual(compression[AVVideoMaxKeyFrameIntervalKey] as? Int, 60)
    XCTAssertEqual(compression[AVVideoProfileLevelKey] as? String, VideoQuality.medium.h264ProfileLevel)

    let color = try XCTUnwrap(settings[AVVideoColorPropertiesKey] as? [String: Any])
    XCTAssertEqual(color[AVVideoColorPrimariesKey] as? String, AVVideoColorPrimaries_ITU_R_709_2)
    XCTAssertEqual(color[AVVideoTransferFunctionKey] as? String, AVVideoTransferFunction_ITU_R_709_2)
    XCTAssertEqual(color[AVVideoYCbCrMatrixKey] as? String, AVVideoYCbCrMatrix_ITU_R_709_2)
  }

  func testMakeVideoSettings_hevcOmitsH264Profile() throws {
    let settings = RecordingVideoEncodingSettings.makeVideoSettings(
      width: 1_920,
      height: 1_080,
      fps: 30,
      quality: .high,
      codec: .hevc,
      bitrate: 10_000_000
    )

    XCTAssertEqual(codecRawValue(settings[AVVideoCodecKey]), AVVideoCodecType.hevc.rawValue)
    let compression = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
    XCTAssertNil(compression[AVVideoProfileLevelKey])
  }

  func testMakeSystemAudioSettings_usesStereoAACCompatibilityProfile() throws {
    let settings = RecordingAudioEncodingSettings.makeSystemAudioSettings()

    XCTAssertEqual(audioFormatRawValue(settings[AVFormatIDKey]), kAudioFormatMPEG4AAC)
    XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
    XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 128_000)
    XCTAssertEqual(try channelLayoutTag(from: settings), kAudioChannelLayoutTag_Stereo)
  }

  func testMakeMicrophoneAudioSettings_usesStereoAACCompatibilityProfile() throws {
    let settings = RecordingAudioEncodingSettings.makeMicrophoneAudioSettings()

    XCTAssertEqual(audioFormatRawValue(settings[AVFormatIDKey]), kAudioFormatMPEG4AAC)
    XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
    XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 128_000)
    XCTAssertEqual(try channelLayoutTag(from: settings), kAudioChannelLayoutTag_Stereo)
  }

  func testMakeMixedAudioSettings_usesHigherBitrateStereoAACCompatibilityProfile() throws {
    let settings = RecordingAudioEncodingSettings.makeMixedAudioSettings()

    XCTAssertEqual(audioFormatRawValue(settings[AVFormatIDKey]), kAudioFormatMPEG4AAC)
    XCTAssertEqual(settings[AVSampleRateKey] as? Int, 48_000)
    XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(settings[AVEncoderBitRateKey] as? Int, 192_000)
    XCTAssertEqual(try channelLayoutTag(from: settings), kAudioChannelLayoutTag_Stereo)
  }

  func testAudioCompatibilityExporterRequiresMixDownOnlyForMultipleAudioTracks() {
    XCTAssertFalse(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 0))
    XCTAssertFalse(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 1))
    XCTAssertTrue(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 2))
    XCTAssertTrue(RecordingAudioCompatibilityExporter.requiresMixDown(audioTrackCount: 3))
  }

  func testAudioCompatibilityExporterMixdownInputVolumeAddsHeadroom() {
    XCTAssertEqual(RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: 0), 1.0)
    XCTAssertEqual(RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: 1), 1.0)
    XCTAssertEqual(RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: 2), 0.5)
    XCTAssertEqual(
      RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: 3),
      1.0 / 3.0,
      accuracy: 0.0001
    )
  }

  private func codecRawValue(_ value: Any?) -> String? {
    if let codec = value as? AVVideoCodecType {
      return codec.rawValue
    }
    return value as? String
  }

  private func audioFormatRawValue(_ value: Any?) -> AudioFormatID? {
    if let format = value as? AudioFormatID {
      return format
    }
    if let format = value as? Int {
      return AudioFormatID(format)
    }
    return nil
  }

  private func channelLayoutTag(from settings: [String: Any]) throws -> AudioChannelLayoutTag {
    let data = try XCTUnwrap(settings[AVChannelLayoutKey] as? Data)
    var layout = AudioChannelLayout()
    _ = withUnsafeMutableBytes(of: &layout) { destination in
      data.copyBytes(to: destination)
    }
    return layout.mChannelLayoutTag
  }
}
