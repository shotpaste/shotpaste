//
//  AnnotateExporter.swift
//  ShotPaste
//
//  Export functionality for annotated images
//

import AppKit
import ImageIO
import SwiftUI

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

  static func renderCanvasEffects(
    sourceImage: NSImage,
    effects: AnnotationCanvasEffects
  ) -> NSImage? {
    let startedAt = CFAbsoluteTimeGetCurrent()
    var outputSizeDescription = "nil"
    defer {
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
      DiagnosticLogger.shared.log(.debug, .annotate, "Render canvas effects completed", context: [
        "background": "\(effects.backgroundStyle)",
        "outputSize": outputSizeDescription,
        "durationMs": "\(durationMs)",
      ])
    }

    let effectiveBounds = CGRect(origin: .zero, size: sourceImage.size)
    let padding = effects.backgroundStyle != .none ? effects.padding : 0
    let alignmentSpace: CGFloat = effects.imageAlignment != .center ? 40 : 0

    let totalSize: NSSize = effects.aspectRatio.canvasSize(
      for: effectiveBounds.size,
      padding: padding,
      alignmentSpace: alignmentSpace,
      orientation: effects.aspectRatioOrientation
    )
    outputSizeDescription = "\(Int(totalSize.width))x\(Int(totalSize.height))"

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
    drawBackground(effects: effects, in: context, size: totalSize)

    let destinationOrigin = destinationOrigin(
      imageSize: effectiveBounds.size,
      totalSize: totalSize,
      alignment: effects.imageAlignment
    )

    if effects.cornerRadius > 0 {
      let clipRect = NSRect(
        x: destinationOrigin.x,
        y: destinationOrigin.y,
        width: effectiveBounds.width,
        height: effectiveBounds.height
      )
      let path = NSBezierPath(roundedRect: clipRect, xRadius: effects.cornerRadius, yRadius: effects.cornerRadius)
      path.addClip()
    }

    drawSourceImage(
      sourceImage,
      effectiveBounds: effectiveBounds,
      destinationOrigin: destinationOrigin,
      in: context
    )
    context.resetClip()

    let image = NSImage(size: totalSize)
    image.addRepresentation(bitmapRep)
    return image
  }

  /// Main-actor render entry point (Save As / Copy / Share). Freezes state into a
  /// snapshot first so every render path shares one implementation.
  static func renderFinalImage(state: AnnotateState) -> NSImage? {
    guard let snapshot = state.makeRenderSnapshot() else { return nil }
    if snapshot.editorMode == .mockup {
      DiagnosticLogger.shared.log(.debug, .annotate, "Rendering mockup image")
      guard let flatImage = renderMockupFlatImage(snapshot: snapshot) else { return nil }
      return compositeMockupImage(flatImage: flatImage, snapshot: snapshot)
    }
    return renderFlatFinalImage(snapshot: snapshot)
  }

  /// Off-main render entry point for the save-and-close background path.
  /// Mockup mode renders the flat image off-main, then composites 3D transforms on main
  /// (SwiftUI `ImageRenderer` is a main-only API).
  nonisolated static func renderFinalImage(snapshot: AnnotateRenderSnapshot) async -> NSImage? {
    if snapshot.editorMode == .mockup {
      DiagnosticLogger.shared.log(.debug, .annotate, "Rendering mockup image")
      guard let flatImage = renderMockupFlatImage(snapshot: snapshot) else { return nil }
      return await compositeMockupImage(flatImage: flatImage, snapshot: snapshot)
    }
    return renderFlatFinalImage(snapshot: snapshot)
  }

  /// Flat render pipeline (no mockup transforms). Pure CoreGraphics/AppKit drawing into a
  /// private bitmap context — safe on any queue, reads only the frozen snapshot.
  nonisolated static func renderFlatFinalImage(snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let startedAt = CFAbsoluteTimeGetCurrent()
    let embeddedLayerCount = snapshot.annotations.reduce(into: 0) { count, annotation in
      if case .embeddedImage = annotation.type {
        count += 1
      }
    }
    var outputSizeDescription = "nil"
    defer {
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000)
      DiagnosticLogger.shared.log(.debug, .annotate, "Render final image completed", context: [
        "mode": snapshot.editorMode.rawValue,
        "annotations": "\(snapshot.annotations.count)",
        "embeddedLayers": "\(embeddedLayerCount)",
        "outputSize": outputSizeDescription,
        "durationMs": "\(durationMs)",
      ])
    }

    let sourceImage = snapshot.sourceImage

    DiagnosticLogger.shared.log(.debug, .annotate, "Rendering final image", context: [
      "annotations": "\(snapshot.annotations.count)",
      "hasCrop": "\(snapshot.cropRect != nil)",
      "background": "\(snapshot.backgroundStyle)",
    ])

    // Determine effective bounds (crop or full image)
    let effectiveBounds: CGRect = if snapshot.isCombineMode {
      snapshot.effectiveContentBounds
    } else if let cropRect = snapshot.cropRect {
      cropRect
    } else {
      CGRect(origin: .zero, size: sourceImage.size)
    }

    let padding = snapshot.isCombineMode ? snapshot.padding : (snapshot.backgroundStyle != .none ? snapshot.padding : 0)

    // Add alignment space for non-center alignments (matches preview)
    let alignmentSpace: CGFloat = snapshot.imageAlignment != .center ? 40 : 0

    let totalSize: NSSize = snapshot.isCombineMode
      ? NSSize(width: effectiveBounds.width + padding * 2, height: effectiveBounds.height + padding * 2)
      : snapshot.aspectRatio.canvasSize(
        for: effectiveBounds.size,
        padding: padding,
        alignmentSpace: alignmentSpace,
        orientation: snapshot.aspectRatioOrientation
      )
    outputSizeDescription = "\(Int(totalSize.width))x\(Int(totalSize.height))"

    // Render at pixel resolution using NSBitmapImageRep for Retina quality
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
    bitmapRep.size = totalSize // Point size — CG context will scale drawings to pixel dimensions

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext

    // Draw background
    drawBackground(snapshot: snapshot, in: context, size: totalSize)

    // Calculate image position based on alignment
    let imageWidth = effectiveBounds.width
    let imageHeight = effectiveBounds.height
    let totalExtraWidth = totalSize.width - imageWidth
    let totalExtraHeight = totalSize.height - imageHeight

    // Calculate destRect origin based on alignment
    // Note: CoreGraphics Y=0 is at bottom, so top alignment needs higher Y value
    let destX: CGFloat
    let destY: CGFloat

    switch snapshot.isCombineMode ? ImageAlignment.center : snapshot.imageAlignment {
    case .center:
      destX = totalExtraWidth / 2
      destY = totalExtraHeight / 2
    case .topLeft:
      destX = 0
      destY = totalExtraHeight // Top in CG = max Y
    case .top:
      destX = totalExtraWidth / 2
      destY = totalExtraHeight
    case .topRight:
      destX = totalExtraWidth
      destY = totalExtraHeight
    case .left:
      destX = 0
      destY = totalExtraHeight / 2
    case .right:
      destX = totalExtraWidth
      destY = totalExtraHeight / 2
    case .bottomLeft:
      destX = 0
      destY = 0 // Bottom in CG = Y=0
    case .bottom:
      destX = totalExtraWidth / 2
      destY = 0
    case .bottomRight:
      destX = totalExtraWidth
      destY = 0
    }

    if snapshot.cornerRadius > 0 {
      let clipRect = NSRect(
        x: destX,
        y: destY,
        width: effectiveBounds.width,
        height: effectiveBounds.height
      )
      let path = NSBezierPath(roundedRect: clipRect, xRadius: snapshot.cornerRadius, yRadius: snapshot.cornerRadius)
      path.addClip()
    }

    drawSourceImage(
      sourceImage,
      effectiveBounds: effectiveBounds,
      destinationOrigin: CGPoint(x: destX, y: destY),
      in: context
    )

    if !snapshot.isCombineMode {
      context.resetClip()
    }

    // Unified Spotlight overlay pass (drawn below other annotations, above base image).
    // Opacity sourced from per-item properties so exported image matches the on-screen appearance.
    let spotlightRegions: [SpotlightRegion] = snapshot.annotations.compactMap { a in
      guard case .spotlight = a.type else { return nil }
      let offset = offsetAnnotationForExport(
        a,
        cropOrigin: effectiveBounds.origin,
        imageX: destX,
        imageY: destY
      )
      return SpotlightRegion(
        rect: offset.bounds,
        cornerRadius: offset.properties.cornerRadius,
        opacity: offset.properties.spotlightOpacity
      )
    }
    SpotlightCompositor.drawOverlay(
      regions: spotlightRegions,
      previewRegion: nil,
      canvasRect: CGRect(x: destX, y: destY, width: effectiveBounds.width, height: effectiveBounds.height),
      in: context
    )

    // Draw annotations (offset by crop origin and image position based on alignment)
    let renderer = AnnotationRenderer(
      context: context,
      sourceImage: sourceImage,
      embeddedImageProvider: { assetId in
        snapshot.embeddedImages[assetId]
      },
      embeddedCGImageProvider: { assetId in
        snapshot.embeddedCGImages[assetId]
      }
    )
    for annotation in snapshot.annotations.renderOrdered {
      if case .spotlight = annotation.type {
        continue
      }
      // Only include annotations that intersect with crop bounds
      if let cropRect = snapshot.cropRect {
        guard annotation.bounds.intersects(cropRect) else { continue }
      }
      let offsetAnnotation = offsetAnnotationForExport(
        annotation,
        cropOrigin: effectiveBounds.origin,
        imageX: destX,
        imageY: destY
      )
      renderer.draw(offsetAnnotation)
    }

    if snapshot.isCombineMode {
      context.resetClip()
    }

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: totalSize)
    image.addRepresentation(bitmapRep)
    return image
  }

  /// Draw only the source-image portion that intersects the requested canvas bounds.
  /// Expanded crop areas outside the source image intentionally stay transparent/background-filled.
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

  /// Offset annotation for export, accounting for crop origin and alignment-based image position
  private nonisolated static func offsetAnnotationForExport(
    _ annotation: AnnotationItem,
    cropOrigin: CGPoint,
    imageX: CGFloat,
    imageY: CGFloat
  ) -> AnnotationItem {
    var result = annotation
    result.bounds = CGRect(
      x: annotation.bounds.origin.x - cropOrigin.x + imageX,
      y: annotation.bounds.origin.y - cropOrigin.y + imageY,
      width: annotation.bounds.width,
      height: annotation.bounds.height
    )

    // Offset internal points for types that store coordinates
    switch annotation.type {
    case .arrow(let geometry):
      result.type = .arrow(
        geometry.translatedBy(
          dx: -cropOrigin.x + imageX,
          dy: -cropOrigin.y + imageY
        )
      )
    case .line(let start, let end):
      result.type = .line(
        start: CGPoint(x: start.x - cropOrigin.x + imageX, y: start.y - cropOrigin.y + imageY),
        end: CGPoint(x: end.x - cropOrigin.x + imageX, y: end.y - cropOrigin.y + imageY)
      )
    case .path(let points):
      result.type = .path(points.map {
        CGPoint(x: $0.x - cropOrigin.x + imageX, y: $0.y - cropOrigin.y + imageY)
      })
    case .highlight(let points):
      result.type = .highlight(points.map {
        CGPoint(x: $0.x - cropOrigin.x + imageX, y: $0.y - cropOrigin.y + imageY)
      })
    default:
      break
    }

    return result
  }

  /// Offset annotation for crop, accounting for crop origin and padding
  private nonisolated static func offsetAnnotationForCrop(
    _ annotation: AnnotationItem,
    cropOrigin: CGPoint,
    padding: CGFloat
  ) -> AnnotationItem {
    var result = annotation
    result.bounds = CGRect(
      x: annotation.bounds.origin.x - cropOrigin.x + padding,
      y: annotation.bounds.origin.y - cropOrigin.y + padding,
      width: annotation.bounds.width,
      height: annotation.bounds.height
    )

    // Offset internal points for types that store coordinates
    switch annotation.type {
    case .arrow(let geometry):
      result.type = .arrow(
        geometry.translatedBy(
          dx: -cropOrigin.x + padding,
          dy: -cropOrigin.y + padding
        )
      )
    case .line(let start, let end):
      result.type = .line(
        start: CGPoint(x: start.x - cropOrigin.x + padding, y: start.y - cropOrigin.y + padding),
        end: CGPoint(x: end.x - cropOrigin.x + padding, y: end.y - cropOrigin.y + padding)
      )
    case .path(let points):
      result.type = .path(points.map {
        CGPoint(x: $0.x - cropOrigin.x + padding, y: $0.y - cropOrigin.y + padding)
      })
    case .highlight(let points):
      result.type = .highlight(points.map {
        CGPoint(x: $0.x - cropOrigin.x + padding, y: $0.y - cropOrigin.y + padding)
      })
    default:
      break
    }

    return result
  }

  /// Offset an annotation by padding, including internal points for lines/arrows
  private nonisolated static func offsetAnnotation(_ annotation: AnnotationItem,
                                                   by padding: CGFloat) -> AnnotationItem {
    var result = annotation
    result.bounds = annotation.bounds.offsetBy(dx: padding, dy: padding)

    // Also offset internal points for types that store coordinates
    switch annotation.type {
    case .arrow(let geometry):
      result.type = .arrow(geometry.translatedBy(dx: padding, dy: padding))
    case .line(let start, let end):
      result.type = .line(
        start: CGPoint(x: start.x + padding, y: start.y + padding),
        end: CGPoint(x: end.x + padding, y: end.y + padding)
      )
    case .path(let points):
      result.type = .path(points.map { CGPoint(x: $0.x + padding, y: $0.y + padding) })
    case .highlight(let points):
      result.type = .highlight(points.map { CGPoint(x: $0.x + padding, y: $0.y + padding) })
    default:
      break
    }

    return result
  }

  /// Snapshot-based background draw using immutable render inputs.
  private nonisolated static func drawBackground(snapshot: AnnotateRenderSnapshot, in context: CGContext,
                                                 size: NSSize) {
    let rect = CGRect(origin: .zero, size: size)

    switch snapshot.backgroundStyle {
    case .none:
      break

    case .gradient(let preset):
      drawLinearGradient(colors: preset.colors, in: context, size: size)

    case .solidColor(let color):
      context.setFillColor(NSColor(color).cgColor)
      context.fill(rect)
      if snapshot.isBlurredBackgroundEffectActive {
        drawBlurredBackgroundTint(effect: snapshot.blurredBackgroundEffect, in: context, rect: rect)
      }
    }
  }

  private static func drawBackground(effects: AnnotationCanvasEffects, in context: CGContext, size: NSSize) {
    let rect = CGRect(origin: .zero, size: size)

    switch effects.backgroundStyle {
    case .none:
      break

    case .gradient(let preset):
      drawLinearGradient(colors: preset.colors, in: context, size: size)

    case .solidColor(let color):
      context.setFillColor(NSColor(color).cgColor)
      context.fill(rect)
      if isBlurredBackgroundEffectActive(effects) {
        drawBlurredBackgroundTint(effect: effects.blurredBackgroundEffect, in: context, rect: rect)
      }
    }
  }

  private static func isBlurredBackgroundEffectActive(_ effects: AnnotationCanvasEffects) -> Bool {
    effects.backgroundStyle.supportsBlurredBackgroundEffect && effects.isBlurredBackgroundEnabled
  }

  private nonisolated static func drawLinearGradient(colors: [Color], in context: CGContext, size: NSSize) {
    let cgColors = colors.map { NSColor($0).cgColor }
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: cgColors as CFArray,
      locations: nil
    )
    if let gradient {
      context.drawLinearGradient(
        gradient,
        start: .zero,
        end: CGPoint(x: size.width, y: size.height),
        options: []
      )
    }
  }

  private nonisolated static func drawBlurredBackgroundTint(
    effect: BlurredBackgroundEffect,
    in context: CGContext,
    rect: CGRect
  ) {
    guard effect.tintOpacity > 0 else { return }

    context.saveGState()
    context.setFillColor(NSColor(effect.tintColor).withAlphaComponent(CGFloat(effect.tintOpacity)).cgColor)
    context.fill(rect)
    context.restoreGState()
  }

  private nonisolated static func destinationOrigin(
    imageSize: CGSize,
    totalSize: CGSize,
    alignment: ImageAlignment
  ) -> CGPoint {
    let totalExtraWidth = totalSize.width - imageSize.width
    let totalExtraHeight = totalSize.height - imageSize.height

    switch alignment {
    case .center:
      return CGPoint(x: totalExtraWidth / 2, y: totalExtraHeight / 2)
    case .topLeft:
      return CGPoint(x: 0, y: totalExtraHeight)
    case .top:
      return CGPoint(x: totalExtraWidth / 2, y: totalExtraHeight)
    case .topRight:
      return CGPoint(x: totalExtraWidth, y: totalExtraHeight)
    case .left:
      return CGPoint(x: 0, y: totalExtraHeight / 2)
    case .right:
      return CGPoint(x: totalExtraWidth, y: totalExtraHeight / 2)
    case .bottomLeft:
      return .zero
    case .bottom:
      return CGPoint(x: totalExtraWidth / 2, y: 0)
    case .bottomRight:
      return CGPoint(x: totalExtraWidth, y: 0)
    }
  }

  // MARK: - Mockup Rendering

  /// Render the flattened image + annotations that mockup transforms are applied to.
  /// Pure bitmap drawing from the frozen snapshot — safe on any queue.
  nonisolated static func renderMockupFlatImage(snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let sourceImage = snapshot.sourceImage

    // Determine effective bounds (crop or full image)
    let effectiveBounds: CGRect = if let cropRect = snapshot.cropRect {
      cropRect
    } else {
      CGRect(origin: .zero, size: sourceImage.size)
    }

    // Render at pixel resolution using NSBitmapImageRep for Retina quality
    let scale = sourceImageScale(sourceImage)
    let pixelWidth = max(1, Int(ceil(effectiveBounds.width * scale)))
    let pixelHeight = max(1, Int(ceil(effectiveBounds.height * scale)))

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
    bitmapRep.size = effectiveBounds.size // Point size

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    let context = graphicsContext.cgContext

    drawSourceImage(sourceImage, effectiveBounds: effectiveBounds, destinationOrigin: .zero, in: context)

    // Draw annotations offset by crop origin
    let renderer = AnnotationRenderer(
      context: context,
      sourceImage: sourceImage,
      embeddedImageProvider: { assetId in
        snapshot.embeddedImages[assetId]
      },
      embeddedCGImageProvider: { assetId in
        snapshot.embeddedCGImages[assetId]
      }
    )
    for annotation in snapshot.annotations.renderOrdered {
      if let cropRect = snapshot.cropRect {
        guard annotation.bounds.intersects(cropRect) else { continue }
      }
      let offsetAnnotation = offsetAnnotationForCrop(
        annotation,
        cropOrigin: effectiveBounds.origin,
        padding: 0
      )
      renderer.draw(offsetAnnotation)
    }

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: effectiveBounds.size)
    image.addRepresentation(bitmapRep)
    return image
  }

  /// Apply mockup 3D transforms to the flattened image via SwiftUI ImageRenderer.
  /// ImageRenderer is main-only — this is the sole main-actor step of mockup export.
  @MainActor static func compositeMockupImage(flatImage: NSImage, snapshot: AnnotateRenderSnapshot) -> NSImage? {
    let mockupView = MockupExportViewForAnnotate(flatImage: flatImage, snapshot: snapshot)
    let renderer = ImageRenderer(content: mockupView)
    renderer.scale = 2.0

    return renderer.nsImage
  }
}

