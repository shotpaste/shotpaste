//
//  ShotPasteAutomation.swift
//  ShotPaste
//
//  Shared, allow-listed automation commands used by URL Scheme and MCP.
//

import AppKit
import Foundation

enum ShotPasteAutomationCaptureMode: String, CaseIterable, Equatable {
  case screenshot
  case scrolling
  case recording

  var oneShotTab: OneShotTab {
    switch self {
    case .screenshot: .screenshot
    case .scrolling: .scrolling
    case .recording: .recording
    }
  }
}

enum ShotPasteAutomationHistoryFilter: String, CaseIterable, Equatable {
  case all
  case screenshot
  case scrolling
  case recording
  case clipboard

  var captureHistoryCategory: CaptureHistoryCategory? {
    switch self {
    case .all: nil
    case .screenshot: .screenshot
    case .scrolling: .scrollingScreenshot
    case .recording: .recording
    case .clipboard: .clipboard
    }
  }
}

enum ShotPasteAutomationRecordingAction: String, CaseIterable, Equatable {
  case pause
  case resume
  case stop
}

enum ShotPasteAutomationCommand: Equatable {
  case startCapture(ShotPasteAutomationCaptureMode)
  case cancelCapture
  case openHistory(ShotPasteAutomationHistoryFilter?)
  case openSettings(PreferencesTab?)
  case controlRecording(ShotPasteAutomationRecordingAction)

  var logName: String {
    switch self {
    case .startCapture(let mode): "startCapture(\(mode.rawValue))"
    case .cancelCapture: "cancelCapture"
    case .openHistory(let filter): "openHistory(\(filter?.rawValue ?? "default"))"
    case .openSettings(let tab): "openSettings(\(Self.settingsTabName(tab) ?? "default"))"
    case .controlRecording(let action): "controlRecording(\(action.rawValue))"
    }
  }

  init?(url: URL, variant: AppVariant = .current) {
    guard let scheme = url.scheme?.lowercased(), scheme == variant.urlScheme else {
      return nil
    }

    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = url.host?.lowercased()
    let pathParts = url.path.split(separator: "/").map { $0.lowercased() }
    let parts = ([host] + pathParts).compactMap { $0 }
    let command = parts.joined(separator: "/")

    switch command {
    case "capture/one-shot", "capture", "one-shot", "oneshot", "screenshot/one-shot":
      guard let mode = Self.captureMode(from: components, default: .screenshot) else { return nil }
      self = .startCapture(mode)
    case "capture/screenshot", "screenshot":
      self = .startCapture(.screenshot)
    case "capture/scrolling", "scrolling-capture":
      self = .startCapture(.scrolling)
    case "record", "record/screen", "recording/start":
      self = .startCapture(.recording)
    case "capture/cancel", "one-shot/cancel":
      self = .cancelCapture
    case "open/history", "history", "capture-history":
      guard let filter = Self.historyFilter(from: components) else { return nil }
      self = .openHistory(filter)
    case "open/clipboard", "clipboard-history":
      self = .openHistory(.clipboard)
    case "recording/pause":
      self = .controlRecording(.pause)
    case "recording/resume":
      self = .controlRecording(.resume)
    case "recording/stop", "record/stop":
      self = .controlRecording(.stop)
    case "settings", "preferences":
      guard let requestedTabName = Self.requestedPreferencesTabName(
        from: components,
        pathParts: pathParts
      ) else {
        self = .openSettings(nil)
        return
      }
      guard let tab = Self.preferencesTab(named: requestedTabName) else { return nil }
      self = .openSettings(tab)
    case let value where value.hasPrefix("settings/") || value.hasPrefix("preferences/"):
      guard let tab = Self.preferencesTab(
        named: Self.requestedPreferencesTabName(from: components, pathParts: pathParts)
      ) else { return nil }
      self = .openSettings(tab)
    default:
      return nil
    }
  }

  static func preferencesTab(named name: String?) -> PreferencesTab? {
    switch normalizedValue(name) {
    case "general": .general
    case "capture", "screenshots", "screenshot": .capture
    case "quick-access", "quickaccess": .quickAccess
    case "history": .history
    case "agent", "agent-mode": .agent
    case "shortcuts", "keyboard-shortcuts": .shortcuts
    case "permissions", "privacy": .permissions
    case "advanced", "configuration", "config", "toml": .advanced
    default: nil
    }
  }

  static func settingsTabName(_ tab: PreferencesTab?) -> String? {
    switch tab {
    case .general: "general"
    case .capture: "capture"
    case .quickAccess: "quick-access"
    case .history: "history"
    case .agent: "agent"
    case .shortcuts: "shortcuts"
    case .permissions: "permissions"
    case .advanced: "advanced"
    case nil: nil
    }
  }

  private static func captureMode(
    from components: URLComponents?,
    default defaultMode: ShotPasteAutomationCaptureMode
  ) -> ShotPasteAutomationCaptureMode? {
    guard let value = queryValue(named: "mode", from: components), !value.isEmpty else {
      return defaultMode
    }
    return ShotPasteAutomationCaptureMode(rawValue: normalizedValue(value) ?? "")
  }

  /// A missing filter is valid and means the user's configured default. An
  /// unknown filter is rejected instead of silently widening the history view.
  private static func historyFilter(
    from components: URLComponents?
  ) -> ShotPasteAutomationHistoryFilter?? {
    guard let value = queryValue(named: "filter", from: components), !value.isEmpty else {
      return .some(nil)
    }

    let normalized = normalizedValue(value)
    let filter: ShotPasteAutomationHistoryFilter? = switch normalized {
    case "all": .all
    case "screenshot", "screenshots": .screenshot
    case "scrolling", "scrolling-screenshot", "scrolling-screenshots": .scrolling
    case "recording", "recordings", "video", "videos": .recording
    case "clipboard": .clipboard
    default: nil
    }
    guard let filter else { return nil }
    return .some(filter)
  }

