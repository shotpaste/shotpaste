//
//  ShortcutValidationService.swift
//  ShotPaste
//
//  Centralized validation rules for editable keyboard shortcuts
//

import Foundation

enum ShortcutValidationSeverity: Equatable {
  case warning
  case error
}

struct ShortcutValidationIssue: Equatable {
  let severity: ShortcutValidationSeverity
  let message: String
}

enum ShortcutValidationDecision: Equatable {
  case accept(issue: ShortcutValidationIssue?)
  case reject(issue: ShortcutValidationIssue)
}

@MainActor
final class ShortcutValidationService {
  static let shared = ShortcutValidationService()

  func validateGlobalShortcut(
    _ config: ShortcutConfig?,
    for kind: GlobalShortcutKind
  ) -> ShortcutValidationDecision {
    guard let config else { return .accept(issue: nil) }

    if let conflictKind = conflictingGlobalShortcut(for: config, excluding: kind) {
      return .reject(issue: ShortcutValidationIssue(
        severity: .error,
        message: L10n.ShortcutValidation.alreadyUsedBy(conflictKind.displayName)
      ))
    }

    let systemConflicts = SystemScreenshotShortcutManager.shared.conflictDescriptions(
      for: kind,
      shortcut: config
    )

    if let systemConflict = systemConflicts.first {
      return .accept(issue: ShortcutValidationIssue(
        severity: .warning,
        message: L10n.ShortcutValidation.matchesSystemConflict(systemConflict)
      ))
    }

    return .accept(issue: nil)
  }

  private func conflictingGlobalShortcut(
    for config: ShortcutConfig,
    excluding excludedKind: GlobalShortcutKind?
  ) -> GlobalShortcutKind? {
    GlobalShortcutKind.allCases.first(where: {
      $0 != excludedKind
        && KeyboardShortcutManager.shared.isShortcutEnabled(for: $0)
        && KeyboardShortcutManager.shared.shortcut(for: $0) == config
    })
  }

  private init() {}
}
