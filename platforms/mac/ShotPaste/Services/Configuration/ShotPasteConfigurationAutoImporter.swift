//
//  ShotPasteConfigurationAutoImporter.swift
//  ShotPaste
//
//  Applies user-edited TOML configuration on app launch when the file changes.
//

import CryptoKit
import Foundation

enum ShotPasteConfigurationAutoImportStatus: Equatable {
  case applied
  case failed
  case skippedMissingFile
  case skippedUnchanged
}

struct ShotPasteConfigurationAutoImportResult {
  let status: ShotPasteConfigurationAutoImportStatus
  let fileURL: URL
  let importResult: ShotPasteConfigurationImportResult?
  let errorMessage: String?

  var appliedChangeCount: Int {
    importResult?.appliedChangeCount ?? 0
  }

  var warningCount: Int {
    importResult?.issues.filter { $0.severity == .warning }.count ?? 0
  }

  var errorCount: Int {
    importResult?.issues.filter { $0.severity == .error }.count ?? 0
  }
}

@MainActor
enum ShotPasteConfigurationAutoImporter {
  static func applyIfNeededOnLaunch(
    defaults: UserDefaults = .standard
  ) -> ShotPasteConfigurationAutoImportResult {
    applyIfNeeded(from: ShotPasteConfigurationPaths.suggestedConfigURL, defaults: defaults)
  }

  static func applyIfNeeded(
    from fileURL: URL,
    defaults: UserDefaults = .standard
  ) -> ShotPasteConfigurationAutoImportResult {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return ShotPasteConfigurationAutoImportResult(
        status: .skippedMissingFile,
        fileURL: fileURL,
        importResult: nil,
        errorMessage: nil
      )
    }

    let source: String
    do {
      source = try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
      return ShotPasteConfigurationAutoImportResult(
        status: .failed,
        fileURL: fileURL,
        importResult: nil,
        errorMessage: error.localizedDescription
      )
    }

    let signature = contentSignature(for: source)
    if defaults.string(forKey: PreferencesKeys.configurationLastAppliedSignature) == signature {
      return ShotPasteConfigurationAutoImportResult(
        status: .skippedUnchanged,
        fileURL: fileURL,
        importResult: nil,
        errorMessage: nil
      )
    }

    let importResult = ShotPasteConfigurationImporter.importTOML(source, defaults: defaults)
    if importResult.hasErrors {
      return ShotPasteConfigurationAutoImportResult(
        status: .failed,
        fileURL: fileURL,
        importResult: importResult,
        errorMessage: nil
      )
    }

    defaults.set(signature, forKey: PreferencesKeys.configurationLastAppliedSignature)
    return ShotPasteConfigurationAutoImportResult(
      status: .applied,
      fileURL: fileURL,
      importResult: importResult,
      errorMessage: nil
    )
  }

  nonisolated static func contentSignature(for source: String) -> String {
    let digest = SHA256.hash(data: Data(source.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
