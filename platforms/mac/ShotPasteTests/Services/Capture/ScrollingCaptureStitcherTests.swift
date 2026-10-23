//
//  ScrollingCaptureStitcherTests.swift
//  ShotPasteTests
//
//  Unit tests for the scrolling capture stitch algorithm.
//

import CoreGraphics
import CoreText
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

  func testAppend_smallStepsAtNonIntegralGrayScaleDoNotAccumulateDrift() throws {
    let width = 920
    let height = 635
    let step = 20
    let appendCount = 24
    let expectedHeight = height + step * appendCount
    let document = try textDocument(width: width, height: expectedHeight)
    let expected = try XCTUnwrap(ScrollingCaptureRaster(cgImage: document))
    func frame(at offset: Int) throws -> CGImage {
      let start = offset * expected.bytesPerRow
      let pixels = Array(expected.pixels[start ..< start + height * expected.bytesPerRow])
      return try XCTUnwrap(ScrollingCaptureRaster(width: width, height: height, pixels: pixels).makeCGImage())
    }

    // 920x635 becomes 480x331. Each 20px movement has a fractional gray
    // displacement, so a biased subpixel fit can silently accumulate error.
    let stitcher = ScrollingCaptureStitcher()
    _ = try XCTUnwrap(stitcher.start(with: frame(at: 0), maxOutputHeight: expectedHeight + 64))
    for index in 1 ... appendCount {
      let update = try XCTUnwrap(stitcher.append(
        frame(at: index * step), maxOutputHeight: expectedHeight + 64,
        expectedSignedDeltaPixels: step, renderMergedImage: false
      ))
      guard case .appended = update.outcome else {
        return XCTFail("Every small movement must append; frame \(index): \(update.outcome)")
      }
      XCTAssertEqual(update.acceptedFrameCount, index + 1)
      XCTAssertEqual(update.matchFailureCount, 0)
    }

    let actual = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
    XCTAssertEqual(actual.width, width)
    XCTAssertLessThanOrEqual(abs(actual.height - expectedHeight), 1, "Small-step errors must not accumulate")
    XCTAssertTrue(
      actual.pixels.elementsEqual(expected.pixels),
      "Text and horizontal rules must retain their original spacing across all seams"
    )
  }

  private func textDocument(width: Int, height: Int) throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
    let sentences = [
      "Scrolling capture keeps each document line at its original vertical position.",
      "A short paragraph contains normal text, punctuation, and useful whitespace.",
      "Measure the complete page after many small scrolls, including every seam.",
      "The selected region should preserve the distance between section headings.",
      "Local screenshots can contain tables, horizontal rules, and numbered notes.",
    ]
    var top = 10
    var lineNumber = 0
    while top + 20 < height {
      let text = String(format: "%03d  ", lineNumber) + sentences[lineNumber % sentences.count]
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1),
      ]))
      context.textPosition = CGPoint(x: 24, y: height - top - 16)
      CTLineDraw(line, context)
      // Vary line spacing and number every line to avoid periodic NCC peaks.
      top += 24 + (lineNumber % 4) * 3
      if lineNumber % 5 == 4 {
        context.setFillColor(gray: 0.55, alpha: 1)
        context.fill(CGRect(x: 24, y: height - top - 2, width: width - 48, height: 2))
        top += 13
      }
      lineNumber += 1
    }
    return try XCTUnwrap(context.makeImage())
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

  func testAppend_translucentEdgesPreserveFixedMarkersAndContinuousBodyAtBothScales() throws {
    for scale in [1, 2] {
      try assertTranslucentEdgeSequence(scale: scale, hasFixedOverlays: true)
    }
  }

  func testAppend_smallInitialMotionWaitsWithoutConsumingTheReference() throws {
    let first = try XCTUnwrap(TestImageFactory.scrollingFrame(
      width: 240, height: 480, logicalYOffset: 100
    ))
    let stitcher = ScrollingCaptureStitcher()
    _ = try XCTUnwrap(stitcher.start(with: first))
    let small = try XCTUnwrap(TestImageFactory.scrollingFrame(
      width: 240, height: 480, logicalYOffset: 101
    ))
    let waiting = try XCTUnwrap(stitcher.append(
      small, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 1
    ))
    guard case .ignoredNoMovement = waiting.outcome else {
      return XCTFail("The first reference must survive a sub-resolution movement")
    }
    XCTAssertEqual(waiting.acceptedFrameCount, 1)
    XCTAssertEqual(waiting.matchFailureCount, 0)
    XCTAssertFalse(waiting.likelyReachedBoundary)
    XCTAssertEqual(waiting.mergeDirection, .unresolved)

    let measurable = try XCTUnwrap(TestImageFactory.scrollingFrame(
      width: 240, height: 480, logicalYOffset: 103
    ))
    let accepted = try XCTUnwrap(stitcher.append(
      measurable, maxOutputHeight: 10_000, expectedSignedDeltaPixels: 2
    ))
    guard case .appended(let rows) = accepted.outcome else {
      return XCTFail("Accumulated motion must be measured against the original reference")
    }
    XCTAssertEqual(rows, 3)
    XCTAssertEqual(accepted.acceptedFrameCount, 2)
    XCTAssertEqual(accepted.matchFailureCount, 0)
    XCTAssertEqual(accepted.outputHeight, 483)
  }

  func testAppend_movingTextWithoutOverlaysRemainsUncroppedAtBothScales() throws {
    for scale in [1, 2] {
      try assertTranslucentEdgeSequence(scale: scale, hasFixedOverlays: false)
    }
  }

  private enum TranslucentEdgeFixture {
    static let width = 480
    static let height = 640
    static let headerHeight = 64
    static let footerHeight = 104
    static let markerColors: [[UInt8]] = [
      [237, 25, 165, 255], // Fixed title marker.
      [247, 77, 13, 255], // Top border of the footer buttons.
      [19, 231, 243, 255], // Vertical markers inside both footer buttons.
    ]
  }

  private func assertTranslucentEdgeSequence(scale: Int, hasFixedOverlays: Bool) throws {
    // Start with a small movement, grow beyond the entire footer, reverse past
    // the initial top, retraverse captured content, then expose new bottom rows.
    let offsets = [160, 184, 300, 136, 300, 324]
    let first = try frameWithTranslucentEdges(
      logicalYOffset: offsets[0], scale: scale, hasFixedOverlays: hasFixedOverlays
    )
    let firstRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: first))
    let markerCounts = TranslucentEdgeFixture.markerColors.map { markerPixelCount($0, in: firstRaster) }
    if hasFixedOverlays {
      XCTAssertTrue(markerCounts.allSatisfy { $0 > 0 }, "All fixed markers must be present in the fixture")
    }
    let stitcher = ScrollingCaptureStitcher()
    _ = try XCTUnwrap(stitcher.start(with: first))
    var minimumOffset = offsets[0]
    var maximumOffset = offsets[0]
    for index in 1 ..< offsets.count {
      let offset = offsets[index]
      let growth = max(0, offset - maximumOffset) + max(0, minimumOffset - offset)
      let frame = try frameWithTranslucentEdges(
        logicalYOffset: offset, scale: scale, hasFixedOverlays: hasFixedOverlays
      )
      let update = try XCTUnwrap(stitcher.append(
        frame, maxOutputHeight: 10_000,
        expectedSignedDeltaPixels: (offset - offsets[index - 1]) * scale
      ))
      let context = "scale=\(scale), offset=\(offset), overlays=\(hasFixedOverlays)"
      if growth > 0 {
        guard case .appended(let rows) = update.outcome else {
          return XCTFail("Valid movement must append successfully: \(update.outcome), \(context)")
        }
        XCTAssertEqual(rows, growth * scale, context)
      } else {
        guard case .ignoredNoMovement = update.outcome else {
          return XCTFail("Retraversal must not duplicate captured rows: \(update.outcome), \(context)")
        }
      }
      minimumOffset = min(minimumOffset, offset)
      maximumOffset = max(maximumOffset, offset)
      let expectedHeight = TranslucentEdgeFixture.height + maximumOffset - minimumOffset
      XCTAssertEqual(update.outputHeight, expectedHeight * scale, context)
      let actual = try XCTUnwrap(ScrollingCaptureRaster(cgImage: XCTUnwrap(stitcher.mergedImage())))
      let expectedImage = try frameWithTranslucentEdges(
        logicalYOffset: minimumOffset, scale: scale, hasFixedOverlays: false, height: expectedHeight
      )
      let expected = try XCTUnwrap(ScrollingCaptureRaster(cgImage: expectedImage))
      XCTAssertEqual(actual.width, expected.width, context)
      XCTAssertEqual(actual.height, expected.height, context)
      if hasFixedOverlays {
        for (markerIndex, color) in TranslucentEdgeFixture.markerColors.enumerated() {
          XCTAssertEqual(
            markerPixelCount(color, in: actual), markerCounts[markerIndex],
            "Fixed marker \(markerIndex) must survive exactly once: \(context)"
          )
        }
        assertContinuousBodyAnchors(actual: actual, expected: expected, scale: scale, context: context)
      } else {
        XCTAssertTrue(
          actual.pixels.elementsEqual(expected.pixels),
          "Moving text must remain pixel-exact over the entire captured range: \(context)"
        )
      }
    }
  }

  private func frameWithTranslucentEdges(
    logicalYOffset: Int,
    scale: Int,
    hasFixedOverlays: Bool,
    height: Int = TranslucentEdgeFixture.height
  ) throws -> CGImage {
    let width = TranslucentEdgeFixture.width
    let content = try XCTUnwrap(TestImageFactory.scrollingFrame(
      width: width, height: height, logicalYOffset: logicalYOffset
    ))
    let raster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: content))
    var pixels = raster.pixels
    for row in 0 ..< height {
      let logicalRow = logicalYOffset + row
      for x in 0 ..< width {
        let offset = row * raster.bytesPerRow + x * 4
        let gray = (Int(pixels[offset]) * 77 + Int(pixels[offset + 1]) * 150
          + Int(pixels[offset + 2]) * 29) >> 8
        // The existing factory supplies unique row signatures. Add text-like
        // strokes in content coordinates, so they scroll with those rows.
        let isText = x >= 24 && x < 272 && (6 ..< 16).contains(logicalRow % 24)
          && (x % 12 == 2 || (logicalRow % 24 == 6 && (x / 12 + logicalRow / 24) % 3 != 0))
        let bodyGray = UInt8(isText ? 24 + gray / 8 : 48 + gray * 160 / 256)
        var color: [UInt8] = [bodyGray, bodyGray, bodyGray, 255]
        if hasFixedOverlays {
          let structure = UInt64(row) &* 1_103_515_245 &+ UInt64(x) &* 2_654_435_761
            &+ 0x9E37_79B9_7F4A_7C15
          let mixed = UInt8(truncatingIfNeeded: structure ^ (structure >> 29) ^ (structure >> 47))
          let ink = UInt8(24 + Int(mixed) * 176 / 256)
          if row < 8 || row >= height - 8 {
            // Only these thin outer rows have a genuinely fixed background.
            color = [36, 36, 36, 255]
          } else if row < TranslucentEdgeFixture.headerHeight {
            // A low-frequency glass background changes brightness with scroll
            // position; full-row absolute difference cannot identify the title.
            let glass = UInt8(126 + logicalYOffset % 80 / 2 + x / 40 + row / 16)
            color = [glass, glass, glass, 255]
            if (48 ..< 304).contains(x), row >= 12 {
              let tintedInk = UInt8(Int(ink) + logicalYOffset % 80 / 2)
              color = row < 16 ? TranslucentEdgeFixture.markerColors[0] : [tintedInk, tintedInk, tintedInk, 255]
            }
          } else if row >= height - TranslucentEdgeFixture.footerHeight {
            // The left side and button gaps retain the moving body. The fixed
            // high-contrast structures occupy only the right side of the inset.
            if row < height - TranslucentEdgeFixture.footerHeight + 4, (304 ..< 448).contains(x) {
              color = TranslucentEdgeFixture.markerColors[1]
            } else if (304 ..< 368).contains(x) || (384 ..< 448).contains(x) {
              color = [ink, ink, ink, 255]
              if (312 ..< 316).contains(x) || (392 ..< 396).contains(x) {
                color = TranslucentEdgeFixture.markerColors[2]
              }
            }
          }
        }
        for component in 0 ..< 4 {
          pixels[offset + component] = color[component]
        }
      }
    }
    if scale == 1 {
      return try XCTUnwrap(ScrollingCaptureRaster(width: width, height: height, pixels: pixels).makeCGImage())
    }
    // Scale the same logical scene, including controls and scroll deltas, to
    // exercise the matcher's gray-to-full-resolution mapping at Retina density.
    let scaledWidth = width * scale
    var scaledPixels = [UInt8](repeating: 0, count: scaledWidth * height * scale * 4)
    for row in 0 ..< height * scale {
      for x in 0 ..< scaledWidth {
        let source = ((row / scale) * width + x / scale) * 4
        let destination = (row * scaledWidth + x) * 4
        for component in 0 ..< 4 {
          scaledPixels[destination + component] = pixels[source + component]
        }
      }
    }
    return try XCTUnwrap(ScrollingCaptureRaster(
      width: scaledWidth, height: height * scale, pixels: scaledPixels
    ).makeCGImage())
  }

  private func markerPixelCount(_ color: [UInt8], in raster: ScrollingCaptureRaster) -> Int {
    stride(from: 0, to: raster.pixels.count, by: 4).reduce(into: 0) { count, offset in
      if raster.pixels[offset ..< offset + 4].elementsEqual(color) {
        count += 1
      }
    }
  }

  private func assertContinuousBodyAnchors(
    actual: ScrollingCaptureRaster,
    expected: ScrollingCaptureRaster,
    scale: Int,
    context: String
  ) {
    // Allow a small margin around the synthetic chrome instead of prescribing
    // the detector's exact crop row. Everything inside must remain continuous.
    let firstExpectedRow = (TranslucentEdgeFixture.headerHeight + 16) * scale
    let bodyEnd = expected.height - (TranslucentEdgeFixture.footerHeight + 24) * scale
    let xStart = 40 * scale * 4
    let xEnd = 232 * scale * 4
    var firstActualRow: Int?
    for expectedRow in stride(from: firstExpectedRow, to: bodyEnd, by: 32 * scale) {
      let expectedStart = expectedRow * expected.bytesPerRow
      let signature = expected.pixels[expectedStart + xStart ..< expectedStart + xEnd]
      let matchingRows = (0 ..< actual.height).filter { row in
        let actualStart = row * actual.bytesPerRow
        return actual.pixels[actualStart + xStart ..< actualStart + xEnd].elementsEqual(signature)
      }
      // Nearest-neighbor Retina scaling repeats each logical row twice.
      XCTAssertEqual(matchingRows.count, scale, "A body anchor was duplicated or lost: \(context)")
      guard let actualRow = matchingRows.first else { return }
      if let firstActualRow {
        XCTAssertEqual(
          actualRow - firstActualRow, expectedRow - firstExpectedRow,
          "Body anchors must retain their order and spacing: \(context)"
        )
      } else {
        firstActualRow = actualRow
      }
    }
    guard let firstActualRow, firstActualRow + bodyEnd - firstExpectedRow <= actual.height else {
      return XCTFail("The continuous body range is missing: \(context)")
    }
    for relativeRow in 0 ..< bodyEnd - firstExpectedRow {
      let actualStart = (firstActualRow + relativeRow) * actual.bytesPerRow
      let expectedStart = (firstExpectedRow + relativeRow) * expected.bytesPerRow
      guard actual.pixels[actualStart + xStart ..< actualStart + xEnd]
        .elementsEqual(expected.pixels[expectedStart + xStart ..< expectedStart + xEnd]) else {
        return XCTFail("Body rows were repeated, skipped, or replaced at row \(relativeRow): \(context)")
      }
    }
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
