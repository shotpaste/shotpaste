//
//  PermissionAuthorizationAssistant.swift
//  ShotPaste
//
//  Guided System Settings assistant for completing macOS privacy authorization.
//

import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI

nonisolated enum PermissionAuthorizationSettingsTarget: String, CaseIterable, Hashable {
  case screenRecording
  case microphone
  case accessibility

  static let guideOrder: [Self] = [.screenRecording, .accessibility, .microphone]
  static let dragSupportedTargets: [Self] = [.screenRecording, .accessibility]

  var supportsDragging: Bool {
    Self.dragSupportedTargets.contains(self)
  }

  var tccService: String {
    switch self {
    case .screenRecording:
      "ScreenCapture"
    case .microphone:
      "Microphone"
    case .accessibility:
      "Accessibility"
    }
  }

  var urlString: String {
    switch self {
    case .screenRecording:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    case .microphone:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case .accessibility:
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }
  }
}

nonisolated struct PermissionAuthorizationSnapshot: Equatable {
  let screenRecordingGranted: Bool
  let microphoneGranted: Bool
  let accessibilityGranted: Bool

  var allGranted: Bool {
    PermissionAuthorizationSettingsTarget.guideOrder.allSatisfy(isGranted)
  }

  func isGranted(_ target: PermissionAuthorizationSettingsTarget) -> Bool {
    switch target {
    case .screenRecording:
      screenRecordingGranted
    case .microphone:
      microphoneGranted
    case .accessibility:
      accessibilityGranted
    }
  }

  func replacing(
    _ target: PermissionAuthorizationSettingsTarget,
    granted: Bool
  ) -> Self {
    switch target {
    case .screenRecording:
      Self(
        screenRecordingGranted: granted,
        microphoneGranted: microphoneGranted,
        accessibilityGranted: accessibilityGranted
      )
    case .microphone:
      Self(
        screenRecordingGranted: screenRecordingGranted,
        microphoneGranted: granted,
        accessibilityGranted: accessibilityGranted
      )
    case .accessibility:
      Self(
        screenRecordingGranted: screenRecordingGranted,
        microphoneGranted: microphoneGranted,
        accessibilityGranted: granted
      )
    }
  }
}

nonisolated enum PermissionAuthorizationGuidePolicy {
  static func firstMissingTarget(
    in snapshot: PermissionAuthorizationSnapshot
  ) -> PermissionAuthorizationSettingsTarget? {
    PermissionAuthorizationSettingsTarget.guideOrder.first { !snapshot.isGranted($0) }
  }

  static func authorizationAction(
    for target: PermissionAuthorizationSettingsTarget,
    microphoneStatus: AVAuthorizationStatus
  ) -> PermissionAuthorizationGuideAction {
    switch target {
    case .screenRecording, .accessibility:
      .openSystemSettings
    case .microphone:
      switch microphoneStatus {
      case .notDetermined:
        .requestMicrophoneAccess
      case .denied:
        .openSystemSettings
      case .authorized, .restricted:
        .none
      @unknown default:
        .none
      }
    }
  }
}

nonisolated enum PermissionAuthorizationGuideAction: Equatable {
  case openSystemSettings
  case requestMicrophoneAccess
  case none
}

nonisolated enum PermissionSettingsHighlightGeometry {
  static func highlightFrame(in settingsWindowFrame: CGRect) -> CGRect {
    let horizontalInset = max(18, settingsWindowFrame.width * 0.025)
    let topInset = max(70, settingsWindowFrame.height * 0.13)
    let bottomInset = max(26, settingsWindowFrame.height * 0.05)
    let contentStart = settingsWindowFrame.minX + settingsWindowFrame.width * 0.37

    return CGRect(
      x: contentStart,
      y: settingsWindowFrame.minY + bottomInset,
      width: max(180, settingsWindowFrame.maxX - horizontalInset - contentStart),
      height: max(140, settingsWindowFrame.height - topInset - bottomInset)
    )
  }
}

