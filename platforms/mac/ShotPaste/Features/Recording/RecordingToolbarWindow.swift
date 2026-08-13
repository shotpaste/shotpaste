//
//  RecordingToolbarWindow.swift
//  ShotPaste
//
//  Floating window container for recording toolbar and status bar
//

import AppKit
import Combine
import SwiftUI

// MARK: - Recording Output Mode

enum RecordingOutputMode: String, CaseIterable {
  case video
  case gif

  var displayName: String {
    switch self {
    case .video: L10n.RecordingToolbar.outputVideo
    case .gif: L10n.RecordingToolbar.outputGIF
    }
  }

  var iconName: String {
    switch self {
    case .video: "video"
    case .gif: "photo.on.rectangle"
    }
  }
}

enum RecordingToolbarPreferences {
  static func selectedFormat(defaults: UserDefaults = .standard) -> VideoFormat {
    guard let formatString = defaults.string(forKey: PreferencesKeys.recordingFormat),
          let format = VideoFormat(rawValue: formatString)
    else {
      return .mov
    }
    return format
  }

  static func selectedQuality(defaults: UserDefaults = .standard) -> VideoQuality {
    guard let qualityString = defaults.string(forKey: PreferencesKeys.recordingQuality),
          let quality = VideoQuality(rawValue: qualityString)
    else {
      return .high
    }
    return quality
  }

  static func captureAudio(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingCaptureAudio) as? Bool ?? true
  }

  static func captureMicrophone(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingCaptureMicrophone) as? Bool ?? false
  }

  static func microphoneDeviceID(defaults: UserDefaults = .standard) -> String {
    RecordingMicrophoneDeviceProvider.storedDeviceID(defaults: defaults)
  }

  static func outputMode(defaults: UserDefaults = .standard) -> RecordingOutputMode {
    guard let modeString = defaults.string(forKey: PreferencesKeys.recordingOutputMode),
          let mode = RecordingOutputMode(rawValue: modeString)
    else {
      return .video
    }
    return mode
  }

  static func highlightClicks(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingHighlightClicks) as? Bool ?? false
  }

  static func showKeystrokes(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingShowKeystrokes) as? Bool ?? false
  }

  static func showCursor(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingShowCursor) as? Bool ?? true
  }

  /// Whether the area outside the recording region is dimmed during recording.
  /// Defaults to `true` (dimmed) to preserve prior behavior when unset.
  static func dimNonSelectedArea(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingDimNonSelectedArea) as? Bool ?? true
  }

  /// Whether the floating recording controls bar is shown during recording.
  /// Defaults to `true` (visible) to preserve prior behavior when unset.
  static func hoverBarVisible(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingHoverBarVisible) as? Bool ?? true
  }

  /// Whether the elapsed recording time is shown next to the menu bar icon. Defaults to `true`.
  static func showTimeOnMenuBar(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: PreferencesKeys.recordingShowTimeOnMenuBar) as? Bool ?? true
  }
}

enum RecordingToolbarPlacement {
  static let screenEdgeInset: CGFloat = 10
  static let outsideSelectionGap: CGFloat = 20
  static let insideSelectionBottomInset: CGFloat = 24

  static func frameOrigin(
    toolbarSize: CGSize,
    anchorRect rect: CGRect,
    screenFrame: CGRect
  ) -> CGPoint {
    let x = rect.midX - toolbarSize.width / 2
    let minX = screenFrame.minX + screenEdgeInset
    let maxX = screenFrame.maxX - toolbarSize.width - screenEdgeInset
    let safeX = max(minX, min(x, maxX))

    let minY = screenFrame.minY + screenEdgeInset
    let maxY = screenFrame.maxY - toolbarSize.height - screenEdgeInset
    let belowSelectionY = rect.minY - toolbarSize.height - outsideSelectionGap
    let preferredY = belowSelectionY >= minY
      ? belowSelectionY
      : rect.minY + insideSelectionBottomInset
    let safeY = max(minY, min(preferredY, maxY))

    return CGPoint(x: safeX, y: safeY)
  }
}

