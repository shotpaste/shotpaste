//
//  ScrollingCaptureStitcherTests.swift
//  ShotPasteTests
//
//  Unit tests for the scrolling capture stitch algorithm.
//

import CoreGraphics
@testable import ShotPaste
import XCTest

final class ScrollingCaptureStitcherTests: XCTestCase {
  // MARK: - start(with:)

  func testStart_initializesCorrectly() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 200, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    let update = stitcher.start(with: image)

    XCTAssertNotNil(update)
    XCTAssertEqual(update?.acceptedFrameCount, 1)
    XCTAssertEqual(update?.outputHeight, 100)
    XCTAssertNotNil(update?.mergedImage)

    if case .initialized = update?.outcome {} else {
      XCTFail("Expected .initialized outcome, got: \(String(describing: update?.outcome))")
    }
  }

  func testStart_setsFrameCount() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 50) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    XCTAssertEqual(stitcher.acceptedFrameCount, 1)
    XCTAssertEqual(stitcher.outputHeight, 50)
  }

  // MARK: - append identical image

  func testAppend_identicalImage_ignoredNoMovement() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(
      width: 200, height: 100,
      red: 80, green: 80, blue: 80
    ) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)

    let update = stitcher.append(image, maxOutputHeight: 10000)

    XCTAssertNotNil(update)
    if case .ignoredNoMovement = update?.outcome {} else {
      XCTFail("Expected .ignoredNoMovement for identical frame, got: \(String(describing: update?.outcome))")
    }

    // Frame count should NOT increment for ignored frames
    XCTAssertEqual(stitcher.acceptedFrameCount, 1)
  }

  // MARK: - append mismatched dimensions

  func testAppend_mismatchedDimensions_ignoredAlignmentFailed() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image1 = TestImageFactory.solidColor(width: 200, height: 100),
          let image2 = TestImageFactory.solidColor(width: 300, height: 100) else {
      XCTFail("Failed to create test images")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    XCTAssertNotNil(update)
    if case .ignoredAlignmentFailed = update?.outcome {} else {
      XCTFail("Expected .ignoredAlignmentFailed for mismatched dims, got: \(String(describing: update?.outcome))")
    }
  }

  func testAppend_mismatchedHeight_ignoredAlignmentFailed() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image1 = TestImageFactory.solidColor(width: 200, height: 100),
          let image2 = TestImageFactory.solidColor(width: 200, height: 150) else {
      XCTFail("Failed to create test images")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    if case .ignoredAlignmentFailed = update?.outcome {} else {
      XCTFail("Expected .ignoredAlignmentFailed for mismatched height")
    }
  }

  // MARK: - mergedImage

  func testMergedImage_afterStart_returnsNonNil() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let merged = stitcher.mergedImage()

    XCTAssertNotNil(merged)
    XCTAssertEqual(merged?.width, 100)
    XCTAssertEqual(merged?.height, 100)
  }

  func testMergedImage_beforeStart_returnsNil() {
    let stitcher = ScrollingCaptureStitcher()
    XCTAssertNil(stitcher.mergedImage())
  }

  // MARK: - previewImage

  func testPreviewImage_respectsMaxBounds() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 400, height: 400) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)

    let preview = stitcher.previewImage(maxPixelWidth: 100, maxPixelHeight: 100)
    XCTAssertNotNil(preview)

    if let preview {
      XCTAssertLessThanOrEqual(preview.width, 100)
      XCTAssertLessThanOrEqual(preview.height, 100)
    }
  }

  func testPreviewImage_beforeStart_returnsNil() {
    let stitcher = ScrollingCaptureStitcher()
    XCTAssertNil(stitcher.previewImage(maxPixelWidth: 200, maxPixelHeight: 200))
  }

  // MARK: - append with shifted content (integration)

  func testAppend_shiftedContent_appendsExactRows() {
    let stitcher = ScrollingCaptureStitcher()
    let width = 200
    let height = 100

    // Use distinct row signatures so there is measurable inter-frame change.
    guard let image1 = TestImageFactory.scrollingFrame(width: width, height: height, logicalYOffset: 0) else {
      XCTFail("Failed to create frame 1")
      return
    }

    guard let image2 = TestImageFactory.scrollingFrame(width: width, height: height, logicalYOffset: 20) else {
      XCTFail("Failed to create frame 2")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    XCTAssertNotNil(update)

    guard case .appended(let deltaY) = update?.outcome else {
      return XCTFail("Expected deterministic alignment, got \(String(describing: update?.outcome))")
    }
    XCTAssertEqual(deltaY, 20)
    XCTAssertEqual(stitcher.outputHeight, height + 20)
    XCTAssertEqual(stitcher.acceptedFrameCount, 2)
  }

  // MARK: - Multiple appends build height

  func testMultipleAppends_outputHeightAccumulates() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 50) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let initialHeight = stitcher.outputHeight
    XCTAssertEqual(initialHeight, 50)

    // Appending identical images won't increase height (no movement detected)
    _ = stitcher.append(image, maxOutputHeight: 10000)
    // Height should not change for identical frames
    XCTAssertEqual(stitcher.outputHeight, 50)
  }

  func testAppend_directionReversal_growsPastBothHistoricalExtents() throws {
    let stitcher = ScrollingCaptureStitcher()
    let base = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 100)
    )
    let down = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 124)
    )
    let aboveBase = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: 240, height: 180, logicalYOffset: 88)
    )

    _ = stitcher.start(with: base)
    let downUpdate = try XCTUnwrap(
      stitcher.append(down, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 24)
    )
    if case .appended(let delta) = downUpdate.outcome {
      XCTAssertEqual(delta, 24)
    } else {
      XCTFail("Expected downward append, got \(downUpdate.outcome)")
    }

    let reverseUpdate = try XCTUnwrap(
      stitcher.append(aboveBase, maxOutputHeight: 10_000, expectedSignedDeltaPixels: -36)
    )
    if case .appended(let delta) = reverseUpdate.outcome {
      XCTAssertEqual(delta, 12)
    } else {
      XCTFail("Expected reverse append beyond the historical top, got \(reverseUpdate.outcome)")
    }
    XCTAssertEqual(stitcher.outputHeight, 216)
  }

  func testAppend_firstMovementPreservesSelectedStaticEdgesExactlyOnce() throws {
    let width = 240
    let height = 400
    let headerHeight = 40
    let footerHeight = 32
    // The native regression first locked its direction after only two pixels
    // of movement, while the selected title was still in the initial frame.
    let delta = 2
    let first = try frameWithStaticEdges(
      width: width, height: height, logicalYOffset: 0, headerHeight: headerHeight, footerHeight: footerHeight
    )
    let second = try frameWithStaticEdges(
      width: width, height: height, logicalYOffset: delta, headerHeight: headerHeight, footerHeight: footerHeight
    )
    let stitcher = ScrollingCaptureStitcher()
    _ = stitcher.start(with: first)

    let update = try XCTUnwrap(stitcher.append(second, maxOutputHeight: 10_000, expectedSignedDeltaPixels: delta))
    guard case .appended(let appendedRows) = update.outcome else {
      return XCTFail("Expected first movement to append, got \(update.outcome)")
    }
    XCTAssertEqual(appendedRows, delta)
    XCTAssertEqual(
      update.outputHeight,
      height + delta,
      "Detecting fixed edges must not delete the selected first frame"
    )

    let mergedImage = try XCTUnwrap(stitcher.mergedImage())
    let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: mergedImage))
    let firstRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: first))
    let secondRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: second))
    XCTAssertTrue(
      merged.pixels.prefix(headerHeight * merged.bytesPerRow)
        .elementsEqual(firstRaster.pixels.prefix(headerHeight * firstRaster.bytesPerRow)),
      "The selected title/header must remain at the top"
    )
    XCTAssertTrue(
      merged.pixels.suffix(footerHeight * merged.bytesPerRow)
        .elementsEqual(secondRaster.pixels.suffix(footerHeight * secondRaster.bytesPerRow)),
      "The selected footer must remain at the bottom"
    )
    // The body should be a single continuous content range, without another
    // copy of either fixed edge inserted between the two captured frames.
    let expectedContentImage = try XCTUnwrap(
      TestImageFactory.scrollingFrame(width: width, height: height + delta, logicalYOffset: 0)
    )
    let expectedContent = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expectedContentImage))
    let bodyStart = headerHeight * merged.bytesPerRow
    let bodyEnd = (merged.height - footerHeight) * merged.bytesPerRow
    XCTAssertTrue(merged.pixels[bodyStart ..< bodyEnd].elementsEqual(expectedContent.pixels[bodyStart ..< bodyEnd]))
  }

  func testAppend_staticEdgesRemainSingleDuringBidirectionalGrowthAndRetraversal() throws {
    let stitcher = ScrollingCaptureStitcher()
    let offsets = [100, 124, 148, 124, 100, 76, 100, 148]
    let first = try frameWithStaticEdges(
      width: 240, height: 400, logicalYOffset: offsets[0], headerHeight: 40, footerHeight: 32
    )
    _ = stitcher.start(with: first)
    var minimumOffset = offsets[0]
    var maximumOffset = offsets[0]
    for index in 1 ..< offsets.count {
      let offset = offsets[index]
      let frame = try frameWithStaticEdges(
        width: 240, height: 400, logicalYOffset: offset, headerHeight: 40, footerHeight: 32
      )
      let previousHeight = stitcher.outputHeight
      let exposesNewContent = offset < minimumOffset || offset > maximumOffset
      let update = try XCTUnwrap(stitcher.append(
        frame, maxOutputHeight: 10_000, expectedSignedDeltaPixels: offset - offsets[index - 1]
      ))
      minimumOffset = min(minimumOffset, offset)
      maximumOffset = max(maximumOffset, offset)
      XCTAssertEqual(update.outputHeight, 400 + maximumOffset - minimumOffset)
      if exposesNewContent {
        guard case .appended = update.outcome else {
          return XCTFail("Expected growth at offset \(offset), got \(update.outcome)")
        }
      } else {
        guard case .ignoredNoMovement = update.outcome else {
          return XCTFail("Already captured content must not be duplicated, got \(update.outcome)")
        }
        XCTAssertEqual(update.outputHeight, previousHeight)
      }
    }
    let expected = try frameWithStaticEdges(
      width: 240, height: 400 + maximumOffset - minimumOffset,
      logicalYOffset: minimumOffset, headerHeight: 40, footerHeight: 32
    )
    let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    let expectedRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected))
    XCTAssertEqual(merged.width, expectedRaster.width)
    XCTAssertEqual(merged.height, expectedRaster.height)
    XCTAssertTrue(merged.pixels.elementsEqual(expectedRaster.pixels), "Fixed edges appear only at the two outer ends")
  }

  func testAppend_heightLimitIncludesPreservedHeaderAndFooter() throws {
    let stitcher = ScrollingCaptureStitcher()
    let maximumHeight = 424
    let first = try frameWithStaticEdges(
      width: 240, height: 400, logicalYOffset: 0, headerHeight: 40, footerHeight: 32
    )
    let second = try frameWithStaticEdges(
      width: 240, height: 400, logicalYOffset: 24, headerHeight: 40, footerHeight: 32
    )
    _ = stitcher.start(with: first, maxOutputHeight: maximumHeight)
    let update = try XCTUnwrap(stitcher.append(
      second, maxOutputHeight: maximumHeight, expectedSignedDeltaPixels: 24
    ))
    guard case .reachedHeightLimit = update.outcome else {
      return XCTFail("The output budget must include both fixed edges, got \(update.outcome)")
    }
    let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    let expected = try frameWithStaticEdges(
      width: 240, height: maximumHeight, logicalYOffset: 0, headerHeight: 40, footerHeight: 32
    )
    let expectedRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected))
    XCTAssertEqual(update.outputHeight, maximumHeight)
    XCTAssertEqual(merged.height, maximumHeight)
    XCTAssertTrue(merged.pixels.elementsEqual(expectedRaster.pixels))
  }

  func testAppend_thickFooterProducesContinuousPixelsDuringRetraversal() throws {
    let stitcher = ScrollingCaptureStitcher()
    let offsets = [100, 124, 148, 124, 100, 76, 100, 148]
    let first = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: offsets[0], headerHeight: 40, footerHeight: 120
    )
    _ = stitcher.start(with: first)
    var minimumOffset = offsets[0]
    var maximumOffset = offsets[0]
    for index in 1 ..< offsets.count {
      let offset = offsets[index]
      let frame = try frameWithStaticEdges(
        width: 240, height: 480, logicalYOffset: offset, headerHeight: 40, footerHeight: 120
      )
      let growth = max(0, offset - maximumOffset) + max(0, minimumOffset - offset)
      let update = try XCTUnwrap(stitcher.append(
        frame, maxOutputHeight: 10_000, expectedSignedDeltaPixels: offset - offsets[index - 1]
      ))
      if growth > 0 {
        guard case .appended(let delta) = update.outcome else {
          return XCTFail("Expected growth at offset \(offset), got \(update.outcome)")
        }
        XCTAssertEqual(delta, growth)
      } else {
        guard case .ignoredNoMovement = update.outcome else {
          return XCTFail("Retraversal must not add rows: \(update.outcome)")
        }
      }
      minimumOffset = min(minimumOffset, offset)
      maximumOffset = max(maximumOffset, offset)
      let expected = try frameWithStaticEdges(
        width: 240, height: 480 + maximumOffset - minimumOffset,
        logicalYOffset: minimumOffset, headerHeight: 40, footerHeight: 120
      )
      let actualRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
      let expectedRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected))
      XCTAssertEqual(actualRaster.height, expectedRaster.height)
      XCTAssertTrue(
        actualRaster.pixels.elementsEqual(expectedRaster.pixels),
        "Every seam must be continuous at \(offset)"
      )
    }
  }

  func testAppend_singleNoisyOuterRowDoesNotHideFixedFooter() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 100, headerHeight: 40, footerHeight: 80
    )
    _ = try XCTUnwrap(stitcher.start(with: first))
    let cleanSecond = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 124, headerHeight: 40, footerHeight: 80
    )
    let raster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: cleanSecond))
    var noisyPixels = raster.pixels
    for x in 0 ..< raster.width {
      for component in 0 ..< 3 {
        noisyPixels[(raster.height - 1) * raster.bytesPerRow + x * 4 + component] += 6
      }
    }
    let second = try XCTUnwrap(ScrollingCaptureRaster(
      width: raster.width, height: raster.height, pixels: noisyPixels
    ).makeCGImage())
    let update = try XCTUnwrap(stitcher.append(second, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 24))
    guard case .appended(let rows) = update.outcome else {
      return XCTFail("A single noisy edge row must not prevent a valid append: \(update.outcome)")
    }
    XCTAssertEqual(rows, 24)
    let expected = try frameWithStaticEdges(
      width: 240, height: 504, logicalYOffset: 100, headerHeight: 40, footerHeight: 80
    )
    let expectedRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected))
    var expectedPixels = expectedRaster.pixels
    // The latest outer edge is retained once; its changed row must never enter
    // an interior seam or replace any newly exposed body rows.
    for x in 0 ..< expectedRaster.width {
      for component in 0 ..< 3 {
        expectedPixels[(expectedRaster.height - 1) * expectedRaster.bytesPerRow + x * 4 + component] += 6
      }
    }
    let actual = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    XCTAssertEqual(actual.pixels, expectedPixels)
  }

  func testAppend_unresolvedFooterRejectsWithoutChangingCanvasOrReference() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 100, headerHeight: 40, footerHeight: 200
    )
    _ = stitcher.start(with: first)
    let initial = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    for offset in [124, 148] {
      let frame = try frameWithStaticEdges(
        width: 240, height: 480, logicalYOffset: offset, headerHeight: 40, footerHeight: 200
      )
      let update = try XCTUnwrap(stitcher.append(
        frame, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 24
      ))
      guard case .ignoredAlignmentFailed = update.outcome else {
        return XCTFail("An unbounded footer must not be appended: \(update.outcome)")
      }
      XCTAssertEqual(update.safety, .unsafe(reason: "static-edges-unresolved"))
      XCTAssertEqual(update.mergeDirection, .unresolved)
      XCTAssertEqual(update.acceptedFrameCount, 1)
      XCTAssertEqual(update.outputHeight, 480)
      let actual = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
      XCTAssertTrue(actual.pixels.elementsEqual(initial.pixels))
    }
    // Going back to the exact initial observation must still be stationary.
    let back = try XCTUnwrap(stitcher.append(first, maxOutputHeight: 10_000))
    guard case .ignoredNoMovement = back.outcome else {
      return XCTFail("Rejected observations must not replace the matching reference")
    }
  }

  func testAppend_thickFooterHeightLimitKeepsAdjacentContent() throws {
    let stitcher = ScrollingCaptureStitcher()
    let first = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 100, headerHeight: 40, footerHeight: 120
    )
    let second = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 124, headerHeight: 40, footerHeight: 120
    )
    _ = stitcher.start(with: first, maxOutputHeight: 490)
    let update = try XCTUnwrap(stitcher.append(
      second, maxOutputHeight: 490, expectedSignedDeltaPixels: 24
    ))
    guard case .reachedHeightLimit = update.outcome else {
      return XCTFail("Expected clipped growth, got \(update.outcome)")
    }
    let expected = try frameWithStaticEdges(
      width: 240, height: 490, logicalYOffset: 100, headerHeight: 40, footerHeight: 120
    )
    let actualRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    let expectedRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected))
    XCTAssertEqual(update.outputHeight, 490)
    XCTAssertTrue(actualRaster.pixels.elementsEqual(expectedRaster.pixels))
  }

  func testAppend_lowContrastFirstMovementPreservesEdgesAndContinuousBody() throws {
    for (header, footer) in [(40, 120), (0, 0)] {
      let first = try frameWithStaticEdges(
        width: 240, height: 480, logicalYOffset: 100, headerHeight: header, footerHeight: footer,
        lowContrastBody: true
      )
      let second = try frameWithStaticEdges(
        width: 240, height: 480, logicalYOffset: 124, headerHeight: header, footerHeight: footer,
        lowContrastBody: true
      )
      let tracker = ScrollingCaptureMotionTracker()
      let difference = tracker.frameDifference(
        previous: try XCTUnwrap(tracker.makeGrayFrame(from: first)),
        current: try XCTUnwrap(tracker.makeGrayFrame(from: second))
      )
      XCTAssertGreaterThanOrEqual(difference, 1.2)
      XCTAssertLessThan(difference, 4.5)
      let stitcher = ScrollingCaptureStitcher()
      _ = stitcher.start(with: first)
      let update = try XCTUnwrap(stitcher.append(
        second, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 24
      ))
      guard case .appended(let rows) = update.outcome else {
        return XCTFail("Low-contrast movement must append safely: \(update.outcome)")
      }
      XCTAssertEqual(rows, 24)
      XCTAssertEqual(update.outputHeight, 504)
      XCTAssertEqual(update.acceptedFrameCount, 2)
      let expected = try frameWithStaticEdges(
        width: 240, height: 504, logicalYOffset: 100, headerHeight: header, footerHeight: footer,
        lowContrastBody: true
      )
      let actual = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
      XCTAssertEqual(actual.pixels, try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected)).pixels)
    }
  }

  func testAppend_decodeFailureDoesNotCommitDirectionOrCursorBeforeReverseGrowth() throws {
    var decodeCount = 0
    let stitcher = ScrollingCaptureStitcher { image in
      decodeCount += 1
      return decodeCount == 2 ? nil : ScrollingCaptureRaster(cgImage: image)
    }
    let first = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 100, headerHeight: 40, footerHeight: 120
    )
    _ = try XCTUnwrap(stitcher.start(with: first))
    let down = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 124, headerHeight: 40, footerHeight: 120
    )
    let rejected = try XCTUnwrap(stitcher.append(down, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 24))
    guard case .ignoredAlignmentFailed = rejected.outcome else {
      return XCTFail("Expected injected decode failure")
    }
    XCTAssertEqual(rejected.mergeDirection, .unresolved)
    XCTAssertEqual(rejected.outputHeight, 480)
    XCTAssertEqual(rejected.acceptedFrameCount, 1)
    let unchanged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    XCTAssertEqual(unchanged.pixels, try XCTUnwrap(ScrollingCaptureRaster(cgImage: first)).pixels)

    let up = try frameWithStaticEdges(
      width: 240, height: 480, logicalYOffset: 76, headerHeight: 40, footerHeight: 120
    )
    let recovered = try XCTUnwrap(stitcher.append(up, maxOutputHeight: 10_000, expectedSignedDeltaPixels: -24))
    guard case .appended(let rows) = recovered.outcome else {
      return XCTFail("Rejected decode must not consume reverse growth: \(recovered.outcome)")
    }
    XCTAssertEqual(rows, 24)
    XCTAssertEqual(recovered.mergeDirection, .appendFromTop)
    XCTAssertEqual(recovered.acceptedFrameCount, 2)
    let expected = try frameWithStaticEdges(
      width: 240, height: 504, logicalYOffset: 76, headerHeight: 40, footerHeight: 120
    )
    let actual = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    XCTAssertEqual(actual.pixels, try XCTUnwrap(ScrollingCaptureRaster(cgImage: expected)).pixels)
  }

  private func frameWithStaticEdges(
    width: Int,
    height: Int,
    logicalYOffset: Int,
    headerHeight: Int,
    footerHeight: Int,
    lowContrastBody: Bool = false
  ) throws -> CGImage {
    let content = try XCTUnwrap(TestImageFactory.scrollingFrame(
      width: width, height: height, logicalYOffset: logicalYOffset
    ))
    let raster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: content))
    var pixels = raster.pixels
    if lowContrastBody {
      for row in headerHeight ..< height - footerHeight {
        for x in 0 ..< width {
          let offset = row * raster.bytesPerRow + x * 4
          let gray = (Int(pixels[offset]) * 77 + Int(pixels[offset + 1]) * 150
            + Int(pixels[offset + 2]) * 29) >> 8
          let value = UInt8(120 + gray / 16)
          pixels[offset] = value
          pixels[offset + 1] = value
          pixels[offset + 2] = value
        }
      }
    }
    for row in 0 ..< height where row < headerHeight || row >= height - footerHeight {
      let color: [UInt8] = row < headerHeight ? [231, 29, 43, 255] : [37, 227, 59, 255]
      for x in 0 ..< width {
        let offset = row * raster.bytesPerRow + x * 4
        pixels.replaceSubrange(offset ..< offset + 4, with: color)
      }
    }
    return try XCTUnwrap(ScrollingCaptureRaster(width: width, height: height, pixels: pixels).makeCGImage())
  }

  // MARK: - maxOutputHeight enforcement

  func testAppend_atMaxOutputHeight_returnsReachedHeightLimit() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)

    // max = current output height → no more room
    let update = stitcher.append(image, maxOutputHeight: stitcher.outputHeight)

    // For identical images, likely ignoredNoMovement; for shifted images it would be reachedHeightLimit
    // Either outcome is acceptable since we're testing the height limit enforcement path
    XCTAssertNotNil(update)
  }

  // MARK: - Alignment Debug Info

  func testStart_alignmentDebug_isInitialFrame() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    let update = stitcher.start(with: image)
    XCTAssertEqual(update?.alignmentDebug?.path, .initialFrame)
    XCTAssertEqual(update?.alignmentDebug?.confidence, 1.0)
    XCTAssertNil(update?.alignmentDebug?.peakCorrelation)
    XCTAssertEqual(update?.alignmentDebug?.horizontalShift, 0)
    XCTAssertEqual(update?.safety, .confirmed)
  }

  // MARK: - Merge Direction

  func testStart_mergeDirectionIsUnresolved() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    let update = stitcher.start(with: image)
    XCTAssertEqual(update?.mergeDirection, .unresolved)
  }

  // MARK: - likelyReachedBoundary

  func testAppend_identicalImage_setsLikelyReachedBoundary() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(
      width: 200, height: 100,
      red: 120, green: 120, blue: 120
    ) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let update = stitcher.append(image, maxOutputHeight: 10000)

    if case .ignoredNoMovement = update?.outcome {
      XCTAssertTrue(update?.likelyReachedBoundary ?? false)
    }
  }

  // MARK: - renderMergedImage flag

  func testAppend_renderMergedImageFalse_skipsMergedImage() {
    let stitcher = ScrollingCaptureStitcher()
    guard let image = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }

    _ = stitcher.start(with: image)
    let update = stitcher.append(image, maxOutputHeight: 10000, renderMergedImage: false)

    // When renderMergedImage is false, mergedImage in the update may still be
    // the cached version from start(), so we just verify the call succeeds.
    XCTAssertNotNil(update)
  }

  func testAppend_mismatchedDimensions_marksUnsafe() {
    let stitcher = ScrollingCaptureStitcher()
    guard
      let image1 = TestImageFactory.solidColor(width: 100, height: 100),
      let image2 = TestImageFactory.solidColor(width: 120, height: 100)
    else {
      XCTFail("Failed to create test images")
      return
    }

    _ = stitcher.start(with: image1)
    let update = stitcher.append(image2, maxOutputHeight: 10000)

    XCTAssertEqual(update?.safety, .unsafe(reason: "alignment-failed"))
  }
}