nonisolated enum PermissionSettingsHighlightVisibilityPolicy {
  static func shouldShow(
    isGuideActive: Bool,
    isSystemSettingsFrontmost: Bool,
    hasSystemSettingsWindow: Bool,
    hasModalWindow: Bool = false,
    isInteractionSuppressed: Bool = false
  ) -> Bool {
    isGuideActive
      && isSystemSettingsFrontmost
      && hasSystemSettingsWindow
      && !hasModalWindow
      && !isInteractionSuppressed
  }
}

nonisolated enum PermissionAssistantPanelGeometry {
  static func origin(
    settingsWindowFrame: CGRect,
    panelSize: CGSize,
    visibleFrame: CGRect,
    gap: CGFloat = 12
  ) -> CGPoint {
    let margin: CGFloat = 12
    let leftX = settingsWindowFrame.minX - panelSize.width - gap
    let rightX = settingsWindowFrame.maxX + gap
    let fitsLeft = leftX >= visibleFrame.minX + margin
    let fitsRight = rightX + panelSize.width <= visibleFrame.maxX - margin

    let x: CGFloat
    if fitsLeft {
      x = leftX
    } else if fitsRight {
      x = rightX
    } else {
      let leftOverlap = max(
        0,
        visibleFrame.minX + margin + panelSize.width + gap - settingsWindowFrame.minX
      )
      let rightOverlap = max(
        0,
        settingsWindowFrame.maxX + gap + panelSize.width - visibleFrame.maxX + margin
      )
      x = leftOverlap <= rightOverlap
        ? visibleFrame.minX + margin
        : visibleFrame.maxX - margin - panelSize.width
    }

    let preferredY = settingsWindowFrame.midY - panelSize.height / 2
    let minimumY = visibleFrame.minY + margin
    let maximumY = visibleFrame.maxY - margin - panelSize.height
    return CGPoint(
      x: x,
      y: max(minimumY, min(preferredY, maximumY))
    )
  }
}

