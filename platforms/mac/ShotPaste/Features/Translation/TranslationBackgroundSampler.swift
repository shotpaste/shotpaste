//
//  TranslationBackgroundSampler.swift
//  ShotPaste
//
//  Local luminance sampling from the frozen CGImage. The sampled pixels never
//  leave this process and are reduced to one boolean per OCR block.
//

import CoreGraphics
import Foundation

nonisolated enum TranslationBackgroundSampler {
  static func luminanceByID(
    blocks: [TranslationTextBlock],
    image: CGImage,
    deadline: Date
  ) throws -> [String: CGFloat] {
    var values: [String: CGFloat] = [:]
    values.reserveCapacity(blocks.count)
    for block in blocks {
      try TranslationOCRDeadline.check(deadline)
      values[block.id] = luminance(around: block.pixelBounds, in: image)
    }
    return values
  }

  private static func luminance(around bounds: CGRect, in image: CGImage) -> CGFloat {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let sampleRect = bounds.insetBy(
      dx: -max(2, bounds.width * 0.08),
      dy: -max(2, bounds.height * 0.08)
    ).intersection(imageBounds)
    guard !sampleRect.isEmpty,
          let crop = image.cropping(to: sampleRect.integral),
          let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              | CGBitmapInfo.byteOrder32Big.rawValue
          )
    else { return 0 }
    context.interpolationQuality = .medium
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
    let red = Double(pixels[0])
    let green = Double(pixels[1])
    let blue = Double(pixels[2])
    let value = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
    return CGFloat(value)
  }
}
