//
//  OneShotSessionState.swift
//  LiteScreen
//
//  Shared state machine for the One Shot capture entry.
//

import Combine
import CoreGraphics
import Foundation

enum OneShotTab: String, CaseIterable, Identifiable {
  case screenshot
  case scrolling
  case recording
  case clipboard

  var id: String {
    rawValue
  }

  var isCaptureMode: Bool {
    self != .clipboard
  }
}

enum OneShotPhase: String, Equatable {
  case idle
  case preparing
  case armed
  case selecting
  case selected
  case committed
  case executing
  case terminating
}

enum OneShotCommitReason: String, Equatable {
  case screenshotTool
  case screenshotProperty
  case screenshotUndoRedo
  case screenshotToolbarDrag
  case screenshotAnnotation
  case screenshotOCR
  case screenshotPin
  case screenshotCopy
  case screenshotFinish
  case scrollingStart
  case scrollingControl
  case recordingOutputMode
  case recordingCursor
  case recordingSystemAudio
  case recordingMicrophone
  case recordingStart
  case recordingToolbarDrag
}

enum OneShotTabRequestResult: Equatable {
  case switched
  case openClipboard
  case rejected
}

enum OneShotColorFormat: String, Equatable {
  case hex = "HEX"
  case rgb = "RGB"
}

struct OneShotRecordingOptions: Equatable {
  var outputMode: RecordingOutputMode
  var showsCursor: Bool
  var capturesSystemAudio: Bool
  var capturesMicrophone: Bool

  static func current(defaults: UserDefaults = .standard) -> OneShotRecordingOptions {
    OneShotRecordingOptions(
      outputMode: RecordingToolbarPreferences.outputMode(defaults: defaults),
      showsCursor: RecordingToolbarPreferences.showCursor(defaults: defaults),
      capturesSystemAudio: RecordingToolbarPreferences.captureAudio(defaults: defaults),
      capturesMicrophone: RecordingToolbarPreferences.captureMicrophone(defaults: defaults)
    )
  }
}

@MainActor
final class OneShotSessionState: ObservableObject {
  @Published private(set) var phase: OneShotPhase = .idle
  @Published private(set) var activeTab: OneShotTab = .screenshot
  @Published private(set) var selectionRectGlobal: CGRect?
  @Published private(set) var selectionDisplayIDs = Set<CGDirectDisplayID>()
  @Published private(set) var isPristine = true
  @Published private(set) var commitReason: OneShotCommitReason?
  @Published private(set) var frozenDisplayIDs = Set<CGDirectDisplayID>()
  @Published private(set) var teardownPerformed = false
  @Published private(set) var showsScrollingHelp = false
  @Published private(set) var colorFormat: OneShotColorFormat = .hex
  @Published private(set) var currentColorValue: String?
  @Published private(set) var recordingOptions: OneShotRecordingOptions
  @Published var switcherX: CGFloat = 0
  @Published var modeToolbarPosition: CGPoint?

  private(set) var switcherDisplayID: CGDirectDisplayID = 0
  private var currentHexValue: String?
  private var currentRGBValue: String?

  init(recordingOptions: OneShotRecordingOptions? = nil) {
    self.recordingOptions = recordingOptions ?? .current()
  }

  /// This state has no actor-bound teardown work. Keeping deinitialization
  /// nonisolated also avoids scheduling a main-actor deinit from XCTest worker
  /// processes on macOS versions older than the active Xcode SDK.
  nonisolated deinit {}

  var canSwitchTab: Bool {
    (phase == .armed || phase == .selected) && isPristine
  }

  var selectionIsEditable: Bool {
    phase == .selected && isPristine
  }

  var showsTopSwitcher: Bool {
    phase == .armed || phase == .selected || phase == .committed
  }

  func beginPreparing(switcherDisplayID: CGDirectDisplayID, switcherX: CGFloat) {
    guard phase == .idle else { return }
    self.switcherDisplayID = switcherDisplayID
    self.switcherX = switcherX
    phase = .preparing
  }

  func arm(frozenDisplayIDs: Set<CGDirectDisplayID>) {
    guard phase == .preparing else { return }
    self.frozenDisplayIDs = frozenDisplayIDs
    activeTab = .screenshot
    isPristine = true
    commitReason = nil
    selectionRectGlobal = nil
    selectionDisplayIDs.removeAll()
    phase = .armed
  }

