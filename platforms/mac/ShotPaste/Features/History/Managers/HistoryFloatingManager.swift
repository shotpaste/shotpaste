//
//  HistoryFloatingManager.swift
//  ShotPaste
//
//  State management for the floating history panel
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

/// Manages the floating history panel settings and display state
@MainActor
final class HistoryFloatingManager: ObservableObject {
  static let shared = HistoryFloatingManager()

  // MARK: - Published State

  @Published var position: HistoryPanelPosition = .topCenter {
    didSet {
      UserDefaults.standard.set(position.rawValue, forKey: Keys.position)
      guard presentationMode == .compact else { return }
      panelController.updatePosition(position)
    }
  }

  @Published var isEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
      if !isEnabled {
        hide()
      }
    }
  }

  @Published var defaultFilter: CaptureHistoryCategory? = .clipboard {
    didSet {
      if let filter = defaultFilter {
        UserDefaults.standard.set(filter.rawValue, forKey: Keys.defaultFilter)
      } else {
        UserDefaults.standard.removeObject(forKey: Keys.defaultFilter)
      }
    }
  }

  @Published var maxDisplayedItems: Int = 10 {
    didSet {
      let clamped = min(max(maxDisplayedItems, 3), 50)
      guard clamped == maxDisplayedItems else {
        maxDisplayedItems = clamped
        return
      }
      UserDefaults.standard.set(maxDisplayedItems, forKey: Keys.maxDisplayedItems)
    }
  }

  @Published var panelScale: Double = HistoryFloatingLayout.defaultScale {
    didSet {
      let clamped = HistoryFloatingLayout.clampedScale(panelScale)
      guard clamped == panelScale else {
        panelScale = clamped
        return
      }
      UserDefaults.standard.set(panelScale, forKey: PreferencesKeys.historyFloatingScale)
      refreshPanel()
    }
  }

  @Published var toggleModeShortcut: ShortcutConfig? = nil {
    didSet {
      saveToggleModeShortcut()
    }
  }

  @Published var isToggleModeShortcutEnabled: Bool = true {
    didSet {
      UserDefaults.standard.set(isToggleModeShortcutEnabled, forKey: Keys.isToggleModeShortcutEnabled)
    }
  }

  static let defaultToggleModeShortcut = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_E),
    modifiers: UInt32(cmdKey)
  )

  @Published private(set) var presentationMode: HistoryFloatingPresentationMode = .compact
  @Published var expandedFilter: CaptureHistoryCategory? = .clipboard
  @Published var expandedTimeFilter: HistoryFloatingTimeFilter = .all
  @Published var searchText: String = ""

  // MARK: - Private

  private let panelController = HistoryFloatingPanelController()
  private lazy var panelContentView = HistoryFloatingContentView(manager: self)
  private var localEscapeMonitor: Any?
  private var globalEscapeMonitor: Any?
  private var modalInteractionSuppressionCount = 0
  private var isModalInteractionActive: Bool {
    modalInteractionSuppressionCount > 0
  }

  private enum Keys {
    static let enabled = "history.floating.enabled"
    static let position = "history.floating.position"
    static let defaultFilter = "history.floating.defaultFilter"
    static let maxDisplayedItems = "history.floating.maxDisplayedItems"
    static let toggleModeShortcut = "history.toggleModeShortcut"
    static let isToggleModeShortcutEnabled = "history.isToggleModeShortcutEnabled"
  }

  // MARK: - Init

  private init() {
    panelController.onPanelDidResignKey = { [weak self] in
      self?.handlePanelDidResignKey()
    }
    loadSettings()
  }

  private func loadSettings() {
    isEnabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true

    if let positionRaw = UserDefaults.standard.string(forKey: Keys.position),
       let savedPosition = HistoryPanelPosition(rawValue: positionRaw) {
      position = savedPosition
    }

    if let filterRaw = UserDefaults.standard.string(forKey: Keys.defaultFilter),
       let filter = CaptureHistoryCategory(rawValue: filterRaw) {
      defaultFilter = filter
    }

    maxDisplayedItems = min(
      max(UserDefaults.standard.object(forKey: Keys.maxDisplayedItems) as? Int ?? 10, 3),
      50
    )
    panelScale = HistoryFloatingLayout.storedScale()
    expandedFilter = defaultFilter
    loadToggleModeShortcut()
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Floating history settings loaded",
      context: [
        "enabled": isEnabled ? "true" : "false",
        "position": position.rawValue,
        "maxDisplayedItems": "\(maxDisplayedItems)",
      ]
    )
  }

  private func loadToggleModeShortcut() {
    let enabled = UserDefaults.standard.object(forKey: Keys.isToggleModeShortcutEnabled) as? Bool ?? true
    _isToggleModeShortcutEnabled = Published(initialValue: enabled)

    if let data = UserDefaults.standard.data(forKey: Keys.toggleModeShortcut),
       let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) {
      _toggleModeShortcut = Published(initialValue: config)
    } else {
      _toggleModeShortcut = Published(initialValue: Self.defaultToggleModeShortcut)
    }
  }

  private func saveToggleModeShortcut() {
    if let config = toggleModeShortcut {
      if let data = try? JSONEncoder().encode(config) {
        UserDefaults.standard.set(data, forKey: Keys.toggleModeShortcut)
      }
    } else {
      UserDefaults.standard.removeObject(forKey: Keys.toggleModeShortcut)
    }
  }

  func resetToggleModeShortcut() {
    toggleModeShortcut = Self.defaultToggleModeShortcut
    isToggleModeShortcutEnabled = true
  }

  // MARK: - Public Methods

  /// Toggle the floating history panel visibility
  func toggle() {
    DiagnosticLogger.shared.log(
      .info,
      .history,
      "Floating history toggled",
      context: [
        "isPresenting": panelController.isPresenting ? "true" : "false",
        "enabled": isEnabled ? "true" : "false",
      ]
    )
    if panelController.isPresenting {
      hide()
    } else {
      showDefaultHistory()
    }
  }

  /// Show the complete history window using the configured opening filter.
  func show() {
    showDefaultHistory()
  }

  /// Hide the floating history panel
  func hide() {
    removeEscapeMonitors()
    panelController.hide()
    DiagnosticLogger.shared.log(.debug, .history, "Floating history hidden")
  }

  func showCompact() {
    guard isEnabled else {
      DiagnosticLogger.shared.log(.debug, .history, "Floating history compact show skipped; disabled")
      return
    }
    presentationMode = .compact
    presentCurrentMode()
  }

  func showExpanded(initialFilter: CaptureHistoryCategory? = nil) {
    presentExpanded(initialFilter: initialFilter ?? expandedFilter ?? defaultFilter)
  }

  /// Open the expanded history surface without a product category filter.
  func showAllHistory() {
    presentExpanded(initialFilter: nil)
  }

  private func presentExpanded(initialFilter: CaptureHistoryCategory?) {
    resetExpandedState(initialFilter: initialFilter)
    presentationMode = .expanded
    DiagnosticLogger.shared.log(
      .info,
      .history,
      "Floating history expanded",
      context: ["filter": initialFilter?.rawValue ?? "all"]
    )
    presentCurrentMode()
  }

  /// Open the complete history surface using the user's configured default filter.
  func showDefaultHistory() {
    showExpanded(initialFilter: defaultFilter)
    focusPanel()
  }

  /// Clipboard-specific entry points always open the complete Clipboard view.
  /// Re-presenting an already-visible panel updates and focuses the same panel.
  func showClipboardHistory() {
    showExpanded(initialFilter: .clipboard)
    focusPanel()
  }

  func collapse() {
    guard isEnabled else {
      DiagnosticLogger.shared.log(.debug, .history, "Floating history collapse routed to hide; disabled")
      hide()
      return
    }
    presentationMode = .compact
    DiagnosticLogger.shared.log(.debug, .history, "Floating history collapsed")
    presentCurrentMode()
  }

  func togglePresentationMode() {
    guard isEnabled else { return }
    if presentationMode == .compact {
      showExpanded()
    } else {
      collapse()
    }
  }

  /// Refresh panel content if visible
  func refreshPanel() {
    guard panelController.isVisible else { return }
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Floating history refreshed",
      context: ["mode": "\(presentationMode)"]
    )
    presentCurrentMode()
  }

  /// Check if panel is currently visible
  var isVisible: Bool {
    panelController.isVisible
  }

  func focusPanel() {
    panelController.focusPanel()
    DiagnosticLogger.shared.log(.debug, .history, "Floating history focused")
  }

  func performModalInteraction<Result>(_ action: () -> Result) -> Result {
    modalInteractionSuppressionCount += 1
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Floating history modal interaction began",
      context: ["depth": "\(modalInteractionSuppressionCount)"]
    )
    let result = action()

    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.modalInteractionSuppressionCount = max(0, self.modalInteractionSuppressionCount - 1)
        DiagnosticLogger.shared.log(
          .debug,
          .history,
          "Floating history modal interaction ended",
          context: ["depth": "\(self.modalInteractionSuppressionCount)"]
        )
        if self.panelController.isPresenting {
          self.focusPanel()
        }
      }
    }

    return result
  }

  private var preferredPanelSize: CGSize {
    HistoryFloatingLayout.panelSize(
      for: panelScale,
      mode: presentationMode,
      on: ScreenUtility.activeScreen()
    )
  }

  private var preferredPosition: HistoryPanelPosition {
    position
  }

  private var preferredCornerRadius: CGFloat {
    HistoryFloatingLayout.cornerRadius(
      for: panelScale,
      mode: presentationMode,
      on: ScreenUtility.activeScreen()
    )
  }

  private func presentCurrentMode() {
    panelController.show(
      panelContentView,
      size: preferredPanelSize,
      position: preferredPosition,
      cornerRadius: preferredCornerRadius
    )
    setupEscapeMonitors()
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Floating history presented",
      context: [
        "mode": "\(presentationMode)",
        "position": preferredPosition.rawValue,
      ]
    )
  }

  private func handlePanelDidResignKey() {
    guard Self.shouldDismissPanelAfterResigningKey(
      isShowing: panelController.isShowing,
      isModalInteractionActive: isModalInteractionActive
    ) else {
      if panelController.isShowing {
        panelController.refocusAfterPresentation()
        DiagnosticLogger.shared.log(
          .debug,
          .history,
          "Floating history resign-key ignored during presentation"
        )
      } else {
        DiagnosticLogger.shared.log(
          .debug,
          .history,
          "Floating history resign-key ignored during modal interaction"
        )
      }
      return
    }
    hide()
  }

  nonisolated static func shouldDismissPanelAfterResigningKey(
    isShowing: Bool,
    isModalInteractionActive: Bool
  ) -> Bool {
    !isShowing && !isModalInteractionActive
  }

  private func resetExpandedState(initialFilter: CaptureHistoryCategory?) {
    expandedFilter = initialFilter
    expandedTimeFilter = .all
    searchText = ""
  }

  private func setupEscapeMonitors() {
    removeEscapeMonitors()

    localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }
      guard self?.isModalInteractionActive == false else { return event }
      self?.hide()
      return nil
    }

    globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return }
      Task { @MainActor [weak self] in
        guard self?.isModalInteractionActive == false else { return }
        self?.hide()
      }
    }
  }

  private func removeEscapeMonitors() {
    if let localEscapeMonitor {
      NSEvent.removeMonitor(localEscapeMonitor)
      self.localEscapeMonitor = nil
    }

    if let globalEscapeMonitor {
      NSEvent.removeMonitor(globalEscapeMonitor)
      self.globalEscapeMonitor = nil
    }
  }
}