@MainActor
final class PermissionAuthorizationAssistantController: NSObject, ObservableObject,
  NSWindowDelegate {
  static let shared = PermissionAuthorizationAssistantController()

  @Published private(set) var isGuiding = false
  @Published private(set) var currentTarget: PermissionAuthorizationSettingsTarget?
  @Published private(set) var screenRecordingGranted = ScreenCaptureManager.shared.hasPermission
  @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
  @Published private(set) var microphoneGranted =
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
  @Published private(set) var didCompleteGuide = false
  @Published private(set) var didFailCurrentDetection = false
  @Published private(set) var requiresManualSettingsOpen = false
  @Published private(set) var isRequestingMicrophone = false

  private var panel: PermissionAuthorizationAssistantPanel?
  private var highlightPanel: PermissionSettingsHighlightPanel?
  private var guideTask: Task<Void, Never>?
  private var highlightTask: Task<Void, Never>?
  private var isHighlightInteractionSuppressed = false
  private var highlightInteractionArmedAt = Date.distantFuture
  private var forcedMissingTargets: Set<PermissionAuthorizationSettingsTarget> = []
  private var observedRevokedTargets: Set<PermissionAuthorizationSettingsTarget> = []

  var isVisible: Bool {
    panel?.isVisible == true
  }

  var snapshot: PermissionAuthorizationSnapshot {
    PermissionAuthorizationSnapshot(
      screenRecordingGranted: screenRecordingGranted,
      microphoneGranted: microphoneGranted,
      accessibilityGranted: accessibilityGranted
    )
  }

  func show() {
    showPanel()
    refreshPermissionStates()
  }

  func startGuidedAuthorization() {
    if isGuiding {
      panel?.orderFrontRegardless()
      return
    }

    guideTask?.cancel()
    didCompleteGuide = false
    didFailCurrentDetection = false
    requiresManualSettingsOpen = false
    isGuiding = true

    guideTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await refreshPermissionStatesNow()

      guard !snapshot.allGranted else {
        finishGuide(showCompletionPanel: false)
        AppToastManager.shared.show(
          message: L10n.PreferencesPermissions.authorizationAllGranted,
          style: .success,
          position: .bottomCenter,
          duration: 3
        )
        return
      }

      showPanel()
      advanceGuide(openSettings: true)

      while !Task.isCancelled, isGuiding {
        try? await Task.sleep(nanoseconds: 750_000_000)
        guard !Task.isCancelled else { break }
        await refreshPermissionStatesNow()
        advanceGuide(openSettings: true)
      }
    }
  }

  func checkCurrentAndContinue() {
    guard let target = currentTarget else { return }
    didFailCurrentDetection = false

    // tccutil can leave this process with the old granted value. An explicit
    // check from the user is the safe point to release that reset-time shield.
    forcedMissingTargets.remove(target)
    observedRevokedTargets.remove(target)
    if target == .screenRecording {
      ScreenCaptureManager.shared.clearPermissionResetOverride()
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      await refreshPermissionStatesNow()
      if snapshot.isGranted(target) {
        advanceGuide(openSettings: true)
      } else {
        didFailCurrentDetection = true
        performAuthorizationAction(for: target)
      }
    }
  }

  func markPermissionsReset(report: PermissionResetReport) {
    let resetTargets = Set(PermissionAuthorizationSettingsTarget.allCases.filter {
      report.succeeded(for: $0.tccService)
    })
    guard !resetTargets.isEmpty else { return }

    guideTask?.cancel()
    guideTask = nil
    isGuiding = false
    currentTarget = nil
    didCompleteGuide = false
    didFailCurrentDetection = false
    forcedMissingTargets.formUnion(resetTargets)
    observedRevokedTargets.subtract(resetTargets)
    hideHighlight()

    if resetTargets.contains(.screenRecording) {
      ScreenCaptureManager.shared.markPermissionReset()
      screenRecordingGranted = false
    }
    if resetTargets.contains(.microphone) {
      microphoneStatus = .notDetermined
      microphoneGranted = false
    }
    if resetTargets.contains(.accessibility) {
      accessibilityGranted = false
    }
  }

  func clearResetOverride(for target: PermissionAuthorizationSettingsTarget) {
    forcedMissingTargets.remove(target)
    observedRevokedTargets.remove(target)
    if target == .screenRecording {
      ScreenCaptureManager.shared.clearPermissionResetOverride()
    }
  }

  func refreshPermissionStates() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await refreshPermissionStatesNow()
      if isGuiding {
        advanceGuide(openSettings: true)
      }
    }
  }

  func authorizationAction(
    for target: PermissionAuthorizationSettingsTarget
  ) -> PermissionAuthorizationGuideAction {
    PermissionAuthorizationGuidePolicy.authorizationAction(
      for: target,
      microphoneStatus: microphoneStatus
    )
  }

  func performAuthorizationAction(for target: PermissionAuthorizationSettingsTarget) {
    switch authorizationAction(for: target) {
    case .openSystemSettings:
      _ = openSettings(target)
    case .requestMicrophoneAccess:
      requestMicrophoneAccess()
    case .none:
      break
    }
  }

  @discardableResult
  func openSettings(_ target: PermissionAuthorizationSettingsTarget) -> Bool {
    guard let url = URL(string: target.urlString) else {
      requiresManualSettingsOpen = true
      return false
    }

    let opened = NSWorkspace.shared.open(url)
    requiresManualSettingsOpen = !opened
    guard opened else { return false }

    panel?.level = .floating
    startHighlightTracking(for: target)
    return true
  }

  func permissionIconDragBegan() {
    suppressHighlightForSystemInteraction()
    panel?.level = .normal
    panel?.resignKey()
  }

  func permissionIconDragEnded() {
    suppressHighlightForSystemInteraction()
    panel?.level = .normal
    panel?.resignKey()
  }

  func close() {
    guideTask?.cancel()
    guideTask = nil
    isGuiding = false
    currentTarget = nil
    hideHighlight()
    panel?.orderOut(nil)
  }

  func windowShouldClose(_: NSWindow) -> Bool {
    close()
    return false
  }

  private func refreshPermissionStatesNow() async {
    let screenCaptureManager = ScreenCaptureManager.shared
    await screenCaptureManager.checkPermission()

    let rawMicrophoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let rawSnapshot = PermissionAuthorizationSnapshot(
      screenRecordingGranted: screenCaptureManager.hasPermission,
      microphoneGranted: rawMicrophoneStatus == .authorized,
      accessibilityGranted: AXIsProcessTrusted()
    )

    for target in Array(forcedMissingTargets) {
      if !rawSnapshot.isGranted(target) {
        observedRevokedTargets.insert(target)
      } else if observedRevokedTargets.contains(target) {
        forcedMissingTargets.remove(target)
        observedRevokedTargets.remove(target)
      }
    }

    let effectiveSnapshot = forcedMissingTargets.reduce(rawSnapshot) { snapshot, target in
      snapshot.replacing(target, granted: false)
    }
    screenRecordingGranted = effectiveSnapshot.screenRecordingGranted
    microphoneStatus = forcedMissingTargets.contains(.microphone)
      ? .notDetermined
      : rawMicrophoneStatus
    microphoneGranted = effectiveSnapshot.microphoneGranted
    accessibilityGranted = effectiveSnapshot.accessibilityGranted
  }

  private func advanceGuide(openSettings shouldOpenSettings: Bool) {
    guard isGuiding else { return }
    guard let nextTarget = PermissionAuthorizationGuidePolicy.firstMissingTarget(in: snapshot) else {
      finishGuide(showCompletionPanel: true)
      return
    }

    guard nextTarget != currentTarget else { return }
    currentTarget = nextTarget
    didFailCurrentDetection = false
    requiresManualSettingsOpen = false
    hideHighlight()
    if shouldOpenSettings {
      performAuthorizationAction(for: nextTarget)
    }
  }

  private func requestMicrophoneAccess() {
    guard microphoneStatus == .notDetermined, !isRequestingMicrophone else { return }

    clearResetOverride(for: .microphone)
    requiresManualSettingsOpen = false
    isRequestingMicrophone = true
    hideHighlight()

    // The preceding guide steps keep System Settings frontmost. Bring ShotPaste
    // forward so the native microphone authorization alert is immediately visible.
    NSApp.activate(ignoringOtherApps: true)
    panel?.level = .floating
    panel?.orderFrontRegardless()

    Task { @MainActor [weak self] in
      _ = await AVCaptureDevice.requestAccess(for: .audio)
      guard let self else { return }

      isRequestingMicrophone = false
      await refreshPermissionStatesNow()
      if isGuiding {
        advanceGuide(openSettings: true)
      }
    }
  }

  private func finishGuide(showCompletionPanel: Bool) {
    guideTask?.cancel()
    guideTask = nil
    isGuiding = false
    currentTarget = nil
    hideHighlight()

    if showCompletionPanel {
      didCompleteGuide = true
      panel?.orderFrontRegardless()
      AppToastManager.shared.show(
        message: L10n.PreferencesPermissions.authorizationComplete,
        style: .success,
        position: .bottomCenter,
        duration: 3
      )
    }
  }

  private func showPanel() {
    let panel = panel ?? makePanel()
    self.panel = panel
    position(panel)
    panel.orderFrontRegardless()
  }

  private func makePanel() -> PermissionAuthorizationAssistantPanel {
    let size = NSSize(width: 460, height: 540)
    let panel = PermissionAuthorizationAssistantPanel(
      contentRect: NSRect(origin: .zero, size: size)
    )
    panel.title = L10n.PreferencesPermissions.authorizationGuideTitle
    panel.delegate = self
    panel.contentMinSize = size
    panel.contentMaxSize = size

    let hostingView = NSHostingView(
      rootView: PermissionAuthorizationAssistantView(controller: self)
    )
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView
    return panel
  }

  private func position(_ panel: NSPanel) {
    let visibleFrame = ScreenUtility.activeScreen().visibleFrame
    panel.setFrameOrigin(NSPoint(
      x: visibleFrame.minX + 24,
      y: visibleFrame.midY - panel.frame.height / 2
    ))
  }

  private func startHighlightTracking(for target: PermissionAuthorizationSettingsTarget) {
    highlightTask?.cancel()
    highlightPanel?.orderOut(nil)
    isHighlightInteractionSuppressed = false
    highlightInteractionArmedAt = Date().addingTimeInterval(0.75)
    highlightPanel = PermissionSettingsHighlightPanel(
      contentRect: .zero,
      target: target
    )

    highlightTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled, isGuiding {
        updateHighlightVisibility()
        try? await Task.sleep(nanoseconds: 50_000_000)
      }
      highlightPanel?.orderOut(nil)
    }
  }

  private func updateHighlightVisibility() {
    let isSystemSettingsFrontmost = NSWorkspace.shared.frontmostApplication?
      .bundleIdentifier == "com.apple.systempreferences"
    let windowContext = systemSettingsWindowContext()

    if let windowContext, let panel {
      let origin = PermissionAssistantPanelGeometry.origin(
        settingsWindowFrame: windowContext.frame,
        panelSize: panel.frame.size,
        visibleFrame: windowContext.visibleFrame
      )
      if panel.frame.origin != origin {
        panel.setFrameOrigin(origin)
      }
    }

    if Date() >= highlightInteractionArmedAt,
       CGEventSource.buttonState(.combinedSessionState, button: .left) {
      suppressHighlightForSystemInteraction()
    }

    guard PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: isGuiding,
      isSystemSettingsFrontmost: isSystemSettingsFrontmost,
      hasSystemSettingsWindow: windowContext != nil,
      hasModalWindow: windowContext?.hasModalWindow == true,
      isInteractionSuppressed: isHighlightInteractionSuppressed
    ), let windowContext else {
      highlightPanel?.orderOut(nil)
      return
    }

    let frame = PermissionSettingsHighlightGeometry.highlightFrame(in: windowContext.frame)
    highlightPanel?.setFrame(frame, display: true)
    if highlightPanel?.isVisible != true {
      highlightPanel?.orderFrontRegardless()
    }
  }

  private func hideHighlight() {
    highlightTask?.cancel()
    highlightTask = nil
    highlightPanel?.orderOut(nil)
    highlightPanel = nil
    isHighlightInteractionSuppressed = false
    highlightInteractionArmedAt = .distantFuture
  }

  private func suppressHighlightForSystemInteraction() {
    isHighlightInteractionSuppressed = true
    highlightPanel?.orderOut(nil)
  }

  private struct SystemSettingsWindowContext {
    let frame: CGRect
    let visibleFrame: CGRect
    let hasModalWindow: Bool
  }

  private func systemSettingsWindowContext() -> SystemSettingsWindowContext? {
    guard let application = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.apple.systempreferences"
    ).first else { return nil }
    guard let windowInfo = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else { return nil }

    let candidates = windowInfo.compactMap { info -> CGRect? in
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == application.processIdentifier,
            (info[kCGWindowLayer as String] as? Int) == 0,
            (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
            let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDictionary),
            frame.width >= 180,
            frame.height >= 100
      else { return nil }
      return frame
    }
    guard let quartzFrame = candidates.max(by: {
      $0.width * $0.height < $1.width * $1.height
    }) else { return nil }
    let hasModalWindow = candidates.contains { candidate in
      candidate != quartzFrame
        && candidate.intersects(quartzFrame)
        && candidate.width >= 240
        && candidate.height >= 120
    }

    for screen in NSScreen.screens {
      guard let displayNumber = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber else { continue }
      let displayBounds = CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
      guard displayBounds.intersects(quartzFrame) else { continue }
      let frame = CGRect(
        x: screen.frame.minX + quartzFrame.minX - displayBounds.minX,
        y: screen.frame.maxY - (quartzFrame.maxY - displayBounds.minY),
        width: quartzFrame.width,
        height: quartzFrame.height
      )
      return SystemSettingsWindowContext(
        frame: frame,
        visibleFrame: screen.visibleFrame,
        hasModalWindow: hasModalWindow
      )
    }

    let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
    let frame = CGRect(
      x: quartzFrame.minX,
      y: mainDisplayBounds.maxY - quartzFrame.maxY,
      width: quartzFrame.width,
      height: quartzFrame.height
    )
    return SystemSettingsWindowContext(
      frame: frame,
      visibleFrame: NSScreen.main?.visibleFrame ?? frame,
      hasModalWindow: hasModalWindow
    )
  }
}

