import CoreGraphics
@testable import ShotPaste
import XCTest

final class ScrollingCaptureMotionTrackerTests: XCTestCase {
  func testInferStaticBands_findsRetinaHeaderBeyondOldPixelLimit() {
    let tracker = ScrollingCaptureMotionTracker()
    let previous = grayFixture(offset: 100, header: 100, footer: 40, scale: 2)
    let current = grayFixture(offset: 124, header: 100, footer: 40, scale: 2)
    tracker.inferStaticBands(previous: previous, current: current)

    XCTAssertEqual(tracker.staticBands.header, 100)
    XCTAssertEqual(tracker.staticBands.footer, 40)
    XCTAssertEqual(tracker.staticBandsInPixels(fullResScale: 2).header, 200)
  }

  func testInferStaticBands_canRetryAfterUnresolvedPair() {
    let tracker = ScrollingCaptureMotionTracker()
    let previous = grayFixture(offset: 100, header: 40, footer: 180)
    let current = grayFixture(offset: 124, header: 40, footer: 180)
    tracker.inferStaticBands(previous: previous, current: current)
    XCTAssertTrue(tracker.hasUnresolvedStaticEdges)
    // A later pair with an observable boundary must clear the unresolved state.
    tracker.inferStaticBands(
      previous: grayFixture(offset: 100, header: 40, footer: 60),
      current: grayFixture(offset: 124, header: 40, footer: 60)
    )
    XCTAssertEqual(tracker.staticBands.header, 40)
    XCTAssertEqual(tracker.staticBands.footer, 60)
    XCTAssertFalse(tracker.hasUnresolvedStaticEdges)
  }

  func testInferStaticBands_resolvesBoundaryAtMaximumCrop() {
    for scale in [1.0, 2.0] {
      for footer in [400 / 3 - 1, 400 / 3, 400 / 3 + 1] {
        let tracker = ScrollingCaptureMotionTracker()
        tracker.inferStaticBands(
          previous: grayFixture(offset: 100, header: 40, footer: footer, scale: scale),
          current: grayFixture(offset: 124, header: 40, footer: footer, scale: scale)
        )
        if footer <= 400 / 3 {
          XCTAssertEqual(tracker.staticBands.footer, footer)
          XCTAssertEqual(tracker.staticBandsInPixels(fullResScale: scale).footer, Int(Double(footer) * scale))
          XCTAssertFalse(tracker.hasUnresolvedStaticEdges)
        } else {
          XCTAssertTrue(tracker.hasUnresolvedStaticEdges)
        }
      }
    }
  }

  func testEstimateMotion_recoveryUsesBandsAgreeingOnDisplacement() throws {
    let tracker = ScrollingCaptureMotionTracker()
    for (previousOffset, currentOffset) in [(120, 240), (240, 120)] {
      let previousImage = try XCTUnwrap(TestImageFactory.scrollingFrame(
        width: 240, height: 480, logicalYOffset: previousOffset
      ))
      let currentImage = try XCTUnwrap(TestImageFactory.scrollingFrame(
        width: 240, height: 480, logicalYOffset: currentOffset
      ))
      let result = try XCTUnwrap(tracker.estimateMotion(
        previous: try XCTUnwrap(tracker.makeGrayFrame(from: previousImage)),
        current: try XCTUnwrap(tracker.makeGrayFrame(from: currentImage)),
        expectedSignedDeltaPixels: 1,
        lastAcceptedDeltaPixels: nil
      ))
      XCTAssertTrue(result.usedRecoverySearch)
      XCTAssertEqual(result.deltaY, Double(currentOffset - previousOffset), accuracy: 0.6)
      XCTAssertGreaterThanOrEqual(result.confidentBandCount, 3)
    }
  }

  func testEstimateMotion_rejectsOppositeDirectionAliasWithIndependentSupport() {
    let width = 64
    let height = 400
    let period = 300
    var seed: UInt64 = 26
    var pattern = [UInt8](repeating: 0, count: width * period)
    for index in pattern.indices {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      pattern[index] = UInt8(truncatingIfNeeded: seed >> 32)
    }
    var previous = [UInt8](repeating: 0, count: width * height)
    var current = previous
    for row in 0 ..< height {
      for x in 0 ..< width {
        previous[row * width + x] = pattern[(row % period) * width + x]
        current[row * width + x] = pattern[((row + 140) % period) * width + x]
      }
    }
    // Both +140 and -160 have at least three exact overlapping strips.
    // A majority vote must not erase the other valid displacement.
    for direction in [ScrollingCaptureMergeDirection.unresolved, .appendFromBottom] {
      for hint in [80, 140, -160] {
        let tracker = ScrollingCaptureMotionTracker()
        tracker.lockDirection(direction)
        XCTAssertNil(tracker.estimateMotion(
          previous: grayFrame(width: width, height: height, pixels: previous),
          current: grayFrame(width: width, height: height, pixels: current),
          expectedSignedDeltaPixels: hint,
          lastAcceptedDeltaPixels: nil
        ))
      }
    }
  }

