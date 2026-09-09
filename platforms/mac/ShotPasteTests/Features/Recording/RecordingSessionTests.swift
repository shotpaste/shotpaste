//
//  RecordingSessionTests.swift
//  ShotPasteTests
//
//  Unit tests for RecordingSession thread-safe state management.
//

import CoreMedia
@testable import ShotPaste
import XCTest

final class RecordingSessionTests: XCTestCase {
  private var session: RecordingSession!

  override func setUp() {
    super.setUp()
    session = RecordingSession()
  }

  override func tearDown() {
    session = nil
    super.tearDown()
  }

  func testInitialState() {
    XCTAssertFalse(session.sessionStarted)
    XCTAssertFalse(session.isCapturing)
    XCTAssertNil(session.assetWriter)
    XCTAssertNil(session.videoInput)
    XCTAssertNil(session.audioInput)
    XCTAssertNil(session.microphoneInput)
  }

  func testReset_clearsState() {
    session.isCapturing = true
    session.sessionStarted = true
    session.reset()
    XCTAssertFalse(session.isCapturing)
    XCTAssertFalse(session.sessionStarted)
  }

  func testVideoWriteStats_initiallyZero() {
    let stats = session.videoWriteStats()
    XCTAssertEqual(stats.receivedFrames, 0)
    XCTAssertEqual(stats.appendedFrames, 0)
    XCTAssertEqual(stats.droppedFramesDueToBackpressure, 0)
    XCTAssertEqual(stats.failedAppendFrames, 0)
    XCTAssertEqual(stats.microphoneSamplesReceived, 0)
    XCTAssertEqual(stats.microphoneSamplesAppended, 0)
  }

}
