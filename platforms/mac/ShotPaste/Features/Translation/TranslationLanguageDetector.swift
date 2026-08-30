//
//  TranslationLanguageDetector.swift
//  ShotPaste
//
//  Local NaturalLanguage detection and conservative preserve-original
//  classification. The recognizer receives OCR strings in memory only.
//

import Foundation
import NaturalLanguage
import Vision

nonisolated enum TranslationTextClassification: String, Codable, Sendable {
  case translatable
  case url
  case email
  case number
  case code
  case filePath
  case productName
}

nonisolated struct TranslationLanguageDetection: Equatable, Sendable {
  let languageIdentifier: String?
  let confidence: Float
  let classification: TranslationTextClassification
  let preserveOriginal: Bool

  init(
    languageIdentifier: String?,
    confidence: Float,
    classification: TranslationTextClassification = .translatable,
    preserveOriginal: Bool = false
  ) {
    self.languageIdentifier = languageIdentifier
    self.confidence = confidence
    self.classification = classification
    self.preserveOriginal = preserveOriginal
  }
}

/// Stateless value wrapper around Apple's local language recognizer. A new
/// recognizer is created for each call because NLLanguageRecognizer is mutable
/// and is not shared across concurrent OCR blocks.
nonisolated struct TranslationLanguageDetector: Sendable {
  static let minimumUsefulConfidence: Float = 0.25
  private static let visionLanguageCache = VisionRecognitionLanguageCache()

  init() {}

  private func detectCore(
    _ text: String,
    sourceLanguageHint: String? = nil,
    recognitionLanguageHints: [String] = []
  ) -> TranslationLanguageDetection {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return TranslationLanguageDetection(
        languageIdentifier: nil,
        confidence: 0,
        classification: .translatable,
        preserveOriginal: false
      )
    }

    let classification = classify(trimmed)
    if classification != .translatable {
      return TranslationLanguageDetection(
        languageIdentifier: nil,
        confidence: 1,
        classification: classification,
        preserveOriginal: true
      )
    }

    // A configured source language is authoritative for translatable OCR
    // text.  Do this before NaturalLanguage sees the string: short labels
    // such as "OK" are especially prone to confident but incorrect guesses.
    // An explicit unknown is also authoritative, but means that the language
    // remains unknown rather than being guessed locally.
    if Self.isExplicitUnknown(sourceLanguageHint) {
      return TranslationLanguageDetection(
        languageIdentifier: nil,
        confidence: 0,
        classification: .translatable,
        preserveOriginal: false
      )
    }

    let normalizedHint = Self.normalizedIdentifier(sourceLanguageHint)
    if let normalizedHint {
      return TranslationLanguageDetection(
        languageIdentifier: normalizedHint,
        confidence: 1,
        classification: .translatable,
        preserveOriginal: false
      )
    }

    // Vision recognition hints are local evidence only.  Keep an explicit
    // unknown hint fail-closed, but never let a recognition hint override a
    // valid manual source language (handled above).
    if recognitionLanguageHints.contains(where: Self.isExplicitUnknown) {
      return TranslationLanguageDetection(
        languageIdentifier: nil,
        confidence: 0,
        classification: .translatable,
        preserveOriginal: false
      )
    }

    let normalizedRecognitionHint = recognitionLanguageHints
      .compactMap(Self.normalizedIdentifier)
      .first

    // NaturalLanguage is deliberately used only for text that has enough
    // signal. Short labels frequently produce a confident but incorrect
    // answer; the configured source/hints are a safer fallback there.
    guard meaningfulCharacterCount(trimmed) >= 2 else {
      return TranslationLanguageDetection(
        languageIdentifier: normalizedHint ?? normalizedRecognitionHint,
        confidence: 0,
        classification: .translatable,
        preserveOriginal: false
      )
    }

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(trimmed)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
    let dominant = recognizer.dominantLanguage.map { Self.normalizedIdentifier($0.rawValue) }
      ?? nil
    let detected = dominant ?? normalizedRecognitionHint
    let confidence: Float
    if let detected,
       let hypothesis = hypotheses.first(where: {
         Self.normalizedIdentifier($0.key.rawValue) == detected
       }) {
      confidence = Float(hypothesis.value)
    } else {
      confidence = 0
    }

    return TranslationLanguageDetection(
      languageIdentifier: detected,
      confidence: confidence,
      classification: .translatable,
      preserveOriginal: false
    )
  }

  /// Deadline-aware wrapper used by the OCR pipeline. NaturalLanguage is a
  /// local synchronous API, so the checks before and after the recognizer call
  /// are the cancellation seam available to this stage.
  func detect(
    _ text: String,
    sourceLanguageHint: String? = nil,
    recognitionLanguageHints: [String] = [],
    deadline: Date
  ) throws -> TranslationLanguageDetection {
    try TranslationOCRDeadline.check(deadline)
    guard text.utf8.count <= TranslationOCRLimits.maximumTextCharacters else {
      throw TranslationFailure.inputTooLarge
    }
    let result = detectCore(
      text,
      sourceLanguageHint: sourceLanguageHint,
      recognitionLanguageHints: recognitionLanguageHints
    )
    try TranslationOCRDeadline.check(deadline)
    return result
  }

  func detectSessionLanguage(
    for texts: [String],
    sourceLanguageHint: String? = nil,
    deadline: Date
  ) throws -> String? {
    try TranslationOCRDeadline.check(deadline)
    guard texts.count <= TranslationOCRLimits.maximumTextBlocks else {
      throw TranslationFailure.inputTooLarge
    }

    // Validate the aggregate budget before the manual-hint fast path.  Every
    // production-visible entry point owns the same fail-closed text limit;
    // callers must not be able to bypass it by supplying a source hint.
    var totalCharacters = 0
    for text in texts {
      try TranslationOCRDeadline.check(deadline)
      let characterCount = text.utf8.count
      guard characterCount <= TranslationOCRLimits.maximumTextCharacters - totalCharacters else {
        throw TranslationFailure.inputTooLarge
      }
      totalCharacters += characterCount
    }

    if Self.isExplicitUnknown(sourceLanguageHint) {
      try TranslationOCRDeadline.check(deadline)
      return nil
    }

    if let sourceLanguageHint = Self.normalizedIdentifier(sourceLanguageHint) {
      try TranslationOCRDeadline.check(deadline)
      return sourceLanguageHint
    }

    // Do this before NaturalLanguage aggregation.  A short block can produce
    // a low-confidence or simply wrong NL result, but a local script-family
    // boundary (for example Latin + Han, kana + Hangul) is still decisive
    // evidence that one session language would be unsafe.  This pass only
    // inspects in-memory OCR characters and never emits them to diagnostics.
    if try hasMixedScriptEvidence(in: texts, deadline: deadline) {
      return nil
    }

    var scores: [String: Double] = [:]
    var totalScore = 0.0
    for text in texts {
      try TranslationOCRDeadline.check(deadline)
      let detection = try detect(text, deadline: deadline)
      guard !detection.preserveOriginal,
            let language = detection.languageIdentifier,
            detection.confidence >= Self.minimumUsefulConfidence
      else { continue }
      let weight = Double(max(1, meaningfulCharacterCount(text)))
        * Double(max(detection.confidence, 0.1))
      scores[language, default: 0] += weight
      totalScore += weight
    }

    try TranslationOCRDeadline.check(deadline)
    guard let winner = scores.max(by: { lhs, rhs in
      if lhs.value == rhs.value { return lhs.key > rhs.key }
      return lhs.value < rhs.value
    }), totalScore > 0 else { return nil }
    let ratio = winner.value / totalScore
    try TranslationOCRDeadline.check(deadline)
    return ratio >= 0.60 ? winner.key : nil
  }

  static func normalizedIdentifier(_ identifier: String?) -> String? {
    guard let identifier else { return nil }
    let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let lowercased = value.replacingOccurrences(of: "_", with: "-").lowercased()

    if lowercased == "auto" || lowercased == "automatic"
      || lowercased == "und" || lowercased.hasPrefix("und-")
      || lowercased == "unknown" || lowercased.hasPrefix("unknown-") {
      return nil
    }

    if lowercased.hasPrefix("zh-hant") || lowercased.contains("traditional") {
      return "zh-Hant"
    }
    if lowercased.hasPrefix("zh") || lowercased.contains("simplified") {
      return "zh-Hans"
    }
    if lowercased.hasPrefix("en") { return "en" }
    if lowercased.hasPrefix("vi") { return "vi" }
    if lowercased.hasPrefix("es") { return "es" }
    if lowercased.hasPrefix("ja") { return "ja" }
    if lowercased.hasPrefix("ko") { return "ko" }
    if lowercased.hasPrefix("ru") { return "ru" }
    if lowercased.hasPrefix("fr") { return "fr" }
    if lowercased.hasPrefix("de") { return "de" }
    if lowercased.hasPrefix("it") { return "it" }
    if lowercased.hasPrefix("pt") { return "pt" }
    if lowercased.hasPrefix("nl") { return "nl" }
    if lowercased.hasPrefix("ar") { return "ar" }
    if lowercased.hasPrefix("th") { return "th" }
    if lowercased.hasPrefix("tr") { return "tr" }
    if lowercased.hasPrefix("pl") { return "pl" }
    return value
  }

  /// Converts an app language identifier into a locale currently accepted by
  /// Vision. The result is selected from Vision's installed runtime list; a
  /// bare app code is never passed to `recognitionLanguages`.
  static func visionRecognitionIdentifier(for identifier: String?) -> String? {
    visionRecognitionIdentifier(
      for: identifier,
      supportedLanguages: supportedVisionRecognitionLanguages()
    )
  }

  /// Injectable variant for deterministic tests. Matching is exact first,
  /// then a locale prefix within the same language family. Script-specific
  /// Chinese candidates intentionally do not fall back to an arbitrary `zh`
  /// locale because that could select the wrong writing system.
  static func visionRecognitionIdentifier(
    for identifier: String?,
    supportedLanguages: [String]
  ) -> String? {
    guard let normalized = normalizedIdentifier(identifier),
          !supportedLanguages.isEmpty
    else { return nil }

    let candidates = visionLocaleCandidates[normalized] ?? []
    guard !candidates.isEmpty else { return nil }
    let supported = supportedLanguages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    for candidate in candidates {
      if let exact = supported.first(where: {
        $0.caseInsensitiveCompare(candidate) == .orderedSame
      }) {
        return exact
      }
    }

    for candidate in candidates {
      let candidateLower = candidate.lowercased()
      if let prefixed = supported.first(where: {
        $0.lowercased().hasPrefix(candidateLower + "-")
      }) {
        return prefixed
      }
      let isChineseScript = candidateLower.hasPrefix("zh-hans")
        || candidateLower.hasPrefix("zh-hant")
      guard !isChineseScript else { continue }
      let base = candidateLower.split(separator: "-").first.map(String.init) ?? candidateLower
      if let prefix = supported.first(where: {
        let value = $0.lowercased()
        guard value.contains("-") else { return false }
        return value == base || value.hasPrefix(base + "-")
      }) {
        return prefix
      }
    }
    return nil
  }

  /// Vision's language list is a property of the installed recognition
  /// revision, not a hard-coded product promise. Failure to query it is a
  /// safe automatic-OCR fallback.
  static func supportedVisionRecognitionLanguages() -> [String] {
    visionLanguageCache.value {
      if #available(macOS 12.0, *) {
        return (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
      }
      return []
    }
  }

  private static let visionLocaleCandidates: [String: [String]] = [
    "en": ["en-US", "en-GB"],
    "vi": ["vi-VT", "vi-VN"],
    "zh-Hans": ["zh-Hans", "zh-CN"],
    "zh-Hant": ["zh-Hant", "zh-TW"],
    "es": ["es-ES", "es-MX"],
    "ja": ["ja-JP"],
    "ko": ["ko-KR"],
    "ru": ["ru-RU"],
    "fr": ["fr-FR", "fr-CA"],
    "de": ["de-DE"],
  ]

  private func classify(_ text: String) -> TranslationTextClassification {
    if matches(text, pattern: #"(?i)^(?:https?://|www\.)\S+$"#) {
      return .url
    }
    if matches(text, pattern: #"(?i)^[^\s@]+@[^\s@]+\.[^\s@]+$"#) {
      return .email
    }
    if matches(text, pattern: #"^[\d\s.,:%+\-–—/()]+$"#), text.rangeOfCharacter(from: .decimalDigits) != nil {
      return .number
    }
    if matches(text, pattern: #"^(?:[A-Za-z]:[\\/]|~[\\/]|/).*$"#)
      || (text.contains("/") && !text.contains(" ") && text.contains(".")) {
      return .filePath
    }
    if looksLikeCode(text) {
      return .code
    }
    if looksLikeProductName(text) {
      return .productName
    }
    return .translatable
  }

  private func looksLikeCode(_ text: String) -> Bool {
    if text.contains("```") { return true }
    if text.range(of: #"\b(?:func|let|var|class|struct|import|return|const|def|public|private)\b"#, options: .regularExpression) != nil {
      return true
    }
    let codePunctuation = ["=>", "==", "!=", "&&", "||", "{}", ";", "()", "[]"]
    return codePunctuation.contains(where: text.contains)
  }

  private func looksLikeProductName(_ text: String) -> Bool {
    let tokens = text.split(whereSeparator: { $0.isWhitespace })
    guard tokens.count == 1, let token = tokens.first else { return false }
    let value = String(token)
    let hasLetter = value.rangeOfCharacter(from: .letters) != nil
    let hasNumber = value.rangeOfCharacter(from: .decimalDigits) != nil
    if hasLetter && hasNumber { return true }
    // Mixed-case identifiers such as ShotPaste are safer to keep than to
    // translate. A normal sentence word has no interior uppercase transition.
    return value.range(of: #"^[A-Z][a-z]+[A-Z][A-Za-z]+$"#, options: .regularExpression) != nil
  }

  private func matches(_ text: String, pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }

  private func meaningfulCharacterCount(_ text: String) -> Int {
    text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }.count
  }

  private static func isExplicitUnknown(_ identifier: String?) -> Bool {
    guard let identifier else { return false }
    let value = identifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
      .lowercased()
    return value == "und" || value.hasPrefix("und-")
      || value == "unknown" || value.hasPrefix("unknown-")
  }

  private enum ScriptFamily: Hashable {
    case latin
    case han
    case kana
    case hangul
    case cyrillic
    case greek
    case arabic
    case hebrew
    case devanagari
    case thai
    case other
  }

  /// A language-family profile intentionally treats Han + kana as Japanese
  /// evidence.  Japanese commonly mixes those two scripts within a single
  /// paragraph; treating every distinct Unicode script as a language boundary
  /// would incorrectly reject ordinary Japanese screens.  Other combinations
  /// remain conservative and are considered mixed.
  private enum ScriptProfile: Hashable {
    case latin
    case han
    case japanese
    case hangul
    case cyrillic
    case greek
    case arabic
    case hebrew
    case devanagari
    case thai
    case other
    case mixed
  }

  private func hasMixedScriptEvidence(
    in texts: [String],
    deadline: Date
  ) throws -> Bool {
    var profiles = Set<ScriptProfile>()
    for text in texts {
      try TranslationOCRDeadline.check(deadline)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, classify(trimmed) == .translatable,
            let profile = Self.scriptProfile(for: trimmed)
      else { continue }
      if profile == .mixed { return true }
      profiles.insert(profile)
      if profiles.count > 1 { return true }
    }
    try TranslationOCRDeadline.check(deadline)
    return false
  }

  private static func scriptProfile(for text: String) -> ScriptProfile? {
    let scripts = scriptFamilies(in: text)
    guard !scripts.isEmpty else { return nil }
    if scripts.contains(.kana), scripts.isSubset(of: [.han, .kana]) {
      return .japanese
    }
    guard scripts.count == 1, let script = scripts.first else { return .mixed }
    switch script {
    case .latin: return .latin
    case .han: return .han
    case .kana: return .japanese
    case .hangul: return .hangul
    case .cyrillic: return .cyrillic
    case .greek: return .greek
    case .arabic: return .arabic
    case .hebrew: return .hebrew
    case .devanagari: return .devanagari
    case .thai: return .thai
    case .other: return .other
    }
  }

  private static func scriptFamilies(in text: String) -> Set<ScriptFamily> {
    var result = Set<ScriptFamily>()
    for scalar in text.unicodeScalars {
      // Numbers, punctuation, symbols, whitespace, combining marks, and
      // emoji are Common/Inherited script and do not establish a language
      // boundary.  The explicit ranges below are used instead of newer
      // Unicode.Scalar script APIs so the app remains compatible with the
      // project's macOS 13 / Swift 5 deployment target.
      guard CharacterSet.letters.contains(scalar) else { continue }
      let value = scalar.value
      switch value {
      case 0x0041 ... 0x005A, 0x0061 ... 0x007A,
           0x00C0 ... 0x02AF, 0x1E00 ... 0x1EFF:
        result.insert(.latin)
      case 0x0370 ... 0x03FF, 0x1F00 ... 0x1FFF:
        result.insert(.greek)
      case 0x0400 ... 0x052F, 0x2DE0 ... 0x2DFF, 0xA640 ... 0xA69F:
        result.insert(.cyrillic)
      case 0x0530 ... 0x058F:
        result.insert(.other)
      case 0x0590 ... 0x05FF:
        result.insert(.hebrew)
      case 0x0600 ... 0x06FF, 0x0750 ... 0x077F,
           0x08A0 ... 0x08FF, 0xFB50 ... 0xFDFF, 0xFE70 ... 0xFEFF:
        result.insert(.arabic)
      case 0x0900 ... 0x097F, 0xA8E0 ... 0xA8FF:
        result.insert(.devanagari)
      case 0x0E00 ... 0x0E7F:
        result.insert(.thai)
      case 0x1100 ... 0x11FF, 0x3130 ... 0x318F,
           0xA960 ... 0xA97F, 0xAC00 ... 0xD7FF:
        result.insert(.hangul)
      case 0x3040 ... 0x309F, 0x30A0 ... 0x30FF,
           0x31F0 ... 0x31FF, 0xFF66 ... 0xFF9D:
        result.insert(.kana)
      case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF,
           0xF900 ... 0xFAFF, 0x20000 ... 0x2FA1F:
        result.insert(.han)
      default:
        result.insert(.other)
      }
    }
    return result
  }
}

/// Vision's supported-locale query is process-stable but may be reached by
/// concurrent OCR workers. Keep the result once without racing mutable state.
private final class VisionRecognitionLanguageCache: @unchecked Sendable {
  private let lock = NSLock()
  private var cached: [String]?

  func value(loader: () -> [String]) -> [String] {
    lock.lock()
    if let cached {
      lock.unlock()
      return cached
    }
    lock.unlock()

    let loaded = loader()
    lock.lock()
    if cached == nil { cached = loaded }
    let result = cached ?? loaded
    lock.unlock()
    return result
  }
}
