//
//  TranslationOCRModels.swift
//  ShotPaste
//
//  Session-only value types shared by the local OCR pipeline and the text
//  translation integration.  These types deliberately contain no image
//  encoding or provider response fields.  In particular, a text block's
//  geometry is produced locally and is never a provider input/output field.
//

import CoreGraphics
import Foundation

/// The two layout directions currently supported by the local OCR pipeline.
/// Vision reports normalized rectangles but not a useful semantic direction,
/// so vertical text is classified locally from the observed geometry.
nonisolated enum TranslationTextDirection: String, Codable, CaseIterable, Sendable {
  case horizontal
  case vertical
}

/// A single Vision OCR observation after it has been mapped into the full
/// frozen image. `pixelBounds` always uses a top-left origin.
nonisolated struct TranslationOCRLine: Equatable, Sendable {
  let text: String
  let pixelBounds: CGRect
  let confidence: Float
  let direction: TranslationTextDirection
  /// Hints used to configure the Vision request. Vision does not expose a
  /// language for every individual observation, so these are retained as
  /// local evidence and are not treated as authoritative detection.
  let recognitionLanguageHints: [String]
  let sourceTileID: String

  init(
    text: String,
    pixelBounds: CGRect,
    confidence: Float,
    direction: TranslationTextDirection = .horizontal,
    recognitionLanguageHints: [String] = [],
    sourceTileID: String = ""
  ) {
    self.text = text
    self.pixelBounds = pixelBounds
    self.confidence = confidence
    self.direction = direction
    self.recognitionLanguageHints = recognitionLanguageHints
    self.sourceTileID = sourceTileID
  }

  var normalizedText: String {
    TranslationOCRTextNormalization.normalized(text)
  }
}

/// The normalized observation returned by an OCR executor. `visionBounds`
/// mirrors `VNRectangleObservation.boundingBox`: x/y/width/height are in
/// [0, 1] and the origin is bottom-left.
nonisolated struct TranslationOCRObservation: Equatable, Sendable {
  let text: String
  let confidence: Float
  let visionBounds: CGRect
  let recognitionLanguageHints: [String]
  let direction: TranslationTextDirection?

  init(
    text: String,
    confidence: Float,
    visionBounds: CGRect,
    recognitionLanguageHints: [String] = [],
    direction: TranslationTextDirection? = nil
  ) {
    self.text = text
    self.confidence = confidence
    self.visionBounds = visionBounds
    self.recognitionLanguageHints = recognitionLanguageHints
    self.direction = direction
  }
}

/// A locally resolved paragraph. `pixelBounds` is retained for layout and
/// diagnostics while `screenBounds` is ready for an AppKit overlay. Both are
/// derived from the frozen image and never from a provider response.
nonisolated struct TranslationTextBlock: Identifiable, Equatable, Sendable {
  let id: String
  let sourceText: String
  let pixelBounds: CGRect
  let screenBounds: CGRect
  let direction: TranslationTextDirection
  let alignment: TranslationTextAlignment
  let confidence: Float
  let detectedLanguage: String?
  let preserveOriginal: Bool

  init(
    id: String,
    sourceText: String,
    pixelBounds: CGRect,
    screenBounds: CGRect,
    direction: TranslationTextDirection,
    alignment: TranslationTextAlignment,
    confidence: Float,
    detectedLanguage: String?,
    preserveOriginal: Bool = false
  ) {
    self.id = id
    self.sourceText = sourceText
    self.pixelBounds = pixelBounds
    self.screenBounds = screenBounds
    self.direction = direction
    self.alignment = alignment
    self.confidence = confidence
    self.detectedLanguage = detectedLanguage
    self.preserveOriginal = preserveOriginal
  }
}

/// Frozen input to the local OCR pipeline. The image is the already captured
/// snapshot (or a crop of that snapshot); this type has no screen-capture API.
nonisolated struct TranslationOCRRequest: Sendable {
  let image: CGImage
  /// AppKit global coordinates (bottom-left origin) occupied by `image`.
  let screenRect: CGRect
  /// `nil` means automatic language selection. When present, this is passed to
  /// Vision as a recognition-language hint and retained as a detector hint.
  let sourceLanguageIdentifier: String?
  let deadline: Date

  init(
    image: CGImage,
    screenRect: CGRect,
    sourceLanguageIdentifier: String? = nil,
    deadline: Date
  ) {
    self.image = image
    self.screenRect = screenRect
    self.sourceLanguageIdentifier = sourceLanguageIdentifier
    self.deadline = deadline
  }
}

