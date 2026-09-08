import AppKit
import CoreGraphics
@testable import ShotPaste
import XCTest

final class AnnotateBlurEffectRendererTests: XCTestCase {
  private func patternedContext() throws -> CGContext {
    let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64,
      bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for y in 0..<32 {
      for x in 0..<32 {
        context.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: x * 2, y: y * 2, width: 2, height: 2))
      }
    }
    return context
  }

  private func pixels(_ context: CGContext) throws -> Data {
    Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
  }

  func testEffectsChangeContentWithinTheirDrawingBounds() throws {
    let renderers: [(String, (CGContext, NSImage, CGRect) -> Void)] = [
      ("pixelated", { BlurEffectRenderer.drawPixelatedRegion(in: $0, sourceImage: $1, region: $2, pixelSize: 8) }),
      ("gaussian", { BlurEffectRenderer.drawGaussianRegion(in: $0, sourceImage: $1, region: $2, radius: 10) }),
      ("hexagonal", { BlurEffectRenderer.drawHexagonalRegion(in: $0, sourceImage: $1, region: $2, scale: 8) }),
      ("crystallized", { BlurEffectRenderer.drawCrystallizedRegion(in: $0, sourceImage: $1, region: $2, radius: 8) }),
      ("pointillism", { BlurEffectRenderer.drawPointillismRegion(in: $0, sourceImage: $1, region: $2, radius: 8) }),
      ("halftone", { BlurEffectRenderer.drawHalftoneRegion(in: $0, sourceImage: $1, region: $2, width: 8) }),
      ("tape", { BlurEffectRenderer.drawTapeRegion(in: $0, sourceImage: $1, region: $2, patternSpacing: 10) }),
      ("washi", { BlurEffectRenderer.drawWashiRegion(in: $0, sourceImage: $1, region: $2, patternSpacing: 10) })
    ]
    for (name, render) in renderers {
      let context = try patternedContext()
      let source = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 64, height: 64))
      let before = try pixels(context)
      render(context, source, CGRect(x: 16, y: 16, width: 32, height: 32))
      let after = try pixels(context)
      var changedInside = false
      var changedOutside = 0
      // Decorative tape has a torn edge and a 2-point offset shadow; blur filters do not.
      let margin = ["crystallized", "pointillism", "halftone", "tape", "washi"].contains(name) ? 8 : 0
      for y in 0..<64 {
        for x in 0..<64 {
          let offset = y * 256 + x * 4
          let changed = before[offset..<offset + 4] != after[offset..<offset + 4]
          if (16..<48).contains(x), (16..<48).contains(y) { changedInside = changedInside || changed }
          else if !(16 - margin..<48 + margin).contains(x) || !(16 - margin..<48 + margin).contains(y) {
            if changed { changedOutside += 1 }
          }
        }
      }
      XCTAssertEqual(changedOutside, 0, "\(name) changed unrelated surrounding content")
      XCTAssertTrue(changedInside, "\(name) must change the selected content, not merely avoid crashing")
    }
  }

  func testEmptyRegionPreservesImage() throws {
    let context = try patternedContext()
    let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 64, height: 64))
    let before = try pixels(context)
    BlurEffectRenderer.drawPixelatedRegion(in: context, sourceImage: image, region: .zero)
    XCTAssertEqual(try pixels(context), before)
  }
}
