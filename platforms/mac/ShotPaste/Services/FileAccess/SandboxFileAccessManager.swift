//
//  SandboxFileAccessManager.swift
//  ShotPaste
//
//  Handles export directory persistence and security-scoped access for sandbox mode.
//

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "ShotPaste", category: "SandboxFileAccess")

@MainActor
final class SandboxFileAccessManager {
  static let shared = SandboxFileAccessManager()

  private let defaults = UserDefaults.standard
  private var didPromptForMissingExportPermissionThisSession = false

  private init() {}

  struct ScopedAccess: Sendable {
    let url: URL
    private let accessURL: URL
    private let didStartAccessing: Bool

    init(url: URL, accessURL: URL, didStartAccessing: Bool) {
      self.url = url
      self.accessURL = accessURL
      self.didStartAccessing = didStartAccessing
    }

    nonisolated func stop() {
      if didStartAccessing {
        accessURL.stopAccessingSecurityScopedResource()
      }
    }
  }

  var defaultExportDirectory: URL {
    AppDataLocations.defaultExportDirectory(for: .current)
  }

  func ensureExportLocationInitialized() {
    if defaults.string(forKey: PreferencesKeys.exportLocation)?.isEmpty != false {
      defaults.set(defaultExportDirectory.path, forKey: PreferencesKeys.exportLocation)
      DiagnosticLogger.shared.log(
        .info,
        .fileAccess,
        "Default export location initialized",
        context: ["directory": defaultExportDirectory.lastPathComponent]
      )
    }
  }

  var exportLocationPath: String {
    ensureExportLocationInitialized()
    return defaults.string(forKey: PreferencesKeys.exportLocation) ?? defaultExportDirectory.path
  }

  var exportLocationURL: URL {
    URL(fileURLWithPath: exportLocationPath, isDirectory: true)
  }

  var hasPersistedExportPermission: Bool {
    ensureExportLocationInitialized()
    guard isRunningSandboxed else {
      return true
    }

    guard let bookmarkURL = resolveExportBookmarkURL(removeInvalidBookmark: true) else {
      return false
    }

    let didStart = bookmarkURL.startAccessingSecurityScopedResource()
    if didStart {
      bookmarkURL.stopAccessingSecurityScopedResource()
      return true
    }

    // A failed startAccessing means the persisted scope is unusable.
    // Require user to re-grant via folder picker.
    return false
  }

  func resolvedExportDirectoryURL() -> URL {
    if let bookmarkURL = resolveExportBookmarkURL(removeInvalidBookmark: true) {
      return bookmarkURL
    }
    return exportLocationURL
  }

  @discardableResult
  func setExportDirectory(_ url: URL) -> Bool {
    let normalizedURL = url.standardizedFileURL

    guard isRunningSandboxed else {
      defaults.set(normalizedURL.path, forKey: PreferencesKeys.exportLocation)
      do {
        let bookmarkData = try normalizedURL.bookmarkData(
          options: .withSecurityScope,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        defaults.set(bookmarkData, forKey: PreferencesKeys.exportLocationBookmark)
      } catch {
        defaults.removeObject(forKey: PreferencesKeys.exportLocationBookmark)
        DiagnosticLogger.shared.log(
          .debug,
          .fileAccess,
          "Export directory bookmark skipped outside sandbox",
          context: ["directory": normalizedURL.lastPathComponent]
        )
      }

      didPromptForMissingExportPermissionThisSession = false
      DiagnosticLogger.shared.log(
        .info,
        .fileAccess,
        "Export directory saved",
        context: ["directory": normalizedURL.lastPathComponent]
      )
      return true
    }

    do {
      let bookmarkData = try normalizedURL.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      defaults.set(normalizedURL.path, forKey: PreferencesKeys.exportLocation)
      defaults.set(bookmarkData, forKey: PreferencesKeys.exportLocationBookmark)
      didPromptForMissingExportPermissionThisSession = false
      DiagnosticLogger.shared.log(
        .info,
        .fileAccess,
        "Export directory bookmark saved",
        context: ["directory": normalizedURL.lastPathComponent]
      )
      return true
    } catch {
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Export directory bookmark save failed",
        context: ["directory": normalizedURL.lastPathComponent]
      )
      return false
    }
  }