private final class PermissionAuthorizationAssistantPanel: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .floating
    isFloatingPanel = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    sharingType = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = false
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

private final class PermissionSettingsHighlightPanel: NSPanel {
  init(contentRect: NSRect, target: PermissionAuthorizationSettingsTarget) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Keep system modal/password panels above this decorative overlay.
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    sharingType = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    contentView = NSHostingView(rootView: PermissionSettingsHighlightView(target: target))
  }

  override var canBecomeKey: Bool {
    false
  }

  override var canBecomeMain: Bool {
    false
  }
}

private struct PermissionSettingsHighlightView: View {
  let target: PermissionAuthorizationSettingsTarget
  @State private var isPulsing = false

  var body: some View {
    RoundedRectangle(cornerRadius: 16)
      .stroke(Color.accentColor, lineWidth: isPulsing ? 6 : 3)
      .background(Color.accentColor.opacity(isPulsing ? 0.09 : 0.035))
      .overlay(alignment: .top) {
        Label(highlightText, systemImage: target.supportsDragging ? "hand.draw.fill" : "cursorarrow.click.2")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .background(Color.accentColor, in: Capsule())
          .offset(y: -18)
      }
      .padding(8)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          isPulsing = true
        }
      }
  }

  private var highlightText: String {
    target.supportsDragging
      ? L10n.PreferencesPermissions.authorizationHighlightDrag
      : L10n.PreferencesPermissions.authorizationHighlightEnable
  }
}

