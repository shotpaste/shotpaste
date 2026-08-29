//
//  AppStatusBarController.swift
//  ShotPaste
//
//  Manages the NSStatusItem for menu-driven capture actions and live recording status.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppStatusBarController: ObservableObject {
  static let shared = AppStatusBarController()

  // MARK: - Properties

  private var statusItem: NSStatusItem?
  private var cancellables = Set<AnyCancellable>()
  private let recorder = ScreenRecordingManager.shared
  private let audioCoordinator = AudioRecordingCoordinator.shared
  private lazy var idleStatusImage = makeIdleStatusImage()
  private lazy var agentStatusImage = makeAgentStatusImage()
  private lazy var recordingStopImage = makeRecordingStopImage()
  private var menu: NSMenu?
  private var didDetectCrash = false

  /// Dependencies injected after setup
  private var viewModel: ScreenCaptureViewModel?

  var screenCaptureViewModel: ScreenCaptureViewModel? {
    viewModel
  }

  // Track if we elevated activation policy for Settings window
  private var didElevateForSettings = false
  private weak var trackedPreferencesWindow: NSWindow?
  private var trackedPreferencesExcludedWindowID: CGWindowID?
  private var pendingPreferencesWindowTrackingWorkItem: DispatchWorkItem?

  // Processing indicator (OCR, etc.)
  private var processingSpinner: NSProgressIndicator?
  private(set) var isProcessing = false

  private init() {}

  // MARK: - Public API

  /// Setup the status bar item with required dependencies
  func setup(viewModel: ScreenCaptureViewModel, didCrash: Bool = false) {
    self.viewModel = viewModel
    didDetectCrash = didCrash

    syncStatusItemVisibility()
    buildMenu()
    observeRecordingState()
    observeAgentState()

    DiagnosticLogger.shared.log(
      .info,
      .ui,
      "Status bar item initialized",
      context: ["previousCrashPrompt": didCrash ? "true" : "false"]
    )
  }

  func stopRecording() {
    if audioCoordinator.isRecording || audioCoordinator.state == .saving {
      audioCoordinator.stop()
    } else {
      RecordingCoordinator.shared.stopFromStatusItem()
    }
  }

  /// Show or hide a processing spinner on the menu bar icon (e.g. during OCR).
  /// The spinner runs on Core Animation so it stays animated even when the main thread is briefly busy.
  func setProcessing(_ active: Bool) {
    guard active != isProcessing else { return }
    isProcessing = active

    guard let button = statusItem?.button else { return }

    if active {
      // Swap to a transparent placeholder of the same size to preserve layout
      if let icon = button.image {
        let placeholder = NSImage(size: icon.size)
        placeholder.isTemplate = true
        button.image = placeholder
      }

      // Create a spinning indicator sized to match the icon
      let size: CGFloat = 16
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isIndeterminate = true
      spinner.isDisplayedWhenStopped = false
      spinner.frame = CGRect(
        x: (button.bounds.width - size) / 2,
        y: (button.bounds.height - size) / 2,
        width: size,
        height: size
      )
      spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
      button.addSubview(spinner)
      spinner.startAnimation(nil)
      processingSpinner = spinner

      DiagnosticLogger.shared.log(.debug, .ui, "Status bar processing indicator started")
    } else {
      processingSpinner?.stopAnimation(nil)
      processingSpinner?.removeFromSuperview()
      processingSpinner = nil

      // Restore original icon
      button.image = idleStatusImage
      DiagnosticLogger.shared.log(.debug, .ui, "Status bar processing indicator stopped")
    }
  }

  // MARK: - Private Setup

  func setMenuBarIconVisible(_ visible: Bool) {
    UserDefaults.standard.set(visible, forKey: PreferencesKeys.showMenuBarIcon)
    syncStatusItemVisibility()
  }

  private func syncStatusItemVisibility() {
    let shouldShow = UserDefaults.standard.object(forKey: PreferencesKeys.showMenuBarIcon) as? Bool ?? true

    if shouldShow {
      setupStatusItem()
    } else {
      removeStatusItem()
    }
  }

  private func setupStatusItem() {
    guard statusItem == nil else {
      renderStatusItem()
      return
    }

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    if let button = statusItem?.button {
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(statusBarButtonClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      renderStatusItem()
    }
  }

  private func removeStatusItem() {
    guard let statusItem else { return }
    processingSpinner?.stopAnimation(nil)
    processingSpinner?.removeFromSuperview()
    processingSpinner = nil
    isProcessing = false
    NSStatusBar.system.removeStatusItem(statusItem)
    self.statusItem = nil
  }

  @objc private func statusBarButtonClicked(_: NSStatusBarButton) {
    guard let event = NSApp.currentEvent else { return }
    switch event.type {
    case .leftMouseUp:
      // With the hover bar hidden during recording, a left-click stops immediately.
      // Right-click still opens the full menu.
      if isMenuBarActingAsStopControl {
        DiagnosticLogger.shared.log(.debug, .ui, "Status bar direct stop (hover bar hidden)")
        stopRecording()
        return
      }
      DiagnosticLogger.shared.log(.debug, .ui, "Status bar menu opened", context: ["event": "leftMouseUp"])
      showMenu()
    case .rightMouseUp:
      DiagnosticLogger.shared.log(.debug, .ui, "Status bar menu opened", context: ["event": "rightMouseUp"])
      showMenu()
    default:
      break
    }
  }

  private func showMenu() {
    guard let button = statusItem?.button else { return }
    buildMenu() // Rebuild to update state
    statusItem?.menu = menu
    button.performClick(nil)
    statusItem?.menu = nil // Reset to allow custom click handling
  }

  // MARK: - Recording UI Preferences

  /// Whether the floating recording controls bar is shown during recording.
  /// When hidden, the menu bar becomes the primary stop control.
  /// Shared source of truth with `RecordingCoordinator` via `RecordingToolbarPreferences`.
  private var isHoverBarVisible: Bool {
    RecordingToolbarPreferences.hoverBarVisible()
  }

  /// Whether the elapsed recording time is shown next to the menu bar icon. Defaults to `true`.
  private var showsRecordingTimeOnMenuBar: Bool {
    RecordingToolbarPreferences.showTimeOnMenuBar()
  }

  /// True while the menu bar item acts as the direct stop control
  /// (recording/paused AND the hover bar is hidden).
  private var isMenuBarActingAsStopControl: Bool {
    (recorder.state == .recording || recorder.state == .paused
      || audioCoordinator.state == .recording || audioCoordinator.state == .paused)
      && !isHoverBarVisible
  }

  private var isAudioRecording: Bool {
    audioCoordinator.state == .recording || audioCoordinator.state == .paused
  }

  private var activeElapsedDuration: String {
    isAudioRecording ? audioCoordinator.formattedElapsed : recorder.formattedDuration
  }

  // MARK: - State Observation

  private func observeRecordingState() {
    recorder.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
        self?.syncTrackedPreferencesWindowExclusion()
      }
      .store(in: &cancellables)

    recorder.$elapsedSeconds
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
      }
      .store(in: &cancellables)

    audioCoordinator.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
        self?.scheduleRenderStatusItem()
      }
      .store(in: &cancellables)

    audioCoordinator.$elapsedSeconds
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.renderStatusItem() }
      .store(in: &cancellables)

    // Re-render when recording UI preferences change (e.g. toggled in Settings mid-recording).
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleRenderStatusItem()
      }
      .store(in: &cancellables)
  }

  private func observeAgentState() {
    let agentMode = AgentModeController.shared
    agentMode.$isEnabled
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
      }
      .store(in: &cancellables)

    agentMode.sessionCoordinator.$phase
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
      }
      .store(in: &cancellables)

    agentMode.sessionCoordinator.$trajectoryEvents
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.renderStatusItem()
      }
      .store(in: &cancellables)
  }

  private var isStatusItemRenderScheduled = false

  /// Coalesce bursts of UserDefaults changes (e.g. slider drags) into one
  /// status-item render per runloop (see issue #335).
  private func scheduleRenderStatusItem() {
    guard !isStatusItemRenderScheduled else { return }
    isStatusItemRenderScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isStatusItemRenderScheduled = false
      renderStatusItem()
    }
  }

  private func renderStatusItem() {
    guard let button = statusItem?.button else { return }
    // When the hover bar is hidden during recording, the menu bar item becomes the stop
    // control and shows a distinct stop glyph. Otherwise use the app icon.
    let showsAgentIdentity = AgentModeController.shared.isEnabled && recorder.state == .idle
    button.image = isMenuBarActingAsStopControl
      ? (recordingStopImage ?? idleStatusImage)
      : (showsAgentIdentity ? agentStatusImage : idleStatusImage)
    button.contentTintColor = showsAgentIdentity ? .systemPurple : nil
    button.attributedTitle = statusItemAttributedTitle(for: recorder.state)
    button.toolTip = statusItemTooltip(for: recorder.state)
  }

  /// Pure decision for the menu bar title text. Empty when the time display is off or there is
  /// nothing to show. Extracted for deterministic testing of the optional-time gating.
  nonisolated static func menuBarTitleString(
    for state: RecordingState,
    duration: String,
    showTime: Bool
  ) -> String {
    guard showTime else { return "" }
    switch state {
    case .recording:
      return duration
    case .paused:
      return "|| \(duration)"
    case .idle, .preparing, .stopping:
      return ""
    }
  }

  nonisolated static func idleMenuBarTooltip(for variant: AppVariant) -> String {
    variant.displayName
  }

  private func statusItemAttributedTitle(for state: RecordingState) -> NSAttributedString {
    let resolvedState: RecordingState = if audioCoordinator.state == .recording {
      .recording
    } else if audioCoordinator.state == .paused {
      .paused
    } else {
      state
    }
    let title = Self.menuBarTitleString(
      for: resolvedState,
      duration: activeElapsedDuration,
      showTime: showsRecordingTimeOnMenuBar
    )

    guard !title.isEmpty else {
      return NSAttributedString(string: "")
    }

    let menuBarFont = NSFont.menuBarFont(ofSize: 0)
    let monospacedDigitsFont = NSFont.monospacedDigitSystemFont(
      ofSize: menuBarFont.pointSize,
      weight: .regular
    )

    return NSAttributedString(
      string: title,
      attributes: [
        .font: monospacedDigitsFont,
        .foregroundColor: NSColor.labelColor,
      ]
    )
  }

  private func statusItemTooltip(for state: RecordingState) -> String {
    // When the menu bar is the stop control, tell the user a click stops the recording.
    if isMenuBarActingAsStopControl {
      return isAudioRecording
        ? "\(L10n.AudioRecording.stop) (\(activeElapsedDuration))"
        : L10n.RecordingToolbar.clickToStop(recorder.formattedDuration)
    }
    if isAudioRecording {
      return "\(L10n.AudioRecording.recording) (\(activeElapsedDuration))"
    }
    if audioCoordinator.hasProcessingStatus {
      return audioCoordinator.processingStatusLabel
    }
    switch state {
    case .recording:
      return "\(L10n.RecordingToolbar.recordingInProgress) (\(recorder.formattedDuration))"
    case .paused:
      return "\(L10n.RecordingToolbar.recordingPaused) (\(recorder.formattedDuration))"
    case .preparing:
      return "ShotPaste"
    case .stopping:
      return "ShotPaste"
    case .idle:
      if AgentModeController.shared.isEnabled {
        return "\(L10n.Agent.modeTitle) · \(AgentModeController.shared.statusMessage)"
      }
      return Self.idleMenuBarTooltip(for: .current)
    }
  }

  private func makeIdleStatusImage() -> NSImage? {
    guard let appIcon = NSImage(named: AppVariant.current.menuBarIconAssetName) else { return nil }

    let canvasSize = NSSize(width: 18, height: 18)
    let drawRect = NSRect(origin: .zero, size: canvasSize)

    let resizedIcon = NSImage(size: canvasSize)
    resizedIcon.lockFocus()
    appIcon.draw(
      in: drawRect,
      from: NSRect(origin: .zero, size: appIcon.size),
      operation: .copy,
      fraction: 1.0
    )
    resizedIcon.unlockFocus()
    // Template images let AppKit adapt the glyph color to the current menu bar material.
    resizedIcon.isTemplate = true
    return resizedIcon
  }

  /// Distinct "stop" glyph shown on the menu bar item while recording with the hover bar hidden.
  /// Signals that a click stops the recording.
  private func makeRecordingStopImage() -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    // Actionable a11y cue matching the icon's behavior (a click stops the recording).
    let image = NSImage(
      systemSymbolName: "stop.circle.fill",
      accessibilityDescription: L10n.RecordingToolbar.stopRecordingHint
    )?.withSymbolConfiguration(config)
    image?.isTemplate = true
    return image
  }

  private func makeAgentStatusImage() -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    let image = NSImage(
      systemSymbolName: "cursorarrow.motionlines",
      accessibilityDescription: L10n.Agent.modeTitle
    )?.withSymbolConfiguration(config)
    image?.isTemplate = true
    return image
  }

  // MARK: - Menu Building

  private func buildMenu() {
    menu = NSMenu()
    menu?.autoenablesItems = false

    guard let viewModel else {
      DiagnosticLogger.shared.log(.warning, .ui, "Status bar menu requested before view model setup")
      return
    }
    let shortcutManager = KeyboardShortcutManager.shared
    let agentMode = AgentModeController.shared

    // Recording status indicator (when recording)
    if recorder.state == .recording || recorder.state == .paused {
      let stopItem = NSMenuItem(
        title: L10n.Menu.stopRecording(recorder.formattedDuration),
        action: #selector(stopRecordingAction),
        keyEquivalent: ""
      )
      stopItem.target = self
      stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
      stopItem.isEnabled = true
      menu?.addItem(stopItem)

      let pauseResumeItem = NSMenuItem(
        title: recorder.isPaused ? L10n.RecordingToolbar.resumeRecording : L10n.RecordingToolbar.pauseRecording,
        action: #selector(togglePauseRecordingAction),
        keyEquivalent: ""
      )
      pauseResumeItem.target = self
      pauseResumeItem.image = NSImage(
        systemSymbolName: recorder.isPaused ? "play.fill" : "pause.fill",
        accessibilityDescription: nil
      )
      pauseResumeItem.isEnabled = recorder.state == .recording || recorder.state == .paused
      menu?.addItem(pauseResumeItem)

      menu?.addItem(NSMenuItem.separator())
    } else if audioCoordinator.state == .recording || audioCoordinator.state == .paused {
      let stopItem = NSMenuItem(
        title: L10n.AudioRecording.stopMenu,
        action: #selector(stopRecordingAction),
        keyEquivalent: ""
      )
      stopItem.target = self
      stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
      stopItem.isEnabled = true
      menu?.addItem(stopItem)

      let pauseResumeItem = NSMenuItem(
        title: audioCoordinator.state == .paused
          ? L10n.AudioRecording.resumeMenu : L10n.AudioRecording.pauseMenu,
        action: #selector(togglePauseRecordingAction),
        keyEquivalent: ""
      )
      pauseResumeItem.target = self
      pauseResumeItem.image = NSImage(
        systemSymbolName: audioCoordinator.state == .paused ? "play.fill" : "pause.fill",
        accessibilityDescription: nil
      )
      pauseResumeItem.isEnabled = true
      menu?.addItem(pauseResumeItem)
      menu?.addItem(NSMenuItem.separator())
    }

    if audioCoordinator.canRetrySave {
      let saveItem = NSMenuItem(
        title: L10n.AudioRecording.retrySave,
        action: #selector(retryAudioSaveAction),
        keyEquivalent: ""
      )
      saveItem.target = self
      saveItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
      saveItem.isEnabled = true
      menu?.addItem(saveItem)
    }

    if audioCoordinator.hasProcessingStatus && !audioCoordinator.canRetrySave {
      let processingItem = NSMenuItem(
        title: audioCoordinator.processingStatusLabel,
        action: audioCoordinator.canRetryProcessing
          ? #selector(retryAudioProcessingAction) : nil,
        keyEquivalent: ""
      )
      processingItem.target = self
      processingItem.image = NSImage(
        systemSymbolName: audioCoordinator.isWaitingForModel
          ? "clock.badge.exclamationmark" : "waveform",
        accessibilityDescription: nil
      )
      processingItem.isEnabled = audioCoordinator.canRetryProcessing
      menu?.addItem(processingItem)
      menu?.addItem(NSMenuItem.separator())
    }

    if agentMode.isEnabled {
      let agentModeItem = NSMenuItem(
        title: L10n.Agent.modeTitle,
        action: #selector(toggleAgentModeAction),
        keyEquivalent: ""
      )
      agentModeItem.target = self
      agentModeItem.state = .on
      agentModeItem.image = NSImage(
        systemSymbolName: "cursorarrow.motionlines",
        accessibilityDescription: nil
      )
      agentModeItem.isEnabled = true
      menu?.addItem(agentModeItem)

      if agentMode.isSessionActive || agentMode.sessionCoordinator.hasTrajectory {
        let activityItem = NSMenuItem(
          title: L10n.Agent.showActivity,
          action: #selector(showAgentActivityAction),
          keyEquivalent: ""
        )
        activityItem.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        activityItem.target = self
        activityItem.isEnabled = true
        menu?.addItem(activityItem)
      }
      if agentMode.sessionCoordinator.canResume {
        let resumeItem = NSMenuItem(
          title: L10n.Agent.resumeAgent,
          action: #selector(resumeAgentAction),
          keyEquivalent: ""
        )
        resumeItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        resumeItem.target = self
        resumeItem.isEnabled = true
        menu?.addItem(resumeItem)
      }
      if agentMode.isSessionActive {
        let stopItem = NSMenuItem(
          title: L10n.Agent.stopAgent,
          action: #selector(stopAgentAction),
          keyEquivalent: ""
        )
        stopItem.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopItem.target = self
        stopItem.isEnabled = true
        menu?.addItem(stopItem)
      } else {
        let startItem = NSMenuItem(
          title: L10n.Agent.startTask,
          action: #selector(startAgentAction),
          keyEquivalent: ""
        )
        applyConfiguredShortcut(startItem, for: .agentMode, using: shortcutManager)
        startItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        startItem.target = self
        startItem.isEnabled = true
        menu?.addItem(startItem)
      }

      menu?.addItem(NSMenuItem.separator())
    }

    // One Shot is the only idle capture entry. Active recording controls stay
    // visible above it while a One Shot recording is running.
    // One Shot and audio are independent entries, but mutually exclusive at
    // the menu boundary (shortcuts enforce the same policy in the ViewModel).
    let oneShotItem = NSMenuItem(
      title: L10n.Actions.oneShot,
      action: #selector(oneShotAction),
      keyEquivalent: ""
    )
    applyConfiguredShortcut(oneShotItem, for: .oneShot, using: shortcutManager)
    oneShotItem.target = self
    oneShotItem.image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: nil)
    oneShotItem.isEnabled = viewModel.hasPermission
      && !recorder.isActive
      && !RecordingCoordinator.shared.isActive
      && !ScrollingCaptureCoordinator.shared.isActive
      && !agentMode.isSessionActive
      && !audioCoordinator.isBlockingOtherCapture
    menu?.addItem(oneShotItem)

    let audioItem = NSMenuItem(
      title: L10n.AudioRecording.startMenu,
      action: #selector(startAudioRecordingAction),
      keyEquivalent: ""
    )
    applyConfiguredShortcut(audioItem, for: .startAudioRecording, using: shortcutManager)
    audioItem.target = self
    audioItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
    audioItem.isEnabled = viewModel.hasPermission
      && !recorder.isActive
      && !RecordingCoordinator.shared.isActive
      && !ScrollingCaptureCoordinator.shared.isActive
      && !audioCoordinator.isBlockingOtherCapture
    menu?.addItem(audioItem)

    menu?.addItem(NSMenuItem.separator())

    // Tools
    let historyItem = NSMenuItem(
      title: L10n.Actions.openHistory,
      action: #selector(openHistoryAction),
      keyEquivalent: ""
    )
    applyConfiguredShortcut(historyItem, for: .history, using: shortcutManager)
    historyItem.target = self
    historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
    historyItem.isEnabled = true
    menu?.addItem(historyItem)

    if !QuickAccessManager.shared.items.isEmpty {
      let quickAccessItem = NSMenuItem(
        title: L10n.Actions.focusQuickAccess,
        action: #selector(focusQuickAccessAction),
        keyEquivalent: ""
      )
      quickAccessItem.target = self
      quickAccessItem.image = NSImage(
        systemSymbolName: "rectangle.stack",
        accessibilityDescription: nil
      )
      quickAccessItem.isEnabled = true
      menu?.addItem(quickAccessItem)
    }

    menu?.addItem(NSMenuItem.separator())

    // Permission (if not granted)
    if !viewModel.hasPermission {
      let permissionItem = NSMenuItem(
        title: L10n.Menu.grantPermission,
        action: #selector(grantPermissionAction),
        keyEquivalent: ""
      )
      permissionItem.target = self
      permissionItem.image = NSImage(
        systemSymbolName: "lock.shield", accessibilityDescription: nil
      )
      permissionItem.isEnabled = true
      menu?.addItem(permissionItem)
      menu?.addItem(NSMenuItem.separator())
    }

    if didDetectCrash {
      let reportItem = NSMenuItem(
        title: L10n.CrashReport.alertTitle,
        action: #selector(reportProblemAction),
        keyEquivalent: ""
      )
      reportItem.target = self
      reportItem.image = NSImage(
        systemSymbolName: "exclamationmark.bubble",
        accessibilityDescription: nil
      )
      reportItem.isEnabled = true
      menu?.addItem(reportItem)
      menu?.addItem(NSMenuItem.separator())
    }

    // Preferences
    let prefsItem = NSMenuItem(
      title: L10n.Menu.preferences,
      action: #selector(openPreferencesAction),
      keyEquivalent: ","
    )
    prefsItem.keyEquivalentModifierMask = .command
    prefsItem.target = self
    prefsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
    prefsItem.isEnabled = true
    menu?.addItem(prefsItem)

    menu?.addItem(NSMenuItem.separator())

    // Quit
    let quitItem = NSMenuItem(
      title: L10n.Menu.quitShotPaste,
      action: #selector(quitAction),
      keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = .command
    quitItem.target = self
    quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
    quitItem.isEnabled = true
    menu?.addItem(quitItem)
  }

  // MARK: - Menu Actions

  @objc private func stopRecordingAction() {
    logMenuAction("stopRecording", context: ["state": "\(recorder.state)"])
    stopRecording()
  }

  @objc private func togglePauseRecordingAction() {
    logMenuAction("togglePauseRecording", context: ["state": "\(recorder.state)"])
    if audioCoordinator.isRecording {
      audioCoordinator.pauseOrResume()
    } else {
      recorder.togglePause()
    }
  }

  @objc private func startAudioRecordingAction() {
    logMenuAction("startAudioRecording")
    viewModel?.startAudioRecording()
  }

  @objc private func retryAudioSaveAction() {
    logMenuAction("retryAudioSave")
    audioCoordinator.retrySave()
  }

  @objc private func retryAudioProcessingAction() {
    logMenuAction("retryAudioProcessing")
    audioCoordinator.retryProcessing()
  }

  @objc private func oneShotAction() {
    logMenuAction("oneShot")
    viewModel?.startOneShot()
  }

  @objc private func toggleAgentModeAction() {
    logMenuAction("toggleAgentMode")
    AgentModeController.shared.toggleEnabled()
  }

  @objc private func startAgentAction() {
    logMenuAction("startAgent")
    AgentModeController.shared.startIntentCapture()
  }

  @objc private func resumeAgentAction() {
    logMenuAction("resumeAgent")
    AgentModeController.shared.resume()
  }

  @objc private func showAgentActivityAction() {
    logMenuAction("showAgentActivity")
    AgentModeController.shared.showActivity()
  }

  @objc private func stopAgentAction() {
    logMenuAction("stopAgent")
    AgentModeController.shared.stopImmediately()
  }

  @objc private func openHistoryAction() {
    logMenuAction("openHistory")
    HistoryWindowController.shared.showWindow()
  }

  @objc private func focusQuickAccessAction() {
    logMenuAction("focusQuickAccess")
    QuickAccessManager.shared.activateKeyboardFocus()
  }

  @objc private func grantPermissionAction() {
    logMenuAction("grantPermission")
    openPreferencesWindow(tab: .permissions)
  }

  @objc private func reportProblemAction() {
    logMenuAction("reportProblem")
    CrashReportService.presentAlert()
    didDetectCrash = false
  }

  @objc private func openPreferencesAction() {
    logMenuAction("openPreferences")
    openPreferencesWindow()
  }

  func openPreferencesWindow(tab: PreferencesTab? = nil) {
    if let tab {
      PreferencesNavigationState.shared.selectedTab = tab
    }
    DiagnosticLogger.shared.log(
      .info,
      .preferences,
      "Preferences window requested",
      context: ["tab": tab.map { "\($0)" } ?? "current"]
    )
    presentPreferencesWindow()
  }

  private func presentPreferencesWindow() {
    let existingWindowNumbers = Set(NSApp.windows.map(\.windowNumber))

    // Elevate to regular app so ShotPaste appears in top-left menu bar
    if !didElevateForSettings {
      NSApp.setActivationPolicy(.regular)
      didElevateForSettings = true
      DiagnosticLogger.shared.log(.debug, .ui, "Activation policy elevated for preferences window")

      // Observe when Settings window closes to revert policy
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowDidClose(_:)),
        name: NSWindow.willCloseNotification,
        object: nil
      )
    }

    NSApp.activate(ignoringOtherApps: true)

    // Trigger Settings scene - equivalent to SettingsLink behavior
    if #available(macOS 14.0, *) {
      if let keyEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: ",",
        charactersIgnoringModifiers: ",",
        isARepeat: false,
        keyCode: 43
      ) {
        NSApp.mainMenu?.performKeyEquivalent(with: keyEvent)
      }
    } else {
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    schedulePreferencesWindowTracking(excludingWindowNumbers: existingWindowNumbers)
  }

  @objc private func windowDidClose(_ notification: Notification) {
    let closingWindow = notification.object as? NSWindow
    if let window = closingWindow, trackedPreferencesWindow === window {
      DiagnosticLogger.shared.log(.debug, .preferences, "Tracked preferences window closed")
      trackedPreferencesWindow = nil
      removeTrackedPreferencesWindowExclusion()
    }

    // Check if any visible windows remain (excluding status bar popover and the closing window)
    let visibleWindows = NSApp.windows.filter { window in
      window.isVisible &&
        window !== closingWindow &&
        window.className != "NSStatusBarWindow" &&
        window.level == .normal
    }

    // If no visible windows, revert to accessory (menu bar only) mode
    if visibleWindows.isEmpty, didElevateForSettings {
      NSApp.setActivationPolicy(.accessory)
      didElevateForSettings = false
      DiagnosticLogger.shared.log(.debug, .ui, "Activation policy restored after preferences closed")
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.willCloseNotification,
        object: nil
      )
    }
  }

  @objc private func quitAction() {
    logMenuAction("quit")
    NSApp.terminate(nil)
  }

  private func logMenuAction(_ action: String, context: [String: String]? = nil) {
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Menu action invoked",
      context: {
        var values = context ?? [:]
        values["action"] = action
        return values
      }()
    )
  }

  private func applyConfiguredShortcut(
    _ item: NSMenuItem,
    for kind: GlobalShortcutKind,
    using manager: KeyboardShortcutManager
  ) {
    guard manager.isShortcutEnabled(for: kind) else {
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }

    let config = manager.shortcut(for: kind)
    guard let config, let keyEquivalent = config.menuKeyEquivalent else {
      item.keyEquivalent = ""
      item.keyEquivalentModifierMask = []
      return
    }

    item.keyEquivalent = keyEquivalent
    item.keyEquivalentModifierMask = config.menuModifierFlags
  }

  private func schedulePreferencesWindowTracking(excludingWindowNumbers existingWindowNumbers: Set<Int>) {
    pendingPreferencesWindowTrackingWorkItem?.cancel()
    DiagnosticLogger.shared.log(
      .debug,
      .preferences,
      "Preferences window tracking scheduled",
      context: ["existingWindows": "\(existingWindowNumbers.count)"]
    )

    let workItem = DispatchWorkItem { [weak self] in
      self?.trackPreferencesWindow(excludingWindowNumbers: existingWindowNumbers, remainingAttempts: 12)
    }
    pendingPreferencesWindowTrackingWorkItem = workItem
    DispatchQueue.main.async(execute: workItem)
  }

  private func trackPreferencesWindow(excludingWindowNumbers existingWindowNumbers: Set<Int>, remainingAttempts: Int) {
    pendingPreferencesWindowTrackingWorkItem = nil

    if let trackedPreferencesWindow, trackedPreferencesWindow.isVisible {
      syncTrackedPreferencesWindowExclusion()
      return
    }

    if let candidate = NSApp.windows.first(where: {
      $0.isVisible &&
        $0.level == .normal &&
        $0.className != "NSStatusBarWindow" &&
        !existingWindowNumbers.contains($0.windowNumber)
    }) {
      trackedPreferencesWindow = candidate
      DiagnosticLogger.shared.log(
        .debug,
        .preferences,
        "Preferences window tracked",
        context: ["windowNumber": "\(candidate.windowNumber)"]
      )
      syncTrackedPreferencesWindowExclusion()
      return
    }

    guard remainingAttempts > 1 else {
      DiagnosticLogger.shared.log(.warning, .preferences, "Preferences window tracking timed out")
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.trackPreferencesWindow(
        excludingWindowNumbers: existingWindowNumbers,
        remainingAttempts: remainingAttempts - 1
      )
    }
    pendingPreferencesWindowTrackingWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
  }

  private func syncTrackedPreferencesWindowExclusion() {
    guard let trackedPreferencesWindow, trackedPreferencesWindow.isVisible else {
      removeTrackedPreferencesWindowExclusion()
      return
    }

    let windowID = CGWindowID(trackedPreferencesWindow.windowNumber)

    guard recorder.isActive else {
      removeTrackedPreferencesWindowExclusion()
      return
    }

    guard trackedPreferencesExcludedWindowID != windowID else { return }

    let previousWindowID = trackedPreferencesExcludedWindowID
    trackedPreferencesExcludedWindowID = windowID
    DiagnosticLogger.shared.log(
      .debug,
      .recording,
      "Preferences window added to runtime recording exclusion",
      context: ["windowID": "\(windowID)"]
    )

    Task { @MainActor [weak self] in
      guard let self else { return }
      if let previousWindowID, previousWindowID != windowID {
        await recorder.removeRuntimeExcludedWindow(windowID: previousWindowID)
      }
      await recorder.addRuntimeExcludedWindow(windowID: windowID)
    }
  }

  private func removeTrackedPreferencesWindowExclusion() {
    guard let windowID = trackedPreferencesExcludedWindowID else { return }
    trackedPreferencesExcludedWindowID = nil
    DiagnosticLogger.shared.log(
      .debug,
      .recording,
      "Preferences window removed from runtime recording exclusion",
      context: ["windowID": "\(windowID)"]
    )

    Task { @MainActor [weak self] in
      guard let self else { return }
      await recorder.removeRuntimeExcludedWindow(windowID: windowID)
    }
  }

  var didElevateForSettingsForTesting: Bool {
    get { didElevateForSettings }
    set { didElevateForSettings = newValue }
  }

  var trackedPreferencesWindowForTesting: NSWindow? {
    get { trackedPreferencesWindow }
    set { trackedPreferencesWindow = newValue }
  }

  func simulateWindowDidClose(notification: Notification) {
    windowDidClose(notification)
  }

  var isHoverBarVisibleForTesting: Bool {
    isHoverBarVisible
  }

  var showsRecordingTimeOnMenuBarForTesting: Bool {
    showsRecordingTimeOnMenuBar
  }
}
