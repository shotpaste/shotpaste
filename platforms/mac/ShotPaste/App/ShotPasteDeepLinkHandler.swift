//
//  ShotPasteDeepLinkHandler.swift
//  ShotPaste
//
//  Handles shotpaste:// automation URLs for external launchers and workflows.
//

import Foundation

@MainActor
struct ShotPasteDeepLinkHandler {
  private let automationController: ShotPasteAutomationController

  init(automationController: ShotPasteAutomationController) {
    self.automationController = automationController
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

    guard let command = ShotPasteAutomationCommand(url: url) else {
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

    _ = automationController.execute(command, source: "urlScheme")
  }
}