struct PermissionDraggableAppIcon: View {
  var size: CGFloat = 54
  var onDragBegan: () -> Void = {}
  var onDragEnded: () -> Void = {}

  private var appIcon: NSImage {
    NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
  }

  var body: some View {
    PermissionAppIconDragSource(
      image: appIcon,
      onDragBegan: onDragBegan,
      onDragEnded: onDragEnded
    )
    .frame(width: size, height: size)
    .padding(10)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Size.radiusLg))
    .overlay {
      RoundedRectangle(cornerRadius: Size.radiusLg)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        .foregroundStyle(Color.accentColor.opacity(0.6))
    }
    .overlay(alignment: .bottomTrailing) {
      Image(systemName: "hand.draw.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(5)
        .background(Color.accentColor, in: Circle())
        .offset(x: 5, y: 5)
    }
    .help(L10n.PreferencesPermissions.dragAppTitle)
    .accessibilityLabel(L10n.PreferencesPermissions.dragAppTitle)
    .accessibilityHint(L10n.PreferencesPermissions.dragAppDescription)
  }
}

private struct PermissionAppIconDragSource: NSViewRepresentable {
  let image: NSImage
  let onDragBegan: () -> Void
  let onDragEnded: () -> Void

  func makeNSView(context _: Context) -> PermissionAppIconDragSourceView {
    let imageView = PermissionAppIconDragSourceView()
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignCenter
    imageView.image = image
    imageView.onDragBegan = onDragBegan
    imageView.onDragEnded = onDragEnded
    return imageView
  }

