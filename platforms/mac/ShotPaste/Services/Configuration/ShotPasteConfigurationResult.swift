//
//  ShotPasteConfigurationResult.swift
//  ShotPaste
//
//  Import/export result models for TOML configuration.
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

enum ShotPasteConfigurationSyncDecision: Equatable, Sendable {
  case alreadyCurrent
  case syncAutomatically
  case askBeforeReplacing
}

enum ShotPasteConfigurationSyncStatus: Equatable, Sendable {
  case alreadyCurrent
  case synced
  case needsConfirmation
  case permissionRequired
}

struct ShotPasteConfigurationSyncResult: Sendable {
  let status: ShotPasteConfigurationSyncStatus
  let fileURL: URL
  let observedFileSignature: String?
  let exportedSettingsSignature: String?

  nonisolated init(
    status: ShotPasteConfigurationSyncStatus,
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

enum ShotPasteConfigurationSyncError: LocalizedError, Sendable {
  case fileChangedSinceConfirmation

  var errorDescription: String? {
    switch self {
    case .fileChangedSinceConfirmation:
      "config.toml changed. Review it and try again."
    }
  }
}
