//
//  ScrollingCaptureMotionTracker.swift
//  ShotPaste
//
//  Fast per-frame motion estimation for real-time scrolling capture stitching.
//  Frames are downsampled to grayscale, split into horizontal bands, and matched
//  with per-band vertical NCC over a guided candidate range. All entry points
//  must run on the coordinator's serial processing queue.
//

import Accelerate
import CoreGraphics
import Foundation

/// Downsampled grayscale representation of a captured frame.
nonisolated struct ScrollingCaptureGrayFrame {
  let width: Int
  let height: Int
  /// Luminance bytes, row-major.
  let pixels: [UInt8]
  /// Same content as Double for NCC accumulation without precision loss.
  let floats: [Double]
  /// Cheap content hash; identical fingerprints short-circuit the matcher.
  let fingerprint: UInt64
  /// Full-resolution pixels per gray pixel (>= 1).
  let fullResScale: Double
}

/// Sticky regions detected at the current scroll position, in gray pixels.
nonisolated struct ScrollingCaptureStaticBands: Equatable {
  var header = 0
  var footer = 0
  var leading = 0
  var trailing = 0
}

nonisolated struct ScrollingCaptureMotionResult {
  /// Signed vertical shift in full-resolution pixels, subpixel-refined.
  /// Positive means the content moved up (user scrolled down).
  let deltaY: Double
  /// Small horizontal drift correction in full-resolution pixels.
  let deltaX: Int
  let confidence: Double
  let peakCorrelation: Double
  let peakToSecondRatio: Double
  let confidentBandCount: Int
  let bandCount: Int
  let usedRecoverySearch: Bool
}