  func updateNSView(_ imageView: PermissionAppIconDragSourceView, context _: Context) {
    imageView.image = image
    imageView.onDragBegan = onDragBegan
    imageView.onDragEnded = onDragEnded
  }
}

private final class PermissionAppIconDragSourceView: NSImageView, NSDraggingSource {
  private var isDraggingApp = false
  var onDragBegan: () -> Void = {}
  var onDragEnded: () -> Void = {}

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with _: NSEvent) {
    isDraggingApp = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isDraggingApp else { return }
    isDraggingApp = true
    onDragBegan()

    let draggingItem = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    draggingItem.setDraggingFrame(bounds, contents: image)
    let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  override func mouseUp(with _: NSEvent) {
    isDraggingApp = false
  }

  func draggingSession(
    _: NSDraggingSession,
    sourceOperationMaskFor _: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _: NSDraggingSession,
    endedAt _: NSPoint,
    operation _: NSDragOperation
  ) {
    isDraggingApp = false
    onDragEnded()
  }
}

private struct PermissionAuthorizationAssistantView: View {
  @ObservedObject var controller: PermissionAuthorizationAssistantController

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      header

      if controller.didCompleteGuide {
        completionCard
      } else if let target = controller.currentTarget {
        currentStepCard(target)
      }

      VStack(spacing: Spacing.xs) {
        permissionStatusRow(
          icon: "rectangle.inset.filled.and.person.filled",
          title: L10n.Permission.screenRecording,
          state: controller.screenRecordingGranted ? .granted : .notGranted,
          target: .screenRecording
        )
        permissionStatusRow(
          icon: "hand.raised.fill",
          title: L10n.Permission.accessibility,
          state: controller.accessibilityGranted ? .granted : .notGranted,
          target: .accessibility
        )
        permissionStatusRow(
          icon: "mic.fill",
          title: L10n.Permission.microphone,
          state: microphoneState,
          target: .microphone
        )
      }

