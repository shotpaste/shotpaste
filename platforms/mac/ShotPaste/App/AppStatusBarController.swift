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
  private lazy var idleStatusImage = makeIdleStatusImage()
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

    DiagnosticLogger.shared.log(
      .info,
      .ui,
      "Status bar item initialized",
      context: ["previousCrashPrompt": didCrash ? "true" : "false"]
    )
  }

  func stopRecording() {
    RecordingCoordinator.shared.stopFromStatusItem()
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

  var isMenuBarIconVisible: Bool {
    statusItem != nil
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
    (recorder.state == .recording || recorder.state == .paused) && !isHoverBarVisible
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

    // Re-render when recording UI preferences change (e.g. toggled in Settings mid-recording).
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.scheduleRenderStatusItem()
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
    button.image = isMenuBarActingAsStopControl ? (recordingStopImage ?? idleStatusImage) : idleStatusImage
    button.contentTintColor = nil
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

  private func statusItemAttributedTitle(for state: RecordingState) -> NSAttributedString {
    let title = Self.menuBarTitleString(
      for: state,
      duration: recorder.formattedDuration,
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
      return L10n.RecordingToolbar.clickToStop(recorder.formattedDuration)
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
      return "ShotPaste"
    }
  }

  private func makeIdleStatusImage() -> NSImage? {
    guard let appIcon = NSImage(named: "MenubarIcon") else { return nil }

    let canvasSize = NSSize(width: 18, height: 18)
    let targetVisibleOccupancy: CGFloat = 0.89
    // Current MenubarIcon PNG alpha bounds occupy 75.28% of its transparent canvas.
    let sourceVisibleOccupancy: CGFloat = 0.7528
    let drawSize = NSSize(
      width: canvasSize.width * targetVisibleOccupancy / sourceVisibleOccupancy,
      height: canvasSize.height * targetVisibleOccupancy / sourceVisibleOccupancy
    )
    let drawRect = NSRect(
      x: (canvasSize.width - drawSize.width) / 2,
      y: (canvasSize.height - drawSize.height) / 2,
      width: drawSize.width,
      height: drawSize.height
    )

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

  // MARK: - Menu Building

  private func buildMenu() {
    menu = NSMenu()
    menu?.autoenablesItems = false

    guard let viewModel else {
      DiagnosticLogger.shared.log(.warning, .ui, "Status bar menu requested before view model setup")
      return
    }
    let shortcutManager = KeyboardShortcutManager.shared

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
    }

    // One Shot is the only idle capture entry. Active recording controls stay
    // visible above it while a One Shot recording is running.
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
    menu?.addItem(oneShotItem)

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
    recorder.togglePause()
  }

  @objc private func oneShotAction() {
    logMenuAction("oneShot")
    viewModel?.startOneShot()
  }

  @objc private func openHistoryAction() {
    logMenuAction("openHistory")
    HistoryWindowController.shared.showWindow()
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

  #if DEBUG
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
  #endif
}
