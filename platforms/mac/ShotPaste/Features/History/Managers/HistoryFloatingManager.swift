//
//  HistoryFloatingManager.swift
//  ShotPaste
//
//  State management for the floating history panel
//

import AppKit
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
      panelController.updatePosition(position)
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

  @Published var keepsOpen: Bool = false {
    didSet {
      UserDefaults.standard.set(keepsOpen, forKey: Keys.keepsOpen)
    }
  }

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
    static let position = "history.floating.position"
    static let defaultFilter = "history.floating.defaultFilter"
    static let keepsOpen = "history.floating.keepsOpen"
  }

  // MARK: - Init

  private init() {
    panelController.onPanelDidResignKey = { [weak self] in
      self?.handlePanelDidResignKey()
    }
    loadSettings()
  }

  private func loadSettings() {
    if let positionRaw = UserDefaults.standard.string(forKey: Keys.position),
       let savedPosition = HistoryPanelPosition(rawValue: positionRaw) {
      position = savedPosition
    }

    if let filterRaw = UserDefaults.standard.string(forKey: Keys.defaultFilter),
       let filter = CaptureHistoryCategory(rawValue: filterRaw) {
      defaultFilter = filter
    }

    panelScale = HistoryFloatingLayout.storedScale()
    keepsOpen = UserDefaults.standard.object(forKey: Keys.keepsOpen) as? Bool ?? false
    expandedFilter = defaultFilter
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Floating history settings loaded",
      context: [
        "position": position.rawValue,
        "scale": "\(panelScale)",
      ]
    )
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

  func showHistory(initialFilter: CaptureHistoryCategory? = nil) {
    presentHistory(initialFilter: initialFilter ?? expandedFilter ?? defaultFilter)
  }

  /// Open the history surface without a product category filter.
  func showAllHistory() {
    presentHistory(initialFilter: nil)
  }

  private func presentHistory(initialFilter: CaptureHistoryCategory?) {
    resetHistoryState(initialFilter: initialFilter)
    DiagnosticLogger.shared.log(
      .info,
      .history,
      "Floating history presented",
      context: ["filter": initialFilter?.rawValue ?? "all"]
    )
    presentPanel()
  }

  /// Open the complete history surface using the user's configured default filter.
  func showDefaultHistory() {
    showHistory(initialFilter: defaultFilter)
    focusPanel()
  }

  /// Clipboard-specific entry points always open the complete Clipboard view.
  /// Re-presenting an already-visible panel updates and focuses the same panel.
  func showClipboardHistory() {
    showHistory(initialFilter: .clipboard)
    focusPanel()
  }

  /// Refresh panel content if visible
  func refreshPanel() {
    guard panelController.isVisible else { return }
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Floating history refreshed"
    )
    presentPanel()
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
      on: ScreenUtility.activeScreen()
    )
  }

  private var preferredPosition: HistoryPanelPosition {
    position
  }

  private var preferredCornerRadius: CGFloat {
    HistoryFloatingLayout.cornerRadius(
      for: panelScale,
      on: ScreenUtility.activeScreen()
    )
  }

  private func presentPanel() {
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
        "position": preferredPosition.rawValue,
      ]
    )
  }

  private func handlePanelDidResignKey() {
    guard Self.shouldDismissPanelAfterResigningKey(
      isShowing: panelController.isShowing,
      isModalInteractionActive: isModalInteractionActive,
      keepsOpen: keepsOpen
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
    isModalInteractionActive: Bool,
    keepsOpen: Bool = false
  ) -> Bool {
    !isShowing && !isModalInteractionActive && !keepsOpen
  }

  private func resetHistoryState(initialFilter: CaptureHistoryCategory?) {
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
        guard NSApp.isActive else { return }
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
    case .last24Hours: L10n.PreferencesHistory.last24HoursShort
    case .last7Days: L10n.PreferencesHistory.last7DaysShort
    case .last30Days: L10n.PreferencesHistory.last30DaysShort
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
  static let basePanelSize = CGSize(width: 1_040, height: 680)
  static let baseCornerRadius: CGFloat = 32
  static let defaultScale = 1.0
  static let scaleRange: ClosedRange<Double> = 0.8 ... 1.4

  static func clampedScale(_ value: Double) -> Double {
    min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
  }

  static func storedScale(userDefaults: UserDefaults = .standard) -> Double {
    clampedScale(userDefaults.object(forKey: PreferencesKeys.historyFloatingScale) as? Double ?? defaultScale)
  }

  static func effectiveScale(
    for scale: Double,
    on screen: NSScreen = ScreenUtility.activeScreen()
  ) -> CGFloat {
    let requestedScale = CGFloat(clampedScale(scale))
    let safeFrame = screen.visibleFrame.insetBy(dx: 42, dy: 42)
    let fittingScale = min(safeFrame.width / basePanelSize.width, safeFrame.height / basePanelSize.height)
    return max(0.58, min(requestedScale, fittingScale))
  }

  static func panelSize(
    for scale: Double,
    on screen: NSScreen = ScreenUtility.activeScreen()
  ) -> CGSize {
    let resolvedScale = effectiveScale(for: scale, on: screen)
    return CGSize(
      width: basePanelSize.width * resolvedScale,
      height: basePanelSize.height * resolvedScale
    )
  }

  static func cornerRadius(
    for scale: Double,
    on screen: NSScreen = ScreenUtility.activeScreen()
  ) -> CGFloat {
    baseCornerRadius * effectiveScale(for: scale, on: screen)
  }
}