  private static func requestedPreferencesTabName(
    from components: URLComponents?,
    pathParts: [String]
  ) -> String? {
    queryValue(named: "tab", from: components) ?? pathParts.first
  }

  private static func queryValue(named name: String, from components: URLComponents?) -> String? {
    components?.queryItems?
      .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?
      .value
  }

  private static func normalizedValue(_ value: String?) -> String? {
    value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
  }
}

nonisolated struct ShotPasteAutomationResult {
  let isSuccess: Bool
  let message: String
  let state: [String: String]

  static func success(_ message: String, state: [String: String] = [:]) -> Self {
    Self(isSuccess: true, message: message, state: state)
  }

  static func failure(_ message: String, state: [String: String] = [:]) -> Self {
    Self(isSuccess: false, message: message, state: state)
  }
}

@MainActor
final class ShotPasteAutomationController {
  private let screenCaptureViewModel: ScreenCaptureViewModel

  init(screenCaptureViewModel: ScreenCaptureViewModel) {
    self.screenCaptureViewModel = screenCaptureViewModel
  }

  func execute(_ command: ShotPasteAutomationCommand, source: String) -> ShotPasteAutomationResult {
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Handling automation command",
      context: ["action": command.logName, "source": source]
    )

    let result: ShotPasteAutomationResult
    switch command {
    case .startCapture(let mode):
      result = startCapture(mode)
    case .cancelCapture:
      result = cancelCapture()
    case .openHistory(let filter):
      result = openHistory(filter)
    case .openSettings(let tab):
      AppStatusBarController.shared.openPreferencesWindow(tab: tab)
      result = .success("Opened ShotPaste settings.", state: statusState())
    case .controlRecording(let action):
      result = controlRecording(action)
    }

    DiagnosticLogger.shared.log(
      result.isSuccess ? .info : .warning,
      .action,
      result.isSuccess ? "Automation command accepted" : "Automation command rejected",
      context: [
        "action": command.logName,
        "source": source,
        "message": result.message,
      ]
    )
    return result
  }

  func status() -> ShotPasteAutomationResult {
    .success("ShotPaste automation status.", state: statusState())
  }

  private func startCapture(_ mode: ShotPasteAutomationCaptureMode) -> ShotPasteAutomationResult {
    if RecordingCoordinator.shared.isActive || ScrollingCaptureCoordinator.shared.isActive {
      return .failure("Another capture or recording session is already active.", state: statusState())
    }

    let started = screenCaptureViewModel.startOneShot(initialTab: mode.oneShotTab)
    if started {
      return .success("Started One Shot in \(mode.rawValue) mode.", state: statusState())
    }

    if !screenCaptureViewModel.hasPermission {
      return .failure(
        "Screen Recording permission is required; ShotPaste opened the permission flow.",
        state: statusState()
      )
    }
    return .failure("A capture session is already active.", state: statusState())
  }

  private func cancelCapture() -> ShotPasteAutomationResult {
    guard OneShotCoordinator.shared.isActive else {
      return .failure("No One Shot capture session is active.", state: statusState())
    }
    OneShotCoordinator.shared.cancel()
    return .success("Cancelled the active One Shot capture session.", state: statusState())
  }

  private func openHistory(
    _ filter: ShotPasteAutomationHistoryFilter?
  ) -> ShotPasteAutomationResult {
    if filter == .all {
      HistoryFloatingManager.shared.showAllHistory()
      HistoryFloatingManager.shared.focusPanel()
    } else if let filter {
      HistoryFloatingManager.shared.showHistory(initialFilter: filter.captureHistoryCategory)
      HistoryFloatingManager.shared.focusPanel()
    } else {
      HistoryWindowController.shared.showWindow()
    }
    NSApp.activate(ignoringOtherApps: true)
    return .success(
      "Opened ShotPaste history with the \(filter?.rawValue ?? "default") filter.",
      state: statusState()
    )
  }

  private func controlRecording(
    _ action: ShotPasteAutomationRecordingAction
  ) -> ShotPasteAutomationResult {
    let recorder = ScreenRecordingManager.shared
    switch action {
    case .pause:
      guard recorder.state == .recording else {
        return .failure("No running recording can be paused.", state: statusState())
      }
      recorder.pauseRecording()
    case .resume:
      guard recorder.state == .paused else {
        return .failure("No paused recording can be resumed.", state: statusState())
      }
      recorder.resumeRecording()
    case .stop:
      guard recorder.state.isPauseResumeEligible else {
        return .failure("No active recording can be stopped.", state: statusState())
      }
      RecordingCoordinator.shared.stopFromStatusItem()
    }

    return .success("Recording \(action.rawValue) request accepted.", state: statusState())
  }

  private func statusState() -> [String: String] {
    let recorder = ScreenRecordingManager.shared
    return [
      "platform": "macOS",
      "oneShot": OneShotCoordinator.shared.isActive ? "active" : "idle",
      "oneShotMode": OneShotCoordinator.shared.sessionState?.activeTab.rawValue ?? "none",
      "scrollingCapture": ScrollingCaptureCoordinator.shared.isActive ? "active" : "idle",
      "recording": String(describing: recorder.state),
      "recordingDuration": recorder.formattedDuration,
      "historyVisible": HistoryFloatingManager.shared.isVisible ? "true" : "false",
    ]
  }
}
