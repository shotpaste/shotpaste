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
  /// A narrow image retaining original rows for final displacement precision.
  var verticalSamples: ScrollingCaptureVerticalSamples?
}

nonisolated struct ScrollingCaptureVerticalSamples {
  let width: Int
  let height: Int
  let floats: [Double]
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
  private static let maximumHorizontalShiftPixels = 8
  private static let horizontalShiftImprovement = 0.002
  private static let staticBandDifferenceThreshold = 5.0
  private static let maximumStaticSidePixels = 120.0

  private(set) var lockedDirection: ScrollingCaptureMergeDirection = .unresolved
  /// Sticky bands in gray pixels; refreshed per frame until the direction lock.
  private(set) var staticBands = ScrollingCaptureStaticBands()
  /// Reaching a scan limit proves only a lower bound on a static edge.
  /// Such a frame must not lock an incomplete crop into the canvas.
  private(set) var hasUnresolvedStaticEdges = false
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
    guard let gray = luminancePixels(from: image, width: width, height: height) else { return nil }
    var frame = ScrollingCaptureGrayFrame(
      width: width,
      height: height,
      pixels: gray,
      floats: floatingSamples(gray),
      fingerprint: fingerprint(of: gray),
      fullResScale: Double(image.width) / Double(width)
    )
    if scale < 1 {
      // Keep the vertical sampling grid at source resolution. Upscaling the
      // parabola fitted to the small image otherwise accumulates biased rows
      // over many small auto-scroll steps. Exclude the scrollbar and borders.
      let inset = image.width / 18
      guard let interior = image.cropping(to: CGRect(
        x: inset, y: 0, width: image.width - 2 * inset, height: image.height
      )), let samples = luminancePixels(from: interior, width: 128, height: image.height) else { return nil }
      frame.verticalSamples = ScrollingCaptureVerticalSamples(
        width: 128, height: image.height, floats: floatingSamples(samples)
      )
    }
    return frame
  }

  private func luminancePixels(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
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

    return gray
  }

  private func floatingSamples(_ gray: [UInt8]) -> [Double] {
    let count = gray.count
    var floats = [Double](repeating: 0, count: count)
    gray.withUnsafeBufferPointer { source in
      floats.withUnsafeMutableBufferPointer { destination in
        guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
        vDSP_vfltu8D(sourceBase, 1, destinationBase, 1, vDSP_Length(count))
      }
    }

    return floats
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

    // Scale the edge threshold with observable movement so low-contrast body
    // rows are not mistaken for fixed chrome. Keep the stationary noise floor.
    let differenceThreshold = min(
      Self.staticBandDifferenceThreshold,
      max(1.2, frameDifference(previous: previous, current: current) / 2)
    )
    let header = detectStaticEdgeRows(
      previous: previous, current: current, fromTop: true, differenceThreshold: differenceThreshold
    )
    let footer = detectStaticEdgeRows(
      previous: previous, current: current, fromTop: false, differenceThreshold: differenceThreshold
    )
    guard let header, let footer else {
      hasUnresolvedStaticEdges = true
      return
    }
    hasUnresolvedStaticEdges = false
    staticBands = ScrollingCaptureStaticBands(
      header: header,
      footer: footer,
      leading: detectStaticSideColumns(previous: previous, current: current, fromLeading: true),
      trailing: detectStaticSideColumns(previous: previous, current: current, fromLeading: false)
    )
  }

  // MARK: - Motion estimation

  /// A glass toolbar or a transparent footer can change its background while
  /// its controls remain fixed. Absolute row differences cannot identify that
  /// boundary. After measuring body motion, look for textured local structure
  /// that agrees at zero displacement and disagrees at the body displacement.
  /// Only a cluster of neighboring patches may extend an inferred edge.
  func refineStaticBands(
    previous: ScrollingCaptureGrayFrame,
    current: ScrollingCaptureGrayFrame,
    motion: ScrollingCaptureMotionResult
  ) -> Bool {
    guard !hasLockedStaticBands, previous.width == current.width,
          previous.height == current.height else { return false }
    let delta = Int((motion.deltaY / previous.fullResScale).rounded())
    guard abs(delta) >= 2 else { return false }
    let cap = previous.height / 3
    let patchWidth = 16, patchHeight = 4, rowStep = 2
    guard previous.width >= patchWidth + 16, cap >= patchHeight + rowStep else { return false }

    func fixedPatch(x: Int, y: Int) -> Bool {
      var horizontalEnergy = 0.0, verticalEnergy = 0.0
      for row in 0 ..< patchHeight {
        for column in 0 ..< patchWidth {
          let index = (y + row) * previous.width + x + column
          if column > 0 {
            let d = Double(previous.pixels[index]) - Double(previous.pixels[index - 1])
            horizontalEnergy += d * d
          }
          if row > 0 {
            let d = Double(previous.pixels[index]) - Double(previous.pixels[index - previous.width])
            verticalEnergy += d * d
          }
        }
      }
      guard horizontalEnergy >= Double((patchWidth - 1) * patchHeight) * 10,
            verticalEnergy >= Double((patchHeight - 1) * patchWidth) * 10 else { return false }

      func correlation(_ a: ScrollingCaptureGrayFrame, _ ay: Int,
                       _ b: ScrollingCaptureGrayFrame, _ by: Int) -> Double {
        var sumA = 0.0, sumB = 0.0, squareA = 0.0, squareB = 0.0, product = 0.0
        for row in 0 ..< patchHeight {
          for column in 0 ..< patchWidth {
            let va = Double(a.pixels[(ay + row) * a.width + x + column])
            let vb = Double(b.pixels[(by + row) * b.width + x + column])
            sumA += va
            sumB += vb
            squareA += va * va
            squareB += vb * vb
            product += va * vb
          }
        }
        let count = Double(patchWidth * patchHeight)
        let variance = (count * squareA - sumA * sumA) * (count * squareB - sumB * sumB)
        return variance > 0.000_001 ? (count * product - sumA * sumB) / sqrt(variance) : 0
      }

      let stationary = correlation(previous, y, current, y)
      guard stationary >= 0.94 else { return false }
      var moving = -1.0
      if y + delta >= 0, y + delta + patchHeight <= previous.height {
        moving = max(moving, correlation(previous, y + delta, current, y))
      }
      if y - delta >= 0, y - delta + patchHeight <= current.height {
        moving = max(moving, correlation(previous, y, current, y - delta))
      }
      return moving >= -0.999 && stationary > moving + 0.1
    }

    func fixedRows(in range: Range<Int>) -> [Int] {
      var rows: [Int] = []
      for y in stride(from: range.lowerBound, to: range.upperBound, by: rowStep) {
        var support = 0
        for x in stride(from: 8, through: previous.width - patchWidth - 8, by: 8) {
          if fixedPatch(x: x, y: y) {
            support += 1
          }
        }
        if support >= 2 {
          rows.append(y)
        }
      }
      // Isolated patches cannot establish a fixed edge.
      return rows.filter { rows.contains($0 - rowStep) || rows.contains($0 + rowStep) }
    }

    let headerRows = fixedRows(in: 0 ..< cap - patchHeight + 1)
    let footerRows = fixedRows(in: previous.height - cap ..< previous.height - patchHeight + 1)
    var bands = staticBands
    if let last = headerRows.last {
      let edge = last + patchHeight + 2
      if edge > bands.header + 6 {
        bands.header = edge
      }
    }
    if let first = footerRows.first {
      let edge = previous.height - first + 2
      if edge > bands.footer + 6 {
        bands.footer = edge
      }
    }
    guard bands != staticBands else { return false }
    guard bands.header <= cap, bands.footer <= cap else {
      hasUnresolvedStaticEdges = true
      return true
    }
    staticBands = bands
    return true
  }

  /// Estimates the signed vertical shift between two consecutive frames.
  /// `expectedSignedDeltaPixels` carries the scroll-event hint and
  /// `lastAcceptedDeltaPixels` the signed last accepted shift; both center the
  /// guided candidate range. Ambiguous or insufficiently supported motion is
  /// rejected even when an individual candidate can be measured.
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

    let guided = previousCompact.withUnsafeBufferPointer { previousBuffer in
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

    // A hint can prioritize a displacement, but cannot establish uniqueness:
    // an equally valid opposite-direction peak can sit outside its range.
    // Keep the dense full-range evidence, including for a successful guided fit.
    let best = previousCompact.withUnsafeBufferPointer { previousBuffer in
      currentCompact.withUnsafeBufferPointer { currentBuffer in
        searchBands(
          previous: previousBuffer,
          current: currentBuffer,
          stripWidth: stripWidth,
          contentHeight: contentHeight,
          bandStarts: bandStarts,
          bandHeight: bandHeight,
          candidates: Array(-maximumDelta ... maximumDelta)
        )
      }
    }
    let usedRecoverySearch = !isAcceptable(guided) || guided?.delta != best?.delta

    // Recovery is a search strategy, not an exemption from acceptance gates.
    // Confidence alone can exceed 0.85 with just one textured band.
    guard isAcceptable(best), let result = best, let deltaGray = result.delta else {
      return nil
    }

    let subpixelGray = subpixelRefinement(
      aggregate: result.aggregate,
      bestIndex: result.aggregateBestIndex,
      candidateDeltas: result.candidateDeltas
    ) ?? Double(deltaGray)

    let deltaY: Double
    if let previousSamples = previous.verticalSamples, let currentSamples = current.verticalSamples {
      guard let refined = refineVerticalDisplacement(
        previous: previousSamples, current: currentSamples,
        coarseDelta: subpixelGray * scale,
        grayHeight: previous.height, contentTop: contentTop,
        bandStarts: result.confidentBandStarts, bandHeight: bandHeight
      ) else { return nil }
      deltaY = refined
    } else {
      deltaY = subpixelGray * scale
    }

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
      deltaY: deltaY,
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

  /// Refines only a displacement already accepted by the full bidirectional
  /// search. This local fit cannot establish or override global uniqueness.
  private func refineVerticalDisplacement(
    previous: ScrollingCaptureVerticalSamples,
    current: ScrollingCaptureVerticalSamples,
    coarseDelta: Double,
    grayHeight: Int,
    contentTop: Int,
    bandStarts: [Int],
    bandHeight: Int
  ) -> Double? {
    guard previous.width == current.width, previous.height == current.height else { return nil }
    let scale = Double(previous.height) / Double(grayHeight)
    let radius = Int(ceil(scale)) + 1
    let center = Int(coarseDelta.rounded())
    let candidates = Array(center - radius ... center + radius)
    // Cover the complete coarse supporting strip: sparse text may occur only
    // at its end, so a fixed-height prefix can discard all useful evidence.
    let height = max(8, Int((Double(bandHeight) * scale).rounded()))
    let starts = bandStarts.map { Int((Double(contentTop + $0) * scale).rounded()) }
    let width = previous.width
    let sampleCount = height * width
    var curves: [(peak: Int, values: [Double])] = []
    previous.floats.withUnsafeBufferPointer { previousBuffer in
      current.floats.withUnsafeBufferPointer { currentBuffer in
        guard let previousBase = previousBuffer.baseAddress, let currentBase = currentBuffer.baseAddress else { return }
        for start in starts where start + height <= current.height {
          let currentStrip = currentBase + start * width
          var sum = 0.0, squareSum = 0.0
          vDSP_sveD(currentStrip, 1, &sum, vDSP_Length(sampleCount))
          vDSP_svesqD(currentStrip, 1, &squareSum, vDSP_Length(sampleCount))
          let curve = candidates.map { delta -> Double in
            let previousStart = start + delta
            guard previousStart >= 0, previousStart + height <= previous.height else { return -1 }
            return normalizedCorrelation(
              previous: previousBase + previousStart * width, current: currentStrip,
              sampleCount: sampleCount, currentSum: sum, currentSquareSum: squareSum
            )
          }
          guard let peak = curve.indices.max(by: { curve[$0] < curve[$1] }),
                curve[peak] >= Self.minimumAcceptanceCorrelation else { continue }
          curves.append((peak, curve))
        }
      }
    }
    guard curves.count >= Self.minimumConfidentBandCount else { return nil }
    let peaks = curves.map(\.peak).sorted()
    let median = peaks[peaks.count / 2]
    let consistent = curves.filter { abs($0.peak - median) <= 1 }
    guard consistent.count >= Self.minimumConfidentBandCount else { return nil }
    let aggregate = candidates.indices.map { index in
      consistent.reduce(0.0) { $0 + $1.values[index] } / Double(consistent.count)
    }
    guard let best = aggregate.indices.max(by: { aggregate[$0] < aggregate[$1] }),
          best > 0, best < candidates.count - 1 else { return nil }
    // Pixel-exact overlap has no fractional displacement. Interpolating even
    // that peak introduces a small content-dependent bias on every frame.
    if aggregate[best] >= 0.9999 {
      return Double(candidates[best])
    }
    return subpixelRefinement(aggregate: aggregate, bestIndex: best, candidateDeltas: candidates)
      ?? Double(candidates[best])
  }

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
      // Horizontal outlines repeated on every row cannot constrain vertical
      // motion and must not manufacture either a winner or a competing peak.
      var verticalEnergy = 0.0
      for index in stripWidth ..< sampleCount {
        let difference = currentStrip[index] - currentStrip[index - stripWidth]
        verticalEnergy += difference * difference
      }
      guard verticalEnergy / Double(sampleCount - stripWidth) >= 1 else { continue }
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

    // Newly exposed bands have no true overlap and may vote for unrelated
    // locations. Choose a coherent cluster before taking its median; four
    // unrelated outliers must not erase three near-exact agreeing strips.
    let clusters = confidentPeaks.map { peak in
      confidentPeaks.filter { abs($0.delta - peak.delta) <= 2 }
    }.filter { $0.count >= Self.minimumConfidentBandCount }
    guard let cluster = clusters.max(by: { lhs, rhs in
      let left = lhs.map(\.peak).reduce(0, +) / Double(lhs.count)
      let right = rhs.map(\.peak).reduce(0, +) / Double(rhs.count)
      return left == right ? lhs.count < rhs.count : left < right
    }) else { return nil }
    let sortedDeltas = cluster.map(\.delta).sorted()
    let medianDelta = sortedDeltas[sortedDeltas.count / 2]
    // Fixed controls can be a perfect zero-shift fit while noisy body bands
    // still establish real movement. Their lower correlation must not turn
    // that conflicting observation into a confirmed stationary boundary.
    if abs(medianDelta) <= 1, clusters.contains(where: { alternative in
      alternative.filter {
        abs($0.delta) > 4 && $0.peak >= Self.minimumAcceptanceCorrelation
      }.count >= Self.minimumConfidentBandCount
    }) {
      return nil
    }
    let consistentPeaks = cluster.filter { abs($0.delta - medianDelta) <= 2 }

    var aggregate = [Double](repeating: 0, count: candidates.count)
    for peak in consistentPeaks {
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

    let confidentCount = Double(consistentPeaks.count)
    let meanPeak = aggregate[bestIndex] / confidentCount
    // Another displacement supported by enough bands is ambiguous even when
    // those bands do not belong to the winning cluster. Include non-unique
    // bands here: a band with two exact peaks still supports both hypotheses.
    let competingThreshold = max(Self.minimumAcceptanceCorrelation, meanPeak - Self.minimumPeakMargin)
    for index in candidates.indices where abs(candidates[index] - candidates[bestIndex]) > 4 {
      let support = bandPeaks.lazy.filter { $0.curve[index] >= competingThreshold }.count
      if support >= Self.minimumConfidentBandCount {
        return nil
      }
    }
    var runnerUp = 0.0
    for index in 0 ..< candidates.count where abs(index - bestIndex) > 4 {
      runnerUp = max(runnerUp, aggregate[index] / confidentCount)
    }

    let consistentDeltas = consistentPeaks.map(\.delta)
    let spread = (consistentDeltas.max() ?? medianDelta) - (consistentDeltas.min() ?? medianDelta)
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
      confidentBandStarts: consistentPeaks.map(\.bandStart),
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
    fromTop: Bool,
    differenceThreshold: Double
  ) -> Int? {
    let height = previous.height
    // Use the same geometric limit as strip extraction. A fixed 160 full-res
    // pixel limit can end inside a Retina toolbar/footer before finding motion.
    let cap = height / 3
    let xInset = max(8, previous.width / 18)
    let xStart = xInset
    let xEnd = previous.width - xInset
    let columnStride = max(1, (xEnd - xStart) / 44)
    guard xEnd > xStart else { return nil }

    var movingStart: Int?
    // A single changed outer row can be a shadow/capture artifact. Require a
    // short run of motion, with lookahead beyond the maximum legal crop.
    for offset in 0 ... min(height - 1, cap + 2) {
      let row = fromTop ? offset : height - 1 - offset
      let difference = rowMeanDifference(
        previous: previous,
        current: current,
        row: row,
        xStart: xStart,
        xEnd: xEnd,
        columnStride: columnStride
      )

      if difference >= differenceThreshold {
        if movingStart == nil {
          movingStart = offset
        }
        if let movingStart, movingStart <= cap, offset - movingStart >= 2 {
          return movingStart
        }
      } else {
        movingStart = nil
      }
    }

    // The body can move while every edge sample remains fixed. Neither zero
    // nor the cap is a proven boundary; reject and retry against the same base.
    return nil
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