final nonisolated class ScrollingCaptureMotionTracker: @unchecked Sendable {
  /// Width the matcher downsamples to; keeps per-frame cost independent of the
  /// capture resolution.
  static let targetGrayWidth = 480
  static let minimumAcceptanceConfidence = 0.5

  private static let bandCount = 7
  private static let minimumConfidentBandCount = 3
  private static let minimumPeakCorrelation = 0.45
  private static let minimumPeakMargin = 0.04
  private static let minimumAcceptanceCorrelation = 0.5
  /// Guided range is +/-(multiplier x |hint| + padding) in full-res pixels.
  private static let guidedRangeMultiplier = 1.5
  private static let guidedRangePaddingPixels = 24.0
  private static let defaultGuidedRangePixels = 64.0
  private static let recoveryCoarseStepGray = 3
  private static let maximumHorizontalShiftPixels = 8
  private static let horizontalShiftImprovement = 0.002
  private static let staticBandDifferenceThreshold = 5.0
  private static let maximumStaticHeaderFooterPixels = 160.0
  private static let maximumStaticSidePixels = 120.0

  private(set) var lockedDirection: ScrollingCaptureMergeDirection = .unresolved
  /// Sticky bands in gray pixels; refreshed per frame until the direction lock.
  private(set) var staticBands = ScrollingCaptureStaticBands()
  private var hasLockedStaticBands = false

  func lockDirection(_ direction: ScrollingCaptureMergeDirection) {
    guard lockedDirection == .unresolved, direction != .unresolved else { return }
    lockedDirection = direction
    hasLockedStaticBands = true
  }

  /// Static bands scaled back to full-resolution pixels for strip extraction.
  func staticBandsInPixels(fullResScale: Double) -> ScrollingCaptureStaticBands {
    ScrollingCaptureStaticBands(
      header: Int((Double(staticBands.header) * fullResScale).rounded()),
      footer: Int((Double(staticBands.footer) * fullResScale).rounded()),
      leading: Int((Double(staticBands.leading) * fullResScale).rounded()),
      trailing: Int((Double(staticBands.trailing) * fullResScale).rounded())
    )
  }

  // MARK: - Gray frame construction

  /// Renders the frame straight into the small gray buffer, so tracking never
  /// pays for a full-resolution rasterization of frames that get rejected.
  func makeGrayFrame(from image: CGImage) -> ScrollingCaptureGrayFrame? {
    let scale = min(1.0, Double(Self.targetGrayWidth) / Double(max(1, image.width)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    let bytesPerRow = width * 4
    var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)

    let drew = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
      guard let baseAddress = rawBuffer.baseAddress else { return false }
      guard
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else {
        return false
      }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drew else { return nil }

    let count = width * height
    var gray = [UInt8](repeating: 0, count: count)
    for index in 0 ..< count {
      let offset = index * 4
      gray[index] = UInt8(
        (Int(rgba[offset]) * 77 + Int(rgba[offset + 1]) * 150 + Int(rgba[offset + 2]) * 29) >> 8
      )
    }

    var floats = [Double](repeating: 0, count: count)
    gray.withUnsafeBufferPointer { source in
      floats.withUnsafeMutableBufferPointer { destination in
        guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
        vDSP_vfltu8D(sourceBase, 1, destinationBase, 1, vDSP_Length(count))
      }
    }

    return ScrollingCaptureGrayFrame(
      width: width,
      height: height,
      pixels: gray,
      floats: floats,
      fingerprint: fingerprint(of: gray),
      fullResScale: Double(image.width) / Double(width)
    )
  }

  // MARK: - Frame difference

  /// Sampled mean absolute gray difference over the content area. Near-zero for
  /// stationary frames even when the stream re-encodes pixels with slight noise.
  func frameDifference(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame
  ) -> Double {
    guard previous.width == current.width, previous.height == current.height else { return 255 }
    let contentTop = min(staticBands.header, previous.height / 3)
    let contentBottom = max(contentTop + 1, previous.height - min(staticBands.footer, previous.height / 3))
    let rowStride = max(1, (contentBottom - contentTop) / 48)
    let columnStride = max(1, previous.width / 120)

    var total = 0
    var count = 0
    for row in stride(from: contentTop, to: contentBottom, by: rowStride) {
      let rowOffset = row * previous.width
      for x in stride(from: 0, to: previous.width, by: columnStride) {
        total += abs(Int(previous.pixels[rowOffset + x]) - Int(current.pixels[rowOffset + x]))
        count += 1
      }
    }
    return count > 0 ? Double(total) / Double(count) : 255
  }

  // MARK: - Static band detection

  /// Detects sticky header/footer rows and static side bars: regions identical
  /// at the same absolute coordinates while the content underneath scrolled.
  /// Refreshed every moving frame until the direction locks, then frozen.
  func inferStaticBands(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame
  ) {
    guard !hasLockedStaticBands else { return }
    guard previous.width == current.width, previous.height == current.height else { return }

    staticBands = ScrollingCaptureStaticBands(
      header: detectStaticEdgeRows(previous: previous, current: current, fromTop: true),
      footer: detectStaticEdgeRows(previous: previous, current: current, fromTop: false),
      leading: detectStaticSideColumns(previous: previous, current: current, fromLeading: true),
      trailing: detectStaticSideColumns(previous: previous, current: current, fromLeading: false)
    )
  }

  // MARK: - Motion estimation

  /// Estimates the signed vertical shift between two consecutive frames.
  /// `expectedSignedDeltaPixels` carries the scroll-event hint and
  /// `lastAcceptedDeltaPixels` the signed last accepted shift; both center the
  /// guided candidate range. Returns nil only when no candidate is measurable.
  func estimateMotion(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame,
    expectedSignedDeltaPixels: Int?,
    lastAcceptedDeltaPixels: Int?
  ) -> ScrollingCaptureMotionResult? {
    guard previous.width == current.width, previous.height == current.height else { return nil }

    let width = previous.width
    let contentTop = min(staticBands.header, previous.height / 3)
    let contentBottom = max(contentTop + 1, previous.height - min(staticBands.footer, previous.height / 3))
    let contentHeight = contentBottom - contentTop
    guard contentHeight > 32 else { return nil }

    let xStart = max(0, min(staticBands.leading, width - 33))
    let xEnd = min(width, max(xStart + 32, width - staticBands.trailing))
    let stripWidth = xEnd - xStart
    guard stripWidth >= 32 else { return nil }

    // Compact the content region into contiguous buffers so every NCC strip is
    // a single vDSP call regardless of static side bars.
    let previousCompact = compactContent(
      of: previous,
      contentTop: contentTop,
      contentHeight: contentHeight,
      xStart: xStart,
      stripWidth: stripWidth
    )
    let currentCompact = compactContent(
      of: current,
      contentTop: contentTop,
      contentHeight: contentHeight,
      xStart: xStart,
      stripWidth: stripWidth
    )

    let bandHeight = max(8, min(48, contentHeight / (Self.bandCount + 1)))
    let bandSpacing = max(1, (contentHeight - bandHeight) / Self.bandCount)
    let bandStarts = (0 ..< Self.bandCount).map { $0 * bandSpacing }
      .filter { $0 + bandHeight <= contentHeight }
    guard bandStarts.count >= Self.minimumConfidentBandCount else { return nil }

    let scale = previous.fullResScale
    // Before the first accepted frame the wheel/content sign mapping is not
    // known, so search symmetrically. Afterwards the coordinator supplies the
    // learned content-motion sign, including when the user reverses direction.
    let centerGray: Double
    let rangeGray: Double
    if let expectedSignedDeltaPixels {
      let magnitude = abs(Double(expectedSignedDeltaPixels))
      centerGray = lockedDirection == .unresolved
        ? 0
        : Double(expectedSignedDeltaPixels) / scale
      rangeGray = (magnitude * Self.guidedRangeMultiplier + Self.guidedRangePaddingPixels) / scale
    } else if let lastAcceptedDeltaPixels {
      centerGray = Double(lastAcceptedDeltaPixels) / scale
      rangeGray = (abs(Double(lastAcceptedDeltaPixels)) * Self.guidedRangeMultiplier
        + Self.guidedRangePaddingPixels) / scale
    } else {
      centerGray = 0
      rangeGray = Self.defaultGuidedRangePixels / scale
    }

    let minimumOverlap = max(16, contentHeight / 4)
    let maximumDelta = contentHeight - minimumOverlap
    guard maximumDelta > 2 else { return nil }

    let guidedLower = max(-maximumDelta, Int((centerGray - rangeGray).rounded(.down)))
    let guidedUpper = min(maximumDelta, Int((centerGray + rangeGray).rounded(.up)))

    var usedRecoverySearch = false
    var best = previousCompact.withUnsafeBufferPointer { previousBuffer in
      currentCompact.withUnsafeBufferPointer { currentBuffer in
        searchBands(
          previous: previousBuffer,
          current: currentBuffer,
          stripWidth: stripWidth,
          contentHeight: contentHeight,
          bandStarts: bandStarts,
          bandHeight: bandHeight,
          candidates: Array(guidedLower ... max(guidedLower, guidedUpper))
        )
      }
    }

    if !isAcceptable(best) {
      usedRecoverySearch = true
      let preferredSign: Int = if let expectedSignedDeltaPixels, expectedSignedDeltaPixels != 0 {
        expectedSignedDeltaPixels > 0 ? 1 : -1
      } else if let lastAcceptedDeltaPixels, lastAcceptedDeltaPixels != 0 {
        lastAcceptedDeltaPixels > 0 ? 1 : -1
      } else {
        lockedDirection == .appendFromTop ? -1 : 1
      }
      let preferredSigns = [preferredSign, -preferredSign]
      var recoveryBest: BandSearchResult?

      previousCompact.withUnsafeBufferPointer { previousBuffer in
        currentCompact.withUnsafeBufferPointer { currentBuffer in
          for sign in preferredSigns {
            var coarseCandidates: [Int] = []
            var magnitude = 2
            while magnitude <= maximumDelta {
              coarseCandidates.append(sign * magnitude)
              magnitude += Self.recoveryCoarseStepGray
            }
            guard
              let coarse = searchBands(
                previous: previousBuffer,
                current: currentBuffer,
                stripWidth: stripWidth,
                contentHeight: contentHeight,
                bandStarts: bandStarts,
                bandHeight: bandHeight,
                candidates: coarseCandidates
              ),
              let coarseDelta = coarse.delta
            else { continue }

            let refineLower = max(-maximumDelta, coarseDelta - Self.recoveryCoarseStepGray)
            let refineUpper = min(maximumDelta, coarseDelta + Self.recoveryCoarseStepGray)
            let refined = searchBands(
              previous: previousBuffer,
              current: currentBuffer,
              stripWidth: stripWidth,
              contentHeight: contentHeight,
              bandStarts: bandStarts,
              bandHeight: bandHeight,
              candidates: Array(refineLower ... refineUpper)
            )

            if let refined, isBetter(refined, than: recoveryBest) {
              recoveryBest = refined
            }
            if isAcceptable(recoveryBest) {
              break
            }
          }
        }
      }

      if let recoveryBest {
        best = recoveryBest
      }
    }

    guard let result = best, let deltaGray = result.delta else { return nil }

    let subpixelGray = subpixelRefinement(
      aggregate: result.aggregate,
      bestIndex: result.aggregateBestIndex,
      candidateDeltas: result.candidateDeltas
    ) ?? Double(deltaGray)

    let deltaX = previousCompact.withUnsafeBufferPointer { previousBuffer in
      currentCompact.withUnsafeBufferPointer { currentBuffer in
        estimateHorizontalShift(
          previous: previousBuffer,
          current: currentBuffer,
          stripWidth: stripWidth,
          bandStarts: result.confidentBandStarts,
          bandHeight: bandHeight,
          deltaGray: deltaGray,
          contentHeight: contentHeight,
          fullResScale: scale
        )
      }
    }

    return ScrollingCaptureMotionResult(
      deltaY: subpixelGray * scale,
      deltaX: deltaX,
      confidence: result.confidence,
      peakCorrelation: result.peakCorrelation,
      peakToSecondRatio: result.peakToSecondRatio,
      confidentBandCount: result.confidentBandStarts.count,
      bandCount: bandStarts.count,
      usedRecoverySearch: usedRecoverySearch
    )
  }

  // MARK: - Private: band search

  private struct BandSearchResult {
    /// Best signed delta in gray pixels; nil when no band produced a peak.
    let delta: Int?
    let confidence: Double
    let peakCorrelation: Double
    let peakToSecondRatio: Double
    /// Starts (in compact content rows) of the bands that voted for the peak.
    let confidentBandStarts: [Int]
    let aggregate: [Double]
    let aggregateBestIndex: Int
    let candidateDeltas: [Int]
  }

  private struct BandPeak {
    let bandStart: Int
    let delta: Int
    let peak: Double
    let margin: Double
    let curve: [Double]

    var isConfident: Bool {
      peak >= ScrollingCaptureMotionTracker.minimumPeakCorrelation
        && margin >= ScrollingCaptureMotionTracker.minimumPeakMargin
    }
  }

  /// Computes a per-band NCC curve over the candidate deltas, then fuses the
  /// confident bands into one aggregate curve whose peak is the frame delta.
  private func searchBands(
    previous: UnsafeBufferPointer<Double>,
    current: UnsafeBufferPointer<Double>,
    stripWidth: Int,
    contentHeight: Int,
    bandStarts: [Int],
    bandHeight: Int,
    candidates: [Int]
  ) -> BandSearchResult? {
    guard !candidates.isEmpty, let previousBase = previous.baseAddress,
          let currentBase = current.baseAddress else { return nil }
    let sampleCount = bandHeight * stripWidth
    guard sampleCount > 0 else { return nil }

    var bandPeaks: [BandPeak] = []
    bandPeaks.reserveCapacity(bandStarts.count)

    for bandStart in bandStarts {
      // The current-frame strip is fixed per band; precompute its moments once.
      let currentStrip = currentBase + bandStart * stripWidth
      var currentSum = 0.0
      var currentSquareSum = 0.0
      vDSP_sveD(currentStrip, 1, &currentSum, vDSP_Length(sampleCount))
      vDSP_svesqD(currentStrip, 1, &currentSquareSum, vDSP_Length(sampleCount))

      var curve = [Double](repeating: -.greatestFiniteMagnitude, count: candidates.count)
      for (index, delta) in candidates.enumerated() {
        let previousStart = bandStart + delta
        guard previousStart >= 0, previousStart + bandHeight <= contentHeight else { continue }
        curve[index] = normalizedCorrelation(
          previous: previousBase + previousStart * stripWidth,
          current: currentStrip,
          sampleCount: sampleCount,
          currentSum: currentSum,
          currentSquareSum: currentSquareSum
        )
      }

      if let peak = bandPeak(from: curve, candidates: candidates, bandStart: bandStart) {
        bandPeaks.append(peak)
      }
    }

    let confidentPeaks = bandPeaks.filter(\.isConfident)
    guard !confidentPeaks.isEmpty else {
      return BandSearchResult(
        delta: nil,
        confidence: 0,
        peakCorrelation: 0,
        peakToSecondRatio: 0,
        confidentBandStarts: [],
        aggregate: [],
        aggregateBestIndex: 0,
        candidateDeltas: candidates
      )
    }

    // Median of the confident band deltas anchors the aggregate peak search.
    let sortedDeltas = confidentPeaks.map(\.delta).sorted()
    let medianDelta = sortedDeltas[sortedDeltas.count / 2]

    var aggregate = [Double](repeating: 0, count: candidates.count)
    for peak in confidentPeaks {
      for index in 0 ..< candidates.count where peak.curve[index] > -.greatestFiniteMagnitude {
        aggregate[index] += peak.curve[index]
      }
    }

    let anchorWindow = max(3, candidates.count / 12)
    guard let anchorIndex = candidates.firstIndex(of: medianDelta) else { return nil }
    let searchLower = max(0, anchorIndex - anchorWindow)
    let searchUpper = min(candidates.count - 1, anchorIndex + anchorWindow)
    var bestIndex = searchLower
    for index in searchLower ... searchUpper where aggregate[index] > aggregate[bestIndex] {
      bestIndex = index
    }

    let confidentCount = Double(confidentPeaks.count)
    let meanPeak = aggregate[bestIndex] / confidentCount
    var runnerUp = 0.0
    for index in 0 ..< candidates.count where abs(index - bestIndex) > 4 {
      runnerUp = max(runnerUp, aggregate[index] / confidentCount)
    }

    let spread = (sortedDeltas.last ?? medianDelta) - (sortedDeltas.first ?? medianDelta)
    let correlationComponent = min(1, max(0, (meanPeak - 0.35) / 0.5))
    let marginComponent = min(1, max(0, (meanPeak - runnerUp) / 0.12))
    let bandComponent = confidentCount / Double(bandStarts.count)
    let spreadComponent = min(1, max(0, 1 - Double(spread) / 8))
    let confidence = correlationComponent * 0.45
      + marginComponent * 0.25
      + bandComponent * 0.15
      + spreadComponent * 0.15

    return BandSearchResult(
      delta: candidates[bestIndex],
      confidence: confidence,
      peakCorrelation: meanPeak,
      peakToSecondRatio: meanPeak / max(runnerUp, 0.000_001),
      confidentBandStarts: confidentPeaks.map(\.bandStart),
      aggregate: aggregate,
      aggregateBestIndex: bestIndex,
      candidateDeltas: candidates
    )
  }

  private func bandPeak(from curve: [Double], candidates: [Int], bandStart: Int) -> BandPeak? {
    var bestIndex = 0
    var bestValue = -Double.greatestFiniteMagnitude
    for (index, value) in curve.enumerated() where value > bestValue {
      bestValue = value
      bestIndex = index
    }
    guard bestValue > -.greatestFiniteMagnitude else { return nil }

    let exclusionWindow = max(2, candidates.count / 6)
    var runnerUp = 0.0
    for (index, value) in curve.enumerated() where abs(index - bestIndex) > exclusionWindow {
      if value > -.greatestFiniteMagnitude {
        runnerUp = max(runnerUp, value)
      }
    }

    return BandPeak(
      bandStart: bandStart,
      delta: candidates[bestIndex],
      peak: bestValue,
      margin: bestValue - runnerUp,
      curve: curve
    )
  }

  /// Pearson correlation of two equally sized strips, with the current strip's
  /// moments precomputed by the caller.
  private func normalizedCorrelation(
    previous: UnsafePointer<Double>,
    current: UnsafePointer<Double>,
    sampleCount: Int,
    currentSum: Double,
    currentSquareSum: Double
  ) -> Double {
    var dot = 0.0
    var previousSum = 0.0
    var previousSquareSum = 0.0
    vDSP_dotprD(previous, 1, current, 1, &dot, vDSP_Length(sampleCount))
    vDSP_sveD(previous, 1, &previousSum, vDSP_Length(sampleCount))
    vDSP_svesqD(previous, 1, &previousSquareSum, vDSP_Length(sampleCount))

    let count = Double(sampleCount)
    let numerator = count * dot - previousSum * currentSum
    let previousVariance = count * previousSquareSum - previousSum * previousSum
    let currentVariance = count * currentSquareSum - currentSum * currentSum
    let denominator = previousVariance * currentVariance
    guard denominator > 0.000_001 else { return 0 }
    return numerator / sqrt(denominator)
  }

  private func isAcceptable(_ result: BandSearchResult?) -> Bool {
    guard let result, result.delta != nil else { return false }
    return result.confidence >= Self.minimumAcceptanceConfidence
      && result.peakCorrelation >= Self.minimumAcceptanceCorrelation
      && result.confidentBandStarts.count >= Self.minimumConfidentBandCount
  }

  private func isBetter(_ candidate: BandSearchResult, than current: BandSearchResult?) -> Bool {
    guard let current else { return true }
    return candidate.confidence > current.confidence
  }

  /// Parabolic interpolation of the aggregate curve around its integer peak.
  private func subpixelRefinement(
    aggregate: [Double],
    bestIndex: Int,
    candidateDeltas: [Int]
  ) -> Double? {
    guard bestIndex > 0, bestIndex < aggregate.count - 1 else { return nil }
    let lower = aggregate[bestIndex - 1]
    let center = aggregate[bestIndex]
    let upper = aggregate[bestIndex + 1]
    let denominator = lower - 2 * center + upper
    // A correlation peak is a maximum, so the curvature must be negative.
    guard denominator < 0 else { return nil }

    let offset = 0.5 * (lower - upper) / denominator
    guard abs(offset) <= 1 else { return nil }

    let step = bestIndex + 1 < candidateDeltas.count
      ? candidateDeltas[bestIndex + 1] - candidateDeltas[bestIndex]
      : 1
    guard step > 0 else { return nil }
    return Double(candidateDeltas[bestIndex]) + offset * Double(step)
  }

  /// Estimates a small horizontal drift from the strongest confident bands at
  /// the winning vertical delta. Kept deliberately narrow: real scroll drift is
  /// a few pixels, anything larger means the match should not be trusted.
  private func estimateHorizontalShift(
    previous: UnsafeBufferPointer<Double>,
    current: UnsafeBufferPointer<Double>,
    stripWidth: Int,
    bandStarts: [Int],
    bandHeight: Int,
    deltaGray: Int,
    contentHeight: Int,
    fullResScale: Double
  ) -> Int {
    let maximumShiftGray = 2
    let sampleWidth = stripWidth - maximumShiftGray * 2
    guard sampleWidth >= 24, !bandStarts.isEmpty,
          let previousBase = previous.baseAddress, let currentBase = current.baseAddress
    else { return 0 }

    let strongestBands = Array(bandStarts.prefix(2))
    var baselineCorrelation = -Double.greatestFiniteMagnitude
    var bestShift = 0
    var bestShiftCorrelation = -Double.greatestFiniteMagnitude

    // Establish the zero-shift baseline before considering non-zero offsets.
    // Evaluating negative shifts first would compare them against -infinity and
    // incorrectly retain a horizontal drift even when the aligned frame has a
    // perfect zero-shift correlation.
    let candidateShifts = [0, -1, 1, -2, 2].filter { abs($0) <= maximumShiftGray }
    for shift in candidateShifts {
      var dot = 0.0
      var previousSum = 0.0
      var previousSquareSum = 0.0
      var currentSum = 0.0
      var currentSquareSum = 0.0
      var sampleCount = 0

      for bandStart in strongestBands {
        let previousStart = bandStart + deltaGray
        guard previousStart >= 0, previousStart + bandHeight <= contentHeight else { continue }

        for row in 0 ..< bandHeight {
          let previousRow = previousBase + (previousStart + row) * stripWidth + maximumShiftGray + shift
          let currentRow = currentBase + (bandStart + row) * stripWidth + maximumShiftGray
          var rowDot = 0.0
          var rowPreviousSum = 0.0
          var rowPreviousSquareSum = 0.0
          var rowCurrentSum = 0.0
          var rowCurrentSquareSum = 0.0
          vDSP_dotprD(previousRow, 1, currentRow, 1, &rowDot, vDSP_Length(sampleWidth))
          vDSP_sveD(previousRow, 1, &rowPreviousSum, vDSP_Length(sampleWidth))
          vDSP_svesqD(previousRow, 1, &rowPreviousSquareSum, vDSP_Length(sampleWidth))
          vDSP_sveD(currentRow, 1, &rowCurrentSum, vDSP_Length(sampleWidth))
          vDSP_svesqD(currentRow, 1, &rowCurrentSquareSum, vDSP_Length(sampleWidth))
          dot += rowDot
          previousSum += rowPreviousSum
          previousSquareSum += rowPreviousSquareSum
          currentSum += rowCurrentSum
          currentSquareSum += rowCurrentSquareSum
          sampleCount += sampleWidth
        }
      }

      let count = Double(sampleCount)
      guard count > 0 else { continue }
      let numerator = count * dot - previousSum * currentSum
      let denominator = (count * previousSquareSum - previousSum * previousSum)
        * (count * currentSquareSum - currentSum * currentSum)
      guard denominator > 0.000_001 else { continue }
      let correlation = numerator / sqrt(denominator)

      if shift == 0 {
        baselineCorrelation = correlation
      } else if baselineCorrelation > -Double.greatestFiniteMagnitude,
                correlation > baselineCorrelation + Self.horizontalShiftImprovement,
                correlation > bestShiftCorrelation {
        bestShiftCorrelation = correlation
        bestShift = shift
      }
    }

    let shiftPixels = Int((Double(bestShift) * fullResScale).rounded())
    return min(Self.maximumHorizontalShiftPixels, max(-Self.maximumHorizontalShiftPixels, shiftPixels))
  }

  // MARK: - Private: static bands

  private func detectStaticEdgeRows(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame,
    fromTop: Bool
  ) -> Int {
    let height = previous.height
    let cap = min(
      height / 5,
      max(8, Int((Self.maximumStaticHeaderFooterPixels / previous.fullResScale).rounded()))
    )
    let step = max(1, height / 256)
    let xInset = max(8, previous.width / 18)
    let xStart = xInset
    let xEnd = previous.width - xInset
    let columnStride = max(1, (xEnd - xStart) / 44)
    guard xEnd > xStart else { return 0 }

    var detected = 0
    var sawMovingContent = false

    for offset in stride(from: 0, to: cap, by: step) {
      let row = fromTop ? offset : height - 1 - offset
      let difference = rowMeanDifference(
        previous: previous,
        current: current,
        row: row,
        xStart: xStart,
        xEnd: xEnd,
        columnStride: columnStride
      )

      if difference < Self.staticBandDifferenceThreshold {
        detected = offset + step
      } else {
        sawMovingContent = true
        if offset >= step * 2 {
          break
        }
      }
    }

    // When every sampled row matched, the frame is stationary rather than
    // sticky; claiming a maximal band would only shrink the content area.
    return sawMovingContent ? detected : 0
  }

  private func detectStaticSideColumns(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame,
    fromLeading: Bool
  ) -> Int {
    let width = previous.width
    let cap = min(
      width / 6,
      max(4, Int((Self.maximumStaticSidePixels / previous.fullResScale).rounded()))
    )
    let step = max(1, width / 256)
    let yInset = max(10, previous.height / 16)
    let yStart = yInset
    let yEnd = previous.height - yInset
    guard yEnd - yStart > 24 else { return 0 }

    var detected = 0
    var sawMovingContent = false

    for bandWidth in stride(from: step, through: cap, by: step) {
      let xStart = fromLeading ? 0 : width - bandWidth
      let xEnd = fromLeading ? bandWidth : width

      var total = 0
      var count = 0
      for row in stride(from: yStart, to: yEnd, by: 2) {
        let rowOffset = row * width
        for x in stride(from: xStart, to: xEnd, by: 2) {
          total += abs(Int(previous.pixels[rowOffset + x]) - Int(current.pixels[rowOffset + x]))
          count += 1
        }
      }
      let difference = count > 0 ? Double(total) / Double(count) : 255

      if difference < Self.staticBandDifferenceThreshold {
        detected = bandWidth
      } else {
        sawMovingContent = true
        if bandWidth >= step * 3 {
          break
        }
      }
    }

    return sawMovingContent ? detected : 0
  }

  private func rowMeanDifference(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame,
    row: Int,
    xStart: Int,
    xEnd: Int,
    columnStride: Int
  ) -> Double {
    var total = 0
    var count = 0
    let rowOffset = row * previous.width
    for x in stride(from: xStart, to: xEnd, by: columnStride) {
      total += abs(Int(previous.pixels[rowOffset + x]) - Int(current.pixels[rowOffset + x]))
      count += 1
    }
    return count > 0 ? Double(total) / Double(count) : 255
  }

  // MARK: - Private: helpers

  private func compactContent(
    of frame: ScrollingCaptureGrayFrame,
    contentTop: Int,
    contentHeight: Int,
    xStart: Int,
    stripWidth: Int
  ) -> [Double] {
    var compact = [Double](repeating: 0, count: contentHeight * stripWidth)
    frame.floats.withUnsafeBufferPointer { source in
      compact.withUnsafeMutableBufferPointer { destination in
        guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
        for row in 0 ..< contentHeight {
          (destinationBase + row * stripWidth).update(
            from: sourceBase + (contentTop + row) * frame.width + xStart,
            count: stripWidth
          )
        }
      }
    }
    return compact
  }

  /// FNV-1a over strided samples; a match means the frames are visually identical.
  private func fingerprint(of pixels: [UInt8]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    let strideLength = max(1, pixels.count / 512)
    var index = 0
    while index < pixels.count {
      hash = (hash ^ UInt64(pixels[index])) &* 0x0000_0100_0000_01b3
      index += strideLength
    }
    return hash
  }
}