  func testEstimateMotion_verticalFlatBandsCannotVetoUniqueMotion() throws {
    let width = 64
    let height = 400
    var seed: UInt64 = 26
    var document = [UInt8](repeating: 0, count: width * (height + 24))
    for index in document.indices {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      let row = index / width
      let x = index % width
      document[index] = (60 ..< 240).contains(row)
        ? UInt8(40 + (x * 37) % 180) : UInt8(truncatingIfNeeded: seed >> 32)
    }
    let result = try XCTUnwrap(ScrollingCaptureMotionTracker().estimateMotion(
      previous: grayFrame(width: width, height: height, pixels: Array(document.prefix(width * height))),
      current: grayFrame(width: width, height: height, pixels: Array(document.dropFirst(width * 24))),
      expectedSignedDeltaPixels: 24,
      lastAcceptedDeltaPixels: nil
    ))
    XCTAssertEqual(result.deltaY, 24, accuracy: 0.6)
    XCTAssertGreaterThanOrEqual(result.confidentBandCount, 3)
  }

  func testEstimateMotion_rejectsOneConfidentBandEvenWithHighConfidence() {
    let width = 64
    let height = 480
    var previous = [UInt8](repeating: 127, count: width * height)
    var current = previous
    var seed: UInt64 = 26
    // Only the band at row 244 has texture in the current image. Its exact
    // 24px match scores 1.0, but one band cannot establish a reliable motion.
    for row in 0 ..< 36 {
      for x in 0 ..< width {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let value = UInt8(truncatingIfNeeded: seed >> 32)
        previous[(274 + row) * width + x] = value
        current[(250 + row) * width + x] = value
      }
    }
    let tracker = ScrollingCaptureMotionTracker()
    tracker.lockDirection(.appendFromBottom)
    XCTAssertNil(tracker.estimateMotion(
      previous: grayFrame(width: width, height: height, pixels: previous),
      current: grayFrame(width: width, height: height, pixels: current),
      expectedSignedDeltaPixels: 24,
      lastAcceptedDeltaPixels: 24
    ))
  }

  func testEstimateMotion_recoveryRejectsPeriodicAlias() {
    let width = 64
    let height = 180
    let period = 40
    var seed: UInt64 = 26
    var pattern = [UInt8](repeating: 0, count: width * period)
    for index in pattern.indices {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      pattern[index] = UInt8(truncatingIfNeeded: seed >> 32)
    }
    var previous = [UInt8](repeating: 0, count: width * height)
    var current = previous
    for row in 0 ..< height {
      for x in 0 ..< width {
        previous[row * width + x] = pattern[(row % period) * width + x]
        current[row * width + x] = pattern[((row + 66) % period) * width + x]
      }
    }
    // The actual 66px shift is indistinguishable from 26px. A coarse search
    // can skip the second exact peak, then manufacture uniqueness on refine.
    XCTAssertNil(ScrollingCaptureMotionTracker().estimateMotion(
      previous: grayFrame(width: width, height: height, pixels: previous),
      current: grayFrame(width: width, height: height, pixels: current),
      expectedSignedDeltaPixels: 66,
      lastAcceptedDeltaPixels: nil
    ))
  }

  private func grayFixture(
    offset: Int, header: Int, footer: Int, scale: Double = 1
  ) -> ScrollingCaptureGrayFrame {
    let width = 240
    let height = 400
    var pixels = [UInt8](repeating: 0, count: width * height)
    for row in 0 ..< height {
      for x in 0 ..< width {
        let value = UInt64(offset + row) &* 1_103_515_245
          &+ UInt64(x) &* 2_654_435_761 &+ 0x9E37_79B9_7F4A_7C15
        let mixed = value ^ (value >> 29) ^ (value >> 47)
        pixels[row * width + x] = row < header ? 231
          : row >= height - footer ? 37 : UInt8(truncatingIfNeeded: mixed)
      }
    }
    return grayFrame(width: width, height: height, pixels: pixels, scale: scale)
  }

  private func grayFrame(
    width: Int, height: Int, pixels: [UInt8], scale: Double = 1
  ) -> ScrollingCaptureGrayFrame {
    ScrollingCaptureGrayFrame(
      width: width, height: height, pixels: pixels, floats: pixels.map { Double($0) },
      fingerprint: 0, fullResScale: scale
    )
  }

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
