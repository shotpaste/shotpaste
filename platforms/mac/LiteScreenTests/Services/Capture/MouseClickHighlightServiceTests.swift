//
//  MouseClickHighlightServiceTests.swift
//  LiteScreenTests
//
//  Unit tests for MouseClickHighlightService lifecycle.
//

import CoreGraphics
@testable import LiteScreen
import XCTest

@MainActor
final class MouseClickHighlightServiceTests: XCTestCase {
  private var service: MouseClickHighlightService!

  override func setUp() {
    super.setUp()
    service = MouseClickHighlightService()
  }

  override func tearDown() {
    service.stop()
    service = nil
    super.tearDown()
  }

  func testStartStop_lifecycleDoesNotCrash() {
    service.start(recordingRect: CGRect(x: 0, y: 0, width: 100, height: 100))
    service.stop()
  }

  func testStart_whenAlreadyRunning_noOp() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
    service.start(recordingRect: rect)
    service.start(recordingRect: rect)
    service.stop()
  }

  func testUpdateRecordingRect_doesNotCrash() {
    service.start(recordingRect: CGRect(x: 0, y: 0, width: 100, height: 100))
    service.updateRecordingRect(CGRect(x: 10, y: 10, width: 200, height: 200))
    service.stop()
  }

  func testStop_whenNotRunning_noOp() {
    service.stop()
  }
}