enum HistoryFloatingPresentationMode: Equatable {
  case compact
  case expanded
}

enum HistoryFloatingTimeFilter: String, CaseIterable, Identifiable, Equatable {
  case all
  case last24Hours
  case last7Days
  case last30Days

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .all: L10n.PreferencesHistory.anyTime
    case .last24Hours: "24H"
    case .last7Days: "7D"
    case .last30Days: "30D"
    }
  }

  func includes(_ date: Date, relativeTo now: Date = Date()) -> Bool {
    switch self {
    case .all:
      true
    case .last24Hours:
      date >= now.addingTimeInterval(-86_400)
    case .last7Days:
      date >= now.addingTimeInterval(-604_800)
    case .last30Days:
      date >= now.addingTimeInterval(-2_592_000)
    }
  }
}

enum HistoryFloatingLayout {
  static let compactBasePanelSize = CGSize(width: 920, height: 316)
  static let expandedBasePanelSize = CGSize(width: 1_040, height: 680)
  static let compactBaseCornerRadius: CGFloat = 30
  static let expandedBaseCornerRadius: CGFloat = 32
  static let defaultScale = 1.0
  static let scaleRange: ClosedRange<Double> = 0.8 ... 1.4

  static func basePanelSize(for mode: HistoryFloatingPresentationMode) -> CGSize {
    switch mode {
    case .compact:
      compactBasePanelSize
    case .expanded:
      expandedBasePanelSize
    }
  }

