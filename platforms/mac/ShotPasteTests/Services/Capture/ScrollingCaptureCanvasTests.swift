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
