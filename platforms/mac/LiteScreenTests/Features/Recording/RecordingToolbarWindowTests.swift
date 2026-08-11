//
//  RecordingToolbarWindowTests.swift
//  LiteScreenTests
//
//  Unit tests for recording hover bar drag-position clamping (issue #351).
//

import AppKit
@testable import LiteScreen
import XCTest

@MainActor
final class RecordingToolbarWindowTests: XCTestCase {
  private let union = CGRect(x: 0, y: 0, width: 1000, height: 800)
  private let size = CGSize(width: 200, height: 50)

  func testClampedOrigin_insideBounds_isUnchanged() {
    let origin = CGPoint(x: 100, y: 120)
    let result = RecordingToolbarWindow.clampedOrigin(origin, size: size, within: union)
    XCTAssertEqual(result, origin)
  }

  func testClampedOrigin_offRightAndTop_isPulledInsideSoWindowFits() {
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: 5000, y: 5000), size: size, within: union
    )
    XCTAssertEqual(result.x, union.maxX - size.width, accuracy: 0.001) // 800
    XCTAssertEqual(result.y, union.maxY - size.height, accuracy: 0.001) // 750
  }

  func testClampedOrigin_offLeftAndBottom_isPulledToMinCorner() {
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: -500, y: -500), size: size, within: union
    )
    XCTAssertEqual(result.x, union.minX, accuracy: 0.001)
    XCTAssertEqual(result.y, union.minY, accuracy: 0.001)
  }

  func testClampedOrigin_withOffsetUnion_respectsMinOrigin() {
    let offsetUnion = CGRect(x: -200, y: -100, width: 1200, height: 900)
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: -9999, y: -9999), size: size, within: offsetUnion
    )
    XCTAssertEqual(result.x, offsetUnion.minX, accuracy: 0.001)
    XCTAssertEqual(result.y, offsetUnion.minY, accuracy: 0.001)
  }

  func testClampedOrigin_nullUnion_returnsOriginUnchanged() {
    let origin = CGPoint(x: 42, y: 24)
    let result = RecordingToolbarWindow.clampedOrigin(origin, size: size, within: .null)
    XCTAssertEqual(result, origin)
  }

  func testClampedOrigin_windowLargerThanUnion_clampsToMinCorner() {
    // A window wider/taller than the visible area should pin to the min corner (never negative maxX/maxY).
    let big = CGSize(width: 2000, height: 2000)
    let result = RecordingToolbarWindow.clampedOrigin(
      CGPoint(x: 500, y: 500), size: big, within: union
    )
    XCTAssertEqual(result.x, union.minX, accuracy: 0.001)
    XCTAssertEqual(result.y, union.minY, accuracy: 0.001)
  }

  func testShowRecordingStatusBar_hiddenBridgeWindowBecomesVisibleAndDraggable() {
    let window = RecordingToolbarWindow(anchorRect: CGRect(x: 100, y: 100, width: 400, height: 300))
    XCTAssertFalse(window.isVisible, "One Shot bridge window must stay hidden until recording starts")

    window.showRecordingStatusBar(recorder: ScreenRecordingManager.shared, visible: true)

    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.isMovableByWindowBackground)
    window.close()
  }
}
