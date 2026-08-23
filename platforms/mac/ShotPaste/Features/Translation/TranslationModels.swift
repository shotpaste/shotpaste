//
//  TranslationModels.swift
//  ShotPaste
//
//  Session-only state for local-OCR/text translation. Frozen pixels remain in
//  TranslationInput for local OCR and rendering only; no provider-facing model
//  in this file contains an image, coordinate, or pixel field.
//

import AppKit
import CoreGraphics
import Foundation

nonisolated enum TranslationSessionPhase: Equatable {
  case ready
  case translating
  case showingResult
  case failed(TranslationFailure)
  case terminating

  var isRequestInFlight: Bool {
    self == .translating
  }
}

/// UI-only progress. These values deliberately do not become part of the One
/// Shot lifecycle state machine or the provider protocol.
nonisolated enum TranslationProgress: Equatable, Sendable {
  case recognizingText
  case detectingLanguage
  case translatingText
  case layingOut
}

nonisolated enum TranslationFailure: Error, Equatable, Sendable {
  case recognizedTextSharingDisabled
  case missingAPIKey
  case invalidConfiguration
  case timedOut
  case cancelled
  case noText
  case invalidResponse
  case providerStatus(Int)
  case inputTooLarge
  case captureFailed
  case unavailable

  var requiresProviderSettings: Bool {
    switch self {
    case .recognizedTextSharingDisabled, .missingAPIKey, .invalidConfiguration:
      true
    case .providerStatus(let status):
      status == 401 || status == 403
    case .timedOut, .cancelled, .noText, .invalidResponse,
         .inputTooLarge, .captureFailed, .unavailable:
      false
    }
  }

  /// A final 429/5xx remains a retryable user action while the frozen layer
  /// is still visible. Authentication/configuration failures are terminal.
  var isRetryable: Bool {
    switch self {
    case .providerStatus(let status):
      status == 408 || status == 429 || (500 ... 599).contains(status)
    case .recognizedTextSharingDisabled, .missingAPIKey, .invalidConfiguration,
         .timedOut, .cancelled, .noText, .invalidResponse, .inputTooLarge,
         .captureFailed, .unavailable:
      false
    }
  }

  init(providerError: TranslationTextProviderError) {
    switch providerError {
    case .missingAPIKey:
      self = .missingAPIKey
    case .invalidConfiguration:
      self = .invalidConfiguration
    case .invalidRequest:
      self = .invalidResponse
    case .inputTooLarge:
      self = .inputTooLarge
    case .timedOut:
      self = .timedOut
    case .cancelled:
      self = .cancelled
    case .invalidResponse:
      self = .invalidResponse
    case .providerStatus(let status):
      self = .providerStatus(status)
    case .transport:
      self = .unavailable
    }
  }
}

nonisolated enum TranslationSourceLanguage: Hashable, Identifiable, Sendable {
  case automatic
  case language(String)

  var id: String {
    switch self {
    case .automatic: "auto"
    case .language(let identifier): identifier
    }
  }

  var providerValue: String {
    switch self {
    case .automatic: "auto"
    case .language(let identifier): identifier
    }
  }
}

nonisolated enum TranslationTargetLanguage: Hashable, Identifiable, Sendable {
  case currentLanguage
  case language(String)

  var id: String {
    switch self {
    case .currentLanguage: "current"
    case .language(let identifier): identifier
    }
  }
}

nonisolated struct TranslationResolvedLanguage: Hashable, Sendable {
  let identifier: String
  let displayName: String
}

