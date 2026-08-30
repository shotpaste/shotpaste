//
//  LocalOCRTilerTests.swift
//  ShotPasteTests
//

import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

final class LocalOCRTilerTests: XCTestCase {
  func testFiveKImageUsesNativeOverlappingTilesWithoutUpscaling() throws {
    let image = try XCTUnwrap(makeImage(width: 5_120, height: 2_880))

    let tiles = try LocalOCRTiler.tiles(for: image, deadline: .distantFuture)

    XCTAssertEqual(tiles.count, 6)
    XCTAssertTrue(tiles.allSatisfy { $0.image.width <= LocalOCRTiler.maximumTileDimension })
    XCTAssertTrue(tiles.allSatisfy { $0.image.height <= LocalOCRTiler.maximumTileDimension })
    XCTAssertEqual(Set(tiles.map(\.id)).count, tiles.count)
    XCTAssertEqual(tiles.map(\.id), (0 ..< tiles.count).map { "ocr-tile-\($0)" })
    assertAxisCoverage(
      origins: try LocalOCRTiler.origins(forLength: 5_120, deadline: .distantFuture),
      length: 5_120
    )
    assertAxisCoverage(
      origins: try LocalOCRTiler.origins(forLength: 2_880, deadline: .distantFuture),
      length: 2_880
    )
    XCTAssertTrue(tiles.allSatisfy { tile in
      tile.image.width == Int(tile.pixelRect.width)
        && tile.image.height == Int(tile.pixelRect.height)
        && tile.pixelRect.width == CGFloat(tile.image.width)
        && tile.pixelRect.height == CGFloat(tile.image.height)
    })
  }

  func testOriginsCoverNearAndLargeDisplayWidthsWithoutHugeRepeatedRegions() throws {
    for length in [2_561, 2_880, 3_840, 5_120] {
      let origins = try LocalOCRTiler.origins(forLength: length, deadline: .distantFuture)
      assertAxisCoverage(origins: origins, length: length)
      XCTAssertEqual(origins.first, 0)
      XCTAssertTrue(origins.allSatisfy { $0 >= 0 && $0 < length })
    }
  }

  func testOriginsStopAtExactBoundaryAndOnlyAddTailAfterEndRemainsUncovered() throws {
    let expected: [(Int, [Int], Int)] = [
      (2_560, [0], 2_560),
      (2_561, [0, 2_464], 97),
      (5_024, [0, 2_464], 2_560),
      (5_025, [0, 2_464, 4_928], 97),
    ]

    for (length, expectedOrigins, expectedFinalWidth) in expected {
      let origins = try LocalOCRTiler.origins(forLength: length, deadline: .distantFuture)
      XCTAssertEqual(origins, expectedOrigins, "length (length)")
      assertAxisCoverage(origins: origins, length: length)
      XCTAssertEqual(length - origins.last!, expectedFinalWidth)
    }
  }

  func testOriginsFailClosedBeforeIntegerOverflowOrUnboundedTileCount() {
    XCTAssertThrowsError(
      try LocalOCRTiler.origins(forLength: Int.max, deadline: .distantFuture)
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
    }
  }