/// Complete local OCR output. `detectedLanguage` is only a local hint for the
/// text provider; it is not an OCR or provider log payload.
nonisolated struct TranslationOCRResult: Equatable, Sendable {
  let lines: [TranslationOCRLine]
  let blocks: [TranslationTextBlock]
  let detectedLanguage: String?
  let imagePixelSize: CGSize
  let screenRect: CGRect
  let lowConfidenceLineCount: Int
}

/// Injected executor seam used by tests and by future offline OCR engines.
/// Implementations must never upload `tile.image`.
nonisolated protocol TranslationOCRExecutor: Sendable {
  func recognize(
    tile: LocalOCRTile,
    sourceLanguageIdentifier: String?,
    deadline: Date
  ) async throws -> [TranslationOCRObservation]
}

/// A local OCR tile. The tile's image is an in-memory crop and its rectangle
/// is in full-image pixel coordinates with a top-left origin.
nonisolated struct LocalOCRTile: Sendable {
  let id: String
  let pixelRect: CGRect
  let image: CGImage

  init(id: String, pixelRect: CGRect, image: CGImage) {
    self.id = id
    self.pixelRect = pixelRect
    self.image = image
  }
}

/// Layout input/output types intentionally carry translated text separately
/// from the OCR block. This makes it impossible for a provider coordinate to
/// enter layout resolution accidentally.
nonisolated struct TranslationLayoutInput: Equatable, Sendable {
  let block: TranslationTextBlock
  let translatedText: String

  init(block: TranslationTextBlock, translatedText: String) {
    self.block = block
    self.translatedText = translatedText
  }
}

nonisolated struct TranslationLayoutItem: Identifiable, Equatable, Sendable {
  let id: String
  let sourceText: String
  let translatedText: String
  let screenBounds: CGRect
  let alignment: TranslationTextAlignment
  let direction: TranslationTextDirection
  let rotationDegrees: Double
  let fontSize: CGFloat
  let confidence: Float
  let usesLightBackground: Bool

  init(
    id: String,
    sourceText: String,
    translatedText: String,
    screenBounds: CGRect,
    alignment: TranslationTextAlignment,
    direction: TranslationTextDirection,
    rotationDegrees: Double,
    fontSize: CGFloat,
    confidence: Float,
    usesLightBackground: Bool
  ) {
    self.id = id
    self.sourceText = sourceText
    self.translatedText = translatedText
    self.screenBounds = screenBounds
    self.alignment = alignment
    self.direction = direction
    self.rotationDegrees = rotationDegrees
    self.fontSize = fontSize
    self.confidence = confidence
    self.usesLightBackground = usesLightBackground
  }
}

/// Shared normalization keeps deduplication deterministic and deliberately
/// avoids emitting OCR contents to logs.
nonisolated enum TranslationOCRTextNormalization {
  static func normalized(_ text: String) -> String {
    text
      .precomposedStringWithCanonicalMapping
      .folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// A single absolute deadline is shared by every synchronous OCR stage. Keeping
/// the check in one small value type makes it possible for tile creation,
/// paragraph analysis, language detection, and layout to use the same timeout
/// semantics without introducing another clock or a sleep-based poller.
nonisolated enum TranslationOCRDeadline {
  static func check(_ deadline: Date) throws {
    try Task.checkCancellation()
    guard Date() < deadline else { throw TranslationFailure.timedOut }
  }
}

/// Hard local-OCR input budgets. They protect the synchronous paragraph and
/// layout passes from pathological Vision output while keeping the product
/// contract finite (the text provider uses the smaller per-request budgets).
nonisolated enum TranslationOCRLimits {
  /// A noisy screenshot may contain more OCR lines than useful text blocks,
  /// but it must not make the local deduplication pass unbounded.
  static let maximumOCRLines = 4_096
  /// The product translation contract supports at most 500 local blocks.
  static let maximumTextBlocks = 500
  /// Keep all in-memory OCR source/translated text bounded as well.
  static let maximumTextCharacters = 200_000
}
