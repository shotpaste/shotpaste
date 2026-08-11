//
//  RecordingAudioLevelMeterTests.swift
//  LiteScreenTests
//
//  Tests for RecordingAudioLevelMeter using real synthesized PCM sample buffers
//  (sine tone vs silence). No mocked RMS — the meter processes genuine audio data.
//

import AVFoundation
@testable import LiteScreen
import XCTest

final class RecordingAudioLevelMeterTests: XCTestCase {
  // MARK: - RMS from real audio

  func testLevelRisesForLoudSineTone() {
    let meter = RecordingAudioLevelMeter()
    let buffer = Self.makeSineBuffer(amplitude: 0.8)

    // Ingest a few buffers to let ballistics build up.
    for _ in 0 ..< 10 {
      meter.ingest(buffer, source: .microphone)
      drainQueues(meter, 0.02)
    }

    XCTAssertTrue(
      waitForLevel(meter) { $0 > 0.3 },
      "Loud sine tone should drive the level well above zero (was \(meter.level))"
    )
    XCTAssertLessThanOrEqual(meter.level, 1.0, "Level must stay normalized within 0...1")
  }

  func testLevelStaysZeroForSilence() {
    let meter = RecordingAudioLevelMeter()
    let silence = Self.makeSineBuffer(amplitude: 0.0)

    for _ in 0 ..< 10 {
      meter.ingest(silence, source: .system)
      drainQueues(meter, 0.02)
    }

    XCTAssertEqual(meter.level, 0, accuracy: 0.0001, "Silence must be gated to a flat zero level")
  }

  func testCombinesSourcesUsingMax() {
    let meter = RecordingAudioLevelMeter()
    let loud = Self.makeSineBuffer(amplitude: 0.8)
    let silent = Self.makeSineBuffer(amplitude: 0.0)

    // Loud mic + silent system → level driven by the louder source.
    for _ in 0 ..< 10 {
      meter.ingest(silent, source: .system)
      meter.ingest(loud, source: .microphone)
      drainQueues(meter, 0.02)
    }

    XCTAssertTrue(waitForLevel(meter) { $0 > 0.3 }, "max(system, mic) should follow the loud source")
  }

  // MARK: - Lifecycle

  func testResetReturnsLevelToZero() {
    let meter = RecordingAudioLevelMeter()
    let loud = Self.makeSineBuffer(amplitude: 0.8)
    for _ in 0 ..< 10 {
      meter.ingest(loud, source: .microphone)
      drainQueues(meter, 0.02)
    }
    XCTAssertTrue(waitForLevel(meter) { $0 > 0.3 })

    meter.reset()
    XCTAssertTrue(waitForLevel(meter) { $0 == 0 }, "reset() must zero the published level")
  }

  func testFreezeIgnoresNewInput() {
    let meter = RecordingAudioLevelMeter()
    let loud = Self.makeSineBuffer(amplitude: 0.8)
    for _ in 0 ..< 10 {
      meter.ingest(loud, source: .microphone)
      drainQueues(meter, 0.02)
    }
    XCTAssertTrue(waitForLevel(meter) { $0 > 0.3 })
    let frozenLevel = meter.level

    meter.freeze()
    drainQueues(meter, 0.05)

    // Feeding silence while frozen must NOT change the held level.
    let silence = Self.makeSineBuffer(amplitude: 0.0)
    for _ in 0 ..< 10 {
      meter.ingest(silence, source: .microphone)
      drainQueues(meter, 0.02)
    }
    XCTAssertEqual(meter.level, frozenLevel, accuracy: 0.0001, "Frozen meter must hold its level")

    // Unfreezing then feeding silence lets it decay back toward zero.
    meter.unfreeze()
    for _ in 0 ..< 40 {
      meter.ingest(silence, source: .microphone)
      drainQueues(meter, 0.02)
    }
    XCTAssertTrue(waitForLevel(meter) { $0 < frozenLevel }, "After unfreeze, silence should let level fall")
  }

  // MARK: - Helpers

  /// Spins the run loop briefly so the meter's serial queue and its main-thread
  /// publish can drain before assertions read `level`.
  private func drainQueues(_ meter: RecordingAudioLevelMeter, _ interval: TimeInterval) {
    meter.flushQueueForTesting()
    RunLoop.current.run(until: Date().addingTimeInterval(interval))
  }

  /// Polls `meter.level` (updated async on main) until `predicate` holds or timeout.
  private func waitForLevel(
    _ meter: RecordingAudioLevelMeter,
    timeout: TimeInterval = 2,
    predicate: @escaping (Float) -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(meter.level) {
        return true
      }
      drainQueues(meter, 0.02)
    }
    return predicate(meter.level)
  }

  /// Builds a real mono Float32 48kHz PCM `CMSampleBuffer` containing a 440Hz sine
  /// at the given peak amplitude (0 = silence).
  private static func makeSineBuffer(amplitude: Float, frames: Int = 1024) -> CMSampleBuffer {
    let sampleRate = 48_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)

    let channel = pcm.floatChannelData![0]
    let twoPiF = 2.0 * Float.pi * 440.0 / Float(sampleRate)
    for i in 0 ..< frames {
      channel[i] = amplitude * sin(twoPiF * Float(i))
    }

    return makeSampleBuffer(from: pcm)!
  }

  private static func makeSampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer? {
    let formatDesc = pcm.format.formatDescription

    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.streamDescription.pointee.mSampleRate)),
      presentationTimeStamp: .zero,
      decodeTimeStamp: .invalid
    )
    guard CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: false,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDesc,
      sampleCount: CMItemCount(pcm.frameLength),
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else {
      return nil
    }

    guard CMSampleBufferSetDataBufferFromAudioBufferList(
      sampleBuffer,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      bufferList: pcm.mutableAudioBufferList
    ) == noErr else {
      return nil
    }

    return sampleBuffer
  }
}
