#!/usr/bin/env swift

import AppKit
import CoreText
import Foundation
import ImageIO

// Invoked by generate-app-icon-assets.sh. Keep macOS packaging separate from
// the shared Windows/README artwork and preserve Debug's visible identity.
let fileManager = FileManager.default
let repositoryURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let sourceURL = repositoryURL.appendingPathComponent("assets/shotpaste-macos-icon.png")
let assetsURL = repositoryURL.appendingPathComponent("platforms/mac/ShotPaste/Resources/Assets.xcassets")
let masterSize = 1024
let artworkRect = CGRect(x: 96, y: 96, width: 832, height: 832)
let iconSpecs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

enum IconGenerationError: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self {
    case .invalid(let message): message
    }
  }
}

func bitmapContext(size: Int) throws -> CGContext {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: nil,
          width: size,
          height: size,
          bitsPerComponent: 8,
          bytesPerRow: size * 4,
          space: colorSpace,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
  else {
    throw IconGenerationError.invalid("Cannot allocate a \(size)px RGBA icon.")
  }
  context.clear(CGRect(x: 0, y: 0, width: size, height: size))
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  return context
}

func masterImage(source: CGImage, debug: Bool) throws -> CGImage {
  let context = try bitmapContext(size: masterSize)
  context.saveGState()
  context.addPath(CGPath(roundedRect: artworkRect, cornerWidth: 185, cornerHeight: 185, transform: nil))
  context.clip()
  context.draw(source, in: artworkRect)
  context.restoreGState()

  if debug {
    // The badge stays inside the standard artwork bounds; the white ring keeps
    // it distinct against both the light tile and the blue brand mark.
    let badgeRect = CGRect(x: 646, y: 120, width: 256, height: 256)
    context.setFillColor(CGColor(srgbRed: 0.12, green: 0.30, blue: 0.73, alpha: 1))
    context.fillEllipse(in: badgeRect)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(10)
    context.strokeEllipse(in: badgeRect.insetBy(dx: 5, dy: 5))

    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 170, nil)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
        srgbRed: 1,
        green: 1,
        blue: 1,
        alpha: 1
      ),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "D", attributes: attributes))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: badgeRect.midX - width / 2, y: badgeRect.midY - CTFontGetCapHeight(font) / 2)
    CTLineDraw(line, context)
  }

  guard let image = context.makeImage() else {
    throw IconGenerationError.invalid("Cannot render the \(debug ? "Debug" : "Release") icon.")
  }
  return image
}

func pngData(master: CGImage, size: Int) throws -> Data {
  let context = try bitmapContext(size: size)
  context.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
  guard let image = context.makeImage() else {
    throw IconGenerationError.invalid("Cannot resize the icon to \(size)px.")
  }
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
    throw IconGenerationError.invalid("Cannot create the PNG encoder.")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw IconGenerationError.invalid("Cannot encode the \(size)px icon.")
  }
  return data as Data
}

func validatePNG(_ data: Data, size: Int, name: String) throws {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        image.width == size, image.height == size,
        image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast
  else {
    throw IconGenerationError.invalid("Invalid size or missing alpha channel: \(name)")
  }
  let context = try bitmapContext(size: size)
  context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
  guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
    throw IconGenerationError.invalid("Cannot inspect icon pixels: \(name)")
  }
  for (x, y) in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)] {
    guard pixels[(y * size + x) * 4 + 3] == 0 else {
      throw IconGenerationError.invalid("Opaque outer corner at (\(x), \(y)): \(name)")
    }
  }
  guard pixels[((size / 2) * size + size / 2) * 4 + 3] > 0 else {
    throw IconGenerationError.invalid("Empty icon center: \(name)")
  }
}

do {
  guard CommandLine.arguments.count == 1 else {
    throw IconGenerationError
      .invalid("Use scripts/generate-app-icon-assets.sh without arguments for the macOS brand icons.")
  }
  guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        image.width == image.height, image.width >= masterSize
  else {
    throw IconGenerationError.invalid("Expected a square PNG of at least 1024px: \(sourceURL.path)")
  }

  // Render and validate both variants before replacing any checked-in asset.
  var generated: [(url: URL, data: Data, pixels: Int?)] = []
  for debug in [false, true] {
    let directory = assetsURL.appendingPathComponent(debug ? "AppIconDebug.appiconset" : "AppIcon.appiconset")
    let prefix = debug ? "ShotPasteDebugIcon" : "ShotPasteIcon"
    let master = try masterImage(source: image, debug: debug)
    var entries: [[String: String]] = []
    for (points, scale) in iconSpecs {
      let size = points * scale
      let filename = "\(prefix)-macOS-\(points)x\(points)@\(scale)x.png"
      let data = try pngData(master: master, size: size)
      try validatePNG(data, size: size, name: filename)
      generated.append((directory.appendingPathComponent(filename), data, size))
      entries.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
    let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
    var data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    generated.append((directory.appendingPathComponent("Contents.json"), data, nil))
  }
  for asset in generated {
    try fileManager.createDirectory(at: asset.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try asset.data.write(to: asset.url, options: .atomic)
    if let size = asset.pixels {
      try validatePNG(Data(contentsOf: asset.url), size: size, name: asset.url.lastPathComponent)
    }
  }
  print("Generated and verified 20 macOS AppIcon PNGs (16–1024px, RGBA, transparent outer corners).")
  print("Source: \(sourceURL.path)")
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
