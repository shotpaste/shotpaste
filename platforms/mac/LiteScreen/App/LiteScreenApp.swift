//
//  LiteScreenApp.swift
//  LiteScreen
//
//  Main app entry point - Menu Bar App
//

import AppKit
import Carbon
import SwiftUI

@main
struct LiteScreenApp: App {
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
    environment["LITESCREEN_ALLOW_INTERACTIVE_XCTEST_HOST"] == "1"
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
          note = "Repair did not succeed. You can reset the database after backing up the current files, or quit Lite Screen."
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
            note = "Reset moved the old database files aside, but Lite Screen still could not create a fresh database."
          }
        } catch {
          currentError = error
          note = "Reset failed before Lite Screen could create a fresh database."
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
    alert.messageText = "Lite Screen could not open its database."

    var informativeText = """
    Lite Screen needs this database for capture history.

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
    alert.addButton(withTitle: "Quit Lite Screen")

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
    alert.messageText = "Reset Lite Screen Database?"
    alert.informativeText = """
    LiteScreen will move the current database files into a recovery folder, then create a new empty database.

    This resets capture history inside LiteScreen. Capture files on disk are not deleted.

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