  @discardableResult
  func chooseExportDirectory(
    message: String = L10n.FileAccess.chooseCapturesFolderMessage,
    prompt: String = L10n.FileAccess.grantAccessPrompt,
    directoryURL: URL? = nil
  ) -> URL? {
    ensureExportLocationInitialized()

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = prompt
    panel.directoryURL = directoryURL ?? defaultExportDirectory

    DiagnosticLogger.shared.log(.info, .fileAccess, "Export directory picker opened")
    if panel.runModal() == .OK, let selectedURL = panel.url {
      guard setExportDirectory(selectedURL) else {
        showBookmarkSaveFailedAlert()
        return nil
      }
      DiagnosticLogger.shared.log(
        .info,
        .fileAccess,
        "Export directory picker accepted",
        context: ["directory": selectedURL.standardizedFileURL.lastPathComponent]
      )
      return selectedURL.standardizedFileURL
    }
    DiagnosticLogger.shared.log(.debug, .fileAccess, "Export directory picker cancelled")
    return nil
  }

  func ensureExportDirectoryForOperation(promptMessage: String) -> URL? {
    ensureExportLocationInitialized()

    guard isRunningSandboxed else {
      return resolvedExportDirectoryURL()
    }

    if hasPersistedExportPermission {
      DiagnosticLogger.shared.log(.debug, .fileAccess, "Export directory permission already available")
      return resolvedExportDirectoryURL()
    }

    // If user dismissed runtime picker once in this app session, avoid re-prompt loops.
    guard !didPromptForMissingExportPermissionThisSession else {
      DiagnosticLogger.shared.log(.warning, .fileAccess, "Export directory permission prompt suppressed for session")
      return nil
    }
    didPromptForMissingExportPermissionThisSession = true

    DiagnosticLogger.shared.log(.warning, .fileAccess, "Export directory permission missing; prompting user")
    return chooseExportDirectory(
      message: promptMessage,
      prompt: L10n.FileAccess.chooseFolderPrompt,
      directoryURL: resolvedExportDirectoryURL()
    )
  }

  func beginAccessingURL(_ targetURL: URL) -> ScopedAccess {
    let scopeURL = resolveURLForScopedAccess(targetURL)
    var accessURL = scopeURL
    var didStartAccessing = scopeURL.startAccessingSecurityScopedResource()

    // Fallback to target URL if bookmark-scope start failed.
    if !didStartAccessing, scopeURL.standardizedFileURL != targetURL.standardizedFileURL {
      didStartAccessing = targetURL.startAccessingSecurityScopedResource()
      if didStartAccessing {
        accessURL = targetURL
      }
    }

    if !didStartAccessing, isRunningSandboxed {
      logger.error(
        "Failed to start security-scoped access for target: \(targetURL.path, privacy: .public)"
      )
      DiagnosticLogger.shared.log(
        .error,
        .fileAccess,
        "Failed to start security-scoped file access",
        context: ["fileName": targetURL.lastPathComponent]
      )
    }

    return ScopedAccess(url: targetURL, accessURL: accessURL, didStartAccessing: didStartAccessing)
  }

  func withScopedAccess<T>(to targetURL: URL, _ operation: () throws -> T) rethrows -> T {
    let access = beginAccessingURL(targetURL)
    defer { access.stop() }
    return try operation()
  }

  private func resolveURLForScopedAccess(_ targetURL: URL) -> URL {
    guard let exportBookmarkURL = resolveExportBookmarkURL(removeInvalidBookmark: true) else {
      return targetURL
    }

    let targetPath = targetURL.standardizedFileURL.resolvingSymlinksInPath().path
    let bookmarkPath = exportBookmarkURL.standardizedFileURL.resolvingSymlinksInPath().path

    if targetPath == bookmarkPath || targetPath.hasPrefix(bookmarkPath + "/") {
      return exportBookmarkURL
    }
    return targetURL
  }

  private func resolveExportBookmarkURL(removeInvalidBookmark: Bool) -> URL? {
    guard let bookmarkData = defaults.data(forKey: PreferencesKeys.exportLocationBookmark) else {
      return nil
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      ).standardizedFileURL

      if isStale {
        _ = setExportDirectory(url)
        DiagnosticLogger.shared.log(
          .warning,
          .fileAccess,
          "Export directory bookmark was stale and refreshed",
          context: ["directory": url.lastPathComponent]
        )
      }

      return url
    } catch {
      if removeInvalidBookmark {
        defaults.removeObject(forKey: PreferencesKeys.exportLocationBookmark)
      }
      DiagnosticLogger.shared.logError(
        .fileAccess,
        error,
        "Export directory bookmark resolve failed",
        context: ["removedInvalidBookmark": removeInvalidBookmark ? "true" : "false"]
      )
      return nil
    }
  }

  private func showBookmarkSaveFailedAlert() {
    DiagnosticLogger.shared.log(.warning, .fileAccess, "Export bookmark save failure alert shown")
    let alert = NSAlert()
    alert.messageText = L10n.FileAccess.bookmarkSaveFailedTitle
    alert.informativeText = L10n.FileAccess.bookmarkSaveFailedMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  private var isRunningSandboxed: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }
}
