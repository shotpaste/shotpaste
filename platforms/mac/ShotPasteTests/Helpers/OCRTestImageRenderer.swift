//
//  OCRTestImageRenderer.swift
//  ShotPasteTests
//
//  Synthetic OCR fixture rendering helpers.
//

import AppKit
@testable import ShotPaste

enum OCRTestImageRenderer {
  static func renderImage(text: String) throws -> CGImage {
    try renderImage(textChunks: [text], horizontalGap: 0)
  }

  static func renderImage(textChunks: [String], horizontalGap: CGFloat) throws -> CGImage {
    let font = NSFont.systemFont(ofSize: 48, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.black,
    ]
    let textSizes = textChunks.map {
      ($0 as NSString).size(withAttributes: attributes)
    }
    let textWidth = textSizes.map(\.width).reduce(0, +)
      + horizontalGap * CGFloat(max(textChunks.count - 1, 0))
    let textHeight = textSizes.map(\.height).max() ?? 0
    let padding: CGFloat = 40
    let imageSize = NSSize(
      width: ceil(textWidth + padding * 2),
      height: ceil(textHeight + padding * 2)
    )
    let image = NSImage(size: imageSize)

    image.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()
    var x = padding
    for (index, text) in textChunks.enumerated() {
      (text as NSString).draw(
        at: NSPoint(x: x, y: padding),
        withAttributes: attributes
      )
      x += textSizes[index].width + horizontalGap
    }
    image.unlockFocus()

    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw OCRError.imageConversionFailed
    }
    return cgImage
  }

  static func renderVerticalCJKImage(text: String) throws -> CGImage {
    let font = NSFont.systemFont(ofSize: 58, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor(calibratedRed: 0.76, green: 0.22, blue: 0.14, alpha: 1),
    ]
    let characters = text.map(String.init)
    let glyphSizes = characters.map {
      ($0 as NSString).size(withAttributes: attributes)
    }
    let maxGlyphWidth = glyphSizes.map(\.width).max() ?? 0
    let maxGlyphHeight = glyphSizes.map(\.height).max() ?? 0
    let horizontalPadding: CGFloat = 14
    let verticalPadding: CGFloat = 10
    let lineGap: CGFloat = 10
    let imageSize = NSSize(
      width: ceil(maxGlyphWidth + horizontalPadding * 2),
      height: ceil(
        (maxGlyphHeight * CGFloat(characters.count))
          + (lineGap * CGFloat(max(characters.count - 1, 0)))
          + verticalPadding * 2
      )
    )
    let image = NSImage(size: imageSize)

    image.lockFocus()
    NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.84, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()

    var y = imageSize.height - verticalPadding - maxGlyphHeight
    for (index, character) in characters.enumerated() {
      let glyphSize = glyphSizes[index]
      let x = (imageSize.width - glyphSize.width) / 2
      (character as NSString).draw(
        at: NSPoint(x: x, y: y),
        withAttributes: attributes
      )
      y -= maxGlyphHeight + lineGap
    }
    image.unlockFocus()

    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      throw OCRError.imageConversionFailed
    }
    return cgImage
  }
}