  func testCropUsesTopLeftPixelRowsForOCRTileCoordinates() throws {
    let image = try XCTUnwrap(makeColorRowImage())
    let tileImage = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 4, height: 2)))

    XCTAssertEqual(pixel(in: tileImage, x: 0, y: 0), [255, 0, 0, 255])
    XCTAssertEqual(pixel(in: tileImage, x: 0, y: 1), [0, 255, 0, 255])
  }

  func testExpiredTileDeadlineStopsBeforeCropping() throws {
    let image = try XCTUnwrap(makeImage(width: 5_120, height: 2_880))
    XCTAssertThrowsError(
      try LocalOCRTiler.tiles(for: image, deadline: Date(timeIntervalSince1970: 0))
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
  }

  func testVisionBottomLeftBoundsBecomeTopLeftPixels() throws {
    let rect = try XCTUnwrap(LocalOCRTiler.topLeftPixelRect(
      fromVisionBounds: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
      tilePixelSize: CGSize(width: 200, height: 100)
    ))

    // Vision's normalized-to-pixel conversion can produce values such as
    // 39.999999999 on a different CoreGraphics/CPU path.  Assert each
    // component with tolerance instead of requiring CGRect bit equality.
    XCTAssertEqual(rect.minX, 20, accuracy: 0.001)
    XCTAssertEqual(rect.minY, 40, accuracy: 0.001)
    XCTAssertEqual(rect.width, 100, accuracy: 0.001)
    XCTAssertEqual(rect.height, 40, accuracy: 0.001)
  }

  func testOutOfRangeVisionBoundsAreClippedAndOnePixelTextSurvives() {
    XCTAssertNil(
      LocalOCRTiler.topLeftPixelRect(
        fromVisionBounds: CGRect(x: -0.2, y: 0.2, width: 0.1, height: 0.1),
        tilePixelSize: CGSize(width: 200, height: 200)
      )
    )

    let onePixel = LocalOCRTiler.topLeftPixelRect(
      fromVisionBounds: CGRect(x: 0.5, y: 0.5, width: 0.005, height: 0.005),
      tilePixelSize: CGSize(width: 200, height: 200)
    )
    XCTAssertEqual(onePixel?.width ?? 0, 1, accuracy: 0.001)
    XCTAssertEqual(onePixel?.height ?? 0, 1, accuracy: 0.001)
  }

  func testRetinaAndNegativeScreenCoordinatesMapCorrectly() throws {
    let screen = LocalOCRTiler.screenRect(
      fromTopLeftPixelRect: CGRect(x: 20, y: 20, width: 100, height: 40),
      imagePixelSize: CGSize(width: 200, height: 100),
      screenRect: CGRect(x: -100, y: 50, width: 100, height: 50)
    )

    let unwrappedScreen = try XCTUnwrap(screen)
    XCTAssertEqual(unwrappedScreen.minX, -90, accuracy: 0.001)
    XCTAssertEqual(unwrappedScreen.minY, 70, accuracy: 0.001)
    XCTAssertEqual(unwrappedScreen.width, 50, accuracy: 0.001)
    XCTAssertEqual(unwrappedScreen.height, 20, accuracy: 0.001)
  }

  func testEqualTextAtDifferentLocationsIsNotDeduplicated() {
    let first = TranslationOCRLine(
      text: "File",
      pixelBounds: CGRect(x: 10, y: 10, width: 40, height: 12),
      confidence: 0.8,
      sourceTileID: "ocr-tile-0"
    )
    let overlap = TranslationOCRLine(
      text: " File ",
      pixelBounds: CGRect(x: 11, y: 10, width: 40, height: 12),
      confidence: 0.9,
      sourceTileID: "ocr-tile-1"
    )
    let other = TranslationOCRLine(
      text: "File",
      pixelBounds: CGRect(x: 400, y: 10, width: 40, height: 12),
      confidence: 0.7,
      sourceTileID: "ocr-tile-1"
    )

    let deduplicated = try! LocalOCRTiler.deduplicated(
      [first, overlap, other],
      deadline: .distantFuture
    )

    XCTAssertEqual(deduplicated.count, 2)
    XCTAssertEqual(deduplicated.first?.confidence, 0.9)
    XCTAssertEqual(deduplicated.last?.pixelBounds.minX, 400)
  }

  private func makeImage(width: Int, height: Int) -> CGImage? {
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
  }

  private func makeColorRowImage() -> CGImage? {
    let rows: [[UInt8]] = [
      [255, 0, 0, 255],
      [0, 255, 0, 255],
      [0, 0, 255, 255],
      [255, 255, 0, 255],
    ]
    var bytes: [UInt8] = []
    for row in rows {
      for _ in 0 ..< 4 { bytes.append(contentsOf: row) }
    }
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
      width: 4,
      height: 4,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 16,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }

  private func pixel(in image: CGImage, x: Int, y: Int) -> [UInt8] {
    let data = image.dataProvider!.data!
    let pointer = CFDataGetBytePtr(data)! + y * image.bytesPerRow + x * 4
    return Array(UnsafeBufferPointer(start: pointer, count: 4))
  }

  private func assertAxisCoverage(
    origins: [Int],
    length: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(origins.isEmpty, file: file, line: line)
    XCTAssertEqual(origins.first, 0, file: file, line: line)
    for (index, origin) in origins.enumerated() {
      let end = min(origin + LocalOCRTiler.maximumTileDimension, length)
      XCTAssertGreaterThan(end, origin, file: file, line: line)
      XCTAssertLessThanOrEqual(origin, length, file: file, line: line)
      if let next = origins.dropFirst(index + 1).first {
        let overlap = max(0, end - next)
        XCTAssertEqual(
          overlap,
          LocalOCRTiler.overlapPixels,
          "Adjacent full tiles must use the configured edge overlap",
          file: file,
          line: line
        )
        XCTAssertGreaterThanOrEqual(end, next, "Adjacent tiles must not leave a gap", file: file, line: line)
        XCTAssertEqual(next, origin + LocalOCRTiler.maximumTileDimension - LocalOCRTiler.overlapPixels, file: file, line: line)
        XCTAssertGreaterThan(
          min(next + LocalOCRTiler.maximumTileDimension, length),
          end,
          "A later tile must extend coverage instead of being fully redundant",
          file: file,
          line: line
        )
      }
    }
    if length > LocalOCRTiler.maximumTileDimension {
      let finalWidth = length - origins.last!
      XCTAssertLessThanOrEqual(finalWidth, LocalOCRTiler.maximumTileDimension, file: file, line: line)
    }
    XCTAssertGreaterThanOrEqual(
      origins.last! + LocalOCRTiler.maximumTileDimension,
      length,
      file: file,
      line: line
    )
  }
}
