//
//  TranslationSettingsMigration.swift
//  ShotPaste
//
//  One-time migration for the text-only translation privacy preference.
//

import Foundation

/// Initializes the translation text-sharing preference for installations that
/// predate the local-OCR/text-provider pipeline.
///
/// `agentProviderSendsImages` belongs exclusively to Agent Mode. New and
/// existing installations that have never configured text sharing start with
/// text sharing enabled. Checking `object(forKey:)` rather than `bool(forKey:)`
/// preserves an explicitly imported or previously stored `false` value.
nonisolated enum TranslationSettingsMigration {
  static let defaultSendRecognizedText = true

  /// Sets the new preference at most once and returns whether it was written.
  @discardableResult
  static func applyIfNeeded(defaults: UserDefaults = .standard) -> Bool {
    let newKey = PreferencesKeys.agentTranslationSendsRecognizedText
    guard defaults.object(forKey: newKey) == nil else { return false }

    defaults.set(defaultSendRecognizedText, forKey: newKey)
    return true
  }

  /// Reads the effective value after ensuring the one-time migration ran.
  static func sendRecognizedText(defaults: UserDefaults = .standard) -> Bool {
    applyIfNeeded(defaults: defaults)
    return defaults.object(forKey: PreferencesKeys.agentTranslationSendsRecognizedText) as? Bool
      ?? defaultSendRecognizedText
  }
}
