//
//  CrashReportService.swift
//  LiteScreen
//
//  Centralized problem report presentation logic.
//  Both the status bar menu and preferences call this single entry point.
//

import AppKit

enum CrashReportService {
  static let bugReportURL = URL(string: "https://github.com/ahtcfg24/LiteScreen/issues/new")!

  /// Present the problem report alert with a draggable diagnostic log archive.
  /// Returns `true` if the user chose to open the report page.
  @MainActor
  @discardableResult
  static func presentAlert() -> Bool {
    let archiveURL = makeLogArchive()

    let alert = NSAlert()
    alert.messageText = L10n.CrashReport.alertTitle
    alert.informativeText = archiveURL == nil ? L10n.CrashReport.alertMessageNoLogBundle : L10n.CrashReport.alertMessage
    alert.alertStyle = .informational
    alert.addButton(withTitle: L10n.CrashReport.submit)
    alert.addButton(withTitle: L10n.CrashReport.dismiss)

    if let archiveURL {
      alert.accessoryView = CrashReportAccessoryView(fileURL: archiveURL)
    }

    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
      NSWorkspace.shared.open(bugReportURL)
      return true
    }

    return false
  }

  private static func makeLogArchive() -> URL? {
    do {
      return try ProblemReportLogArchive.makeArchive(
        from: DiagnosticLogger.shared.logDirectoryURL,
        reportURL: bugReportURL
      )
    } catch {
      DiagnosticLogger.shared.logError(.preferences, error, "Problem report log archive failed")
      return nil
    }
  }
}
