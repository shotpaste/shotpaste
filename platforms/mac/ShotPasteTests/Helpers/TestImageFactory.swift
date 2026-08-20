//
//  TestImageFactory.swift
//  ShotPasteTests
//
//  Synthetic CGImage generator for unit tests.
//

import CoreGraphics
import Foundation

enum TestImageFactory {
  /// Create a solid-color CGImage of the given size.
  static func solidColor(
    width: Int,
    height: Int,
    red: UInt8 = 128,
    green: UInt8 = 128,
    blue: UInt8 = 128,
    alpha: UInt8 = 255
  ) -> CGImage? {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0 ..< height {
      for x in 0 ..< width {
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = red
        pixels[offset + 1] = green
        pixels[offset + 2] = blue
        pixels[offset + 3] = alpha
      }
    }

    return makeCGImage(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
  }

  /// Create a vertical gradient image.
  /// Top row starts at `topGray`, bottom row ends at `bottomGray`.
  static func verticalGradient(
    width: Int,
    height: Int,
    topGray: UInt8 = 0,
    bottomGray: UInt8 = 255
  ) -> CGImage? {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0 ..< height {
      let t = height > 1 ? Double(y) / Double(height - 1) : 0
      let gray = UInt8(Double(topGray) * (1 - t) + Double(bottomGray) * t)

      for x in 0 ..< width {
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = gray
        pixels[offset + 1] = gray
        pixels[offset + 2] = gray
        pixels[offset + 3] = 255
      }
    }

    return makeCGImage(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
  }

  /// Create a hard vertical luminance edge for resampling assertions.
  static func verticalEdge(
    width: Int,
    height: Int,
    edgeX: Int? = nil,
    leftGray: UInt8 = 0,
    rightGray: UInt8 = 255
  ) -> CGImage? {
    let splitX = min(max(edgeX ?? width / 2, 0), width)
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0 ..< height {
      for x in 0 ..< width {
        let gray = x < splitX ? leftGray : rightGray
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = gray
        pixels[offset + 1] = gray
        pixels[offset + 2] = gray
        pixels[offset + 3] = 255
      }
    }

    return makeCGImage(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
  }

  /// Create a frame for scrolling-capture tests where each row has a
  /// deterministic color signature based on its logical content position.
  /// Two frames with overlapping logical ranges produce pixel-perfect overlap,
  /// yielding deterministic `appended` outcomes with an exact `deltaY`.
  static func scrollingFrame(
    width: Int,
    height: Int,
    logicalYOffset: Int = 0
  ) -> CGImage? {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0 ..< height {
      let logicalY = logicalYOffset + y
      for x in 0 ..< width {
        // Vary both axes so repeated row colors cannot create a false NCC peak.
        let value = UInt64(logicalY) &* 1_103_515_245
          &+ UInt64(x) &* 2_654_435_761
          &+ 0x9E37_79B9_7F4A_7C15
        let mixed = value ^ (value >> 29) ^ (value >> 47)
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = UInt8(truncatingIfNeeded: mixed)
        pixels[offset + 1] = UInt8(truncatingIfNeeded: mixed >> 11)
        pixels[offset + 2] = UInt8(truncatingIfNeeded: mixed >> 23)
        pixels[offset + 3] = 255
      }
    }

    return makeCGImage(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
  }

  // MARK: - Private

  private static func makeCGImage(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    pixels: [UInt8]
  ) -> CGImage? {
    let data = Data(pixels) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }

    let bitmapInfo = CGBitmapInfo(rawValue:
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
