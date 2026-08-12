//
//  AppUpdateManager.swift
//  ShotPaste
//
//  Coordinates low-frequency automatic checks and user-initiated checks.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AppUpdateManager: ObservableObject {
  enum State: Equatable {
    case idle(currentVersion: String)
    case checking(currentVersion: String)
    case upToDate(version: String)
    case updateAvailable(currentVersion: String, release: AppRelease)
    case failed(currentVersion: String)
  }

  static let shared = AppUpdateManager(
    service: AppUpdateService(),
    defaults: .standard
  )
  static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

  @Published private(set) var state: State

  private let service: AppUpdateService
  private let defaults: UserDefaults
  private var isChecking = false

  private init(
    service: AppUpdateService,
    defaults: UserDefaults
  ) {
    self.service = service
    self.defaults = defaults
    state = .idle(currentVersion: service.currentVersionString)
  }

  func checkAutomaticallyIfNeeded(now: Date = Date()) {
    let isEnabled = defaults.object(forKey: PreferencesKeys.checkForUpdatesAutomatically) as? Bool ?? true
    guard isEnabled, !isChecking else { return }

    if let lastCheck = defaults.object(forKey: PreferencesKeys.lastUpdateCheckDate) as? Date,
       now.timeIntervalSince(lastCheck) < Self.automaticCheckInterval {
      return
    }

    Task { await performCheck(manually: false, checkedAt: now) }
  }

  func checkManually() {
    Task { await performCheck(manually: true, checkedAt: Date()) }
  }

  func openAvailableRelease() {
    guard case let .updateAvailable(_, release) = state else { return }
    NSWorkspace.shared.open(release.pageURL)
  }

  private func performCheck(manually: Bool, checkedAt: Date) async {
    guard !isChecking else { return }
    isChecking = true
    state = .checking(currentVersion: service.currentVersionString)

    defer {
      isChecking = false
      defaults.set(checkedAt, forKey: PreferencesKeys.lastUpdateCheckDate)
    }

    do {
      let result = try await service.checkForUpdates()
      switch result {
      case let .upToDate(currentVersion, _):
        state = .upToDate(version: currentVersion.description)
        if manually {
          presentUpToDateAlert(version: currentVersion.description)
        }

      case let .updateAvailable(currentVersion, latestRelease):
        state = .updateAvailable(
          currentVersion: currentVersion.description,
          release: latestRelease
        )

        let version = latestRelease.version.description
        let lastPromptedVersion = defaults.string(forKey: PreferencesKeys.lastPromptedUpdateVersion)
        if manually || lastPromptedVersion != version {
          defaults.set(version, forKey: PreferencesKeys.lastPromptedUpdateVersion)
          presentUpdateAvailableAlert(
            currentVersion: currentVersion.description,
            release: latestRelease
          )
        }
      }
    } catch {
      state = .failed(currentVersion: service.currentVersionString)
      DiagnosticLogger.shared.logError(.lifecycle, error, "GitHub update check failed")
      if manually {
        presentFailureAlert()
      }
    }
  }

  private func presentUpdateAvailableAlert(currentVersion: String, release: AppRelease) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L10n.PreferencesGeneral.updatesSection
    alert.informativeText = """
    \(L10n.PreferencesGeneral.updateCurrentVersion): \(currentVersion)
    \(L10n.PreferencesGeneral.updateLatestVersion): \(release.version)

    \(L10n.PreferencesGeneral.updateOpenGitHubPrompt)
    """
    alert.addButton(withTitle: L10n.PreferencesGeneral.updateOpenGitHubButton)
    alert.addButton(withTitle: L10n.Common.cancel)
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(release.pageURL)
    }
  }

  private func presentUpToDateAlert(version: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L10n.PreferencesGeneral.updatesSection
    alert.informativeText = "\(L10n.PreferencesGeneral.updateUpToDate) · v\(version)"
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  private func presentFailureAlert() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L10n.PreferencesGeneral.updatesSection
    alert.informativeText = L10n.PreferencesGeneral.updateCheckFailed
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }
}
