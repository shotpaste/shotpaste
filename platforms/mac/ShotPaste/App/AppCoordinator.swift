//
//  AppCoordinator.swift
//  ShotPaste
//
//  App lifecycle orchestration for startup and shutdown.
//

import AppKit
import CoreGraphics
import Foundation

struct PermissionGuideLaunchPolicy {
  static let currentVersion = 1

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Consumes the current guide version exactly once. Existing users who
  /// already have usable access should not see onboarding later if they revoke
  /// a permission intentionally.
  func consumePresentationIfNeeded(hasUsableScreenRecordingPermission: Bool) -> Bool {
    let presentedVersion = defaults.integer(forKey: PreferencesKeys.permissionGuidePresentedVersion)
    guard presentedVersion < Self.currentVersion else { return false }

    defaults.set(Self.currentVersion, forKey: PreferencesKeys.permissionGuidePresentedVersion)
    return !hasUsableScreenRecordingPermission
  }
}

@MainActor
final class AppCoordinator {
  private let environment: AppEnvironment
  private let automationController: ShotPasteAutomationController

  init(environment: AppEnvironment) {
    self.environment = environment
    automationController = ShotPasteAutomationController(
      screenCaptureViewModel: environment.screenCaptureViewModel
    )
  }

  func applicationDidFinishLaunching() {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: PreferencesKeys.diagnosticsEnabled) == nil {
      defaults.set(true, forKey: PreferencesKeys.diagnosticsEnabled)
    }

    AppIdentityManager.shared.refresh()
    let didCrash = CrashSentinel.shared.checkAndReset()
    DiagnosticLogger.shared.startSession()
    DiagnosticLogger.shared.log(
      .info,
      .lifecycle,
      "App launch sequence started",
      context: ["previousCrash": didCrash ? "true" : "false"]
    )
    if defaults.object(forKey: PreferencesKeys.diagnosticsRetentionDays) == nil {
      defaults.set(LogCleanupScheduler.defaultRetentionDays, forKey: PreferencesKeys.diagnosticsRetentionDays)
    }

    if defaults.object(forKey: PreferencesKeys.urlSchemeEnabled) == nil {
      defaults.set(true, forKey: PreferencesKeys.urlSchemeEnabled)
    }
    if defaults.object(forKey: PreferencesKeys.mcpServerEnabled) == nil {
      defaults.set(false, forKey: PreferencesKeys.mcpServerEnabled)
    }
    if defaults.object(forKey: PreferencesKeys.mcpServerPort) == nil {
      defaults.set(ShotPasteMCPServer.defaultPort, forKey: PreferencesKeys.mcpServerPort)
    }

    // History defaults
    if defaults.object(forKey: PreferencesKeys.historyEnabled) == nil {
      defaults.set(true, forKey: PreferencesKeys.historyEnabled)
    }
    if defaults.object(forKey: PreferencesKeys.historyRetentionDays) == nil {
      defaults.set(PreferencesKeys.defaultHistoryRetentionDays, forKey: PreferencesKeys.historyRetentionDays)
    }
    if defaults.object(forKey: PreferencesKeys.historyMaxCount) == nil {
      defaults.set(PreferencesKeys.defaultHistoryMaxCount, forKey: PreferencesKeys.historyMaxCount)
    }
    if defaults.object(forKey: PreferencesKeys.mediaClipboardEnabled) == nil {
      defaults.set(true, forKey: PreferencesKeys.mediaClipboardEnabled)
    }
    if defaults.object(forKey: "history.floating.position") == nil {
      defaults.set("topCenter", forKey: "history.floating.position")
    }
    // Remove preferences that belonged exclusively to the deleted compact
    // Clipboard History interface.
    for obsoleteKey in [
      "history.floating.enabled",
      "history.floating.maxDisplayedItems",
      "history.toggleModeShortcut",
      "history.isToggleModeShortcutEnabled",
    ] {
      defaults.removeObject(forKey: obsoleteKey)
    }
    let configurationAutoImportResult = applyUserConfigurationIfNeeded()
    startConfigurationSync(after: configurationAutoImportResult)

    LogCleanupScheduler.shared.start()
    RecordingMetadataCleanupScheduler.shared.start()
    CaptureHistoryRetentionService.shared.start()
    MediaClipboardMonitor.shared.start()
    DiagnosticLogger.shared.log(.debug, .lifecycle, "Background schedulers started")

