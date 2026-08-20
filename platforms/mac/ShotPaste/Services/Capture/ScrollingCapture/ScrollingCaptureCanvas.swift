//
//  ScrollingCaptureCanvas.swift
//  ShotPaste
//
//  Incremental bidirectional canvas for real-time scrolling capture stitching.
//  Owns the preallocated output buffer, the subpixel scroll cursor, and the
//  incrementally extended preview thumbnail. All entry points must run on the
//  coordinator's serial processing queue.
//

import Accelerate
import CoreGraphics
import Foundation

/// Flat RGBA pixel buffer decoded from a captured frame.
/// Layout matches the capture pipeline: premultipliedLast alpha, big-endian 32-bit (R, G, B, A in memory).
nonisolated struct ScrollingCaptureRaster {
  let width: Int
  let height: Int
  let bytesPerRow: Int
  let pixels: [UInt8]

  init(width: Int, height: Int, pixels: [UInt8]) {
    self.width = width
    self.height = height
    bytesPerRow = width * 4
    self.pixels = pixels
  }

  init?(cgImage: CGImage) {
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    let drew = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      guard
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      else {
        return false
      }

      context.interpolationQuality = .none
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }

    guard drew else { return nil }

    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    self.pixels = pixels
  }

  func makeCGImage() -> CGImage? {
    Self.makeCGImage(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
  }

  static func makeCGImage(
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

/// Preallocated RGBA canvas that grows in both scroll directions from a
/// mid-buffer origin. Each accepted frame contributes only its newly visible
/// strip, so the per-frame cost stays proportional to the scroll delta instead
/// of the accumulated output height.
final nonisolated class ScrollingCaptureCanvas: @unchecked Sendable {
  /// Rows blended across each seam to hide +/-1px alignment error.
  private static let seamBlendRowCount = 2
  /// Hard cap on accumulated horizontal drift correction so a bad dx estimate
  /// can never walk the content out of the frame.
  private static let maximumHorizontalDriftPixels = 32

  let width: Int
  let maxHeight: Int

  private let bytesPerRow: Int
  private let storage: UnsafeMutablePointer<UInt8>
  private let storageRowCount: Int

  /// Buffer row of the first used row; `bottomRow` is one past the last used row.
  private(set) var topRow = 0
  private(set) var bottomRow = 0
  private var baseContentHeight = 0

  /// Signed subpixel scroll position of the latest accepted frame relative to
  /// the base frame. Positive values mean the user scrolled down.
  private var cursor = 0.0
  /// Historical extremes of `cursor`; strips are appended only when the cursor
  /// moves past them, which makes re-scrolling over captured content free.
  private var downExtent = 0.0
  private var upExtent = 0.0
  private var horizontalOffsetPixels = 0
  private var lastGrowthDirection: ScrollingCaptureMergeDirection = .appendFromBottom

  private let thumbnailWidth: Int
  private let thumbnailScale: Double
  private let thumbnailStorage: UnsafeMutablePointer<UInt8>
  private let thumbnailRowCount: Int
  private var thumbnailBaseContentHeight = 0
  /// Thumbnail buffer row that maps to logical row 0 (top of the base content).
  private var thumbnailOriginRow = 0
  private var thumbnailTopRow = 0
  private var thumbnailBottomRow = 0

  private var thumbnailBytesPerRow: Int {
    thumbnailWidth * 4
  }

  var usedHeight: Int {
    bottomRow - topRow
  }

  var thumbnailUsedHeight: Int {
    thumbnailBottomRow - thumbnailTopRow
  }

  init(width: Int, frameHeight: Int, maxHeight: Int, thumbnailWidth: Int) {
    self.width = width
    self.maxHeight = max(maxHeight, frameHeight)
    bytesPerRow = width * 4
    storageRowCount = self.maxHeight
    // Allocation is left uninitialized on purpose: for a 32768-row canvas the
    // reservation is virtual and physical pages are only committed where strips
    // actually land.
    storage = UnsafeMutablePointer<UInt8>.allocate(capacity: storageRowCount * bytesPerRow)

    self.thumbnailWidth = max(1, min(thumbnailWidth, width))
    thumbnailScale = Double(self.thumbnailWidth) / Double(max(1, width))
    thumbnailRowCount = Int((Double(self.maxHeight) * thumbnailScale).rounded(.up)) + 16
    thumbnailStorage = UnsafeMutablePointer<UInt8>.allocate(
      capacity: thumbnailRowCount * self.thumbnailWidth * 4
    )
  }

  deinit {
    storage.deallocate()
    thumbnailStorage.deallocate()
  }

  /// Places (or replaces) the base content block and resets the scroll cursor.
  /// `contentTop`/`contentBottom` exclude sticky header/footer rows so they are
  /// captured once instead of repeating in every strip. Replacement is only
  /// valid before the first strip has been appended.
  func placeBase(_ raster: ScrollingCaptureRaster, contentTop: Int, contentBottom: Int) {
    let contentHeight = max(1, min(contentBottom, raster.height) - max(0, contentTop))
    let safeContentTop = max(0, min(contentTop, raster.height - contentHeight))
    baseContentHeight = contentHeight

    topRow = max(0, (storageRowCount - contentHeight) / 2)
    bottomRow = topRow + contentHeight
    cursor = 0
    downExtent = 0
    upExtent = 0
    horizontalOffsetPixels = 0
    lastGrowthDirection = .appendFromBottom

    raster.pixels.withUnsafeBufferPointer { sourceBuffer in
      guard let sourceBase = sourceBuffer.baseAddress else { return }
      memcpy(
        storage + topRow * bytesPerRow,
        sourceBase + safeContentTop * raster.bytesPerRow,
        contentHeight * bytesPerRow
      )
    }

    thumbnailBaseContentHeight = max(1, Int((Double(contentHeight) * thumbnailScale).rounded()))
    thumbnailOriginRow = max(0, (thumbnailRowCount - thumbnailBaseContentHeight) / 2)
    thumbnailTopRow = thumbnailOriginRow
    thumbnailBottomRow = thumbnailOriginRow + thumbnailBaseContentHeight
    scaleIntoThumbnail(
      raster: raster,
      sourceStartRow: safeContentTop,
      sourceRowCount: contentHeight,
      destinationRow: thumbnailTopRow,
      destinationRowCount: thumbnailBaseContentHeight
    )
  }

  /// Advances the subpixel scroll cursor and returns how many new rows the
  /// frame exposes beyond the historical extent, capped by `heightBudget`.
  /// Returns 0 when the scroll position stays inside already-captured content.
  @discardableResult
  func advanceCursor(measuredDelta: Double, heightBudget: Int) -> Int {
    cursor += measuredDelta

    if measuredDelta >= 0 {
      let plannedRows = Int(cursor.rounded()) - Int(downExtent.rounded())
      let acceptedRows = max(0, min(plannedRows, max(0, heightBudget)))
      if acceptedRows > 0 {
        downExtent = cursor
      }
      return acceptedRows
    }

    let plannedRows = Int(upExtent.rounded()) - Int(cursor.rounded())
    let acceptedRows = max(0, min(plannedRows, max(0, heightBudget)))
    if acceptedRows > 0 {
      upExtent = cursor
    }
    return acceptedRows
  }

  /// Blits the newly visible strip of `raster` onto the canvas. The strip is
  /// taken from the content region (sticky bands excluded), written with the
  /// accumulated horizontal drift correction, and cross-faded across the seam.
  func blitStrip(
    from raster: ScrollingCaptureRaster,
    direction: ScrollingCaptureMergeDirection,
    rowCount: Int,
    deltaX: Int,
    contentTop: Int,
    contentBottom: Int
  ) {
    guard rowCount > 0 else { return }

    horizontalOffsetPixels = min(
      Self.maximumHorizontalDriftPixels,
      max(-Self.maximumHorizontalDriftPixels, horizontalOffsetPixels + deltaX)
    )
    if direction != .unresolved {
      lastGrowthDirection = direction
    }

    let safeContentTop = max(0, min(contentTop, raster.height - 1))
    let safeContentBottom = max(safeContentTop + 1, min(contentBottom, raster.height))

    switch direction {
    case .appendFromBottom:
      ensureSpace(for: rowCount, growingDown: true)
      let stripSourceStart = max(safeContentTop, safeContentBottom - rowCount)
      blendSeam(
        raster: raster,
        canvasStartRow: bottomRow - Self.seamBlendRowCount,
        rasterStartRow: stripSourceStart - Self.seamBlendRowCount,
        rowLimit: stripSourceStart - safeContentTop
      )
      for localRow in 0 ..< rowCount {
        copyRowWithOffset(
          raster: raster,
          sourceRow: stripSourceStart + localRow,
          destinationRow: bottomRow + localRow
        )
      }
      bottomRow += rowCount
      appendThumbnailStrip(
        raster: raster,
        sourceStartRow: stripSourceStart,
        sourceRowCount: rowCount,
        growingDown: true
      )
    case .appendFromTop:
      ensureSpace(for: rowCount, growingDown: false)
      let stripSourceEnd = min(safeContentBottom, safeContentTop + rowCount)
      for localRow in 0 ..< rowCount {
        copyRowWithOffset(
          raster: raster,
          sourceRow: safeContentTop + localRow,
          destinationRow: topRow - rowCount + localRow
        )
      }
      blendSeam(
        raster: raster,
        canvasStartRow: topRow,
        rasterStartRow: stripSourceEnd,
        rowLimit: safeContentBottom - stripSourceEnd
      )
      topRow -= rowCount
      appendThumbnailStrip(
        raster: raster,
        sourceStartRow: safeContentTop,
        sourceRowCount: rowCount,
        growingDown: false
      )
    case .unresolved:
      break
    }
  }

  /// Crops the used range out of the canvas. This is the only full-size copy
  /// the pipeline ever makes, and it runs once per save.
  func makeMergedCGImage() -> CGImage? {
    let height = usedHeight
    guard height > 0 else { return nil }

    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    pixels.withUnsafeMutableBytes { destination in
      guard let baseAddress = destination.baseAddress else { return }
      memcpy(baseAddress, storage + topRow * bytesPerRow, height * bytesPerRow)
    }

    return ScrollingCaptureRaster.makeCGImage(
      width: width,
      height: height,
      bytesPerRow: bytesPerRow,
      pixels: pixels
    )
  }

  /// Returns a fixed-width viewport into the incrementally maintained
  /// thumbnail. Once the thumbnail outgrows the panel, the viewport follows
  /// the end that most recently grew instead of shrinking the entire long
  /// screenshot into an unreadably thin strip.
  func makePreviewCGImage(maxPixelWidth: Int, maxPixelHeight: Int) -> CGImage? {
    let usedThumbnailHeight = thumbnailUsedHeight
    guard usedThumbnailHeight > 0 else { return nil }

    let scale = min(1, Double(max(1, maxPixelWidth)) / Double(thumbnailWidth))
    let sourceHeightLimit = max(1, Int((Double(max(1, maxPixelHeight)) / scale).rounded(.down)))
    let sourceHeight = min(usedThumbnailHeight, sourceHeightLimit)
    let sourceStartRow: Int = if usedThumbnailHeight <= sourceHeight {
      thumbnailTopRow
    } else if lastGrowthDirection == .appendFromTop {
      thumbnailTopRow
    } else {
      thumbnailBottomRow - sourceHeight
    }
    let outputWidth = max(1, Int((Double(thumbnailWidth) * scale).rounded()))
    let outputHeight = min(
      max(1, maxPixelHeight),
      max(1, Int((Double(sourceHeight) * scale).rounded()))
    )

    if outputWidth == thumbnailWidth, outputHeight == sourceHeight {
      var pixels = [UInt8](repeating: 0, count: sourceHeight * thumbnailBytesPerRow)
      pixels.withUnsafeMutableBytes { destination in
        guard let baseAddress = destination.baseAddress else { return }
        memcpy(
          baseAddress,
          thumbnailStorage + sourceStartRow * thumbnailBytesPerRow,
          sourceHeight * thumbnailBytesPerRow
        )
      }
      return ScrollingCaptureRaster.makeCGImage(
        width: thumbnailWidth,
        height: sourceHeight,
        bytesPerRow: thumbnailBytesPerRow,
        pixels: pixels
      )
    }

    var pixels = [UInt8](repeating: 0, count: outputHeight * outputWidth * 4)

    let scaled = pixels.withUnsafeMutableBytes { destination -> Bool in
      guard let destinationBase = destination.baseAddress else { return false }
      var source = vImage_Buffer(
        data: thumbnailStorage + sourceStartRow * thumbnailBytesPerRow,
        height: vImagePixelCount(sourceHeight),
        width: vImagePixelCount(thumbnailWidth),
        rowBytes: thumbnailBytesPerRow
      )
      var target = vImage_Buffer(
        data: destinationBase,
        height: vImagePixelCount(outputHeight),
        width: vImagePixelCount(outputWidth),
        rowBytes: outputWidth * 4
      )
      return vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
        == kvImageNoError
    }
    guard scaled else { return nil }

    return ScrollingCaptureRaster.makeCGImage(
      width: outputWidth,
      height: outputHeight,
      bytesPerRow: outputWidth * 4,
      pixels: pixels
    )
  }

  // MARK: - Private

  /// Recenters the used range when one side of the buffer runs out of room.
  /// With a mid-buffer origin this happens at most once or twice per session.
  private func ensureSpace(for rowCount: Int, growingDown: Bool) {
    if growingDown, bottomRow + rowCount <= storageRowCount {
      return
    }
    if !growingDown, topRow - rowCount >= 0 {
      return
    }

    let used = usedHeight
    guard used + rowCount <= storageRowCount else { return }

    let centeredTop = (storageRowCount - used) / 2
    let newTop: Int = if growingDown {
      max(0, min(centeredTop, storageRowCount - used - rowCount))
    } else {
      min(max(centeredTop, rowCount), storageRowCount - used)
    }

    let shift = newTop - topRow
    guard shift != 0 else { return }
    memmove(
      storage + newTop * bytesPerRow,
      storage + topRow * bytesPerRow,
      used * bytesPerRow
    )
    topRow = newTop
    bottomRow = newTop + used
  }

  private func ensureThumbnailSpace(for rowCount: Int, growingDown: Bool) {
    if growingDown, thumbnailBottomRow + rowCount <= thumbnailRowCount {
      return
    }
    if !growingDown, thumbnailTopRow - rowCount >= 0 {
      return
    }

    let used = thumbnailUsedHeight
    guard used + rowCount <= thumbnailRowCount else { return }

    let centeredTop = (thumbnailRowCount - used) / 2
    let newTop: Int = if growingDown {
      max(0, min(centeredTop, thumbnailRowCount - used - rowCount))
    } else {
      min(max(centeredTop, rowCount), thumbnailRowCount - used)
    }

    let shift = newTop - thumbnailTopRow
    guard shift != 0 else { return }
    memmove(
      thumbnailStorage + newTop * thumbnailBytesPerRow,
      thumbnailStorage + thumbnailTopRow * thumbnailBytesPerRow,
      used * thumbnailBytesPerRow
    )
    thumbnailTopRow = newTop
    thumbnailBottomRow = newTop + used
    thumbnailOriginRow += shift
  }

  private func copyRowWithOffset(
    raster: ScrollingCaptureRaster,
    sourceRow: Int,
    destinationRow: Int
  ) {
    let shift = min(max(horizontalOffsetPixels, -(width - 1)), width - 1)
    raster.pixels.withUnsafeBufferPointer { sourceBuffer in
      guard let sourceBase = sourceBuffer.baseAddress else { return }
      let sourceRowBase = sourceBase + sourceRow * raster.bytesPerRow
      let destinationRowBase = storage + destinationRow * bytesPerRow

      if shift == 0 {
        memcpy(destinationRowBase, sourceRowBase, bytesPerRow)
        return
      }

      let copyWidth = width - abs(shift)
      if shift > 0 {
        memcpy(destinationRowBase + shift * 4, sourceRowBase, copyWidth * 4)
        // Replicate the leading edge pixel so no black bar appears.
        for x in 0 ..< shift {
          memcpy(destinationRowBase + x * 4, sourceRowBase, 4)
        }
      } else {
        memcpy(destinationRowBase, sourceRowBase + -shift * 4, copyWidth * 4)
        for x in copyWidth ..< width {
          memcpy(destinationRowBase + x * 4, sourceRowBase + (width - 1) * 4, 4)
        }
      }
    }
  }

  /// Cross-fades the 1-2 existing rows adjacent to a seam toward the incoming
  /// frame so a +/-1px alignment error does not produce a visible tear.
  private func blendSeam(
    raster: ScrollingCaptureRaster,
    canvasStartRow: Int,
    rasterStartRow: Int,
    rowLimit: Int
  ) {
    let blendRows = min(Self.seamBlendRowCount, rowLimit)
    guard blendRows > 0 else { return }
    guard canvasStartRow >= topRow, canvasStartRow + blendRows <= bottomRow else { return }
    guard rasterStartRow >= 0, rasterStartRow + blendRows <= raster.height else { return }

    let shift = horizontalOffsetPixels
    raster.pixels.withUnsafeBufferPointer { sourceBuffer in
      guard let sourceBase = sourceBuffer.baseAddress else { return }

      for index in 0 ..< blendRows {
        // Alpha ramps toward the seam: the row touching the new strip is
        // dominated by the incoming frame.
        let incomingWeight = Double(index + 1) / Double(blendRows + 1)
        let canvasRow = storage + (canvasStartRow + index) * bytesPerRow
        let rasterRow = sourceBase + (rasterStartRow + index) * raster.bytesPerRow

        for x in 0 ..< width {
          let sourceX = min(width - 1, max(0, x - shift))
          let sourceIndex = sourceX * 4
          let destinationIndex = x * 4
          for channel in 0 ..< 3 {
            let existing = Double(canvasRow[destinationIndex + channel])
            let incoming = Double(rasterRow[sourceIndex + channel])
            canvasRow[destinationIndex + channel] = UInt8(
              min(255, max(0, (existing * (1 - incomingWeight) + incoming * incomingWeight).rounded()))
            )
          }
          canvasRow[destinationIndex + 3] = 255
        }
      }
    }
  }

  private func appendThumbnailStrip(
    raster: ScrollingCaptureRaster,
    sourceStartRow: Int,
    sourceRowCount: Int,
    growingDown: Bool
  ) {
    let targetRowCount: Int
    if growingDown {
      let targetBottom = thumbnailOriginRow + thumbnailBaseContentHeight
        + Int((downExtent * thumbnailScale).rounded())
      targetRowCount = targetBottom - thumbnailBottomRow
    } else {
      let targetTop = thumbnailOriginRow + Int((upExtent * thumbnailScale).rounded())
      targetRowCount = thumbnailTopRow - targetTop
    }
    guard targetRowCount > 0 else { return }

    ensureThumbnailSpace(for: targetRowCount, growingDown: growingDown)
    if growingDown {
      scaleIntoThumbnail(
        raster: raster,
        sourceStartRow: sourceStartRow,
        sourceRowCount: sourceRowCount,
        destinationRow: thumbnailBottomRow,
        destinationRowCount: targetRowCount
      )
      thumbnailBottomRow += targetRowCount
    } else {
      scaleIntoThumbnail(
        raster: raster,
        sourceStartRow: sourceStartRow,
        sourceRowCount: sourceRowCount,
        destinationRow: thumbnailTopRow - targetRowCount,
        destinationRowCount: targetRowCount
      )
      thumbnailTopRow -= targetRowCount
    }
  }

  private func scaleIntoThumbnail(
    raster: ScrollingCaptureRaster,
    sourceStartRow: Int,
    sourceRowCount: Int,
    destinationRow: Int,
    destinationRowCount: Int
  ) {
    guard sourceRowCount > 0, destinationRowCount > 0 else { return }
    guard destinationRow >= 0, destinationRow + destinationRowCount <= thumbnailRowCount else { return }

    raster.pixels.withUnsafeBufferPointer { sourceBuffer in
      guard let sourceBase = sourceBuffer.baseAddress else { return }
      var source = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: sourceBase + sourceStartRow * raster.bytesPerRow),
        height: vImagePixelCount(sourceRowCount),
        width: vImagePixelCount(raster.width),
        rowBytes: raster.bytesPerRow
      )
      var destination = vImage_Buffer(
        data: thumbnailStorage + destinationRow * thumbnailBytesPerRow,
        height: vImagePixelCount(destinationRowCount),
        width: vImagePixelCount(thumbnailWidth),
        rowBytes: thumbnailBytesPerRow
      )
      vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling))
    }
  }
}
