//
//  AnnotateBlurEffectRenderer.swift
//  ShotPaste
//
//  Helper for rendering pixelated blur effect on image regions
//

import AppKit
import CoreGraphics
import CoreImage
import Metal

/// Quality tier for blur renders. Interactive work must be bounded so UI input never waits on expensive effects.
nonisolated enum BlurRenderQuality: Equatable {
  case interactive
  case settled
  case export

  var maxGaussianSamplePixels: CGFloat? {
    switch self {
    case .interactive:
      420_000
    case .settled:
      1_600_000
    case .export:
      nil
    }
  }
}

/// Renders the available pixelated blur effects.
nonisolated enum BlurEffectRenderer {
  /// Default pixel block size for blur effect
  static let defaultPixelSize: CGFloat = 12

  /// Default Gaussian blur radius
  static let defaultGaussianRadius: Double = 20.0

  /// Security-first radius floor relative to smallest blur dimension
  private static let gaussianSecurityStrengthFactor: CGFloat = 0.35

  /// Sampling padding multiplier around target region
  private static let gaussianPaddingMultiplier: CGFloat = 2.0

  /// Hard cap to keep Gaussian cost bounded on very large regions
  private static let maxAdaptiveGaussianRadius: CGFloat = 120

  /// Shared GPU-backed CIContext for performance (reused across blur operations)
  static let sharedCIContext: CIContext = {
    if let metalDevice = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: metalDevice, options: [
        .cacheIntermediates: true,
        .priorityRequestLow: false,
      ])
    }
    return CIContext(options: [.cacheIntermediates: true])
  }()

  private struct RegionMapping {
    let imageScaleX: CGFloat
    let imageScaleY: CGFloat
    let clampedSourceRegion: CGRect
    let clampedDestRegion: CGRect
    let targetPixelRegion: CGRect
  }

  /// Draw a pixelated version of the source image region
  /// - Parameters:
  ///   - context: The graphics context to draw into
  ///   - sourceImage: The source image to sample from
  ///   - region: The region bounds in image coordinates
  ///   - pixelSize: Size of each pixel block (larger = more blur)
  static func drawPixelatedRegion(
    in context: CGContext,
    sourceImage: NSImage,
    region: CGRect,
    pixelSize: CGFloat = defaultPixelSize
  ) {
    drawPixelatedRegion(
      in: context,
      sourceImage: sourceImage,
      sourceRegion: region,
      destRegion: region,
      pixelSize: pixelSize
    )
  }

  /// Draw a pixelated region by sampling from source region and drawing into destination region.
  static func drawPixelatedRegion(
    in context: CGContext,
    sourceImage: NSImage,
    sourceRegion: CGRect,
    destRegion: CGRect,
    pixelSize: CGFloat = defaultPixelSize
  ) {
    guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    drawPixelatedRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: sourceImage.size,
      sourceRegion: sourceRegion,
      destRegion: destRegion,
      pixelSize: pixelSize
    )
  }

  /// Draw a pixelated region using a CGImage snapshot. Safe for background render work.
  static func drawPixelatedRegion(
    in context: CGContext,
    sourceCGImage cgImage: CGImage,
    sourceSize: CGSize,
    sourceRegion: CGRect,
    destRegion: CGRect,
    pixelSize: CGFloat = defaultPixelSize
  ) {
    guard sourceRegion.width > 0, sourceRegion.height > 0, destRegion.width > 0, destRegion.height > 0 else { return }

    guard let mapping = makeRegionMapping(
      sourceSize: sourceSize,
      cgImage: cgImage,
      sourceRegion: sourceRegion,
      destRegion: destRegion
    ) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    guard let croppedImage = cgImage.cropping(to: mapping.targetPixelRegion) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    drawPixelated(
      croppedImage: croppedImage,
      in: context,
      destRect: mapping.clampedDestRegion,
      pixelSize: pixelSize * max(mapping.imageScaleX, mapping.imageScaleY)
    )
  }

  /// Draw pixelated version of cropped image region.
  /// Uses downsample -> nearest-neighbor upscale instead of one fill call per block.
  private static func drawPixelated(
    croppedImage: CGImage,
    in context: CGContext,
    destRect: CGRect,
    pixelSize: CGFloat
  ) {
    let blockSize = max(1, pixelSize)
    let cols = max(1, Int(ceil(CGFloat(croppedImage.width) / blockSize)))
    let rows = max(1, Int(ceil(CGFloat(croppedImage.height) / blockSize)))

    guard let smallContext = CGContext(
      data: nil,
      width: cols,
      height: rows,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      drawFallbackBlur(in: context, region: destRect)
      return
    }

    smallContext.interpolationQuality = .low
    smallContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: cols, height: rows))

    guard let lowResolutionImage = smallContext.makeImage() else {
      drawFallbackBlur(in: context, region: destRect)
      return
    }

    context.saveGState()
    context.clip(to: destRect)
    context.setAllowsAntialiasing(false)
    context.setShouldAntialias(false)
    context.interpolationQuality = .none
    context.draw(lowResolutionImage, in: destRect)
    context.restoreGState()
  }

  /// Fallback blur when image sampling fails - draws semi-transparent overlay
  private static func drawFallbackBlur(in context: CGContext, region: CGRect) {
    context.setFillColor(NSColor.gray.withAlphaComponent(0.7).cgColor)
    context.fill(region)
  }

  /// Draw a subtle placeholder while an exact async blur render is pending.
  static func drawBlurPlaceholder(
    in context: CGContext,
    region: CGRect
  ) {
    context.saveGState()
    context.setFillColor(NSColor.gray.withAlphaComponent(0.32).cgColor)
    context.fill(region)
    context.restoreGState()
  }

  /// Draw blur preview during drag operation (simpler/faster)
  static func drawBlurPreview(
    in context: CGContext,
    region: CGRect,
    strokeColor: CGColor
  ) {
    // Draw semi-transparent overlay with pattern to indicate blur area
    context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
    context.fill(region)

    // Draw border
    context.setStrokeColor(strokeColor)
    context.setLineWidth(2)
    context.setLineDash(phase: 0, lengths: [6, 4])
    context.stroke(region)
    context.setLineDash(phase: 0, lengths: [])
  }

  /// Draw Gaussian blur region using CIFilter (GPU-accelerated).
  static func drawGaussianRegion(
    in context: CGContext,
    sourceImage: NSImage,
    region: CGRect,
    radius: Double = defaultGaussianRadius,
    quality: BlurRenderQuality = .export
  ) {
    drawGaussianRegion(
      in: context,
      sourceImage: sourceImage,
      sourceRegion: region,
      destRegion: region,
      radius: radius,
      quality: quality
    )
  }

  /// Draw Gaussian blur by sampling from source region and drawing into destination region.
  static func drawGaussianRegion(
    in context: CGContext,
    sourceImage: NSImage,
    sourceRegion: CGRect,
    destRegion: CGRect,
    radius: Double = defaultGaussianRadius,
    quality: BlurRenderQuality = .export
  ) {
    guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    drawGaussianRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: sourceImage.size,
      sourceRegion: sourceRegion,
      destRegion: destRegion,
      radius: radius,
      quality: quality
    )
  }

  /// Draw Gaussian blur using a CGImage snapshot. Safe for background render work.
  static func drawGaussianRegion(
    in context: CGContext,
    sourceCGImage cgImage: CGImage,
    sourceSize: CGSize,
    sourceRegion: CGRect,
    destRegion: CGRect,
    radius: Double = defaultGaussianRadius,
    quality: BlurRenderQuality = .export
  ) {
    guard sourceRegion.width > 0, sourceRegion.height > 0, destRegion.width > 0, destRegion.height > 0 else { return }

    guard let mapping = makeRegionMapping(
      sourceSize: sourceSize,
      cgImage: cgImage,
      sourceRegion: sourceRegion,
      destRegion: destRegion
    ) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    let targetPixelRegion = mapping.targetPixelRegion
    let imageScale = max(mapping.imageScaleX, mapping.imageScaleY)
    let effectiveRadiusPx = effectiveGaussianRadiusPixels(
      baseRadius: CGFloat(radius),
      imageScale: imageScale,
      pixelRegion: targetPixelRegion
    )
    let samplePaddingPx = ceil(effectiveRadiusPx * gaussianPaddingMultiplier)
    let pixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    let sampledPixelRegion = targetPixelRegion.insetBy(dx: -samplePaddingPx, dy: -samplePaddingPx)
      .intersection(pixelBounds)

    guard !sampledPixelRegion.isEmpty,
          let sampledCGImage = cgImage.cropping(to: sampledPixelRegion) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let sampleExtent = CGRect(x: 0, y: 0, width: sampledCGImage.width, height: sampledCGImage.height)
    let sampleArea = sampleExtent.width * sampleExtent.height
    let downsampleScale: CGFloat = if let maxPixels = quality.maxGaussianSamplePixels, sampleArea > maxPixels {
      max(0.05, sqrt(maxPixels / sampleArea))
    } else {
      1
    }

    let sampledCIImage = CIImage(cgImage: sampledCGImage)
    let workingImage: CIImage = if downsampleScale < 0.999 {
      sampledCIImage.transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
    } else {
      sampledCIImage
    }

    let clampedInput = workingImage.clampedToExtent()
    let filter = CIFilter(name: "CIGaussianBlur")
    filter?.setValue(clampedInput, forKey: kCIInputImageKey)
    filter?.setValue(max(1, effectiveRadiusPx * downsampleScale), forKey: kCIInputRadiusKey)
    guard let outputImage = filter?.outputImage else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let targetInSample = CGRect(
      x: targetPixelRegion.minX - sampledPixelRegion.minX,
      y: targetPixelRegion.minY - sampledPixelRegion.minY,
      width: targetPixelRegion.width,
      height: targetPixelRegion.height
    )
    let workingTarget = targetInSample.applying(CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
      .intersection(workingImage.extent)
    guard !workingTarget.isEmpty else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let croppedTargetOutput = outputImage.cropped(to: workingTarget)
    guard let blurredCGImage = sharedCIContext.createCGImage(croppedTargetOutput, from: workingTarget) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    context.saveGState()
    context.clip(to: mapping.clampedDestRegion)
    context.interpolationQuality = downsampleScale < 0.999 ? .high : .default
    context.draw(blurredCGImage, in: mapping.clampedDestRegion)
    context.restoreGState()
  }

  private static func makeRegionMapping(
    sourceSize: CGSize,
    cgImage: CGImage,
    sourceRegion: CGRect,
    destRegion: CGRect
  ) -> RegionMapping? {
    guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

    let normalizedSourceRegion = sourceRegion.standardized
    let normalizedDestRegion = destRegion.standardized
    guard normalizedSourceRegion.width > 0, normalizedSourceRegion.height > 0,
          normalizedDestRegion.width > 0, normalizedDestRegion.height > 0 else { return nil }

    let imageBounds = CGRect(origin: .zero, size: sourceSize)
    let clampedSourceRegion = normalizedSourceRegion.intersection(imageBounds)
    guard !clampedSourceRegion.isEmpty else { return nil }

    let clampedDestRegion: CGRect
    if clampedSourceRegion.equalTo(normalizedSourceRegion) {
      clampedDestRegion = normalizedDestRegion
    } else {
      let scaleX = normalizedDestRegion.width / normalizedSourceRegion.width
      let scaleY = normalizedDestRegion.height / normalizedSourceRegion.height
      let offsetX = clampedSourceRegion.minX - normalizedSourceRegion.minX
      let offsetY = clampedSourceRegion.minY - normalizedSourceRegion.minY
      clampedDestRegion = CGRect(
        x: normalizedDestRegion.minX + offsetX * scaleX,
        y: normalizedDestRegion.minY + offsetY * scaleY,
        width: clampedSourceRegion.width * scaleX,
        height: clampedSourceRegion.height * scaleY
      )
    }

    let imageScaleX = CGFloat(cgImage.width) / sourceSize.width
    let imageScaleY = CGFloat(cgImage.height) / sourceSize.height
    let pixelBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))

    let pixelMinX = max(pixelBounds.minX, floor(clampedSourceRegion.minX * imageScaleX))
    let pixelMaxX = min(pixelBounds.maxX, ceil(clampedSourceRegion.maxX * imageScaleX))
    let pixelMinY = max(pixelBounds.minY, floor((sourceSize.height - clampedSourceRegion.maxY) * imageScaleY))
    let pixelMaxY = min(pixelBounds.maxY, ceil((sourceSize.height - clampedSourceRegion.minY) * imageScaleY))
    let targetPixelRegion = CGRect(
      x: pixelMinX,
      y: pixelMinY,
      width: pixelMaxX - pixelMinX,
      height: pixelMaxY - pixelMinY
    )

    guard !targetPixelRegion.isEmpty, targetPixelRegion.width >= 1, targetPixelRegion.height >= 1 else { return nil }

    return RegionMapping(
      imageScaleX: imageScaleX,
      imageScaleY: imageScaleY,
      clampedSourceRegion: clampedSourceRegion,
      clampedDestRegion: clampedDestRegion,
      targetPixelRegion: targetPixelRegion
    )
  }

  /// Draw a general Core Image filter effect on a region.
  private static func drawCIFilterRegion(
    in context: CGContext,
    sourceCGImage cgImage: CGImage,
    sourceSize: CGSize,
    sourceRegion: CGRect,
    destRegion: CGRect,
    filterName: String,
    configureFilter: (CIFilter, CGFloat) -> Void,
    quality: BlurRenderQuality = .export
  ) {
    guard sourceRegion.width > 0, sourceRegion.height > 0, destRegion.width > 0, destRegion.height > 0 else { return }

    guard let mapping = makeRegionMapping(
      sourceSize: sourceSize,
      cgImage: cgImage,
      sourceRegion: sourceRegion,
      destRegion: destRegion
    ) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }

    let targetPixelRegion = mapping.targetPixelRegion
    let imageScale = max(mapping.imageScaleX, mapping.imageScaleY)

    // Use a standard padding so filter cell boundaries render correctly
    let samplePaddingPx = ceil(40.0 * imageScale)
    let pixelBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    let sampledPixelRegion = targetPixelRegion.insetBy(dx: -samplePaddingPx, dy: -samplePaddingPx)
      .intersection(pixelBounds)

    guard !sampledPixelRegion.isEmpty,
          let sampledCGImage = cgImage.cropping(to: sampledPixelRegion) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let sampleExtent = CGRect(x: 0, y: 0, width: sampledCGImage.width, height: sampledCGImage.height)
    let sampleArea = sampleExtent.width * sampleExtent.height
    let downsampleScale: CGFloat = if let maxPixels = quality.maxGaussianSamplePixels, sampleArea > maxPixels {
      max(0.05, sqrt(maxPixels / sampleArea))
    } else {
      1
    }

    let sampledCIImage = CIImage(cgImage: sampledCGImage)
    let workingImage: CIImage = if downsampleScale < 0.999 {
      sampledCIImage.transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
    } else {
      sampledCIImage
    }

    let clampedInput = workingImage.clampedToExtent()
    guard let filter = CIFilter(name: filterName) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    filter.setValue(clampedInput, forKey: kCIInputImageKey)
    configureFilter(filter, imageScale * downsampleScale)

    guard let outputImage = filter.outputImage else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let targetInSample = CGRect(
      x: targetPixelRegion.minX - sampledPixelRegion.minX,
      y: targetPixelRegion.minY - sampledPixelRegion.minY,
      width: targetPixelRegion.width,
      height: targetPixelRegion.height
    )
    let workingTarget = targetInSample.applying(CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
      .intersection(workingImage.extent)
    guard !workingTarget.isEmpty else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    let croppedTargetOutput = outputImage.cropped(to: workingTarget)
    guard let blurredCGImage = sharedCIContext.createCGImage(croppedTargetOutput, from: workingTarget) else {
      drawFallbackBlur(in: context, region: mapping.clampedDestRegion)
      return
    }

    context.saveGState()
    context.clip(to: mapping.clampedDestRegion)
    context.interpolationQuality = downsampleScale < 0.999 ? .high : .default
    context.draw(blurredCGImage, in: mapping.clampedDestRegion)
    context.restoreGState()
  }

  // MARK: - Hexagonal Region Drawing

  static func drawHexagonalRegion(
    in context: CGContext,
    sourceImage: NSImage,
    region: CGRect,
    scale: Double,
    quality: BlurRenderQuality = .export
  ) {
    drawHexagonalRegion(
      in: context,
      sourceImage: sourceImage,
      sourceRegion: region,
      destRegion: region,
      scale: scale,
      quality: quality
    )
  }

  static func drawHexagonalRegion(
    in context: CGContext,
    sourceImage: NSImage,
    sourceRegion: CGRect,
    destRegion: CGRect,
    scale: Double,
    quality: BlurRenderQuality = .export
  ) {
    guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      drawFallbackBlur(in: context, region: destRegion)
      return
    }
    drawHexagonalRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: sourceImage.size,
      sourceRegion: sourceRegion,
      destRegion: destRegion,
      scale: scale,
      quality: quality
    )
  }

  static func drawHexagonalRegion(
    in context: CGContext,
    sourceCGImage cgImage: CGImage,
    sourceSize: CGSize,
    sourceRegion: CGRect,
    destRegion: CGRect,
    scale: Double,
    quality: BlurRenderQuality = .export
  ) {
    drawCIFilterRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: sourceSize,
      sourceRegion: sourceRegion,
      destRegion: destRegion,
      filterName: "CIHexagonalPixellate",
      configureFilter: { filter, scaleFactor in
        let size = max(2.0, scale * scaleFactor)
        filter.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
        filter.setValue(NSNumber(value: Double(size)), forKey: "inputScale")
      },
      quality: quality
    )
  }

  // MARK: - Crystallized Region Drawing

  private static func drawSparkle(in context: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
    context.saveGState()
    context.setFillColor(color)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    path.addQuadCurve(
      to: CGPoint(x: center.x + radius, y: center.y),
      control: CGPoint(x: center.x + radius * 0.15, y: center.y - radius * 0.15)
    )
    path.addQuadCurve(
      to: CGPoint(x: center.x, y: center.y + radius),
      control: CGPoint(x: center.x + radius * 0.15, y: center.y + radius * 0.15)
    )
    path.addQuadCurve(
      to: CGPoint(x: center.x - radius, y: center.y),
      control: CGPoint(x: center.x - radius * 0.15, y: center.y + radius * 0.15)
    )
    path.addQuadCurve(
      to: CGPoint(x: center.x, y: center.y - radius),
      control: CGPoint(x: center.x - radius * 0.15, y: center.y - radius * 0.15)
    )
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()
    context.restoreGState()
  }

  // MARK: - Crystallized Region Drawing (Starry Tape)

  static func drawCrystallizedRegion(
    in context: CGContext,
    region: CGRect,
    radius: CGFloat
  ) {
    let normalized = region.standardized
    guard normalized.width > 0, normalized.height > 0 else { return }

    let seed = Int(normalized.minX + normalized.minY)
    let path = tornTapePath(in: normalized, seed: seed)

    context.saveGState()

    // 1. Draw subtle shadow
    context.setShadow(
      offset: CGSize(width: 1.0, height: -1.5),
      blur: 2.0,
      color: NSColor.black.withAlphaComponent(0.12).cgColor
    )

    // 2. Fill base color (pastel lilac/lavender)
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.92, green: 0.91, blue: 0.98, alpha: 1.0))
    context.fillPath()

    // Disable shadow for pattern drawing
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // 3. Clip to the torn path for patterns
    context.addPath(path)
    context.clip()

    // 4. Draw sparkles/stars
    let starColor1 = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.8)
    let starColor2 = CGColor(red: 1.0, green: 0.95, blue: 0.77, alpha: 0.7) // pale yellow

    let patternSpacing = radius
    var x = normalized.minX + patternSpacing / 2
    while x < normalized.maxX {
      var y = normalized.minY + patternSpacing / 2
      while y < normalized.maxY {
        let seedValue = sin(x * 0.05 + y * 0.1)
        let offsetX = seedValue * (patternSpacing * 0.25)
        let offsetY = cos(x * 0.05 + y * 0.1) * (patternSpacing * 0.25)
        let center = CGPoint(x: x + offsetX, y: y + offsetY)

        let sizeSeed = abs(cos(x * 0.2 - y * 0.2))
        let starRadius = max(2.0, patternSpacing * (0.12 + sizeSeed * 0.12))
        let color = sizeSeed > 0.5 ? starColor1 : starColor2

        drawSparkle(in: context, center: center, radius: starRadius, color: color)

        y += patternSpacing
      }
      x += patternSpacing
    }

    context.restoreGState()
  }

  static func drawCrystallizedRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    region: CGRect,
    radius: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawCrystallizedRegion(in: context, region: region, radius: CGFloat(radius))
  }

  static func drawCrystallizedRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    radius: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawCrystallizedRegion(in: context, region: destRegion, radius: CGFloat(radius))
  }

  static func drawCrystallizedRegion(
    in context: CGContext,
    sourceCGImage _: CGImage,
    sourceSize _: CGSize,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    radius: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawCrystallizedRegion(in: context, region: destRegion, radius: CGFloat(radius))
  }

  // MARK: - Pointillism Region Drawing (Grid Tape)

  static func drawPointillismRegion(
    in context: CGContext,
    region: CGRect,
    radius: CGFloat
  ) {
    let normalized = region.standardized
    guard normalized.width > 0, normalized.height > 0 else { return }

    let seed = Int(normalized.minX + normalized.minY)
    let path = tornTapePath(in: normalized, seed: seed)

    context.saveGState()

    // 1. Draw subtle shadow
    context.setShadow(
      offset: CGSize(width: 1.0, height: -1.5),
      blur: 2.0,
      color: NSColor.black.withAlphaComponent(0.12).cgColor
    )

    // 2. Fill base color (pastel peach)
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.99, green: 0.94, blue: 0.93, alpha: 1.0))
    context.fillPath()

    // Disable shadow for pattern drawing
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // 3. Clip to the torn path for patterns
    context.addPath(path)
    context.clip()

    // 4. Draw grid lines
    context.setStrokeColor(CGColor(red: 0.94, green: 0.82, blue: 0.80, alpha: 0.6))
    context.setLineWidth(1.0)

    let patternSpacing = radius

    var lx = normalized.minX + patternSpacing
    while lx < normalized.maxX {
      context.move(to: CGPoint(x: lx, y: normalized.minY))
      context.addLine(to: CGPoint(x: lx, y: normalized.maxY))
      context.strokePath()
      lx += patternSpacing
    }

    var ly = normalized.minY + patternSpacing
    while ly < normalized.maxY {
      context.move(to: CGPoint(x: normalized.minX, y: ly))
      context.addLine(to: CGPoint(x: normalized.maxX, y: ly))
      context.strokePath()
      ly += patternSpacing
    }

    // 5. Draw tiny white crosses at centers of some grid cells
    context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.8))
    context.setLineWidth(1.2)
    var px = normalized.minX + patternSpacing / 2
    while px < normalized.maxX {
      var py = normalized.minY + patternSpacing / 2
      while py < normalized.maxY {
        let seedVal = sin(px * 0.05 + py * 0.1)
        if seedVal > 0 {
          let plusSize: CGFloat = max(1.5, patternSpacing * 0.12)
          context.move(to: CGPoint(x: px - plusSize, y: py))
          context.addLine(to: CGPoint(x: px + plusSize, y: py))
          context.move(to: CGPoint(x: px, y: py - plusSize))
          context.addLine(to: CGPoint(x: px, y: py + plusSize))
          context.strokePath()
        }
        py += patternSpacing
      }
      px += patternSpacing
    }

    context.restoreGState()
  }

  static func drawPointillismRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    region: CGRect,
    radius: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawPointillismRegion(in: context, region: region, radius: CGFloat(radius))
  }

  static func drawPointillismRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    radius: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawPointillismRegion(in: context, region: destRegion, radius: CGFloat(radius))
  }

  static func drawPointillismRegion(
    in context: CGContext,
    sourceCGImage _: CGImage,
    sourceSize _: CGSize,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    radius: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawPointillismRegion(in: context, region: destRegion, radius: CGFloat(radius))
  }

  // MARK: - Halftone Region Drawing (Gingham Tape)

  static func drawHalftoneRegion(
    in context: CGContext,
    region: CGRect,
    width: CGFloat
  ) {
    let normalized = region.standardized
    guard normalized.width > 0, normalized.height > 0 else { return }

    let seed = Int(normalized.minX + normalized.minY)
    let path = tornTapePath(in: normalized, seed: seed)

    context.saveGState()

    // 1. Draw subtle shadow
    context.setShadow(
      offset: CGSize(width: 1.0, height: -1.5),
      blur: 2.0,
      color: NSColor.black.withAlphaComponent(0.12).cgColor
    )

    // 2. Fill base color (pastel cream/yellow)
    context.addPath(path)
    context.setFillColor(CGColor(red: 1.0, green: 0.97, blue: 0.90, alpha: 1.0))
    context.fillPath()

    // Disable shadow for pattern drawing
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // 3. Clip to the torn path for patterns
    context.addPath(path)
    context.clip()

    // 4. Draw gingham bands
    let bandColor = CGColor(red: 0.98, green: 0.88, blue: 0.65, alpha: 0.4)
    context.setFillColor(bandColor)

    let patternSpacing = width

    var bx = normalized.minX + patternSpacing / 2
    while bx < normalized.maxX {
      let rectWidth = patternSpacing * 0.5
      context.fill(CGRect(x: bx - rectWidth / 2, y: normalized.minY, width: rectWidth, height: normalized.height))
      bx += patternSpacing
    }

    var by = normalized.minY + patternSpacing / 2
    while by < normalized.maxY {
      let rectHeight = patternSpacing * 0.5
      context.fill(CGRect(x: normalized.minX, y: by - rectHeight / 2, width: normalized.width, height: rectHeight))
      by += patternSpacing
    }

    context.restoreGState()
  }

  static func drawHalftoneRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    region: CGRect,
    width: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawHalftoneRegion(in: context, region: region, width: CGFloat(width))
  }

  static func drawHalftoneRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    width: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawHalftoneRegion(in: context, region: destRegion, width: CGFloat(width))
  }

  static func drawHalftoneRegion(
    in context: CGContext,
    sourceCGImage _: CGImage,
    sourceSize _: CGSize,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    width: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawHalftoneRegion(in: context, region: destRegion, width: CGFloat(width))
  }

  private static func tornTapePath(in rect: CGRect, seed: Int) -> CGPath {
    let path = CGMutablePath()
    let minX = rect.minX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY

    // Start at top-left
    path.move(to: CGPoint(x: minX, y: minY))
    path.addLine(to: CGPoint(x: maxX, y: minY))

    // Jagged right edge (vertical zig-zags)
    let steps = max(3, Int(rect.height / 8))
    for i in 1 ... steps {
      let progress = CGFloat(i) / CGFloat(steps)
      let y = minY + progress * rect.height
      let trigVal = sin(y * 0.4 + CGFloat(seed)) * 2.5 + cos(y * 1.2) * 1.0
      let x = maxX + trigVal - 1.5
      path.addLine(to: CGPoint(x: x, y: y))
    }

    path.addLine(to: CGPoint(x: minX, y: maxY))

    // Jagged left edge (vertical zig-zags, going back up)
    for i in (0 ... (steps - 1)).reversed() {
      let progress = CGFloat(i) / CGFloat(steps)
      let y = minY + progress * rect.height
      let trigVal = sin(y * 0.4 + CGFloat(seed + 42)) * 2.5 + cos(y * 1.2) * 1.0
      let x = minX + trigVal + 1.5
      path.addLine(to: CGPoint(x: x, y: y))
    }

    path.closeSubpath()
    return path
  }

  // MARK: - Tape Region Drawing

  static func drawTapeRegion(
    in context: CGContext,
    region: CGRect,
    patternSpacing: CGFloat
  ) {
    let normalized = region.standardized
    guard normalized.width > 0, normalized.height > 0 else { return }

    let seed = Int(normalized.minX + normalized.minY)
    let path = tornTapePath(in: normalized, seed: seed)

    context.saveGState()

    // 1. Draw subtle shadow
    context.setShadow(
      offset: CGSize(width: 1.0, height: -1.5),
      blur: 2.0,
      color: NSColor.black.withAlphaComponent(0.12).cgColor
    )

    // 2. Fill base color (off-white correction tape)
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1.0))
    context.fillPath()

    // Disable shadow for pattern drawing
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // 3. Clip to the torn path for patterns
    context.addPath(path)
    context.clip()

    // 4. Draw diagonal stripes
    context.setStrokeColor(CGColor(red: 0.90, green: 0.90, blue: 0.86, alpha: 1.0))
    context.setLineWidth(patternSpacing * 0.4)

    let startX = normalized.minX - normalized.height
    let endX = normalized.maxX + normalized.height
    var x = startX
    while x < endX {
      context.move(to: CGPoint(x: x, y: normalized.minY))
      context.addLine(to: CGPoint(x: x + normalized.height, y: normalized.maxY))
      context.strokePath()
      x += patternSpacing
    }

    context.restoreGState()
  }

  static func drawTapeRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    region: CGRect,
    patternSpacing: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawTapeRegion(in: context, region: region, patternSpacing: CGFloat(patternSpacing))
  }

  static func drawTapeRegion(
    in context: CGContext,
    sourceCGImage _: CGImage,
    sourceSize _: CGSize,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    patternSpacing: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawTapeRegion(in: context, region: destRegion, patternSpacing: CGFloat(patternSpacing))
  }

  // MARK: - Washi Region Drawing

  static func drawWashiRegion(
    in context: CGContext,
    region: CGRect,
    patternSpacing: CGFloat
  ) {
    let normalized = region.standardized
    guard normalized.width > 0, normalized.height > 0 else { return }

    let seed = Int(normalized.minX + normalized.minY)
    let path = tornTapePath(in: normalized, seed: seed)

    context.saveGState()

    // 1. Draw subtle shadow
    context.setShadow(
      offset: CGSize(width: 1.0, height: -1.5),
      blur: 2.0,
      color: NSColor.black.withAlphaComponent(0.12).cgColor
    )

    // 2. Fill base color (pastel mint/teal washi tape)
    context.addPath(path)
    context.setFillColor(CGColor(red: 0.88, green: 0.95, blue: 0.94, alpha: 1.0))
    context.fillPath()

    // Disable shadow for pattern drawing
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // 3. Clip to the torn path for patterns
    context.addPath(path)
    context.clip()

    // 4. Draw white dot pattern
    context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.65))
    let dotRadius = max(1.5, patternSpacing * 0.15)
    var x = normalized.minX + patternSpacing / 2
    while x < normalized.maxX {
      var y = normalized.minY + patternSpacing / 2
      while y < normalized.maxY {
        context.addEllipse(in: CGRect(
          x: x - dotRadius,
          y: y - dotRadius,
          width: dotRadius * 2,
          height: dotRadius * 2
        ))
        context.fillPath()
        y += patternSpacing
      }
      x += patternSpacing
    }

    context.restoreGState()
  }

  static func drawWashiRegion(
    in context: CGContext,
    sourceImage _: NSImage,
    region: CGRect,
    patternSpacing: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawWashiRegion(in: context, region: region, patternSpacing: CGFloat(patternSpacing))
  }

  static func drawWashiRegion(
    in context: CGContext,
    sourceCGImage _: CGImage,
    sourceSize _: CGSize,
    sourceRegion _: CGRect,
    destRegion: CGRect,
    patternSpacing: Double,
    quality _: BlurRenderQuality = .export
  ) {
    drawWashiRegion(in: context, region: destRegion, patternSpacing: CGFloat(patternSpacing))
  }

  private static func effectiveGaussianRadiusPixels(
    baseRadius: CGFloat,
    imageScale: CGFloat,
    pixelRegion: CGRect
  ) -> CGFloat {
    let baseRadiusPx = max(1, baseRadius * imageScale)
    let minDimensionPx = min(pixelRegion.width, pixelRegion.height)
    let securityFloorPx = minDimensionPx * gaussianSecurityStrengthFactor
    let adaptiveRadiusPx = max(baseRadiusPx, securityFloorPx)
    let maxRegionRadiusPx = max(24, min(maxAdaptiveGaussianRadius, max(pixelRegion.width, pixelRegion.height) * 0.9))
    return min(adaptiveRadiusPx, maxRegionRadiusPx)
  }
}
