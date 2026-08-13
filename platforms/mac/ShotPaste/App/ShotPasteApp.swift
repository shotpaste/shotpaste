//
//  ShotPasteApp.swift
//  ShotPaste
//
//  Main app entry point - Menu Bar App
//

import AppKit
import Carbon
import SwiftUI

@main
struct ShotPasteApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @ObservedObject private var themeManager = ThemeManager.shared

  init() {
    AppIdentityManager.shared.refresh()
  }

  var body: some Scene {
    // Settings Window
    Settings {
      PreferencesView()
        .preferredColorScheme(themeManager.systemAppearance)
    }
    .commands {
      CommandMenu(L10n.Common.preferences) {
        preferencesCommand(L10n.Preferences.generalTab, tab: .general, key: "1")
        preferencesCommand(L10n.Preferences.captureTab, tab: .capture, key: "2")
        preferencesCommand(L10n.Preferences.quickAccessTab, tab: .quickAccess, key: "3")
        preferencesCommand(L10n.Preferences.historyTab, tab: .history, key: "4")
        preferencesCommand(L10n.Preferences.shortcutsTab, tab: .shortcuts, key: "5")
        preferencesCommand(L10n.Preferences.permissionsTab, tab: .permissions, key: "6")
        preferencesCommand(L10n.Preferences.advancedTab, tab: .advanced, key: "7")
      }
    }
  }

  private func preferencesCommand(_ title: String, tab: PreferencesTab, key: KeyEquivalent) -> some View {
    Button(title) {
      AppStatusBarController.shared.openPreferencesWindow(tab: tab)
    }
    .keyboardShortcut(key, modifiers: .command)
  }
}

