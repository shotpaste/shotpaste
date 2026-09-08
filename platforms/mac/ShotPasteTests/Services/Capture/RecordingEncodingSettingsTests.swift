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

}
