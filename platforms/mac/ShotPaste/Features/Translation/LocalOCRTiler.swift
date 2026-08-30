//
//  LocalOCRTiler.swift
//  ShotPaste
//
//  Native-resolution, in-memory tiling and coordinate conversion for local
//  Vision OCR. Nothing in this file serializes or uploads a tile.
//

import CoreGraphics
import Foundation

nonisolated enum LocalOCRTiler {
  /// A 2560-pixel tile keeps Vision's working set bounded while retaining
  /// enough context for ordinary 4K/5K UI text.
  static let maximumTileDimension = 2_560
  static let overlapPixels = 96
  static let maximumTileCount = 32

  /// A generous guard for a captured display. This is a pixel-count limit,
  /// not a request-size limit; the pixels remain local throughout OCR.
  static let maximumPixelCount = 120_000_000

  /// Creates native-resolution crops while observing the caller's absolute
  /// deadline. The image is already frozen; this method never captures or
  /// serializes pixels.
  static func tiles(for image: CGImage, deadline: Date) throws -> [LocalOCRTile] {
    try TranslationOCRDeadline.check(deadline)
    guard image.width > 0, image.height > 0 else {
      throw TranslationFailure.captureFailed
    }
    guard image.width <= Int.max / max(image.height, 1),
          image.width * image.height <= maximumPixelCount
    else {
      throw TranslationFailure.inputTooLarge
    }

    let xOrigins = try origins(forLength: image.width, deadline: deadline)
    let yOrigins = try origins(forLength: image.height, deadline: deadline)
    guard xOrigins.count <= maximumTileCount,
          yOrigins.count <= maximumTileCount,
          xOrigins.count <= maximumTileCount / max(yOrigins.count, 1),
          xOrigins.count * yOrigins.count <= maximumTileCount else {
      throw TranslationFailure.inputTooLarge
    }

    var result: [LocalOCRTile] = []
    result.reserveCapacity(xOrigins.count * yOrigins.count)
    var index = 0
    for y in yOrigins {
      for x in xOrigins {
        try TranslationOCRDeadline.check(deadline)
        let width = min(maximumTileDimension, image.width - x)
        let height = min(maximumTileDimension, image.height - y)
        guard width > 0, height > 0 else { continue }
        let pixelRect = CGRect(x: x, y: y, width: width, height: height)
        guard let tileImage = image.cropping(to: pixelRect) else {
          throw TranslationFailure.captureFailed
        }
        result.append(LocalOCRTile(id: "ocr-tile-\(index)", pixelRect: pixelRect, image: tileImage))
        index += 1
      }
    }

    try TranslationOCRDeadline.check(deadline)
    guard !result.isEmpty else { throw TranslationFailure.captureFailed }
    return result
  }

  static func makeTiles(for image: CGImage, deadline: Date) throws -> [LocalOCRTile] {
    try tiles(for: image, deadline: deadline)
  }

  /// Converts Vision's bottom-left normalized rectangle to top-left pixel
  /// coordinates relative to a tile. Bounds are clipped instead of enlarged.
  static func topLeftPixelRect(
    fromVisionBounds bounds: CGRect,
    tilePixelSize: CGSize
  ) -> CGRect? {
    guard tilePixelSize.width.isFinite, tilePixelSize.height.isFinite,
          tilePixelSize.width > 0, tilePixelSize.height > 0,
          bounds.minX.isFinite, bounds.minY.isFinite,
          bounds.maxX.isFinite, bounds.maxY.isFinite,
          bounds.width > 0, bounds.height > 0,
          bounds.maxX > 0, bounds.minX < 1,
          bounds.maxY > 0, bounds.minY < 1
    else { return nil }

    // Clamp the rectangle as a rectangle, not its origin and size
    // independently. Independent clamping turns a wholly out-of-range box
    // such as x=-0.1,width=0.1 into a false one-pixel observation.
    let minX = max(bounds.minX, 0)
    let maxX = min(bounds.maxX, 1)
    let minY = max(bounds.minY, 0)
    let maxY = min(bounds.maxY, 1)
    guard maxX > minX, maxY > minY else { return nil }

    let rect = CGRect(
      x: minX * tilePixelSize.width,
      y: (1 - maxY) * tilePixelSize.height,
      width: (maxX - minX) * tilePixelSize.width,
      height: (maxY - minY) * tilePixelSize.height
    ).standardized
    guard rect.width > 0, rect.height > 0 else { return nil }
    let result = rect.intersection(CGRect(origin: .zero, size: tilePixelSize))
    return result.width > 0 && result.height > 0 ? result : nil
  }

  /// Converts a tile-local Vision observation to full-image top-left pixels.
  static func fullImagePixelRect(
    fromVisionBounds bounds: CGRect,
    in tile: LocalOCRTile
  ) -> CGRect? {
    guard let local = topLeftPixelRect(
      fromVisionBounds: bounds,
      tilePixelSize: CGSize(width: tile.image.width, height: tile.image.height)
    ) else { return nil }
    return local.offsetBy(dx: tile.pixelRect.minX, dy: tile.pixelRect.minY)
  }

  /// Maps top-left image pixels to AppKit global screen coordinates. The image
  /// can be a Retina capture and `screenRect` can have negative coordinates.
  static func screenRect(
    fromTopLeftPixelRect pixelRect: CGRect,
    imagePixelSize: CGSize,
    screenRect: CGRect
  ) -> CGRect? {
    guard imagePixelSize.width.isFinite, imagePixelSize.height.isFinite,
          imagePixelSize.width > 0, imagePixelSize.height > 0,
          screenRect.minX.isFinite, screenRect.minY.isFinite,
          screenRect.maxX.isFinite, screenRect.maxY.isFinite,
          screenRect.width > 0, screenRect.height > 0,
          pixelRect.minX.isFinite, pixelRect.minY.isFinite,
          pixelRect.maxX.isFinite, pixelRect.maxY.isFinite,
          pixelRect.width.isFinite, pixelRect.height.isFinite,
          pixelRect.width > 0, pixelRect.height > 0
    else { return nil }

    let imageBounds = CGRect(origin: .zero, size: imagePixelSize)
    let clipped = pixelRect.intersection(imageBounds)
    guard clipped.width > 0, clipped.height > 0 else { return nil }

    // Pixel y=0 is the top edge, whereas AppKit y=0 is the bottom edge.
    let mapped = CGRect(
      x: screenRect.minX + clipped.minX / imagePixelSize.width * screenRect.width,
      y: screenRect.maxY - clipped.maxY / imagePixelSize.height * screenRect.height,
      width: clipped.width / imagePixelSize.width * screenRect.width,
      height: clipped.height / imagePixelSize.height * screenRect.height
    ).standardized
    let result = mapped.intersection(screenRect)
    return result.width > 0 && result.height > 0 ? result : nil
  }

  /// Converts an executor observation into a full-image OCR line.
  static func line(
    from observation: TranslationOCRObservation,
    in tile: LocalOCRTile
  ) -> TranslationOCRLine? {
    let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty,
          observation.confidence.isFinite,
          (0 ... 1).contains(observation.confidence),
          let pixelBounds = fullImagePixelRect(fromVisionBounds: observation.visionBounds, in: tile)
    else { return nil }

    let direction = observation.direction ?? inferDirection(
      text: text,
      pixelBounds: pixelBounds
    )
    return TranslationOCRLine(
      text: text,
      pixelBounds: pixelBounds,
      confidence: observation.confidence,
      direction: direction,
      recognitionLanguageHints: observation.recognitionLanguageHints,
      sourceTileID: tile.id
    )
  }

  /// Deduplicates only equal normalized text whose geometry overlaps. Equal
  /// labels in different buttons therefore remain separate lines.
  /// Deduplicates in deterministic geometry order so tile completion order
  /// cannot change the eventual block IDs or the selected equal-confidence
  /// observation.
  static func deduplicated(
    _ lines: [TranslationOCRLine],
    intersectionOverUnionThreshold: CGFloat = 0.65,
    deadline: Date
  ) throws -> [TranslationOCRLine] {
    try TranslationOCRDeadline.check(deadline)
    guard !lines.isEmpty else { return [] }
    guard lines.count <= TranslationOCRLimits.maximumOCRLines else {
      throw TranslationFailure.inputTooLarge
    }
    var retained: [TranslationOCRLine] = []
    retained.reserveCapacity(lines.count)

    var candidates: [TranslationOCRLine] = []
    candidates.reserveCapacity(lines.count)
    var totalCharacters = 0
    for line in lines {
      try TranslationOCRDeadline.check(deadline)
      let characterCount = line.text.utf8.count
      guard characterCount <= TranslationOCRLimits.maximumTextCharacters - totalCharacters else {
        throw TranslationFailure.inputTooLarge
      }
      totalCharacters += characterCount
      if !line.normalizedText.isEmpty {
        candidates.append(line)
      }
    }
    candidates.sort(by: stableLineOrder)
    for candidate in candidates {
      try TranslationOCRDeadline.check(deadline)
      guard !candidate.normalizedText.isEmpty else { continue }
      var duplicateIndex: Int?
      for index in retained.indices {
        try TranslationOCRDeadline.check(deadline)
        let existing = retained[index]
        guard existing.normalizedText == candidate.normalizedText else { continue }
        if intersectionOverUnion(existing.pixelBounds, candidate.pixelBounds)
          >= intersectionOverUnionThreshold {
          duplicateIndex = index
          break
        }
      }
      if let duplicateIndex {
        let existing = retained[duplicateIndex]
        if candidate.confidence > existing.confidence
          || (candidate.confidence == existing.confidence && isStablePredecessor(candidate, of: existing)) {
          retained[duplicateIndex] = candidate
        }
      } else {
        retained.append(candidate)
      }
    }
    try TranslationOCRDeadline.check(deadline)
    return retained.sorted(by: stableLineOrder)
  }

  static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return 0 }
    let intersection = lhs.intersection(rhs)
    guard intersection.width > 0, intersection.height > 0 else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    guard unionArea > 0 else { return 0 }
    return intersectionArea / unionArea
  }

  /// Advances by exactly one tile minus the intended overlap. The last tile
  /// is allowed to be narrower than the maximum dimension; anchoring it to
  /// `length - maximumTileDimension` would turn a small remainder (notably a
  /// 5K edge) into a multi-thousand-pixel duplicate region.
  static func origins(forLength length: Int, deadline: Date) throws -> [Int] {
    try TranslationOCRDeadline.check(deadline)
    guard length > 0 else { return [] }
    guard length > maximumTileDimension else { return [0] }
    let step = max(1, maximumTileDimension - overlapPixels)
    var result = [0]
    // When the previous tile already reaches the end exactly, do not append a
    // duplicate tail whose only purpose would be to repeat the configured
    // overlap.  A narrow tail is needed only when the end remains uncovered.
    while let last = result.last, last < length - maximumTileDimension {
      try TranslationOCRDeadline.check(deadline)
      guard result.count < maximumTileCount,
            last <= Int.max - step else {
        throw TranslationFailure.inputTooLarge
      }
      let next = last + step
      guard next > last else { break }
      result.append(next)
    }
    return result
  }

  private static func stableLineOrder(
    _ lhs: TranslationOCRLine,
    _ rhs: TranslationOCRLine
  ) -> Bool {
    let left = lhs.pixelBounds
    let right = rhs.pixelBounds
    if left.minY != right.minY { return left.minY < right.minY }
    if left.minX != right.minX { return left.minX < right.minX }
    if left.width != right.width { return left.width < right.width }
    if left.height != right.height { return left.height < right.height }
    if lhs.normalizedText != rhs.normalizedText {
      return lhs.normalizedText < rhs.normalizedText
    }
    if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
    return lhs.sourceTileID < rhs.sourceTileID
  }

  private static func inferDirection(text: String, pixelBounds: CGRect) -> TranslationTextDirection {
    guard pixelBounds.height > pixelBounds.width * 1.45,
          !text.contains(where: { $0.isWhitespace }),
          text.count >= 2
    else { return .horizontal }
    return .vertical
  }

  private static func isStablePredecessor(
    _ candidate: TranslationOCRLine,
    of existing: TranslationOCRLine
  ) -> Bool {
    if candidate.pixelBounds.minY != existing.pixelBounds.minY {
      return candidate.pixelBounds.minY < existing.pixelBounds.minY
    }
    if candidate.pixelBounds.minX != existing.pixelBounds.minX {
      return candidate.pixelBounds.minX < existing.pixelBounds.minX
    }
    return candidate.sourceTileID < existing.sourceTileID
  }
}
