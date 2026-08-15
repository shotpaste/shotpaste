//
//  AnnotateExporter.swift
//  ShotPaste
//
//  Export functionality for annotated images
//

import AppKit
import ImageIO

/// Handles exporting annotated images
@MainActor
final class AnnotateExporter {
  /// Determine the pixel-to-point scale factor from the source image.
  /// Falls back to 1.0 when bitmap metadata is unavailable.
  private nonisolated static func sourceImageScale(_ sourceImage: NSImage) -> CGFloat {
    let pointWidth = sourceImage.size.width
    let pointHeight = sourceImage.size.height
    guard pointWidth > 0, pointHeight > 0 else { return 1.0 }

    if let rep = bestBitmapRepresentation(in: sourceImage) {
      let pixelWidth = CGFloat(rep.pixelsWide)
      let pixelHeight = CGFloat(rep.pixelsHigh)
      if pixelWidth > 0, pixelHeight > 0 {
        let widthScale = pixelWidth / pointWidth
        let heightScale = pixelHeight / pointHeight
        return max(widthScale, heightScale, 1.0)
      }
    }

    if let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      let widthScale = CGFloat(cgImage.width) / pointWidth
      let heightScale = CGFloat(cgImage.height) / pointHeight
      return max(widthScale, heightScale, 1.0)
    }