nonisolated enum TranslationLanguageCatalog {
  static let sourceOptions: [TranslationSourceLanguage] =
    [.automatic] + AppLanguageOption.supported.map { .language($0.identifier) }

  static let targetOptions: [TranslationTargetLanguage] =
    [.currentLanguage] + AppLanguageOption.supported.map { .language($0.identifier) }

  static func displayName(for source: TranslationSourceLanguage) -> String {
    switch source {
    case .automatic:
      L10n.OneShot.translationAutomaticLanguage
    case .language(let identifier):
      displayName(for: identifier)
    }
  }

  static func displayName(for target: TranslationTargetLanguage) -> String {
    switch target {
    case .currentLanguage:
      L10n.OneShot.translationCurrentLanguage
    case .language(let identifier):
      displayName(for: identifier)
    }
  }

  static func resolvedTarget(
    _ target: TranslationTargetLanguage,
    currentLanguageIdentifier: String
  ) -> TranslationResolvedLanguage {
    let identifier: String = switch target {
    case .currentLanguage:
      normalizedSupportedIdentifier(currentLanguageIdentifier) ?? "en"
    case .language(let selectedIdentifier):
      normalizedSupportedIdentifier(selectedIdentifier) ?? "en"
    }
    return TranslationResolvedLanguage(identifier: identifier, displayName: displayName(for: identifier))
  }

  static func normalizedSupportedIdentifier(_ identifier: String) -> String? {
    // Keep this pure/nonisolated. AppLanguageManager is a MainActor object,
    // while target resolution also runs from request setup and tests that do
    // not require the app-language UI actor.
    let normalized = normalizedLanguageIdentifier(from: identifier) ?? identifier
    return AppLanguageOption.supported.contains(where: { $0.identifier == normalized }) ? normalized : nil
  }

  private static func normalizedLanguageIdentifier(from identifier: String) -> String? {
    guard !identifier.isEmpty else { return nil }
    let lowercased = identifier.lowercased()
    if lowercased.contains("hant") || lowercased.hasPrefix("zh-tw")
      || lowercased.hasPrefix("zh-hk") || lowercased.hasPrefix("zh-mo") {
      return "zh-Hant"
    }
    if lowercased.contains("hans") || lowercased.hasPrefix("zh-cn")
      || lowercased.hasPrefix("zh-sg") {
      return "zh-Hans"
    }
    let prefixes = ["en", "vi", "es", "ja", "ko", "ru", "fr", "de"]
    return prefixes.first(where: { lowercased.hasPrefix($0) })
  }

  static func displayName(for identifier: String) -> String {
    AppLanguageOption.supported.first(where: { $0.identifier == identifier })?.displayName ?? identifier
  }
}

nonisolated enum TranslationPromptMode: String, CaseIterable, Sendable {
  case builtin
  case custom
}

nonisolated struct TranslationPreferences: Equatable, Sendable {
  static let defaultTimeoutSeconds = 15
  static let timeoutRange = 5 ... 120
  static let builtinPromptVersion = 1
  static let maximumPromptCharacters = 2_000

  let timeoutSeconds: Int
  let promptMode: TranslationPromptMode
  let prompt: String
  let sendRecognizedText: Bool

  init(
    timeoutSeconds: Int,
    promptMode: TranslationPromptMode,
    prompt: String,
    sendRecognizedText: Bool = true
  ) {
    self.timeoutSeconds = min(max(timeoutSeconds, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
    self.promptMode = promptMode
    self.prompt = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumPromptCharacters))
    self.sendRecognizedText = sendRecognizedText
  }

  static func current(defaults: UserDefaults = .standard) -> TranslationPreferences {
    // Translation can start directly from One Shot, so migration must not be
    // tied to the Preferences view's lifecycle.
    TranslationSettingsMigration.applyIfNeeded(defaults: defaults)
    let storedTimeout = defaults.integer(forKey: PreferencesKeys.agentTranslationTimeoutSeconds)
    let timeout = storedTimeout == 0 ? defaultTimeoutSeconds : storedTimeout
    let rawMode = defaults.string(forKey: PreferencesKeys.agentTranslationPromptMode)
    return TranslationPreferences(
      timeoutSeconds: timeout,
      promptMode: TranslationPromptMode(rawValue: rawMode ?? "") ?? .builtin,
      prompt: defaults.string(forKey: PreferencesKeys.agentTranslationPrompt) ?? "",
      sendRecognizedText: TranslationSettingsMigration.sendRecognizedText(defaults: defaults)
    )
  }

  /// Kept for the settings editor. It is a preference description only; OCR
  /// content is never interpolated into it.
  static let builtinUserPrompt = """
  Translate the visible text faithfully. Preserve names, numbers, code, URLs, and meaningful formatting. Use a natural, concise tone for {{target_language}}.
  Source language: {{source_language}}.
  Target language: {{target_language}}.
  """

  /// The network request receives only this constrained style field. The
  /// built-in value is intentionally narrower than the old image prompt.
  var stylePreferences: String? {
    switch promptMode {
    case .builtin:
      return "faithful translation; preserve names, numbers, code, URLs, and formatting; use a natural concise tone"
    case .custom:
      let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maximumPromptCharacters))
    }
  }
}

