//
//  TranslationTextBlockBuilder.swift
//  ShotPaste
//
//  Local paragraph grouping. Vision lines are deliberately not sent to a
//  provider one-by-one: this builder joins compatible lines and assigns stable
//  block IDs after geometry and language analysis have completed.
//

import CoreGraphics
import Foundation

nonisolated struct TranslationTextBlockBuilder: Sendable {
  let languageDetector: TranslationLanguageDetector

  init(languageDetector: TranslationLanguageDetector = TranslationLanguageDetector()) {
    self.languageDetector = languageDetector
  }

  func buildBlocks(
    from lines: [TranslationOCRLine],
    imagePixelSize: CGSize,
    screenRect: CGRect,
    sourceLanguageHint: String? = nil,
    deadline: Date
  ) throws -> [TranslationTextBlock] {
    try TranslationOCRDeadline.check(deadline)
    guard imagePixelSize.width > 0, imagePixelSize.height > 0,
          imagePixelSize.width.isFinite, imagePixelSize.height.isFinite,
          screenRect.width > 0, screenRect.height > 0,
          screenRect.minX.isFinite, screenRect.minY.isFinite,
          screenRect.maxX.isFinite, screenRect.maxY.isFinite
    else { return [] }
    guard lines.count <= TranslationOCRLimits.maximumOCRLines else {
      throw TranslationFailure.inputTooLarge
    }

    var totalCharacters = 0
    for line in lines {
      try TranslationOCRDeadline.check(deadline)
      guard Self.isValidInputLine(line) else {
        throw TranslationFailure.inputTooLarge
      }
      let characterCount = line.text.utf8.count
      guard characterCount <= TranslationOCRLimits.maximumTextCharacters - totalCharacters else {
        throw TranslationFailure.inputTooLarge
      }
      totalCharacters += characterCount
    }

    let deduplicated = try LocalOCRTiler.deduplicated(lines, deadline: deadline)
    guard !deduplicated.isEmpty else { return [] }
    var classified: [ClassifiedLine] = []
    classified.reserveCapacity(deduplicated.count)
    for line in deduplicated {
      try TranslationOCRDeadline.check(deadline)
      classified.append(ClassifiedLine(
        line: line,
        detection: try languageDetector.detect(
          line.text,
          sourceLanguageHint: sourceLanguageHint,
          recognitionLanguageHints: line.recognitionLanguageHints,
          deadline: deadline
        )
      ))
    }
    let groups = try Self.groupLines(classified, deadline: deadline)

    var blocks: [TranslationTextBlock] = []
    blocks.reserveCapacity(groups.count)
    guard groups.count <= TranslationOCRLimits.maximumTextBlocks else {
      throw TranslationFailure.inputTooLarge
    }
    var nextID = 1
    for group in groups {
      try TranslationOCRDeadline.check(deadline)
      guard let block = try Self.makeBlock(
        id: String(format: "block-%04d", nextID),
        lines: group,
        imagePixelSize: imagePixelSize,
        screenRect: screenRect,
        deadline: deadline
      ) else { continue }
      blocks.append(block)
      nextID += 1
    }
    guard blocks.count <= TranslationOCRLimits.maximumTextBlocks else {
      throw TranslationFailure.inputTooLarge
    }
    try TranslationOCRDeadline.check(deadline)
    return blocks
  }

  static func groupLines(
    _ lines: [TranslationOCRLine],
    deadline: Date
  ) throws -> [[TranslationOCRLine]] {
    try TranslationOCRDeadline.check(deadline)
    guard lines.count <= TranslationOCRLimits.maximumOCRLines else {
      throw TranslationFailure.inputTooLarge
    }
    var totalCharacters = 0
    for line in lines {
      try TranslationOCRDeadline.check(deadline)
      guard Self.isValidInputLine(line) else {
        throw TranslationFailure.inputTooLarge
      }
      let characterCount = line.text.utf8.count
      guard characterCount <= TranslationOCRLimits.maximumTextCharacters - totalCharacters else {
        throw TranslationFailure.inputTooLarge
      }
      totalCharacters += characterCount
    }
    var classified: [ClassifiedLine] = []
    classified.reserveCapacity(lines.count)
    for line in lines {
      try TranslationOCRDeadline.check(deadline)
      classified.append(ClassifiedLine(
        line: line,
        detection: try TranslationLanguageDetector().detect(
          line.text,
          recognitionLanguageHints: line.recognitionLanguageHints,
          deadline: deadline
        )
      ))
    }
    let grouped = try groupLines(classified, deadline: deadline)
    guard grouped.count <= TranslationOCRLimits.maximumTextBlocks else {
      throw TranslationFailure.inputTooLarge
    }
    var result: [[TranslationOCRLine]] = []
    result.reserveCapacity(grouped.count)
    for group in grouped {
      try TranslationOCRDeadline.check(deadline)
      var lines: [TranslationOCRLine] = []
      lines.reserveCapacity(group.count)
      for item in group {
        try TranslationOCRDeadline.check(deadline)
        lines.append(item.line)
      }
      result.append(lines)
    }
    return result
  }

  private struct ClassifiedLine: Sendable {
    let line: TranslationOCRLine
    let detection: TranslationLanguageDetection
  }

  private static func groupLines(
    _ lines: [ClassifiedLine],
    deadline: Date
  ) throws -> [[ClassifiedLine]] {
    try TranslationOCRDeadline.check(deadline)
    guard !lines.isEmpty else { return [] }
    let sorted = lines.sorted(by: readingOrder)
    let standaloneIDs = try likelyUIItemIDs(sorted, deadline: deadline)
    var groups: [[ClassifiedLine]] = []
    var current: [ClassifiedLine] = []

    for item in sorted {
      try TranslationOCRDeadline.check(deadline)
      guard let previous = current.last else {
        current = [item]
        continue
      }

      let canJoin = !standaloneIDs.contains(ObjectIdentifierKey(item.line))
        && !standaloneIDs.contains(ObjectIdentifierKey(previous.line))
        && areCompatible(previous, item)
      if canJoin {
        current.append(item)
      } else {
        groups.append(current)
        current = [item]
      }
    }
    if !current.isEmpty { groups.append(current) }
    try TranslationOCRDeadline.check(deadline)
    return groups
  }

  private static func readingOrder(_ lhs: ClassifiedLine, _ rhs: ClassifiedLine) -> Bool {
    if lhs.line.direction != rhs.line.direction {
      return lhs.line.direction == .horizontal
    }
    switch lhs.line.direction {
    case .horizontal:
      let yDelta = lhs.line.pixelBounds.minY - rhs.line.pixelBounds.minY
      let tolerance = max(lhs.line.pixelBounds.height, rhs.line.pixelBounds.height) * 0.35
      if abs(yDelta) > tolerance { return yDelta < 0 }
      if lhs.line.pixelBounds.minX != rhs.line.pixelBounds.minX {
        return lhs.line.pixelBounds.minX < rhs.line.pixelBounds.minX
      }
    case .vertical:
      if lhs.line.pixelBounds.minX != rhs.line.pixelBounds.minX {
        return lhs.line.pixelBounds.minX < rhs.line.pixelBounds.minX
      }
      if lhs.line.pixelBounds.minY != rhs.line.pixelBounds.minY {
        return lhs.line.pixelBounds.minY < rhs.line.pixelBounds.minY
      }
    }
    if lhs.line.pixelBounds.width != rhs.line.pixelBounds.width {
      return lhs.line.pixelBounds.width < rhs.line.pixelBounds.width
    }
    if lhs.line.pixelBounds.height != rhs.line.pixelBounds.height {
      return lhs.line.pixelBounds.height < rhs.line.pixelBounds.height
    }
    if lhs.line.normalizedText != rhs.line.normalizedText {
      return lhs.line.normalizedText < rhs.line.normalizedText
    }
    return lhs.line.sourceTileID < rhs.line.sourceTileID
  }

  private static func areCompatible(_ lhs: ClassifiedLine, _ rhs: ClassifiedLine) -> Bool {
    guard lhs.line.direction == rhs.line.direction,
          lhs.detection.classification == .translatable,
          rhs.detection.classification == .translatable,
          !lhs.detection.preserveOriginal,
          !rhs.detection.preserveOriginal,
          languagesCanJoin(lhs.detection.languageIdentifier, rhs.detection.languageIdentifier)
    else { return false }

    let first = lhs.line.pixelBounds
    let second = rhs.line.pixelBounds
    let firstSize = lhs.line.direction == .horizontal ? first.height : first.width
    let secondSize = rhs.line.direction == .horizontal ? second.height : second.width
    let sizeRatio = max(firstSize, secondSize) / max(min(firstSize, secondSize), 0.1)
    guard sizeRatio <= 1.75 else { return false }

    switch lhs.line.direction {
    case .horizontal:
      // Lines on the same row should not be merged; a paragraph continuation
      // is below the previous line and has a similar x origin/column.
      let verticalGap = second.minY - first.maxY
      let verticalTolerance = max(first.height, second.height) * 1.85
      guard verticalGap >= -max(first.height, second.height) * 0.18,
            verticalGap <= verticalTolerance
      else { return false }

      let xOriginDelta = abs(second.minX - first.minX)
      let columnTolerance = max(first.height * 4.0, first.width * 0.35)
      guard xOriginDelta <= columnTolerance else { return false }

      let horizontalGap: CGFloat
      if first.maxX < second.minX {
        horizontalGap = second.minX - first.maxX
      } else if second.maxX < first.minX {
        horizontalGap = first.minX - second.maxX
      } else {
        horizontalGap = 0
      }
      return horizontalGap <= max(first.height * 8, 24)
    case .vertical:
      let horizontalGap = second.minX - first.maxX
      let horizontalTolerance = max(first.width, second.width) * 1.85
      guard horizontalGap >= -max(first.width, second.width) * 0.18,
            horizontalGap <= horizontalTolerance
      else { return false }
      let yOriginDelta = abs(second.minY - first.minY)
      return yOriginDelta <= max(first.width * 4, first.height * 0.35)
    }
  }

  private static func languagesCanJoin(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, let rhs,
          let normalizedLHS = TranslationLanguageDetector.normalizedIdentifier(lhs),
          let normalizedRHS = TranslationLanguageDetector.normalizedIdentifier(rhs)
    else { return false }
    return normalizedLHS == normalizedRHS
  }

  /// Detect repeated short sibling rows (File/Edit/View, menu items, button
  /// labels) so they remain independent blocks. A three-line ordinary
  /// paragraph is not enough evidence: rows must also be tightly packed like
  /// controls, leaving normal paragraph leading (and its larger gaps) intact.
  private static func likelyUIItemIDs(
    _ lines: [ClassifiedLine],
    deadline: Date
  ) throws -> Set<ObjectIdentifierKey> {
    var result = Set<ObjectIdentifierKey>()
    var candidates: [ClassifiedLine] = []
    candidates.reserveCapacity(lines.count)
    for item in lines {
      try TranslationOCRDeadline.check(deadline)
      if item.detection.classification == .translatable,
         !item.detection.preserveOriginal,
         isShortControlLabel(item.line.text),
         !item.line.text.contains(where: { ".!?。！？".contains($0) }) {
        candidates.append(item)
      }
    }

    // `lines` is already in the one global reading order established by
    // groupLines.  Preserve that order while collecting siblings so each
    // candidate does not repeat an O(n log n) sort over the same set.
    for candidate in candidates {
      try TranslationOCRDeadline.check(deadline)
      var siblings: [ClassifiedLine] = []
      siblings.reserveCapacity(candidates.count)
      for peer in candidates {
        try TranslationOCRDeadline.check(deadline)
        guard peer.line.direction == candidate.line.direction else { continue }
        let size = max(
          candidate.line.direction == .horizontal
            ? candidate.line.pixelBounds.height
            : candidate.line.pixelBounds.width,
          0.1
        )
        let peerSize = peer.line.direction == .horizontal
          ? peer.line.pixelBounds.height
          : peer.line.pixelBounds.width
        let heightRatio = max(size, peerSize) / max(min(size, peerSize), 0.1)
        let xDelta = abs(candidate.line.pixelBounds.minX - peer.line.pixelBounds.minX)
        let yDelta = abs(candidate.line.pixelBounds.minY - peer.line.pixelBounds.minY)
        guard heightRatio <= 1.25,
              xDelta <= max(size * 0.75, 2),
              yDelta <= size * 8 else { continue }
        siblings.append(peer)
      }
      guard siblings.count >= 3 else { continue }
      var hasControlEvidence = true
      for sibling in siblings {
        try TranslationOCRDeadline.check(deadline)
        if !isControlLikeLabel(sibling.line.text) {
          hasControlEvidence = false
          break
        }
      }
      guard hasControlEvidence else { continue }
      var minimumWidth = CGFloat.greatestFiniteMagnitude
      var maximumWidth: CGFloat = 0
      for sibling in siblings {
        try TranslationOCRDeadline.check(deadline)
        let width = max(sibling.line.pixelBounds.width, 0.1)
        minimumWidth = min(minimumWidth, width)
        maximumWidth = max(maximumWidth, width)
      }
      guard maximumWidth / max(minimumWidth, 0.1) <= 1.75 else { continue }
      let size = candidate.line.direction == .horizontal
        ? max(candidate.line.pixelBounds.height, 0.1)
        : max(candidate.line.pixelBounds.width, 0.1)
      var tightlyPacked = true
      for index in 1 ..< siblings.count {
        try TranslationOCRDeadline.check(deadline)
        let previous = siblings[index - 1]
        let next = siblings[index]
        let gap = candidate.line.direction == .horizontal
          ? next.line.pixelBounds.minY - previous.line.pixelBounds.maxY
          : next.line.pixelBounds.minX - previous.line.pixelBounds.maxX
        if !(gap >= -size * 0.1 && gap <= max(size * 0.25, 2)) {
          tightlyPacked = false
          break
        }
      }
      if tightlyPacked {
        result.insert(ObjectIdentifierKey(candidate.line))
      }
    }
    try TranslationOCRDeadline.check(deadline)
    return result
  }

  private static func isShortControlLabel(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(whereSeparator: { $0.isWhitespace })
    return !trimmed.isEmpty && trimmed.count <= 20 && words.count <= 2
  }

  /// Positive control evidence used after the geometric sibling filter. A
  /// two-word ordinary prose line ("read this", "next line") is short enough
  /// to be a candidate but lacks the title-case/CJK label signal of menu rows;
  /// single short labels remain eligible for buttons and menu items.
  private static func isControlLikeLabel(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(whereSeparator: { $0.isWhitespace })
    guard isShortControlLabel(trimmed) else { return false }
    guard !words.isEmpty else { return false }
    if words.allSatisfy({ isCJKShortLabel(String($0)) }) { return true }
    if words.count == 1 {
      let token = String(words[0])
      let letters = token.filter(\.isLetter)
      guard !letters.isEmpty, token.count <= 12 else { return false }
      // A single short word is common for a button even when the product's
      // localization uses sentence case or lowercase ("save", "cancel").
      return true
    }
    return words.allSatisfy { token in
      let value = String(token)
      let letters = value.filter(\.isLetter)
      guard !letters.isEmpty else { return false }
      if letters.allSatisfy(\.isUppercase) { return true }
      return letters.first?.isUppercase == true
        && letters.dropFirst().allSatisfy { !$0.isUppercase }
    }
  }

  private static func isCJKShortLabel(_ text: String) -> Bool {
    guard !text.isEmpty, text.count <= 8 else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
      (0x3400 ... 0x4DBF).contains(scalar.value)
        || (0x4E00 ... 0x9FFF).contains(scalar.value)
        || (0xF900 ... 0xFAFF).contains(scalar.value)
    }
  }

  private static func makeBlock(
    id: String,
    lines: [ClassifiedLine],
    imagePixelSize: CGSize,
    screenRect: CGRect,
    deadline: Date
  ) throws -> TranslationTextBlock? {
    try TranslationOCRDeadline.check(deadline)
    guard !lines.isEmpty else { return nil }
    let ordered = lines.sorted(by: readingOrder)
    var pixelBounds = ordered[0].line.pixelBounds
    for item in ordered.dropFirst() {
      try TranslationOCRDeadline.check(deadline)
      pixelBounds = pixelBounds.union(item.line.pixelBounds)
    }
    guard let screenBounds = LocalOCRTiler.screenRect(
      fromTopLeftPixelRect: pixelBounds,
      imagePixelSize: imagePixelSize,
      screenRect: screenRect
    ) else { return nil }

    let direction = ordered[0].line.direction
    var sourceParts: [String] = []
    sourceParts.reserveCapacity(ordered.count)
    var totalCharacters = 0
    for item in ordered {
      try TranslationOCRDeadline.check(deadline)
      let text = item.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let characterCount = text.utf8.count
      guard characterCount <= TranslationOCRLimits.maximumTextCharacters - totalCharacters else {
        throw TranslationFailure.inputTooLarge
      }
      totalCharacters += characterCount
      sourceParts.append(text)
    }
    let sourceText = sourceParts.joined(separator: direction == .vertical ? "\n" : " ")
    guard !sourceText.isEmpty else { return nil }
    guard sourceText.utf8.count <= TranslationOCRLimits.maximumTextCharacters else {
      throw TranslationFailure.inputTooLarge
    }

    var confidence: Float = 0
    var languages: [String?] = []
    languages.reserveCapacity(ordered.count)
    var preserveOriginal = false
    var rects: [CGRect] = []
    rects.reserveCapacity(ordered.count)
    for item in ordered {
      try TranslationOCRDeadline.check(deadline)
      confidence += item.line.confidence
      languages.append(item.detection.languageIdentifier)
      preserveOriginal = preserveOriginal || item.detection.preserveOriginal
      rects.append(item.line.pixelBounds)
    }
    confidence /= Float(ordered.count)
    let language = commonLanguage(languages)
    let alignment = alignment(of: rects, in: pixelBounds)

    return TranslationTextBlock(
      id: id,
      sourceText: sourceText,
      pixelBounds: pixelBounds,
      screenBounds: screenBounds,
      direction: direction,
      alignment: alignment,
      confidence: confidence,
      detectedLanguage: language,
      preserveOriginal: preserveOriginal
    )
  }

  private static func commonLanguage(_ values: [String?]) -> String? {
    guard !values.isEmpty,
          values.allSatisfy({ TranslationLanguageDetector.normalizedIdentifier($0) != nil })
    else { return nil }
    let languages = values.compactMap(TranslationLanguageDetector.normalizedIdentifier)
    guard let first = languages.first,
          languages.allSatisfy({ $0 == first })
    else { return nil }
    return first
  }

  private static func alignment(of rects: [CGRect], in bounds: CGRect) -> TranslationTextAlignment {
    guard !rects.isEmpty, bounds.width > 0 else { return .leading }
    let leftGap = rects.map(\.minX).reduce(0, +) / CGFloat(rects.count) - bounds.minX
    let rightGap = bounds.maxX - rects.map(\.maxX).reduce(0, +) / CGFloat(rects.count)
    let centerOffset = abs(
      rects.map(\.midX).reduce(0, +) / CGFloat(rects.count) - bounds.midX
    )
    if centerOffset <= bounds.width * 0.08, leftGap > bounds.width * 0.10, rightGap > bounds.width * 0.10 {
      return .center
    }
    if rightGap < leftGap * 0.45 { return .trailing }
    return .leading
  }

  private static func isValidInputLine(_ line: TranslationOCRLine) -> Bool {
    let bounds = line.pixelBounds
    guard bounds.minX.isFinite, bounds.minY.isFinite,
          bounds.maxX.isFinite, bounds.maxY.isFinite,
          bounds.width.isFinite, bounds.height.isFinite,
          bounds.minX >= 0, bounds.minY >= 0,
          bounds.width > 0, bounds.height > 0,
          line.confidence.isFinite, (0 ... 1).contains(line.confidence)
    else { return false }

    // ObjectIdentifierKey rounds these values before converting to Int. Use
    // the checked initializer as the same representability guard so malformed
    // direct inputs fail closed instead of trapping in that key construction.
    return [bounds.minX, bounds.minY, bounds.width, bounds.height]
      .allSatisfy { Int(exactly: $0.rounded()) != nil }
  }

  /// Value key instead of an object identity so a line can remain a struct.
  private struct ObjectIdentifierKey: Hashable, Sendable {
    let text: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ line: TranslationOCRLine) {
      text = line.text
      x = Int(line.pixelBounds.minX.rounded())
      y = Int(line.pixelBounds.minY.rounded())
      width = Int(line.pixelBounds.width.rounded())
      height = Int(line.pixelBounds.height.rounded())
    }
  }
}