  @discardableResult
  func requestTab(_ tab: OneShotTab) -> OneShotTabRequestResult {
    guard canSwitchTab else { return .rejected }
    if tab == .clipboard {
      selectionRectGlobal = nil
      selectionDisplayIDs.removeAll()
      return .openClipboard
    }
    activeTab = tab
    showsScrollingHelp = false
    return .switched
  }

  func beginSelection() {
    guard phase == .armed || selectionIsEditable else { return }
    selectionRectGlobal = nil
    selectionDisplayIDs.removeAll()
    showsScrollingHelp = false
    phase = .selecting
  }

  func updateSelection(_ rect: CGRect, displayIDs: Set<CGDirectDisplayID>) {
    guard phase == .selecting || selectionIsEditable else { return }
    selectionRectGlobal = rect.standardized
    selectionDisplayIDs = displayIDs
  }

  @discardableResult
  func finishSelection(
    _ rect: CGRect?,
    displayIDs: Set<CGDirectDisplayID>,
    minimumSize: CGFloat = 5
  ) -> Bool {
    guard phase == .selecting else { return false }
    guard let rect = rect?.standardized,
          rect.width > minimumSize,
          rect.height > minimumSize
    else {
      selectionRectGlobal = nil
      selectionDisplayIDs.removeAll()
      phase = .armed
      return false
    }
    selectionRectGlobal = rect
    selectionDisplayIDs = displayIDs
    phase = .selected
    return true
  }

  func updateEditableSelection(_ rect: CGRect, displayIDs: Set<CGDirectDisplayID>) {
    guard selectionIsEditable else { return }
    selectionRectGlobal = rect.standardized
    selectionDisplayIDs = displayIDs
  }

  @discardableResult
  func commitModeInteraction(_ reason: OneShotCommitReason) -> Bool {
    if phase == .committed {
      return activeTab.isCaptureMode
    }
    guard phase == .selected, isPristine, activeTab.isCaptureMode else { return false }
    commitReason = reason
    isPristine = false
    showsScrollingHelp = false
    phase = .committed
    return true
  }

  @discardableResult
  func beginExecuting() -> Bool {
    guard phase == .committed else { return false }
    phase = .executing
    return true
  }

  func toggleScrollingHelp() {
    guard phase == .selected, isPristine, activeTab == .scrolling else { return }
    showsScrollingHelp.toggle()
  }

  func updateRecordingOptions(
    _ options: OneShotRecordingOptions,
    reason: OneShotCommitReason
  ) {
    guard activeTab == .recording else { return }
    guard commitModeInteraction(reason) else { return }
    recordingOptions = options
  }

  func updateCurrentColor(hex: String?, rgb: String?) {
    guard phase == .armed else { return }
    currentHexValue = hex
    currentRGBValue = rgb
    currentColorValue = colorFormat == .hex ? hex : rgb
  }

  func toggleColorFormat() {
    guard phase == .armed else { return }
    colorFormat = colorFormat == .hex ? .rgb : .hex
    currentColorValue = colorFormat == .hex ? currentHexValue : currentRGBValue
  }

  func moveSwitcher(to x: CGFloat, within range: ClosedRange<CGFloat>) {
    guard phase == .armed || phase == .selected || phase == .committed else { return }
    switcherX = min(max(x, range.lowerBound), range.upperBound)
  }

  func beginTerminating(clearSelection: Bool = false) {
    guard phase != .idle, phase != .terminating else { return }
    if clearSelection {
      selectionRectGlobal = nil
      selectionDisplayIDs.removeAll()
    }
    phase = .terminating
  }

  @discardableResult
  func performTeardown() -> Bool {
    guard !teardownPerformed else { return false }
    teardownPerformed = true
    selectionRectGlobal = nil
    selectionDisplayIDs.removeAll()
    frozenDisplayIDs.removeAll()
    showsScrollingHelp = false
    currentColorValue = nil
    currentHexValue = nil
    currentRGBValue = nil
    modeToolbarPosition = nil
    phase = .idle
    return true
  }
}
