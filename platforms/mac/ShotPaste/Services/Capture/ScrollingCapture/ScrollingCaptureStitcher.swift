//
//  ScrollingCaptureStitcher.swift
//  ShotPaste
//
//  Real-time incremental stitcher for scrolling capture sessions.
//  Thin façade over ScrollingCaptureMotionTracker (per-frame motion) and
//  ScrollingCaptureCanvas (incremental bidirectional output buffer).
//

import CoreGraphics
import Foundation

nonisolated enum ScrollingCaptureMergeDirection {
  case unresolved
  case appendFromBottom
  case appendFromTop
}

nonisolated enum ScrollingCaptureStitchOutcome {
  case initialized
  case appended(deltaY: Int)
  case ignoredNoMovement
  case ignoredAlignmentFailed
  case reachedHeightLimit
}

nonisolated enum ScrollingCaptureStitchSafety: Equatable {
  case confirmed
  case tentative(reason: String)
  case unsafe(reason: String)
}

nonisolated enum ScrollingCaptureAlignmentPath: String {
  case initialFrame = "initial-frame"
  case guidedBands = "guided-bands"
  case recoveryBands = "recovery-bands"
  case noMovement = "no-movement"
  case duplicateBoundary = "duplicate-boundary"
  case alignmentFailed = "alignment-failed"
  case heightLimit = "height-limit"
}

nonisolated struct ScrollingCaptureAlignmentDebugInfo {
  let path: ScrollingCaptureAlignmentPath
  let confidence: Double
  let peakCorrelation: Double?
  let peakToSecondRatio: Double?
  let appendDeltaY: Int?
  let horizontalShift: Int
  let confidentBandCount: Int
}

nonisolated struct ScrollingCaptureStitchUpdate {
  let outcome: ScrollingCaptureStitchOutcome
  let mergedImage: CGImage?
  let acceptedFrameCount: Int
  let outputHeight: Int
  let matchFailureCount: Int
  let mergeDirection: ScrollingCaptureMergeDirection
  let likelyReachedBoundary: Bool
  let safety: ScrollingCaptureStitchSafety
  let alignmentDebug: ScrollingCaptureAlignmentDebugInfo?
}

