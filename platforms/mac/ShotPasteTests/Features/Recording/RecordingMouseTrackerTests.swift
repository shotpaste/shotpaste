//
//  RecordingMouseTrackerTests.swift
//  ShotPasteTests
//
//  Unit tests for RecordingMouseTracker sample-rate resolution and lifecycle.
//

import CoreGraphics
@testable import ShotPaste
import XCTest

final class RecordingMouseTrackerTests: XCTestCase {
  func testResolvedSamplesPerSecond_fps15_clampedToMin() {
    XCTAssertEqual(RecordingMouseTracker.resolvedSamplesPerSecond(for: 15), 60)
  }

  func testResolvedSamplesPerSecond_fps30_doubled() {
    XCTAssertEqual(RecordingMouseTracker.resolvedSamplesPerSecond(for: 30), 60)
  }

  func testResolvedSamplesPerSecond_fps60_doubled() {
    XCTAssertEqual(RecordingMouseTracker.resolvedSamplesPerSecond(for: 60), 120)
  }

  func testResolvedSamplesPerSecond_fps120_clampedToMax() {
    XCTAssertEqual(RecordingMouseTracker.resolvedSamplesPerSecond(for: 120), 120)
  }

  func testInit_samplesPerSecond_matchesResolved() async {
    await MainActor.run {
      let tracker = makeTracker()
      XCTAssertEqual(tracker.samplesPerSecond, 60)
    }
  }

  func testStartStop_returnsSamples() async {
    await MainActor.run {
      let clock = TestClock()
      let tracker = makeTracker(clock: clock)

      tracker.start()
      clock.uptime += 0.02
      let samples = tracker.stop()
      XCTAssertGreaterThanOrEqual(samples.count, 2)
      XCTAssertEqual(samples.first?.normalizedX, 0.5)
      XCTAssertEqual(samples.first?.normalizedY, 0.5)
      tracker.reset()
    }
  }

  func testReset_clearsSamples() async {
    await MainActor.run {
      let clock = TestClock()
      let tracker = makeTracker(clock: clock)

      tracker.start()
      clock.uptime += 0.02
      _ = tracker.stop()
      XCTAssertNotNil(tracker.diagnostics)

      tracker.reset()
      XCTAssertNil(tracker.diagnostics)
    }
  }

  @MainActor
  private func makeTracker() -> RecordingMouseTracker {
    makeTracker(clock: TestClock())
  }

  @MainActor
  private func makeTracker(clock: TestClock) -> RecordingMouseTracker {
    RecordingMouseTracker(
      recordingRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      fps: 30,
      uptimeProvider: { clock.uptime },
      mouseLocationProvider: { CGPoint(x: 50, y: 50) },
      mouseMonitorInstaller: { _ in TestMouseMonitor() },
      mouseMonitorRemover: { _ in }
    )
  }
}

private final class TestClock {
  var uptime: TimeInterval = 100
}

private final class TestMouseMonitor {}
