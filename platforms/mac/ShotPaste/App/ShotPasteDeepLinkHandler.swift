//
//  ShotPasteDeepLinkHandler.swift
//  ShotPaste
//
//  Handles shotpaste:// automation URLs for external launchers and workflows.
//

import AppKit
import Foundation

private enum AppURLScheme {
  #if DEBUG
    static let current = "shotpaste-debug"
    static let supported = Set([current, "shotpaste"])
  #else
    static let current = "shotpaste"
    static let supported = Set([current])
  #endif
}

@MainActor
struct ShotPasteDeepLinkHandler {
  private let screenCaptureViewModel: ScreenCaptureViewModel

  init(screenCaptureViewModel: ScreenCaptureViewModel) {
    self.screenCaptureViewModel = screenCaptureViewModel
  }

  func handle(_ url: URL) {
    guard UserDefaults.standard.object(forKey: PreferencesKeys.urlSchemeEnabled) as? Bool ?? true else {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Ignored deeplink because URL Scheme automation is disabled"
      )
      return
    }

    guard let action = ShotPasteDeepLinkAction(url: url) else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Ignored unsupported deeplink",
        context: [
          "scheme": url.scheme ?? "",
          "host": url.host ?? "",
          "path": url.path,
        ]
      )
      return
    }

    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Handling deeplink",
      context: ["action": action.logName]
    )

    switch action {
    case .captureOneShot:
      screenCaptureViewModel.startOneShot()
    case .openHistory:
      HistoryWindowController.shared.showWindow()
    case .openSettings(let tab):
      AppStatusBarController.shared.openPreferencesWindow(tab: tab)
    }
  }
}

enum ShotPasteDeepLinkAction: Equatable {
  case captureOneShot
  case openHistory
  case openSettings(PreferencesTab?)

  init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), AppURLScheme.supported.contains(scheme) else {
      return nil
    }

    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = url.host?.lowercased()
    let pathParts = url.path.split(separator: "/").map { $0.lowercased() }
    let parts = ([host] + pathParts).compactMap { $0 }
    let command = parts.joined(separator: "/")

    switch command {
    case "capture/one-shot", "one-shot", "oneshot", "screenshot/one-shot":
      self = .captureOneShot
    case "open/history", "history", "capture-history":
      self = .openHistory
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
    case let value where value.hasPrefix("settings/"):
      guard let tab = Self.preferencesTab(
        named: Self.requestedPreferencesTabName(from: components, pathParts: pathParts)
      ) else { return nil }
      self = .openSettings(tab)
    case let value where value.hasPrefix("preferences/"):
      guard let tab = Self.preferencesTab(
        named: Self.requestedPreferencesTabName(from: components, pathParts: pathParts)
      ) else { return nil }
      self = .openSettings(tab)
    default:
      return nil
    }
  }

  var logName: String {
    switch self {
    case .captureOneShot: "captureOneShot"
    case .openHistory: "openHistory"
    case .openSettings(let tab): "openSettings(\(String(describing: tab)))"
    }
  }

  private static func requestedPreferencesTabName(
    from components: URLComponents?,
    pathParts: [String]
  ) -> String? {
    let queryTab = components?.queryItems?
      .first(where: { $0.name.lowercased() == "tab" })?
      .value?
      .lowercased()

    let pathTab = pathParts.first
    return queryTab ?? pathTab
  }

  private static func preferencesTab(named name: String?) -> PreferencesTab? {
    switch name {
    case "general":
      .general
    case "capture", "screenshots", "screenshot":
      .capture
    case "quick-access", "quickaccess":
      .quickAccess
    case "history":
      .history
    case "shortcuts", "keyboard-shortcuts":
      .shortcuts
    case "permissions", "privacy":
      .permissions
    case "advanced", "configuration", "config", "toml":
      .advanced
    default:
      nil
    }
  }
}