/// Instances are confined to the coordinator's serial processing queue during capture.
final nonisolated class ScrollingCaptureStitcher: @unchecked Sendable {
  private static let defaultMaxOutputHeight = 32_768
  private static let thumbnailPixelWidth = 440
  /// Measured shifts below this magnitude are treated as noise.
  private static let minimumMotionPixels = 0.75
  /// Sampled gray difference below which frames count as stationary, even when
  /// the stream re-encodes identical content with slight noise.
  private static let stationaryFrameDifference = 1.2
  /// Frames this close to the previous one while scrolling was expected mean
  /// the content likely hit a scroll boundary.
  private static let boundaryFrameDifference = 4.5
  /// Static band inference only runs on frames with real visible change.
  private static let bandInferenceFrameDifference = 4.5

  private let tracker = ScrollingCaptureMotionTracker()
  private var canvas: ScrollingCaptureCanvas?
  /// Retained until the direction lock so the base can be re-trimmed around
  /// sticky header/footer bands before the first strip lands.
  private var baseRaster: ScrollingCaptureRaster?
  private var lastGrayFrame: ScrollingCaptureGrayFrame?
  private var frameWidth = 0
  private var frameHeight = 0
  private var matchNotFoundCount = 0
  private var lastAcceptedDeltaPixels: Int?
  private var cachedMergedImage: CGImage?
  private var cachedPreviewImage: CGImage?
  private var cachedPreviewBounds: (width: Int, height: Int)?

  private(set) var acceptedFrameCount = 0

  var outputHeight: Int {
    canvas?.usedHeight ?? 0
  }

  func start(
    with image: CGImage,
    maxOutputHeight: Int = ScrollingCaptureStitcher.defaultMaxOutputHeight
  ) -> ScrollingCaptureStitchUpdate? {
    guard let raster = ScrollingCaptureRaster(cgImage: image) else { return nil }
    guard let grayFrame = tracker.makeGrayFrame(from: image) else { return nil }

    let canvas = ScrollingCaptureCanvas(
      width: raster.width,
      frameHeight: raster.height,
      maxHeight: max(maxOutputHeight, raster.height),
      thumbnailWidth: min(Self.thumbnailPixelWidth, raster.width)
    )
    canvas.placeBase(raster, contentTop: 0, contentBottom: raster.height)

    self.canvas = canvas
    baseRaster = raster
    lastGrayFrame = grayFrame
    frameWidth = raster.width
    frameHeight = raster.height
    matchNotFoundCount = 0
    lastAcceptedDeltaPixels = nil
    cachedMergedImage = image
    cachedPreviewImage = nil
    cachedPreviewBounds = nil
    acceptedFrameCount = 1

    return ScrollingCaptureStitchUpdate(
      outcome: .initialized,
      mergedImage: image,
      acceptedFrameCount: acceptedFrameCount,
      outputHeight: outputHeight,
      matchFailureCount: matchNotFoundCount,
      mergeDirection: tracker.lockedDirection,
      likelyReachedBoundary: false,
      safety: .confirmed,
      alignmentDebug: ScrollingCaptureAlignmentDebugInfo(
        path: .initialFrame,
        confidence: 1,
        peakCorrelation: nil,
        peakToSecondRatio: nil,
        appendDeltaY: nil,
        horizontalShift: 0,
        confidentBandCount: 0
      )
    )
  }

  func append(
    _ image: CGImage,
    maxOutputHeight: Int,
    expectedSignedDeltaPixels: Int? = nil,
    renderMergedImage: Bool = true
  ) -> ScrollingCaptureStitchUpdate? {
    guard let canvas, let lastGrayFrame else {
      return start(with: image, maxOutputHeight: maxOutputHeight)
    }
    guard image.width == frameWidth, image.height == frameHeight else {
      matchNotFoundCount += 1
      return currentUpdate(
        outcome: .ignoredAlignmentFailed,
        renderMergedImage: renderMergedImage,
        alignmentDebug: makeFailureDebugInfo(confidence: 0)
      )
    }
    guard let grayFrame = tracker.makeGrayFrame(from: image) else {
      matchNotFoundCount += 1
      return currentUpdate(
        outcome: .ignoredAlignmentFailed,
        renderMergedImage: renderMergedImage,
        alignmentDebug: makeFailureDebugInfo(confidence: 0)
      )
    }

    // Stationary periods must cost nothing: identical frames short-circuit
    // before any matching or rasterization work happens.
    if grayFrame.fingerprint == lastGrayFrame.fingerprint {
      return currentUpdate(
        outcome: .ignoredNoMovement,
        renderMergedImage: renderMergedImage,
        likelyReachedBoundary: true,
        alignmentDebug: ScrollingCaptureAlignmentDebugInfo(
          path: .duplicateBoundary,
          confidence: 1,
          peakCorrelation: nil,
          peakToSecondRatio: nil,
          appendDeltaY: nil,
          horizontalShift: 0,
          confidentBandCount: 0
        )
      )
    }

    let frameDifference = tracker.frameDifference(previous: lastGrayFrame, current: grayFrame)
    if frameDifference < Self.stationaryFrameDifference {
      return currentUpdate(
        outcome: .ignoredNoMovement,
        renderMergedImage: renderMergedImage,
        likelyReachedBoundary: true,
        alignmentDebug: ScrollingCaptureAlignmentDebugInfo(
          path: .noMovement,
          confidence: 1,
          peakCorrelation: nil,
          peakToSecondRatio: nil,
          appendDeltaY: nil,
          horizontalShift: 0,
          confidentBandCount: 0
        )
      )
    }

    // Sticky bands are inferred from moving frames only, and freeze once the
    // scroll direction locks.
    if tracker.lockedDirection == .unresolved, frameDifference >= Self.bandInferenceFrameDifference {
      tracker.inferStaticBands(previous: lastGrayFrame, current: grayFrame)
    }

    guard
      let motion = tracker.estimateMotion(
        previous: lastGrayFrame,
        current: grayFrame,
        expectedSignedDeltaPixels: expectedSignedDeltaPixels,
        lastAcceptedDeltaPixels: lastAcceptedDeltaPixels
      )
    else {
      matchNotFoundCount += 1
      return currentUpdate(
        outcome: .ignoredAlignmentFailed,
        renderMergedImage: renderMergedImage,
        alignmentDebug: makeFailureDebugInfo(confidence: 0)
      )
    }

    if abs(motion.deltaY) < Self.minimumMotionPixels {
      // Keep the previous frame as the matching reference so sub-threshold
      // creep accumulates into a measurable shift on a later frame.
      return currentUpdate(
        outcome: .ignoredNoMovement,
        renderMergedImage: renderMergedImage,
        likelyReachedBoundary: frameDifference < Self.boundaryFrameDifference,
        alignmentDebug: makeMotionDebugInfo(
          for: motion,
          path: .noMovement,
          appendDeltaY: nil
        )
      )
    }

    guard motion.confidence >= ScrollingCaptureMotionTracker.minimumAcceptanceConfidence else {
      matchNotFoundCount += 1
      return currentUpdate(
        outcome: .ignoredAlignmentFailed,
        renderMergedImage: renderMergedImage,
        alignmentDebug: makeMotionDebugInfo(
          for: motion,
          path: .alignmentFailed,
          appendDeltaY: nil
        )
      )
    }

    let direction: ScrollingCaptureMergeDirection = motion.deltaY >= 0
      ? .appendFromBottom
      : .appendFromTop
    if tracker.lockedDirection == .unresolved {
      tracker.lockDirection(direction)
      trimBaseAroundStaticBands(fullResScale: grayFrame.fullResScale)
    }

    let staticBands = tracker.staticBandsInPixels(fullResScale: grayFrame.fullResScale)
    let contentTop = min(staticBands.header, frameHeight / 3)
    let contentBottom = frameHeight - min(staticBands.footer, frameHeight / 3)

    let heightBudget = maxOutputHeight - outputHeight
    guard heightBudget > 0 else {
      return currentUpdate(
        outcome: .reachedHeightLimit,
        renderMergedImage: renderMergedImage,
        alignmentDebug: makeMotionDebugInfo(for: motion, path: .heightLimit, appendDeltaY: nil)
      )
    }

    let plannedRows = canvas.advanceCursor(
      measuredDelta: motion.deltaY,
      heightBudget: heightBudget
    )
    guard plannedRows > 0 else {
      // Confident motion inside the already-captured extent: the user scrolled
      // back over content the canvas already holds, so there is nothing to add.
      self.lastGrayFrame = grayFrame
      lastAcceptedDeltaPixels = Int(motion.deltaY.rounded())
      return currentUpdate(
        outcome: .ignoredNoMovement,
        renderMergedImage: renderMergedImage,
        likelyReachedBoundary: false,
        alignmentDebug: makeMotionDebugInfo(for: motion, path: .noMovement, appendDeltaY: nil)
      )
    }

    guard let raster = ScrollingCaptureRaster(cgImage: image) else {
      matchNotFoundCount += 1
      return currentUpdate(
        outcome: .ignoredAlignmentFailed,
        renderMergedImage: renderMergedImage,
        alignmentDebug: makeFailureDebugInfo(confidence: 0)
      )
    }

    canvas.blitStrip(
      from: raster,
      direction: direction,
      rowCount: plannedRows,
      deltaX: motion.deltaX,
      contentTop: contentTop,
      contentBottom: contentBottom
    )

    self.lastGrayFrame = grayFrame
    lastAcceptedDeltaPixels = direction == .appendFromTop ? -plannedRows : plannedRows
    matchNotFoundCount = 0
    acceptedFrameCount += 1
    cachedMergedImage = nil
    cachedPreviewImage = nil
    cachedPreviewBounds = nil

    let reachedHeightLimit = outputHeight >= maxOutputHeight
    let outcome: ScrollingCaptureStitchOutcome = reachedHeightLimit
      ? .reachedHeightLimit
      : .appended(deltaY: plannedRows)
    let path: ScrollingCaptureAlignmentPath = reachedHeightLimit
      ? .heightLimit
      : motion.usedRecoverySearch ? .recoveryBands : .guidedBands

    return currentUpdate(
      outcome: outcome,
      renderMergedImage: renderMergedImage,
      alignmentDebug: makeMotionDebugInfo(for: motion, path: path, appendDeltaY: plannedRows)
    )
  }

  /// Crops the used range out of the incremental canvas; runs once per save.
  func mergedImage() -> CGImage? {
    if let cachedMergedImage {
      return cachedMergedImage
    }

    guard let image = canvas?.makeMergedCGImage() else { return nil }
    cachedMergedImage = image
    return image
  }

  /// Returns the incrementally maintained thumbnail, only downscaling when the
  /// accumulated content outgrows the preview bounds.
  func previewImage(maxPixelWidth: Int, maxPixelHeight: Int) -> CGImage? {
    let bounds = (width: max(1, maxPixelWidth), height: max(1, maxPixelHeight))
    if let cachedPreviewImage,
       let cachedPreviewBounds,
       cachedPreviewBounds.width == bounds.width,
       cachedPreviewBounds.height == bounds.height {
      return cachedPreviewImage
    }

    let image = canvas?.makePreviewCGImage(
      maxPixelWidth: bounds.width,
      maxPixelHeight: bounds.height
    )
    cachedPreviewImage = image
    cachedPreviewBounds = bounds
    return image
  }

  // MARK: - Private

  /// Re-places the base block without its sticky header/footer so those bands
  /// are captured once instead of repeating in every strip.
  private func trimBaseAroundStaticBands(fullResScale: Double) {
    guard let canvas, let baseRaster else { return }
    let staticBands = tracker.staticBandsInPixels(fullResScale: fullResScale)
    let contentTop = min(staticBands.header, baseRaster.height / 3)
    let contentBottom = baseRaster.height - min(staticBands.footer, baseRaster.height / 3)
    guard contentTop > 0 || contentBottom < baseRaster.height else {
      self.baseRaster = nil
      return
    }

    canvas.placeBase(baseRaster, contentTop: contentTop, contentBottom: contentBottom)
    cachedPreviewImage = nil
    cachedPreviewBounds = nil
    self.baseRaster = nil
  }

  private func currentUpdate(
    outcome: ScrollingCaptureStitchOutcome,
    renderMergedImage: Bool = true,
    likelyReachedBoundary: Bool = false,
    safety: ScrollingCaptureStitchSafety? = nil,
    alignmentDebug: ScrollingCaptureAlignmentDebugInfo? = nil
  ) -> ScrollingCaptureStitchUpdate {
    ScrollingCaptureStitchUpdate(
      outcome: outcome,
      mergedImage: renderMergedImage ? mergedImage() : cachedMergedImage,
      acceptedFrameCount: acceptedFrameCount,
      outputHeight: outputHeight,
      matchFailureCount: matchNotFoundCount,
      mergeDirection: tracker.lockedDirection,
      likelyReachedBoundary: likelyReachedBoundary,
      safety: safety ?? defaultSafety(for: outcome),
      alignmentDebug: alignmentDebug
    )
  }

  private func defaultSafety(for outcome: ScrollingCaptureStitchOutcome) -> ScrollingCaptureStitchSafety {
    switch outcome {
    case .initialized, .appended, .ignoredNoMovement, .reachedHeightLimit:
      .confirmed
    case .ignoredAlignmentFailed:
      .unsafe(reason: "alignment-failed")
    }
  }

  private func makeFailureDebugInfo(confidence: Double) -> ScrollingCaptureAlignmentDebugInfo {
    ScrollingCaptureAlignmentDebugInfo(
      path: .alignmentFailed,
      confidence: confidence,
      peakCorrelation: nil,
      peakToSecondRatio: nil,
      appendDeltaY: nil,
      horizontalShift: 0,
      confidentBandCount: 0
    )
  }

  private func makeMotionDebugInfo(
    for motion: ScrollingCaptureMotionResult,
    path: ScrollingCaptureAlignmentPath,
    appendDeltaY: Int?
  ) -> ScrollingCaptureAlignmentDebugInfo {
    ScrollingCaptureAlignmentDebugInfo(
      path: path,
      confidence: motion.confidence,
      peakCorrelation: motion.peakCorrelation,
      peakToSecondRatio: motion.peakToSecondRatio,
      appendDeltaY: appendDeltaY,
      horizontalShift: motion.deltaX,
      confidentBandCount: motion.confidentBandCount
    )
  }
}