nonisolated enum TranslationAvailability: Equatable {
  case available
  case unavailable(TranslationFailure)

  static func evaluate(
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    sendRecognizedText: Bool
  ) -> TranslationAvailability {
    guard sendRecognizedText else {
      return .unavailable(.recognizedTextSharingDisabled)
    }
    guard configuration.isValid else {
      return .unavailable(.invalidConfiguration)
    }
    guard configuration.isLocalEndpoint || AgentCredentialStore.normalizedKey(apiKey) != nil else {
      return .unavailable(.missingAPIKey)
    }
    return .available
  }

  /// Compatibility entry point for older settings/readiness callers. It is
  /// still a privacy gate: the default is the migrated text-sharing value,
  /// never the Agent Mode screenshot flag and never an unconditional `true`.
  static func evaluate(
    configuration: AgentProviderConfiguration,
    apiKey: String?
  ) -> TranslationAvailability {
    evaluate(
      configuration: configuration,
      apiKey: apiKey,
      sendRecognizedText: TranslationSettingsMigration.sendRecognizedText()
    )
  }
}

/// The frozen screenshot/crop is local-only session input. It is deliberately
/// not a field of TranslationTextRequest or any provider response type.
nonisolated struct TranslationInput: Sendable {
  let image: CGImage
  /// AppKit global screen coordinates (bottom-left origin).
  let screenRect: CGRect
}

nonisolated enum TranslationTextAlignment: String, Codable, CaseIterable, Sendable {
  case leading
  case center
  case trailing
}

/// Final renderer contract. Every geometry field originates from local OCR or
/// local layout; the provider contributes only translated text keyed by id.
nonisolated struct TranslationRenderBlock: Identifiable, Equatable, Sendable {
  let id: String
  let sourceText: String
  let translatedText: String
  /// AppKit global screen coordinates (bottom-left origin).
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
    direction: TranslationTextDirection = .horizontal,
    rotationDegrees: Double = 0,
    fontSize: CGFloat? = nil,
    confidence: Float = 0,
    usesLightBackground: Bool = false
  ) {
    self.id = id
    self.sourceText = sourceText
    self.translatedText = translatedText
    self.screenBounds = screenBounds
    self.alignment = alignment
    self.direction = direction
    self.rotationDegrees = rotationDegrees
    self.fontSize = fontSize ?? max(11, min(42, screenBounds.height * 0.58))
    self.confidence = confidence
    self.usesLightBackground = usesLightBackground
  }
}

nonisolated enum TranslationOverlayLayout {
  /// Converts a global screen block into selection-local coordinates and clips
  /// it once more before SwiftUI/renderer drawing.
  static func localFrame(for blockRect: CGRect, inside selectionRect: CGRect) -> CGRect? {
    let visible = blockRect.intersection(selectionRect)
    guard !visible.isEmpty else { return nil }
    return visible.offsetBy(dx: -selectionRect.minX, dy: -selectionRect.minY)
  }
}
