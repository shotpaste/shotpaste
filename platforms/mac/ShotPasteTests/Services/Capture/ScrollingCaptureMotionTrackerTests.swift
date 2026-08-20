import CoreGraphics
@testable import ShotPaste
import XCTest

final class ScrollingCaptureMotionTrackerTests: XCTestCase {
  func testEstimateMotion_detectsDownwardScrollWithoutHorizontalDrift() throws {
    let tracker = ScrollingCaptureMotionTracker()
    let previousImage = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 0)
    )
    let currentImage = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 24)
    )
    let previous = try XCTUnwrap(tracker.makeGrayFrame(from: previousImage))
    let current = try XCTUnwrap(tracker.makeGrayFrame(from: currentImage))

    let motion = try XCTUnwrap(
      tracker.estimateMotion(
        previous: previous,
        current: current,
        expectedSignedDeltaPixels: nil,
        lastAcceptedDeltaPixels: nil
      )
    )

    XCTAssertEqual(motion.deltaY, 24, accuracy: 0.6)
    XCTAssertEqual(motion.deltaX, 0)
    XCTAssertGreaterThanOrEqual(motion.confidentBandCount, 3)
    XCTAssertGreaterThanOrEqual(motion.confidence, ScrollingCaptureMotionTracker.minimumAcceptanceConfidence)
  }

  func testEstimateMotion_detectsDirectionReversal() throws {
    let tracker = ScrollingCaptureMotionTracker()
    let previousImage = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 80)
    )
    let currentImage = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 56)
    )
    let previous = try XCTUnwrap(tracker.makeGrayFrame(from: previousImage))
    let current = try XCTUnwrap(tracker.makeGrayFrame(from: currentImage))

    let motion = try XCTUnwrap(
      tracker.estimateMotion(
        previous: previous,
        current: current,
        expectedSignedDeltaPixels: nil,
        lastAcceptedDeltaPixels: 24
      )
    )

    XCTAssertEqual(motion.deltaY, -24, accuracy: 0.6)
    XCTAssertEqual(motion.deltaX, 0)
  }
}