// MARK: - Mockup Export View for Annotate

/// SwiftUI view for exporting mockup with 3D transforms
struct MockupExportViewForAnnotate: View {
  let flatImage: NSImage // Pre-rendered image with annotations
  let snapshot: AnnotateRenderSnapshot

  var body: some View {
    ZStack {
      backgroundLayer
        .frame(width: canvasSize.width, height: canvasSize.height)

      Image(nsImage: flatImage)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: imageSize.width, maxHeight: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: snapshot.cornerRadius, style: .continuous))
        .rotation3DEffect(
          .degrees(snapshot.mockupRotationY),
          axis: (x: 0, y: 1, z: 0),
          anchor: .center,
          anchorZ: 0,
          perspective: snapshot.mockupPerspective
        )
        .rotation3DEffect(
          .degrees(snapshot.mockupRotationX),
          axis: (x: 1, y: 0, z: 0),
          anchor: .center,
          anchorZ: 0,
          perspective: snapshot.mockupPerspective
        )
        .rotation3DEffect(
          .degrees(snapshot.mockupRotationZ),
          axis: (x: 0, y: 0, z: 1),
          anchor: .center
        )
        .shadow(
          color: .black.opacity(snapshot.shadowIntensity),
          radius: snapshot.mockupShadowRadius,
          x: snapshot.mockupShadowOffsetX,
          y: snapshot.mockupShadowOffsetY
        )
    }
  }

  // MARK: - Size Calculations

  private var imageSize: CGSize {
    flatImage.size
  }

  private var canvasSize: CGSize {
    let padding = snapshot.backgroundStyle != .none ? snapshot.padding : 0
    let extraSpace = padding * 2 + 100 // Extra for shadow and rotation
    return CGSize(
      width: imageSize.width + extraSpace,
      height: imageSize.height + extraSpace
    )
  }

  // MARK: - Background

  @ViewBuilder
  private var backgroundLayer: some View {
    switch snapshot.backgroundStyle {
    case .none:
      Color.clear
    case .gradient(let preset):
      LinearGradient(
        colors: preset.colors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    case .solidColor(let color):
      color
        .brightness(snapshot.isBlurredBackgroundEffectActive ? snapshot.blurredBackgroundEffect.brightness : 0)
        .overlay(
          (snapshot.isBlurredBackgroundEffectActive ? snapshot.blurredBackgroundEffect.tintColor : .clear)
            .opacity(snapshot.isBlurredBackgroundEffectActive ? snapshot.blurredBackgroundEffect.tintOpacity : 0)
        )
    }
  }
}