// MARK: - Observable State

@MainActor
final class RecordingToolbarState: ObservableObject {
  @Published var selectedFormat: VideoFormat
  @Published var selectedQuality: VideoQuality
  @Published var captureAudio: Bool
  @Published var captureMicrophone: Bool
  @Published var microphoneDeviceID: String
  @Published var outputMode: RecordingOutputMode
  @Published var showCursor: Bool
  @Published var highlightClicks: Bool
  @Published var showKeystrokes: Bool
  @Published var dimNonSelectedArea: Bool
  @Published var isPreparingToRecord: Bool = false

  init() {
    selectedFormat = RecordingToolbarPreferences.selectedFormat()
    selectedQuality = RecordingToolbarPreferences.selectedQuality()
    captureAudio = RecordingToolbarPreferences.captureAudio()
    captureMicrophone = RecordingToolbarPreferences.captureMicrophone()
    microphoneDeviceID = RecordingToolbarPreferences.microphoneDeviceID()
    outputMode = RecordingToolbarPreferences.outputMode()
    showCursor = RecordingToolbarPreferences.showCursor()
    highlightClicks = RecordingToolbarPreferences.highlightClicks()
    showKeystrokes = RecordingToolbarPreferences.showKeystrokes()
    dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
  }
}

// MARK: - Toolbar Window

@MainActor
final class RecordingToolbarWindow: NSWindow {
  private var anchorRect: CGRect
  private var isRecordingStatusBarConfigured = false
  private var hostingView: NSHostingView<AnyView>?
  private var effectView: NSVisualEffectView?
  private var cachedContentSize: CGSize?

  // Callbacks
  var onDelete: (() -> Void)?
  var onRestart: (() -> Void)?
  var onStop: (() -> Void)?

  /// Called when annotate button layout position is determined
  var onAnnotateButtonOffsetChanged: ((CGFloat) -> Void)?

  /// Center X offset of the annotate button relative to this window's left edge
  private(set) var annotateButtonCenterXOffset: CGFloat = 0

  // Observable state for SwiftUI
  let state = RecordingToolbarState()
  let annotationState = RecordingAnnotationState()

  /// Expose state properties for external access (read/write)
  var selectedFormat: VideoFormat {
    get { state.selectedFormat }
    set { state.selectedFormat = newValue }
  }

  var selectedQuality: VideoQuality {
    get { state.selectedQuality }
    set { state.selectedQuality = newValue }
  }

  var captureAudio: Bool {
    get { state.captureAudio }
    set { state.captureAudio = newValue }
  }

  var captureMicrophone: Bool {
    get { state.captureMicrophone }
    set { state.captureMicrophone = newValue }
  }

  var microphoneDeviceID: String {
    get { state.microphoneDeviceID }
    set { state.microphoneDeviceID = newValue }
  }

  var outputMode: RecordingOutputMode {
    get { state.outputMode }
    set { state.outputMode = newValue }
  }