    return 1.0
  }

  private nonisolated static func bestBitmapRepresentation(in image: NSImage) -> NSBitmapImageRep? {
    image.representations
      .compactMap { $0 as? NSBitmapImageRep }
      .max { lhs, rhs in
        lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
      }
  }

  nonisolated static func bestCGImage(from image: NSImage) -> CGImage? {
    if let cgImage = bestBitmapRepresentation(in: image)?.cgImage {
      return cgImage
    }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  /// Convert NSImage to Data for any supported format (PNG, JPEG, WebP)
  /// Uses CGImageDestination for WebP support (macOS 14+)
  nonisolated static func imageData(from image: NSImage, for fileExtension: String) -> Data? {
    guard let cgImage = bestCGImage(from: image) else {
      return nil
    }

    let scale = sourceImageScale(image)
    let ext = fileExtension.lowercased()

    // WebP: use WebPEncoder (cwebp CLI) since ImageIO doesn't support WebP encoding
    if ext == "webp" {
      return WebPEncoderService.encode(cgImage)
    }

    // PNG/JPEG: use CGImageDestination
    let utType: CFString = switch ext {
    case "jpg", "jpeg":
      "public.jpeg" as CFString
    default:
      "public.png" as CFString
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, utType, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, cgImage, imageDestinationProperties(for: ext, scaleFactor: scale))
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return data as Data
  }

  private nonisolated static func imageDestinationProperties(
    for fileExtension: String,
    scaleFactor: CGFloat
  ) -> CFDictionary? {
    let resolvedScale = max(Double(scaleFactor), 1.0)
    let dpi = resolvedScale * 72.0
    var properties: [CFString: Any] = [
      kCGImagePropertyDPIWidth: dpi,
      kCGImagePropertyDPIHeight: dpi,
    ]

    switch fileExtension {
    case "png":
      let pixelsPerMeter = Int((dpi / 0.0254).rounded())
      properties[kCGImagePropertyPNGDictionary] = [
        kCGImagePropertyPNGXPixelsPerMeter: pixelsPerMeter,
        kCGImagePropertyPNGYPixelsPerMeter: pixelsPerMeter,
      ] as CFDictionary
    case "jpg", "jpeg":
      properties[kCGImageDestinationLossyCompressionQuality] = 0.9
    default:
      break
    }

    return properties as CFDictionary
  }

  /// Main-actor render entry point (Save As / Copy / Share). Freezes state into a
  /// snapshot first so every render path shares one implementation.
  static func renderFinalImage(state: AnnotateState) -> NSImage? {
    guard let snapshot = state.makeRenderSnapshot() else { return nil }
    return renderFlatFinalImage(snapshot: snapshot)
  }

  /// Off-main render entry point for the save-and-close background path.
  nonisolated static func renderFinalImage(snapshot: AnnotateRenderSnapshot) async -> NSImage? {
    renderFlatFinalImage(snapshot: snapshot)
  }

  /// Pure CoreGraphics/AppKit drawing into a
  /// private bitmap context — safe on any queue, reads only the frozen snapshot.
  nonisolated static func renderFlatFinalImage(snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let startedAt = CFAbsoluteTimeGetCurrent()
    let sourceImage = snapshot.sourceImage
    let totalSize = sourceImage.size
    let outputSizeDescription = "\(Int(totalSize.width))x\(Int(totalSize.height))"

    defer {
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
      DiagnosticLogger.shared.log(.debug, .annotate, "Render final image completed", context: [
        "annotations": "\(snapshot.annotations.count)",
        "outputSize": outputSizeDescription,
        "durationMs": "\(durationMs)",
      ])
    }

    DiagnosticLogger.shared.log(.debug, .annotate, "Rendering final image", context: [
      "annotations": "\(snapshot.annotations.count)",
    ])

    let imageBounds = CGRect(origin: .zero, size: totalSize)
    let scale = sourceImageScale(sourceImage)
    let pixelWidth = max(1, Int(ceil(totalSize.width * scale)))
    let pixelHeight = max(1, Int(ceil(totalSize.height * scale)))

    guard let bitmapRep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth,
      pixelsHigh: pixelHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    bitmapRep.size = totalSize

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext
    drawSourceImage(
      sourceImage,
      effectiveBounds: imageBounds,
      destinationOrigin: .zero,
      in: context
    )

    let spotlightRegions: [SpotlightRegion] = snapshot.annotations.compactMap { annotation in
      guard case .spotlight = annotation.type else { return nil }
      return SpotlightRegion(
        rect: annotation.bounds,
        cornerRadius: annotation.properties.cornerRadius
      )
    }
    SpotlightCompositor.drawOverlay(
      regions: spotlightRegions,
      previewRegion: nil,
      canvasRect: imageBounds,
      in: context
    )

    let renderer = AnnotationRenderer(context: context, sourceImage: sourceImage)
    for annotation in snapshot.annotations.renderOrdered {
      if case .spotlight = annotation.type {
        continue
      }
      renderer.draw(annotation)
    }

    let image = NSImage(size: totalSize)
    image.addRepresentation(bitmapRep)
    return image
  }

  /// Draw the source-image portion that intersects the requested canvas bounds.
  private nonisolated static func drawSourceImage(
    _ sourceImage: NSImage,
    effectiveBounds: CGRect,
    destinationOrigin: CGPoint,
    in context: CGContext
  ) {
    let sourceImageBounds = CGRect(origin: .zero, size: sourceImage.size)
    let visibleSourceBounds = effectiveBounds.intersection(sourceImageBounds)
    guard !visibleSourceBounds.isNull, !visibleSourceBounds.isEmpty else { return }

    let destinationRect = NSRect(
      x: destinationOrigin.x + visibleSourceBounds.minX - effectiveBounds.minX,
      y: destinationOrigin.y + visibleSourceBounds.minY - effectiveBounds.minY,
      width: visibleSourceBounds.width,
      height: visibleSourceBounds.height
    )
    guard
      let sourceCGImage = bestCGImage(from: sourceImage),
      let sourcePixelRect = sourcePixelCropRect(
        for: visibleSourceBounds,
        imageSize: sourceImage.size,
        pixelSize: CGSize(width: sourceCGImage.width, height: sourceCGImage.height)
      ),
      let croppedImage = sourceCGImage.cropping(to: sourcePixelRect)
    else {
      let sourceRect = NSRect(
        x: visibleSourceBounds.minX,
        y: visibleSourceBounds.minY,
        width: visibleSourceBounds.width,
        height: visibleSourceBounds.height
      )
      sourceImage.draw(in: destinationRect, from: sourceRect, operation: .sourceOver, fraction: 1.0)
      return
    }

    let sourceScale = sourceImageScale(sourceImage)
    let destinationPixelSize = CGSize(
      width: destinationRect.width * sourceScale,
      height: destinationRect.height * sourceScale
    )
    let drawsOneToOne = abs(destinationPixelSize.width - CGFloat(croppedImage.width)) < 0.5
      && abs(destinationPixelSize.height - CGFloat(croppedImage.height)) < 0.5

    context.saveGState()
    context.interpolationQuality = drawsOneToOne ? .none : .high
    context.draw(croppedImage, in: destinationRect)
    context.restoreGState()
  }

  private nonisolated static func sourcePixelCropRect(
    for bounds: CGRect,
    imageSize: CGSize,
    pixelSize: CGSize
  ) -> CGRect? {
    guard imageSize.width > 0, imageSize.height > 0, pixelSize.width > 0, pixelSize.height > 0 else {
      return nil
    }

    let scaleX = pixelSize.width / imageSize.width
    let scaleY = pixelSize.height / imageSize.height
    let minX = floor(bounds.minX * scaleX)
    let maxX = ceil(bounds.maxX * scaleX)
    let minY = floor((imageSize.height - bounds.maxY) * scaleY)
    let maxY = ceil((imageSize.height - bounds.minY) * scaleY)
    let imagePixelBounds = CGRect(origin: .zero, size: pixelSize)
    let cropRect = CGRect(
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY
    )
    .intersection(imagePixelBounds)
    .integral

    guard !cropRect.isNull, !cropRect.isEmpty else { return nil }
    return cropRect
  }
}