  static func baseCornerRadius(for mode: HistoryFloatingPresentationMode) -> CGFloat {
    switch mode {
    case .compact:
      compactBaseCornerRadius
    case .expanded:
      expandedBaseCornerRadius
    }
  }

  static func clampedScale(_ value: Double) -> Double {
    min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
  }

  static func storedScale(userDefaults: UserDefaults = .standard) -> Double {
    clampedScale(userDefaults.object(forKey: PreferencesKeys.historyFloatingScale) as? Double ?? defaultScale)
  }

  static func effectiveScale(
    for scale: Double,
    mode: HistoryFloatingPresentationMode,
    on screen: NSScreen = ScreenUtility.activeScreen()
  ) -> CGFloat {
    let requestedScale = CGFloat(clampedScale(scale))
    let baseSize = basePanelSize(for: mode)
    let safeFrame = screen.visibleFrame.insetBy(
      dx: mode == .expanded ? 42 : 24,
      dy: mode == .expanded ? 42 : 24
    )
    let fittingScale = min(safeFrame.width / baseSize.width, safeFrame.height / baseSize.height)
    return max(0.58, min(requestedScale, fittingScale))
  }

  static func panelSize(
    for scale: Double,
    mode: HistoryFloatingPresentationMode,
    on screen: NSScreen = ScreenUtility.activeScreen()
  ) -> CGSize {
    let resolvedScale = effectiveScale(for: scale, mode: mode, on: screen)
    let baseSize = basePanelSize(for: mode)
    return CGSize(
      width: baseSize.width * resolvedScale,
      height: baseSize.height * resolvedScale
    )
  }

  static func cornerRadius(
    for scale: Double,
    mode: HistoryFloatingPresentationMode,
    on screen: NSScreen = ScreenUtility.activeScreen()
  ) -> CGFloat {
    baseCornerRadius(for: mode) * effectiveScale(for: scale, mode: mode, on: screen)
  }
}
