//
//  AgentModeController.swift
//  ShotPaste
//
//  Owns the persistent Agent product mode, its shortcut lifecycle, and the
//  clean multi-display intent-capture handoff into AgentSessionCoordinator.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics

@MainActor
final class AgentModeController: ObservableObject {
  static let shared = AgentModeController()

  @Published private(set) var isEnabled: Bool
  let sessionCoordinator: AgentSessionCoordinator

  private let contextAssembler: AgentContextAssembler
  private let credentialStore: AgentCredentialStore
  private var frozenSession: FrozenAreaCaptureSession?
  private var captureTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()

  private init() {
    let assembler = AgentContextAssembler()
    contextAssembler = assembler
    credentialStore = .shared
    sessionCoordinator = AgentSessionCoordinator(contextAssembler: assembler)
    isEnabled = UserDefaults.standard.bool(forKey: PreferencesKeys.agentModeEnabled)

    sessionCoordinator.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  var phase: AgentSessionPhase {
    sessionCoordinator.phase
  }

  var statusMessage: String {
    sessionCoordinator.statusMessage
  }

  var isSessionActive: Bool {
    sessionCoordinator.isActive
  }

  func startup() {
    KeyboardShortcutManager.shared.setAgentModeRegistrationEnabled(isEnabled)
    DiagnosticLogger.shared.log(
      .info,
      .agent,
      "Agent Mode initialized",
      context: ["enabled": isEnabled ? "true" : "false"]
    )
  }

  func shutdown() {
    captureTask?.cancel()
    captureTask = nil
    AgentAnnotationOverlayCoordinator.shared.cancelActiveSession()
    frozenSession?.invalidate()
    frozenSession = nil
    sessionCoordinator.stopImmediately(reason: "The application is terminating.")
    AgentActivityWindowController.shared.shutdown()
    KeyboardShortcutManager.shared.setAgentModeRegistrationEnabled(false)
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    if !enabled {
      captureTask?.cancel()
      captureTask = nil
      AgentAnnotationOverlayCoordinator.shared.cancelActiveSession()
      frozenSession?.invalidate()
      frozenSession = nil
      sessionCoordinator.stopImmediately(reason: "Agent Mode was turned off.")
      AgentActivityWindowController.shared.hide()
    }

    isEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: PreferencesKeys.agentModeEnabled)
    KeyboardShortcutManager.shared.setAgentModeRegistrationEnabled(enabled)
    DiagnosticLogger.shared.log(
      .info,
      .agent,
      enabled ? "Agent Mode enabled" : "Agent Mode disabled"
    )
  }

  func toggleEnabled() {
    setEnabled(!isEnabled)
  }

  func startIntentCapture() {
    guard isEnabled else { return }

    if sessionCoordinator.isActive {
      // Carbon hot keys can consume Option+A before the global NSEvent monitor
      // sees it. Treat a repeated physical shortcut as user takeover anyway.
      sessionCoordinator.pauseForUserActivity()
      AgentActivityWindowController.shared.showLast(coordinator: sessionCoordinator)
      AppToastManager.shared.show(
        message: L10n.Agent.busyMessage,
        style: .warning,
        position: .bottomCenter
      )
      return
    }

    guard captureTask == nil,
          !OneShotCoordinator.shared.isActive,
          !RecordingCoordinator.shared.isActive,
          !ScrollingCaptureCoordinator.shared.isActive
    else {
      AppToastManager.shared.show(
        message: L10n.Agent.busyMessage,
        style: .warning,
        position: .bottomCenter
      )
      return
    }
    guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
      AppToastManager.shared.show(
        message: L10n.Agent.unavailablePermission,
        style: .warning,
        position: .bottomCenter
      )
      AppStatusBarController.shared.openPreferencesWindow(tab: .agent)
      return
    }

    let configuration = AgentProviderConfiguration.current()
    if !configuration.isLocalEndpoint,
       (try? credentialStore.resolvedAPIKey()) == nil {
      AppToastManager.shared.show(
        message: L10n.Agent.missingAPIKey,
        style: .warning,
        position: .bottomCenter
      )
      AppStatusBarController.shared.openPreferencesWindow(tab: .agent)
      return
    }

    guard sessionCoordinator.beginIntentCapture() else {
      AppToastManager.shared.show(
        message: L10n.Agent.busyMessage,
        style: .warning,
        position: .bottomCenter
      )
      return
    }
    AgentActivityWindowController.shared.hide()

    let initialApplication = contextAssembler.currentApplicationContext()
    let preferredDisplayID = ScreenUtility.activeDisplayID()
    captureTask = Task { [weak self] in
      guard let self else { return }
      defer { captureTask = nil }

      do {
        let session = try await FrozenAreaCaptureSession.prepare(
          showCursor: false,
          excludeDesktopIcons: false,
          excludeDesktopWidgets: false,
          excludeOwnApplication: true
        )
        try Task.checkCancellation()
        frozenSession = session
        let snapshots = session.allSnapshots()
        let screens = NSScreen.screens.filter { screen in
          guard let displayID = screen.displayID else { return false }
          return snapshots[displayID] != nil
        }
        guard !screens.isEmpty else {
          throw CaptureError.noDisplayFound
        }

        sessionCoordinator.markAnnotating()
        let selectedPreferredDisplayID = snapshots[preferredDisplayID] == nil
          ? screens.compactMap(\.displayID).first ?? preferredDisplayID
          : preferredDisplayID
        AgentAnnotationOverlayCoordinator.shared.start(
          screens: screens,
          snapshots: snapshots,
          preferredDisplayID: selectedPreferredDisplayID,
          onSubmit: { [weak self] selection in
            self?.submitIntent(selection, initialApplication: initialApplication)
          },
          onCancel: { [weak self] in
            self?.cancelIntentCapture()
          }
        )
      } catch is CancellationError {
        cancelIntentCapture()
      } catch {
        cancelIntentCapture()
        AppToastManager.shared.show(
          message: error.localizedDescription,
          style: .error,
          position: .bottomCenter
        )
        DiagnosticLogger.shared.logError(.agent, error, "Agent intent capture failed")
      }
    }
  }

  func stopImmediately() {
    captureTask?.cancel()
    captureTask = nil
    AgentAnnotationOverlayCoordinator.shared.cancelActiveSession()
    frozenSession?.invalidate()
    frozenSession = nil
    sessionCoordinator.stopImmediately()
  }

  func resume() {
    sessionCoordinator.resume()
    AgentActivityWindowController.shared.showLast(coordinator: sessionCoordinator)
  }

  func showActivity() {
    AgentActivityWindowController.shared.showLast(coordinator: sessionCoordinator)
  }

  private func submitIntent(
    _ selection: AgentIntentCaptureSelection,
    initialApplication: AgentApplicationContext
  ) {
    guard let session = frozenSession,
          let snapshot = session.snapshot(for: selection.displayID)
    else {
      cancelIntentCapture()
      return
    }

    frozenSession = nil
    session.invalidate()
    let sessionID = UUID()
    let intent = AgentIntent(
      sessionID: sessionID,
      userText: selection.prompt,
      anchor: selection.anchor,
      displayID: selection.displayID,
      initialApplication: initialApplication,
      createdAt: Date()
    )
    sessionCoordinator.start(intent: intent, initialSnapshot: snapshot)
    AgentActivityWindowController.shared.show(
      coordinator: sessionCoordinator,
      displayID: selection.displayID
    )
  }

  private func cancelIntentCapture() {
    frozenSession?.invalidate()
    frozenSession = nil
    sessionCoordinator.cancelIntentCapture()
  }
}