  init(anchorRect: CGRect) {
    self.anchorRect = anchorRect

    super.init(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    configureWindow()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func configureWindow() {
    isOpaque = false
    backgroundColor = .clear
    sharingType = .none
    // Use popUpMenu level to ensure toolbar is above the region overlay (.floating)
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hasShadow = true
    isReleasedWhenClosed = false
    // The toolbar owns its explicit content transitions. AppKit's automatic
    // order-in/order-out transform can outlive a short-lived window (notably
    // XCTest hosts) and race teardown.
    animationBehavior = .none

    // Apply theme appearance at the window level.
    appearance = ThemeManager.shared.nsAppearance
  }

  /// Present the recording status bar.
  /// - Parameter visible: initial visibility. When `false`, the bar's content/state/callbacks stay
  ///   wired but the window is not displayed (hover bar hidden — stop/pause/annotate remain reachable
  ///   from the menu bar and global shortcuts). Visibility also tracks the preference live so toggling
  ///   it mid-recording stays in sync with the menu bar stop control.
  func showRecordingStatusBar(recorder: ScreenRecordingManager, visible: Bool = true) {
    isRecordingStatusBarConfigured = true

    let view = RecordingStatusBarView(
      recorder: recorder,
      audioLevelMeter: recorder.audioLevelMeter,
      annotationState: annotationState,
      state: state,
      onDelete: { [weak self] in self?.onDelete?() },
      onRestart: { [weak self] in self?.onRestart?() },
      onStop: { [weak self] in self?.onStop?() },
      onAnnotateButtonLayout: { [weak self] centerX in
        // centerX is relative to the SwiftUI view's coordinate space
        // Add horizontal padding to get offset relative to window edge
        let offset = centerX + ToolbarConstants.horizontalPadding
        self?.annotateButtonCenterXOffset = offset
        self?.onAnnotateButtonOffsetChanged?(offset)
      }
    )

    setContent(AnyView(view))
    applyRecordingBarVisibility(visible)

    // Track live preference toggles during recording so the on-screen bar and the menu bar stop
    // control never disagree (both derive from `recording.hoverBarVisible`).
    NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(hoverBarVisibilityPreferenceChanged),
      name: UserDefaults.didChangeNotification,
      object: nil
    )
  }

  func showPreparationStatus() {
    isRecordingStatusBarConfigured = false
    let view = HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
      Text(L10n.RecordingToolbar.preparingRecording)
        .font(.system(size: 13, weight: .medium))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n.RecordingToolbar.preparingRecording)

    setContent(AnyView(view))
    showBelowRect(anchorRect)
  }

  // MARK: - Visibility

  @objc private func hoverBarVisibilityPreferenceChanged() {
    guard isRecordingStatusBarConfigured else { return }
    applyRecordingBarVisibility(RecordingToolbarPreferences.hoverBarVisible())
  }

  /// Show or hide the recording bar without rebuilding content. Idempotent so repeated
  /// `UserDefaults.didChangeNotification` ticks don't reposition an already-visible bar.
  private func applyRecordingBarVisibility(_ visible: Bool) {
    guard visible else {
      NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: self)
      orderOut(nil)
      return
    }

    // The recording bar is a movable floating status window.
    isMovableByWindowBackground = true

    guard !isVisible else {
      registerMovePersistenceObserver()
      return
    }

    // Restore a previously dragged position (clamped on-screen), else anchor below the selection.
    if let origin = persistedOrigin(), let size = cachedContentSize {
      setFrameOrigin(clampOriginToVisibleScreens(origin, size: size))
      orderFrontRegardless()
    } else {
      showBelowRect(anchorRect)
    }