struct AppLaunchPolicy {
  private let environment: [String: String]
  private let screenCountProvider: () -> Int

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    screenCountProvider: @escaping () -> Int = { NSScreen.screens.count }
  ) {
    self.environment = environment
    self.screenCountProvider = screenCountProvider
  }

  var shouldStartInteractiveApplication: Bool {
    if isRunningUnderXCTest, !allowsInteractiveXCTestHost {
      return false
    }

    return !isHeadlessDisplaySession
  }

  var isRunningUnderXCTest: Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  var isHeadlessDisplaySession: Bool {
    screenCountProvider() == 0
  }

  private var allowsInteractiveXCTestHost: Bool {
    environment["SHOTPASTE_ALLOW_INTERACTIVE_XCTEST_HOST"] == "1"
  }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  private let launchPolicyProvider: () -> AppLaunchPolicy
  private var coordinator: AppCoordinator?
  private var pendingDeepLinkURLs: [URL] = []
  private var didFinishLaunching = false

  override init() {
    launchPolicyProvider = { AppLaunchPolicy() }
    super.init()
  }

  init(launchPolicyProvider: @escaping () -> AppLaunchPolicy) {
    self.launchPolicyProvider = launchPolicyProvider
    super.init()
  }

  func applicationWillFinishLaunching(_: Notification) {
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  func applicationDidFinishLaunching(_: Notification) {
    guard launchPolicyProvider().shouldStartInteractiveApplication else {
      return
    }

    DebugDataIsolationMigration.applyIfNeeded()
    AppIdentityManager.shared.refresh()

    guard ensureDatabaseReadyForLaunch() else {
      return
    }

    // Cleanup orphaned temp capture files from previous sessions
    TempCaptureManager.shared.cleanupOrphanedFiles()

    let coordinator = AppCoordinator(environment: AppEnvironment.live())
    self.coordinator = coordinator
    coordinator.applicationDidFinishLaunching()
    didFinishLaunching = true
    flushPendingDeepLinks()
  }

  func applicationWillTerminate(_: Notification) {
    NSAppleEventManager.shared().removeEventHandler(
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
    coordinator?.applicationWillTerminate()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard didFinishLaunching else { return .terminateNow }

    let recordingCoordinator = RecordingCoordinator.shared
    if recordingCoordinator.requiresTerminationHandling {
      if recordingCoordinator.hasRecordedContent {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.Recording.quitConfirmationTitle
        alert.informativeText = L10n.Recording.quitConfirmationMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.Common.stopAndQuit)
        alert.addButton(withTitle: L10n.Common.discardAndQuit)
        alert.addButton(withTitle: L10n.Common.cancel)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
          recordingCoordinator.stopForApplicationTermination { succeeded in
            sender.reply(toApplicationShouldTerminate: succeeded)
          }
          return .terminateLater
        case .alertSecondButtonReturn:
          recordingCoordinator.discardForApplicationTermination { succeeded in
            sender.reply(toApplicationShouldTerminate: succeeded)
          }
          return .terminateLater
        default:
          return .terminateCancel
        }
      }

      guard confirmDiscardActiveCapture() else { return .terminateCancel }
      recordingCoordinator.discardForApplicationTermination { succeeded in
        sender.reply(toApplicationShouldTerminate: succeeded)
      }
      return .terminateLater
    }

    if ScrollingCaptureCoordinator.shared.isActive || OneShotCoordinator.shared.isActive {
      guard confirmDiscardActiveCapture() else { return .terminateCancel }
      ScrollingCaptureCoordinator.shared.cancel()
      guard OneShotCoordinator.shared.cancel(discardChanges: true) else {
        return .terminateCancel
      }
    }

    return .terminateNow
  }

  private func confirmDiscardActiveCapture() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L10n.Common.activeCaptureTitle
    alert.informativeText = L10n.Common.activeCaptureMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.returnToShotPaste)
    alert.addButton(withTitle: L10n.Common.discardAndQuit)
    return alert.runModal() == .alertSecondButtonReturn
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    guard didFinishLaunching else { return true }
    let showsMenuBarIcon = UserDefaults.standard.object(forKey: PreferencesKeys.showMenuBarIcon) as? Bool ?? true
    guard !showsMenuBarIcon else { return true }

    AppStatusBarController.shared.openPreferencesWindow(tab: .general)
    return false
  }

  private enum DatabaseLaunchRecoveryAction {
    case repair
    case reset
    case quit
  }

  private func ensureDatabaseReadyForLaunch() -> Bool {
    switch DatabaseManager.prepare() {
    case .success:
      true
    case let .failure(error):
      presentDatabaseRecoveryFlow(startingWith: error)
    }
  }

  private func presentDatabaseRecoveryFlow(startingWith error: Error) -> Bool {
    var currentError: Error = error
    var note: String?

    while true {
      switch presentDatabaseRecoveryAlert(error: currentError, note: note) {
      case .repair:
        do {
          try DatabaseManager.attemptRepair()
          return true
        } catch {
          currentError = error
          note = "Repair did not succeed. You can reset the database after backing up the current files, or quit ShotPaste."
        }

      case .reset:
        guard confirmDatabaseReset(error: currentError) else {
          note = nil
          continue
        }

        do {
          let archive = try DatabaseManager.resetDatabaseFiles()
          switch DatabaseManager.retryInitialization() {
          case .success:
            if let archiveDirectoryURL = archive.archiveDirectoryURL {
              DiagnosticLogger.shared.log(
                .warning,
                .lifecycle,
                "Database reset during launch",
                context: ["archive": archiveDirectoryURL.path]
              )
            }
            return true
          case let .failure(error):
            currentError = error
            note = "Reset moved the old database files aside, but ShotPaste still could not create a fresh database."
          }
        } catch {
          currentError = error
          note = "Reset failed before ShotPaste could create a fresh database."
        }

      case .quit:
        NSApp.terminate(nil)
        return false
      }
    }
  }

  private func presentDatabaseRecoveryAlert(
    error: Error,
    note: String?
  ) -> DatabaseLaunchRecoveryAction {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "ShotPaste could not open its database."

    var informativeText = """
    ShotPaste needs this database for capture history.

    Database:
    \(DatabaseManager.defaultDatabaseURL.path)

    Error:
    \(error.localizedDescription)
    """
    if let note {
      informativeText += "\n\n\(note)"
    }
    informativeText += "\n\nTry a repair first. Reset starts with an empty database after moving the current database files into a recovery folder."
    alert.informativeText = informativeText

    alert.addButton(withTitle: "Try Repair")
    alert.addButton(withTitle: "Reset Database...")
    alert.addButton(withTitle: "Quit ShotPaste")

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .repair
    case .alertSecondButtonReturn:
      return .reset
    default:
      return .quit
    }
  }

  private func confirmDatabaseReset(error: Error) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Reset ShotPaste Database?"
    alert.informativeText = """
    ShotPaste will move the current database files into a recovery folder, then create a new empty database.

    This resets capture history inside ShotPaste. Capture files on disk are not deleted.

    Database:
    \(DatabaseManager.defaultDatabaseURL.path)

    Current error:
    \(error.localizedDescription)
    """
    alert.addButton(withTitle: "Reset Database")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  @objc private func handleGetURLEvent(
    _ event: NSAppleEventDescriptor,
    withReplyEvent _: NSAppleEventDescriptor
  ) {
    guard
      let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
      let url = URL(string: urlString)
    else {
      DiagnosticLogger.shared.log(.warning, .action, "Received invalid URL event")
      return
    }

    guard let coordinator else {
      pendingDeepLinkURLs.append(url)
      return
    }

    coordinator.handleDeepLink(url)
  }

  private func flushPendingDeepLinks() {
    guard let coordinator, !pendingDeepLinkURLs.isEmpty else { return }

    let urls = pendingDeepLinkURLs
    pendingDeepLinkURLs.removeAll()
    urls.forEach { coordinator.handleDeepLink($0) }
  }

  #if DEBUG
    var hasCoordinatorForTesting: Bool {
      coordinator != nil
    }

    var didFinishLaunchingForTesting: Bool {
      didFinishLaunching
    }

  #endif
}
