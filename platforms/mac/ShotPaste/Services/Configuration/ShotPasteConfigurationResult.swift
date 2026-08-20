//
//  ShotPasteConfigurationResult.swift
//  ShotPaste
//
//  Import result models for TOML configuration.
//

import Foundation

enum ShotPasteConfigurationIssueSeverity: Sendable {
  case warning
  case error
}

struct ShotPasteConfigurationIssue: Identifiable, Sendable {
  let id = UUID()
  let severity: ShotPasteConfigurationIssueSeverity
  let message: String
}

struct ShotPasteConfigurationImportResult: Sendable {
  let appliedChangeCount: Int
  let issues: [ShotPasteConfigurationIssue]

  var hasErrors: Bool {
    issues.contains { $0.severity == .error }
  }
}