    // Persist future drags. Added after the initial placement so restore doesn't re-save.
    registerMovePersistenceObserver()
  }

  /// Idempotently (re)registers the move observer that persists drag positions.
  private func registerMovePersistenceObserver() {
    NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(recordingToolbarDidMove(_:)),
      name: NSWindow.didMoveNotification,
      object: self
    )
  }

  // MARK: - Drag Position Persistence

  private var pendingOriginSaveWorkItem: DispatchWorkItem?

  private func persistedOrigin() -> CGPoint? {
    // We are the only writer (always via NSStringFromPoint), so any present, non-empty value is
    // valid — including a legitimate {0, 0}. Absent key => unset.
    guard let stored = UserDefaults.standard.string(forKey: PreferencesKeys.recordingHoverBarFrameOrigin),
          !stored.isEmpty
    else {
      return nil
    }
    return NSPointFromString(stored)
  }

  @objc private func recordingToolbarDidMove(_: Notification) {
    guard isRecordingStatusBarConfigured, isVisible else { return }
    // `didMoveNotification` fires continuously through a drag; debounce so we persist once at rest.
    pendingOriginSaveWorkItem?.cancel()
    let origin = frame.origin
    let workItem = DispatchWorkItem {
      UserDefaults.standard.set(NSStringFromPoint(origin), forKey: PreferencesKeys.recordingHoverBarFrameOrigin)
    }
    pendingOriginSaveWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
  }

  /// Keep the given origin on a real screen. Picks the screen that contains the origin (or overlaps
  /// the window most, else the first) and clamps within *that* screen's visible frame — avoids the
  /// dead zones that a bounding-box union produces on non-aligned multi-monitor layouts.
  private func clampOriginToVisibleScreens(_ origin: CGPoint, size: CGSize) -> CGPoint {
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return origin }

    let windowRect = CGRect(origin: origin, size: size)
    let target = screens.first(where: { $0.visibleFrame.contains(origin) })
      ?? screens.max(by: { overlapArea($0.visibleFrame, windowRect) < overlapArea($1.visibleFrame, windowRect) })
      ?? screens[0]

    return Self.clampedOrigin(origin, size: size, within: target.visibleFrame)
  }

  private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }

  /// Pure clamp of a window origin so a `size`-sized window stays fully inside `bounds`.
  /// Returns `origin` unchanged when `bounds` is null. Extracted for deterministic testing.
  nonisolated static func clampedOrigin(_ origin: CGPoint, size: CGSize, within bounds: CGRect) -> CGPoint {
    guard !bounds.isNull else { return origin }
    let maxX = max(bounds.minX, bounds.maxX - size.width)
    let maxY = max(bounds.minY, bounds.maxY - size.height)
    return CGPoint(
      x: min(max(origin.x, bounds.minX), maxX),
      y: min(max(origin.y, bounds.minY), maxY)
    )
  }

  private func setContent(_ view: AnyView) {
    let themedView = view.preferredColorScheme(ThemeManager.shared.systemAppearance)
    let hosting = NSHostingView(rootView: AnyView(themedView))
    hosting.translatesAutoresizingMaskIntoConstraints = false

    // NSVisualEffectView provides native background-tinted material backing,
    // matching the rest of the app's adaptive window backgrounds.
    let effect = NSVisualEffectView()
    effect.material = .hudWindow
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.wantsLayer = true
    effect.layer?.cornerRadius = ToolbarConstants.toolbarCornerRadius
    effect.layer?.cornerCurve = .continuous
    effect.layer?.masksToBounds = true

    // Make hosting view transparent so material shows through
    hosting.layer?.backgroundColor = .clear

    effect.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.topAnchor.constraint(equalTo: effect.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
      hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
    ])

    // Size the effect view to match hosting content
    let fittingSize = hosting.fittingSize
    effect.frame = CGRect(origin: .zero, size: fittingSize)

    contentView = effect
    hostingView = hosting
    effectView = effect

    setContentSize(fittingSize)
    cachedContentSize = fittingSize
    invalidateShadow()
  }

  private func positionBelowRect(_ rect: CGRect) {
    guard let size = cachedContentSize ?? contentView?.fittingSize else { return }

    // Find the screen containing the anchor rect (not NSScreen.main which is always primary)
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
      ?? ScreenUtility.activeScreen()
    let screenFrame = screen.visibleFrame

    let origin = RecordingToolbarPlacement.frameOrigin(
      toolbarSize: size,
      anchorRect: rect,
      screenFrame: screenFrame
    )

    setFrameOrigin(origin)
  }

  /// Position and order the window to the front (initial show only).
  private func showBelowRect(_ rect: CGRect) {
    positionBelowRect(rect)
    orderFrontRegardless()
  }

  override var canBecomeKey: Bool {
    true
  }

  func updateAnchorRect(_ rect: CGRect) {
    anchorRect = rect
    positionBelowRect(rect)
  }
}