      Spacer(minLength: 0)

      HStack(spacing: Spacing.sm) {
        if let target = controller.currentTarget {
          if controller.authorizationAction(for: target) != .none {
            Button {
              controller.performAuthorizationAction(for: target)
            } label: {
              if target == .microphone, controller.isRequestingMicrophone {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label(
                  authorizationActionTitle(for: target),
                  systemImage: authorizationActionIcon(for: target)
                )
              }
            }
            .buttonStyle(.bordered)
            .disabled(controller.isRequestingMicrophone)
          }

          Button {
            controller.checkCurrentAndContinue()
          } label: {
            Label(
              L10n.PreferencesPermissions.authorizationCheckAndContinue,
              systemImage: "checkmark.circle"
            )
          }
          .buttonStyle(.borderedProminent)
          .disabled(controller.isRequestingMicrophone)
        }

        Spacer()

        Button(L10n.Common.done) {
          controller.close()
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(Spacing.lg)
    .frame(width: 460, height: 540)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { controller.refreshPermissionStates() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      controller.refreshPermissionStates()
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      Image(systemName: controller.didCompleteGuide ? "checkmark.shield.fill" : "lock.shield.fill")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(controller.didCompleteGuide ? Color.green : Color.accentColor)
        .frame(width: 48, height: 48)
        .background(
          (controller.didCompleteGuide ? Color.green : Color.accentColor).opacity(0.1),
          in: RoundedRectangle(cornerRadius: Size.radiusLg)
        )

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(L10n.PreferencesPermissions.authorizationGuideTitle)
          .font(.title3.weight(.semibold))
        Text(L10n.PreferencesPermissions.authorizationGuideDescription)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var completionCard: some View {
    Label(L10n.PreferencesPermissions.authorizationComplete, systemImage: "checkmark.circle.fill")
      .font(.body.weight(.semibold))
      .foregroundStyle(Color.green)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.md)
      .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: Size.radiusLg))
  }

