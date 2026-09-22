import AppKit
import ImageIO
@testable import ShotPaste
import XCTest

final class ScrollingCaptureCanvasTests: XCTestCase {
  func testBidirectionalGrowthAddsOnlyNewExtents() throws {
    let width = 80
    let height = 100
    let canvas = ScrollingCaptureCanvas(
      width: width,
      frameHeight: height,
      maxHeight: 500,
      thumbnailWidth: 40
    )
    canvas.placeBase(
      makeRaster(width: width, height: height, logicalYOffset: 100),
      contentTop: 0,
      contentBottom: height
    )

    let downRows = canvas.advanceCursor(measuredDelta: 20, heightBudget: 400)
    XCTAssertEqual(downRows, 20)
    canvas.blitStrip(
      from: makeRaster(width: width, height: height, logicalYOffset: 120),
      direction: .appendFromBottom,
      rowCount: downRows,
      deltaX: 0,
      contentTop: 0,
      contentBottom: height
    )

    // Reverse across the seed and grow ten rows beyond the historical top.
    let upRows = canvas.advanceCursor(measuredDelta: -30, heightBudget: 380)
    XCTAssertEqual(upRows, 10)
    canvas.blitStrip(
      from: makeRaster(width: width, height: height, logicalYOffset: 90),
      direction: .appendFromTop,
      rowCount: upRows,
      deltaX: 0,
      contentTop: 0,
      contentBottom: height
    )

    XCTAssertEqual(canvas.usedHeight, 130)
    let mergedImage = try XCTUnwrap(canvas.makeMergedCGImage())
    let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: mergedImage))
    XCTAssertEqual(rowSignature(in: merged, row: 0), rowSignature(logicalY: 90))
    XCTAssertEqual(rowSignature(in: merged, row: 129), rowSignature(logicalY: 219))
  }

  func testPreviewKeepsFixedWidthAndFollowsLatestGrowthEdge() throws {
    let width = 100
    let height = 100
    let canvas = ScrollingCaptureCanvas(
      width: width,
      frameHeight: height,
      maxHeight: 600,
      thumbnailWidth: 50
    )
    canvas.placeBase(makeRaster(width: width, height: height, logicalYOffset: 0), contentTop: 0, contentBottom: height)

    for offset in stride(from: 20, through: 160, by: 20) {
      let rows = canvas.advanceCursor(measuredDelta: 20, heightBudget: 600 - canvas.usedHeight)
      canvas.blitStrip(
        from: makeRaster(width: width, height: height, logicalYOffset: offset),
        direction: .appendFromBottom,
        rowCount: rows,
        deltaX: 0,
        contentTop: 0,
        contentBottom: height
      )
    }

    let preview = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: 50, maxPixelHeight: 60))
    XCTAssertEqual(preview.width, 50)
    XCTAssertEqual(preview.height, 60)
  }

  @MainActor
  func testHeightConstrainedPreviewKeepsReadableWidthAndFollowsBothGrowthEdges() throws {
    let anchorRect = CGRect(x: 20, y: 900, width: 570, height: 150)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 1_080)
    let bounds = ScrollingCapturePreviewLayout.renderPixelBounds(
      imagePixelWidth: 200,
      anchorRect: anchorRect,
      visibleFrame: visibleFrame
    )
    let canvas = ScrollingCaptureCanvas(width: 200, frameHeight: 100, maxHeight: 2_000, thumbnailWidth: 200)
    canvas.placeBase(makeRaster(width: 200, height: 100, logicalYOffset: 1_000), contentTop: 0, contentBottom: 100)

    for offset in stride(from: 100, through: 400, by: 100) {
      let rows = canvas.advanceCursor(measuredDelta: 100, heightBudget: 2_000 - canvas.usedHeight)
      canvas.blitStrip(
        from: makeRaster(width: 200, height: 100, logicalYOffset: 1_000 + offset),
        direction: .appendFromBottom,
        rowCount: rows,
        deltaX: 0,
        contentTop: 0,
        contentBottom: 100
      )
    }

    let downPreview = try XCTUnwrap(canvas.makePreviewCGImage(
      maxPixelWidth: bounds.width,
      maxPixelHeight: bounds.height
    ))
    let downRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: downPreview))
    let downSize = ScrollingCapturePreviewLayout.previewSize(
      for: downPreview, anchorRect: anchorRect, visibleFrame: visibleFrame
    )
    XCTAssertEqual(downSize, CGSize(width: 320, height: 168))
    XCTAssertEqual(rowSignature(in: downRaster, row: downRaster.height - 1), rowSignature(logicalY: 1_499))

    for offset in stride(from: 300, through: -200, by: -100) {
      let rows = canvas.advanceCursor(measuredDelta: -100, heightBudget: 2_000 - canvas.usedHeight)
      canvas.blitStrip(
        from: makeRaster(width: 200, height: 100, logicalYOffset: 1_000 + offset),
        direction: .appendFromTop,
        rowCount: rows,
        deltaX: 0,
        contentTop: 0,
        contentBottom: 100
      )
    }

    let upPreview = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: bounds.width, maxPixelHeight: bounds.height))
    let upRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: upPreview))
    let upSize = ScrollingCapturePreviewLayout.previewSize(
      for: upPreview, anchorRect: anchorRect, visibleFrame: visibleFrame
    )
    XCTAssertEqual(upSize, downSize)
    XCTAssertEqual(rowSignature(in: upRaster, row: 0), rowSignature(logicalY: 800))
  }

  @MainActor
  func testMaximumHeightCaptureKeepsOriginalPixelsThroughPNGSaveAndImageExport() async throws {
    let width = 64
    let frameHeight = 1_024
    let maximumHeight = ScrollingCaptureConfiguration.maxOutputHeight
    let canvas = ScrollingCaptureCanvas(
      width: width, frameHeight: frameHeight, maxHeight: maximumHeight, thumbnailWidth: 32
    )
    canvas.placeBase(
      makeRaster(width: width, height: frameHeight, logicalYOffset: 0),
      contentTop: 0,
      contentBottom: frameHeight
    )
    for offset in stride(from: frameHeight, to: maximumHeight, by: frameHeight) {
      let rows = canvas.advanceCursor(
        measuredDelta: Double(frameHeight),
        heightBudget: maximumHeight - canvas.usedHeight
      )
      canvas.blitStrip(
        from: makeRaster(width: width, height: frameHeight, logicalYOffset: offset),
        direction: .appendFromBottom,
        rowCount: rows,
        deltaX: 0,
        contentTop: 0,
        contentBottom: frameHeight
      )
    }
    let merged = try XCTUnwrap(canvas.makeMergedCGImage())
    XCTAssertEqual(merged.width, width)
    XCTAssertEqual(merged.height, maximumHeight)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      merged, to: directory, fileName: "long-capture", format: .png, scaleFactor: 2, emitCompletion: false
    )
    guard case .success(let url) = result else {
      return XCTFail("Expected full-resolution PNG save, got \(result)")
    }
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(decoded.width, width)
    XCTAssertEqual(decoded.height, maximumHeight)
    let raster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: decoded))
    for row in [0, maximumHeight / 2, maximumHeight - 1] {
      XCTAssertEqual(rowSignature(in: raster, row: row), rowSignature(logicalY: row))
    }

    // AppKit reload and the shared annotation/clipboard encoder must keep the
    // backing pixels, even though Retina metadata halves the logical size.
    let image = try XCTUnwrap(NSImage(contentsOf: url))
    let data = try XCTUnwrap(AnnotateExporter.imageData(from: image, for: "png"))
    let exportedSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(exportedSource, 0, nil))
    XCTAssertEqual(exported.width, width)
    XCTAssertEqual(exported.height, maximumHeight)
  }

  func testPreservedEdgesFollowOnlyNewExtentsAndPreviewAcrossSegments() throws {
    let canvas = ScrollingCaptureCanvas(width: 20, frameHeight: 100, maxHeight: 200, thumbnailWidth: 20)
    canvas.placeBase(
      makeRaster(width: 20, height: 100, logicalYOffset: 1_000),
      contentTop: 10, contentBottom: 80, preservingEdges: true
    )
    XCTAssertEqual(canvas.usedHeight, 100)
    let downRows = canvas.advanceCursor(measuredDelta: 20, heightBudget: 100)
    canvas.blitStrip(
      from: makeRaster(width: 20, height: 100, logicalYOffset: 1_020),
      direction: .appendFromBottom, rowCount: downRows, deltaX: 0, contentTop: 10, contentBottom: 80
    )

    for height in [10, 25, 120] {
      let preview = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: 20, maxPixelHeight: height))
      let raster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: preview))
      for row in 0 ..< height {
        XCTAssertEqual(rowSignature(in: raster, row: row), rowSignature(logicalY: 1_120 - height + row))
      }
    }

    let returningRows = canvas.advanceCursor(measuredDelta: -10, heightBudget: 80)
    XCTAssertEqual(returningRows, 0)
    canvas.blitStrip(
      from: makeRaster(width: 20, height: 100, logicalYOffset: 9_000),
      direction: .appendFromTop, rowCount: returningRows, deltaX: 0, contentTop: 10, contentBottom: 80
    )
    let unchanged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: try XCTUnwrap(canvas.makeMergedCGImage())))
    XCTAssertEqual(rowSignature(in: unchanged, row: 0), rowSignature(logicalY: 1_000))
    XCTAssertEqual(rowSignature(in: unchanged, row: 119), rowSignature(logicalY: 1_119))

    let upRows = canvas.advanceCursor(measuredDelta: -30, heightBudget: 80)
    canvas.blitStrip(
      from: makeRaster(width: 20, height: 100, logicalYOffset: 980),
      direction: .appendFromTop, rowCount: upRows, deltaX: 0, contentTop: 10, contentBottom: 80
    )
    XCTAssertEqual(canvas.usedHeight, 140)
    let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: try XCTUnwrap(canvas.makeMergedCGImage())))
    for row in 0 ..< 140 {
      XCTAssertEqual(rowSignature(in: merged, row: row), rowSignature(logicalY: 980 + row))
    }
    for height in [5, 25, 140] {
      let preview = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: 20, maxPixelHeight: height))
      let raster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: preview))
      for row in 0 ..< height {
        XCTAssertEqual(rowSignature(in: raster, row: row), rowSignature(logicalY: 980 + row))
      }
    }
    let scaled = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: 10, maxPixelHeight: 40))
    XCTAssertEqual(scaled.width, 10)
    XCTAssertEqual(scaled.height, 40)
  }

  func testHeightBudgetKeepsAdjacentRowsAndBoundedPreviewInBothDirections() throws {
    for preservingEdges in [false, true] {
      for direction in [ScrollingCaptureMergeDirection.appendFromBottom, .appendFromTop] {
        let header = preservingEdges ? 10 : 0
        let footer = preservingEdges ? 20 : 0
        let canvas = ScrollingCaptureCanvas(width: 20, frameHeight: 100, maxHeight: 120, thumbnailWidth: 10)
        canvas.placeBase(
          makeFixedEdgeRaster(bodyOffset: 100, header: header, footer: footer),
          contentTop: header, contentBottom: 100 - footer, preservingEdges: preservingEdges
        )
        let growingDown = direction == .appendFromBottom
        let rows = canvas.advanceCursor(measuredDelta: growingDown ? 50 : -50, heightBudget: 20)
        XCTAssertEqual(rows, 20)
        canvas.blitStrip(
          from: makeFixedEdgeRaster(bodyOffset: growingDown ? 150 : 50, header: header, footer: footer),
          direction: direction, rowCount: rows, deltaX: 0, contentTop: header, contentBottom: 100 - footer
        )

        XCTAssertEqual(canvas.usedHeight, 120)
        let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: try XCTUnwrap(canvas.makeMergedCGImage())))
        assertFixedEdgeRaster(merged, bodyOffset: growingDown ? 100 : 80, header: header, footer: footer)
        let preview = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: 10, maxPixelHeight: 100))
        XCTAssertEqual(preview.width, 10)
        XCTAssertEqual(preview.height, 60)
        let previewRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: preview))
        for alpha in stride(from: 3, to: previewRaster.pixels.count, by: 4) {
          XCTAssertEqual(previewRaster.pixels[alpha], 255)
        }
      }
    }
  }

  func testPreservedEdgesSurviveBodyRecenteringInBothDirections() throws {
    for direction in [ScrollingCaptureMergeDirection.appendFromBottom, .appendFromTop] {
      let growingDown = direction == .appendFromBottom
      let canvas = ScrollingCaptureCanvas(width: 20, frameHeight: 100, maxHeight: 150, thumbnailWidth: 20)
      canvas.placeBase(
        makeFixedEdgeRaster(bodyOffset: 100, header: 10, footer: 20),
        contentTop: 10, contentBottom: 80, preservingEdges: true
      )
      let rows = canvas.advanceCursor(measuredDelta: growingDown ? 50 : -50, heightBudget: 50)
      canvas.blitStrip(
        from: makeFixedEdgeRaster(bodyOffset: growingDown ? 150 : 50, header: 10, footer: 20),
        direction: direction, rowCount: rows, deltaX: 0, contentTop: 10, contentBottom: 80
      )
      let merged = try XCTUnwrap(ScrollingCaptureRaster(cgImage: try XCTUnwrap(canvas.makeMergedCGImage())))
      XCTAssertEqual(merged.height, 150)
      assertFixedEdgeRaster(merged, bodyOffset: growingDown ? 100 : 50, header: 10, footer: 20)
      let preview = try XCTUnwrap(canvas.makePreviewCGImage(maxPixelWidth: 20, maxPixelHeight: 200))
      let previewRaster = try XCTUnwrap(ScrollingCaptureRaster(cgImage: preview))
      XCTAssertEqual(previewRaster.pixels, merged.pixels)
    }
  }

  private func makeFixedEdgeRaster(bodyOffset: Int, header: Int, footer: Int) -> ScrollingCaptureRaster {
    var pixels: [UInt8] = []
    for row in 0 ..< 100 {
      let logicalY = row < header ? 10_000 + row
        : row >= 100 - footer ? 20_000 + row - (100 - footer) : bodyOffset + row - header
      let signature = rowSignature(logicalY: logicalY)
      for _ in 0 ..< 20 {
        pixels.append(contentsOf: signature + [255])
      }
    }
    return ScrollingCaptureRaster(width: 20, height: 100, pixels: pixels)
  }

  private func assertFixedEdgeRaster(_ raster: ScrollingCaptureRaster, bodyOffset: Int, header: Int, footer: Int) {
    for row in 0 ..< raster.height {
      let logicalY = row < header ? 10_000 + row
        : row >= raster.height - footer ? 20_000 + row - (raster.height - footer) : bodyOffset + row - header
      XCTAssertEqual(rowSignature(in: raster, row: row), rowSignature(logicalY: logicalY), "row \(row)")
    }
  }

  private func makeRaster(width: Int, height: Int, logicalYOffset: Int) -> ScrollingCaptureRaster {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0 ..< height {
      let signature = rowSignature(logicalY: logicalYOffset + row)
      for x in 0 ..< width {
        let index = (row * width + x) * 4
        pixels[index] = signature[0]
        pixels[index + 1] = signature[1]
        pixels[index + 2] = signature[2]
        pixels[index + 3] = 255
      }
    }
    return ScrollingCaptureRaster(width: width, height: height, pixels: pixels)
  }

  private func rowSignature(in raster: ScrollingCaptureRaster, row: Int) -> [UInt8] {
    let index = row * raster.bytesPerRow
    return [raster.pixels[index], raster.pixels[index + 1], raster.pixels[index + 2]]
  }

  private func rowSignature(logicalY: Int) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: logicalY),
      UInt8(truncatingIfNeeded: logicalY * 47),
      UInt8(truncatingIfNeeded: logicalY * 113),
    ]
  }
}
