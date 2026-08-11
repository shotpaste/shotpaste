//
//  LiteScreenConfigurationResult.swift
//  LiteScreen
//
//  Import/export result models for TOML configuration.
//

import Foundation

enum LiteScreenConfigurationIssueSeverity: Sendable {
  case warning
  case error
}

struct LiteScreenConfigurationIssue: Identifiable, Sendable {
  let id = UUID()
  let severity: LiteScreenConfigurationIssueSeverity
  let message: String
}

struct LiteScreenConfigurationImportResult: Sendable {
  let appliedChangeCount: Int
  let issues: [LiteScreenConfigurationIssue]

  var hasErrors: Bool {
    issues.contains { $0.severity == .error }
  }
}

enum LiteScreenConfigurationSyncDecision: Equatable, Sendable {
  case alreadyCurrent
  case syncAutomatically
  case askBeforeReplacing
}

enum LiteScreenConfigurationSyncStatus: Equatable, Sendable {
  case alreadyCurrent
  case synced
  case needsConfirmation
  case permissionRequired
}

struct LiteScreenConfigurationSyncResult: Sendable {
  let status: LiteScreenConfigurationSyncStatus
  let fileURL: URL
  let observedFileSignature: String?
  let exportedSettingsSignature: String?

  nonisolated init(
    status: LiteScreenConfigurationSyncStatus,
    fileURL: URL,
    observedFileSignature: String? = nil,
    exportedSettingsSignature: String? = nil
  ) {
    self.status = status
    self.fileURL = fileURL
    self.observedFileSignature = observedFileSignature
    self.exportedSettingsSignature = exportedSettingsSignature
  }
}

enum LiteScreenConfigurationSyncError: LocalizedError, Sendable {
  case fileChangedSinceConfirmation

  var errorDescription: String? {
    switch self {
    case .fileChangedSinceConfirmation:
      "config.toml changed. Review it and try again."
    }
  }
}