    AppStatusBarController.shared.setup(
      viewModel: environment.screenCaptureViewModel,
      didCrash: didCrash && DiagnosticLogger.shared.isEnabled
    )
    ShotPasteMCPServer.shared.configure(automationController: automationController)
    #if !DEBUG
      AppUpdateManager.shared.checkAutomaticallyIfNeeded()
    #endif
    DiagnosticLogger.shared.log(
      .debug,
      .ui,
      "Status bar controller configured",
      context: ["crashPrompt": (didCrash && DiagnosticLogger.shared.isEnabled) ? "true" : "false"]
    )

    presentPermissionGuideIfNeeded(defaults: defaults)
  }

  private func presentPermissionGuideIfNeeded(defaults: UserDefaults) {
    let hasUsableScreenRecordingPermission = CGPreflightScreenCaptureAccess()
      && AppIdentityManager.shared.health.isHealthy
    let policy = PermissionGuideLaunchPolicy(defaults: defaults)

    guard policy.consumePresentationIfNeeded(
      hasUsableScreenRecordingPermission: hasUsableScreenRecordingPermission
    ) else { return }

    DiagnosticLogger.shared.log(.info, .preferences, "First-run permission guide scheduled")
    DispatchQueue.main.async {
      AppStatusBarController.shared.openPreferencesWindow(tab: .permissions)
    }
  }

  func applicationWillTerminate() {
    flushConfigurationSyncBeforeTermination()
    DiagnosticLogger.shared.log(.info, .lifecycle, "App terminated normally")
    CrashSentinel.shared.markTerminated()
    LogCleanupScheduler.shared.stop()
    RecordingMetadataCleanupScheduler.shared.stop()
    MediaClipboardMonitor.shared.stop()
    ShotPasteMCPServer.shared.stop()
    ShotPasteConfigurationSyncCoordinator.shared.stop()
  }

  func handleDeepLink(_ url: URL) {
    ShotPasteDeepLinkHandler(automationController: automationController)
      .handle(url)
  }

  private func applyUserConfigurationIfNeeded() -> ShotPasteConfigurationAutoImportResult {
    let result = ShotPasteConfigurationAutoImporter.applyIfNeededOnLaunch()
    let context = [
      "file": result.fileURL.path,
      "changes": "\(result.appliedChangeCount)",
      "warnings": "\(result.warningCount)",
      "errors": "\(result.errorCount)",
    ]

    switch result.status {
    case .applied:
      DiagnosticLogger.shared.log(
        .info,
        .preferences,
        "TOML configuration auto-applied",
        context: context
      )
    case .failed:
      var failedContext = context
      if let errorMessage = result.errorMessage {
        failedContext["error"] = errorMessage
      }
      DiagnosticLogger.shared.log(
        .warning,
        .preferences,
        "TOML configuration auto-apply failed",
        context: failedContext
      )
    case .skippedMissingFile:
      DiagnosticLogger.shared.log(
        .debug,
        .preferences,
        "TOML configuration auto-apply skipped; file missing",
        context: ["file": result.fileURL.path]
      )
    case .skippedPermissionRequired:
      DiagnosticLogger.shared.log(
        .debug,
        .preferences,
        "TOML configuration auto-apply skipped; folder access required",
        context: ["file": result.fileURL.path]
      )
    case .skippedUnchanged:
      DiagnosticLogger.shared.log(
        .debug,
        .preferences,
        "TOML configuration auto-apply skipped; file unchanged",
        context: ["file": result.fileURL.path]
      )
    }

    return result
  }

  private func startConfigurationSync(after autoImportResult: ShotPasteConfigurationAutoImportResult) {
    let coordinator = ShotPasteConfigurationSyncCoordinator.shared
    coordinator.start()

    guard autoImportResult.status != .applied else { return }
    coordinator.scheduleSync(reason: .appLaunch)
  }

  private func flushConfigurationSyncBeforeTermination() {
    do {
      try ShotPasteConfigurationSyncCoordinator.shared.flushPendingSync(reason: .appTerminate)
    } catch {
      DiagnosticLogger.shared.logError(
        .preferences,
        error,
        "TOML configuration sync before termination failed"
      )
    }
  }
}
