//
//  TranslationLayoutResolver.swift
//  ShotPaste
//
//  Local overlay layout. It consumes OCR-owned screen bounds and translated
//  strings keyed by stable IDs; no provider geometry is accepted.
//

import CoreGraphics
import Foundation

nonisolated struct TranslationLayoutResolver: Sendable {
  static let minimumFontSize: CGFloat = 11
  static let maximumFontSize: CGFloat = 42
  static let overlapPadding: CGFloat = 2

  init() {}

  func resolve(
    _ inputs: [TranslationLayoutInput],
    inside clipRect: CGRect,
    backgroundLuminanceByID: [String: CGFloat] = [:],
    deadline: Date
  ) throws -> [TranslationLayoutItem] {
    try TranslationOCRDeadline.check(deadline)
    guard clipRect.width > 0, clipRect.height > 0 else { return [] }
    guard inputs.count <= TranslationOCRLimits.maximumTextBlocks else {
      throw TranslationFailure.inputTooLarge
    }
    var filtered: [TranslationLayoutInput] = []
    filtered.reserveCapacity(inputs.count)
    var totalCharacters = 0
    for input in inputs {
      try TranslationOCRDeadline.check(deadline)
      let effectiveText = input.block.preserveOriginal
        ? input.block.sourceText
        : input.translatedText
      let text = effectiveText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let characterCount = text.utf8.count
      guard characterCount <= TranslationOCRLimits.maximumTextCharacters - totalCharacters else {
        throw TranslationFailure.inputTooLarge
      }
      totalCharacters += characterCount
      filtered.append(TranslationLayoutInput(block: input.block, translatedText: effectiveText))
    }
    let sorted = filtered.sorted(by: readingOrder)
    var placed: [TranslationLayoutItem] = []
    placed.reserveCapacity(sorted.count)

    for input in sorted {
      try TranslationOCRDeadline.check(deadline)
      let block = input.block
      let original = preferredFrame(
        for: block.screenBounds,
        inside: clipRect,
        direction: block.direction
      )
      guard original.width > 0, original.height > 0 else { continue }
      var occupiedFrames: [CGRect] = []
      occupiedFrames.reserveCapacity(placed.count)
      for placedItem in placed {
        try TranslationOCRDeadline.check(deadline)
        occupiedFrames.append(placedItem.screenBounds)
      }
      let frame = try findFrame(
        preferred: original,
        clipRect: clipRect,
        occupied: occupiedFrames,
        direction: block.direction,
        deadline: deadline
      )
      let luminance = backgroundLuminanceByID[block.id] ?? 0
      let size = fontSize(for: input.translatedText, frame: frame, direction: block.direction)
      placed.append(
        TranslationLayoutItem(
          id: block.id,
          sourceText: block.sourceText,
          translatedText: input.translatedText,
          screenBounds: frame,
          alignment: block.alignment,
          direction: block.direction,
          rotationDegrees: block.direction == .vertical ? 90 : 0,
          fontSize: size,
          confidence: block.confidence,
          usesLightBackground: luminance > 0.58
        )
      )
    }
    try TranslationOCRDeadline.check(deadline)
    return placed
  }

  func resolve(
    blocks: [TranslationTextBlock],
    translations: [String: String],
    inside clipRect: CGRect,
    backgroundLuminanceByID: [String: CGFloat] = [:],
    deadline: Date
  ) throws -> [TranslationLayoutItem] {
    try TranslationOCRDeadline.check(deadline)
    guard blocks.count <= TranslationOCRLimits.maximumTextBlocks else {
      throw TranslationFailure.inputTooLarge
    }
    var inputs: [TranslationLayoutInput] = []
    inputs.reserveCapacity(blocks.count)
    for block in blocks {
      try TranslationOCRDeadline.check(deadline)
      if block.preserveOriginal {
        inputs.append(TranslationLayoutInput(block: block, translatedText: block.sourceText))
      } else if let translatedText = translations[block.id] {
        inputs.append(TranslationLayoutInput(block: block, translatedText: translatedText))
      }
    }
    return try resolve(
      inputs,
      inside: clipRect,
      backgroundLuminanceByID: backgroundLuminanceByID,
      deadline: deadline
    )
  }

  private func preferredFrame(
    for bounds: CGRect,
    inside clipRect: CGRect,
    direction: TranslationTextDirection
  ) -> CGRect {
    let clipped = bounds.intersection(clipRect)
    guard direction == .vertical, clipped.width > 0, clipped.height > 0 else {
      return clipped
    }

    // The renderer rotates the drawing context around this frame. Swapping
    // width/height before rotation gives translated text its real horizontal
    // measure and avoids laying a long translation into the original narrow
    // OCR column. Fit/shift keeps the frame inside the frozen selection.
    let swapped = CGRect(
      x: clipped.midX - clipped.height / 2,
      y: clipped.midY - clipped.width / 2,
      width: clipped.height,
      height: clipped.width
    )
    return fit(swapped, inside: clipRect)
  }

  private func fit(_ frame: CGRect, inside clipRect: CGRect) -> CGRect {
    guard frame.width > 0, frame.height > 0 else { return .zero }
    var result = frame
    if result.width > clipRect.width { result.size.width = clipRect.width }
    if result.height > clipRect.height { result.size.height = clipRect.height }
    result.origin.x = min(max(result.origin.x, clipRect.minX), clipRect.maxX - result.width)
    result.origin.y = min(max(result.origin.y, clipRect.minY), clipRect.maxY - result.height)
    return result.intersection(clipRect)
  }

  private func fontSize(
    for text: String,
    frame: CGRect,
    direction: TranslationTextDirection
  ) -> CGFloat {
    let base = frame.height * 0.58
    guard direction == .vertical else {
      return min(Self.maximumFontSize, max(Self.minimumFontSize, base))
    }

    let longestLine = max(
      1,
      text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(\.count)
        .max() ?? 1
    )
    // Leave a little inset for the renderer while retaining the global
    // minimum font-size guarantee. The frame has already been swapped to
    // expose the post-rotation text width.
    let widthBound = (frame.width - 8) / CGFloat(longestLine) * 1.55
    return min(
      Self.maximumFontSize,
      max(Self.minimumFontSize, min(base * 1.35, widthBound))
    )
  }

  private func findFrame(
    preferred: CGRect,
    clipRect: CGRect,
    occupied: [CGRect],
    direction: TranslationTextDirection,
    deadline: Date
  ) throws -> CGRect {
    try TranslationOCRDeadline.check(deadline)
    var preferredIntersects = false
    for frame in occupied {
      try TranslationOCRDeadline.check(deadline)
      if frame.intersects(preferred) {
        preferredIntersects = true
        break
      }
    }
    if preferredIntersects {
      let candidates: [CGRect]
      if direction == .vertical {
        candidates = [
          preferred.offsetBy(dx: preferred.width + Self.overlapPadding, dy: 0),
          preferred.offsetBy(dx: -(preferred.width + Self.overlapPadding), dy: 0),
          preferred.offsetBy(dx: 0, dy: -(preferred.height + Self.overlapPadding)),
          preferred.offsetBy(dx: 0, dy: preferred.height + Self.overlapPadding),
        ]
      } else {
        candidates = [
          preferred.offsetBy(dx: 0, dy: -(preferred.height + Self.overlapPadding)),
          preferred.offsetBy(dx: 0, dy: preferred.height + Self.overlapPadding),
          preferred.offsetBy(dx: preferred.width + Self.overlapPadding, dy: 0),
          preferred.offsetBy(dx: -(preferred.width + Self.overlapPadding), dy: 0),
        ]
      }
      for candidate in candidates {
        try TranslationOCRDeadline.check(deadline)
        guard candidate.width > 0, candidate.height > 0,
              clipRect.contains(candidate) else { continue }
        var candidateIntersects = false
        for frame in occupied {
          try TranslationOCRDeadline.check(deadline)
          if frame.intersects(candidate) {
            candidateIntersects = true
            break
          }
        }
        if !candidateIntersects {
          return candidate
        }
      }
    }
    // If the capture is densely packed, preserve OCR geometry and only clip
    // to the selected frozen area. This is safer than moving text to another
    // block's location.
    try TranslationOCRDeadline.check(deadline)
    return preferred.intersection(clipRect)
  }

  private func readingOrder(_ lhs: TranslationLayoutInput, _ rhs: TranslationLayoutInput) -> Bool {
    let lhsBounds = lhs.block.screenBounds
    let rhsBounds = rhs.block.screenBounds
    if lhs.block.direction != rhs.block.direction {
      return lhs.block.direction == .horizontal
    }
    if lhs.block.direction == .vertical {
      if lhsBounds.minX != rhsBounds.minX { return lhsBounds.minX < rhsBounds.minX }
      if lhsBounds.maxY != rhsBounds.maxY { return lhsBounds.maxY > rhsBounds.maxY }
    } else {
      let yDelta = lhsBounds.maxY - rhsBounds.maxY
      let tolerance = max(lhsBounds.height, rhsBounds.height) * 0.35
      if abs(yDelta) > tolerance { return yDelta > 0 }
      if lhsBounds.minX != rhsBounds.minX { return lhsBounds.minX < rhsBounds.minX }
    }
    return lhs.block.id < rhs.block.id
  }
}
