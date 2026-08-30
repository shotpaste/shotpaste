//
//  TranslationResultRenderer.swift
//  ShotPaste
//
//  Renders a user-requested clipboard copy of the frozen source image with its
//  transient translation overlays. This renderer never writes files itself.
//

import AppKit
import Foundation

@MainActor
enum TranslationResultRenderer {
  static func render(input: TranslationInput, blocks: [TranslationRenderBlock]) -> NSImage? {
    guard input.screenRect.width > 0, input.screenRect.height > 0 else { return nil }
    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: input.image.width,
      pixelsHigh: input.image.height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    bitmapRep.size = input.screenRect.size
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }

    let output = NSImage(size: input.screenRect.size)
    output.addRepresentation(bitmapRep)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphicsContext

    let source = NSImage(cgImage: input.image, size: input.screenRect.size)
    source.draw(
      in: CGRect(origin: .zero, size: input.screenRect.size),
      from: .zero,
      operation: .copy,
      fraction: 1
    )

    for block in blocks {
      draw(block: block, in: input, outputSize: input.screenRect.size)
    }
    return output
  }

  private static func draw(
    block: TranslationRenderBlock,
    in input: TranslationInput,
    outputSize: CGSize
  ) {
    let outputBounds = CGRect(origin: .zero, size: outputSize)
    guard let rect = clippedDrawingRect(for: block, input: input) else { return }
    guard rect.width > 0, rect.height > 0,
          let context = NSGraphicsContext.current?.cgContext
    else { return }

    context.saveGState()
    defer { context.restoreGState() }
    // The output image is exactly the frozen selection. Clip before applying
    // the small background overlap and any vertical rotation so no overlay
    // pixel can escape the selected range.
    context.clip(to: outputBounds)
    let rotationDegrees = effectiveRotationDegrees(for: block)
    if rotationDegrees != 0 {
      context.translateBy(x: rect.midX, y: rect.midY)
      context.rotate(by: CGFloat(rotationDegrees * .pi / 180))
      context.translateBy(x: -rect.midX, y: -rect.midY)
    }

    let cornerRadius = min(8, max(3, rect.height * 0.16))
    let background = block.usesLightBackground
      ? NSColor.white.withAlphaComponent(0.88) : NSColor.black.withAlphaComponent(0.84)
    background.setFill()
    NSBezierPath(
      roundedRect: rect.insetBy(dx: -2, dy: -2),
      xRadius: cornerRadius,
      yRadius: cornerRadius
    ).fill()

    if let textRect = textDrawingRect(for: rect) {
      attributedText(for: block, in: textRect).draw(in: textRect)
    }
  }

  /// Exposed as a small deterministic seam for renderer tests and for future
  /// copy-preview consumers. Geometry is always clipped to the frozen input.
  static func clippedDrawingRect(
    for block: TranslationRenderBlock,
    input: TranslationInput
  ) -> CGRect? {
    let outputBounds = CGRect(origin: .zero, size: input.screenRect.size)
    let localRect = block.screenBounds.offsetBy(
      dx: -input.screenRect.minX,
      dy: -input.screenRect.minY
    )
    let clipped = localRect.intersection(outputBounds)
    return clipped.width > 0 && clipped.height > 0 ? clipped : nil
  }

  static func effectiveRotationDegrees(for block: TranslationRenderBlock) -> Double {
    if block.direction == .vertical, block.rotationDegrees == 0 {
      return 90
    }
    return block.rotationDegrees
  }

  static func attributedText(
    for block: TranslationRenderBlock,
    in rect: CGRect
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = textAlignment(for: block.alignment)
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: block.fontSize, weight: .semibold),
      .foregroundColor: block.usesLightBackground ? NSColor.black : NSColor.white,
      .paragraphStyle: paragraph,
    ]
    return NSAttributedString(string: block.translatedText, attributes: attributes)
  }

  /// Returns a positive-size text rect without allowing the normal inset to
  /// turn a tiny OCR block into a negative AppKit drawing rect. Background
  /// painting remains based on the unclipped block rect, so this guard only
  /// affects text drawing for blocks smaller than the usual 8x6 inset budget.
  static func textDrawingRect(for rect: CGRect) -> CGRect? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    let horizontalInset = min(4, max(0, (rect.width - 1) / 2))
    let verticalInset = min(3, max(0, (rect.height - 1) / 2))
    let textRect = rect.insetBy(dx: horizontalInset, dy: verticalInset)
    guard textRect.width > 0, textRect.height > 0 else { return nil }
    return textRect
  }

  private static func textAlignment(for alignment: TranslationTextAlignment) -> NSTextAlignment {
    switch alignment {
    case .leading: .left
    case .center: .center
    case .trailing: .right
    }
  }
}