  private func currentStepCard(_ target: PermissionAuthorizationSettingsTarget) -> some View {
    HStack(spacing: Spacing.lg) {
      if target.supportsDragging {
        PermissionDraggableAppIcon(
          size: 76,
          onDragBegan: controller.permissionIconDragBegan,
          onDragEnded: controller.permissionIconDragEnded
        )
      } else {
        Image(systemName: "mic.badge.plus")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 96, height: 96)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: Size.radiusLg))
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        Text(stepTitle(for: target))
          .font(.body.weight(.semibold))
        Text(instruction(for: target))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if controller.didFailCurrentDetection {
          Label(
            L10n.PreferencesPermissions.authorizationNotDetected,
            systemImage: "exclamationmark.circle"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.orange)
        } else if controller.requiresManualSettingsOpen {
          Label(
            L10n.PreferencesPermissions.authorizationOpenFailed,
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.md)
    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: Size.radiusLg))
    .overlay {
      RoundedRectangle(cornerRadius: Size.radiusLg)
        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1.5)
    }
  }

  private func permissionStatusRow(
    icon: String,
    title: String,
    state: PermissionAssistantVisualState,
    target: PermissionAuthorizationSettingsTarget
  ) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: icon)
        .foregroundStyle(state.tint)
        .frame(width: 22)
      Text(title)
        .font(.callout.weight(.medium))
      Spacer()
      StatusBadge(label: state.label, systemImage: state.icon, tint: state.tint)
      if !state.isGranted, controller.authorizationAction(for: target) != .none {
        Button {
          controller.performAuthorizationAction(for: target)
        } label: {
          if target == .microphone, controller.isRequestingMicrophone {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: authorizationActionIcon(for: target))
          }
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .disabled(controller.isRequestingMicrophone)
        .help(authorizationActionTitle(for: target))
        .accessibilityLabel(authorizationActionTitle(for: target))
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
  }

  private var microphoneState: PermissionAssistantVisualState {
    if controller.microphoneGranted {
      return .granted
    }
    if controller.microphoneStatus == .restricted {
      return .restricted
    }
    return .notGranted
  }

  private func stepTitle(for target: PermissionAuthorizationSettingsTarget) -> String {
    let index = (PermissionAuthorizationSettingsTarget.guideOrder.firstIndex(of: target) ?? 0) + 1
    return L10n.PreferencesPermissions.authorizationStep(
      index,
      PermissionAuthorizationSettingsTarget.guideOrder.count,
      title(for: target)
    )
  }

  private func instruction(for target: PermissionAuthorizationSettingsTarget) -> String {
    target.supportsDragging
      ? L10n.PreferencesPermissions.authorizationDragInstruction
      : L10n.PreferencesPermissions.authorizationMicrophoneInstruction
  }

  private func authorizationActionTitle(
    for target: PermissionAuthorizationSettingsTarget
  ) -> String {
    switch controller.authorizationAction(for: target) {
    case .requestMicrophoneAccess:
      L10n.Permission.grantAccess
    case .openSystemSettings, .none:
      L10n.PreferencesPermissions.authorizationOpenCurrent
    }
  }

  private func authorizationActionIcon(
    for target: PermissionAuthorizationSettingsTarget
  ) -> String {
    switch controller.authorizationAction(for: target) {
    case .requestMicrophoneAccess:
      "mic.badge.plus"
    case .openSystemSettings, .none:
      "arrow.up.forward.app"
    }
  }

  private func title(for target: PermissionAuthorizationSettingsTarget) -> String {
    switch target {
    case .screenRecording:
      L10n.Permission.screenRecording
    case .microphone:
      L10n.Permission.microphone
    case .accessibility:
      L10n.Permission.accessibility
    }
  }
}

private struct PermissionAssistantVisualState {
  let label: String
  let icon: String
  let tint: Color
  let isGranted: Bool

  static let granted = Self(
    label: L10n.PermissionRow.granted,
    icon: "checkmark.circle.fill",
    tint: .green,
    isGranted: true
  )
  static let notGranted = Self(
    label: L10n.Common.notGranted,
    icon: "exclamationmark.circle.fill",
    tint: .orange,
    isGranted: false
  )
  static let restricted = Self(
    label: L10n.PermissionRow.restricted,
    icon: "minus.circle.fill",
    tint: .red,
    isGranted: false
  )
}
