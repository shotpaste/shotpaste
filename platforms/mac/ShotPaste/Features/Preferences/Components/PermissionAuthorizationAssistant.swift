//
//  PermissionAuthorizationAssistant.swift
//  ShotPaste
//
//  Floating drag assistant for completing macOS privacy authorization.
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

  static let dragSupportedTargets: [Self] = [.screenRecording, .accessibility]

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

@MainActor
final class PermissionAuthorizationAssistantController: NSObject, ObservableObject,
  NSWindowDelegate {
  static let shared = PermissionAuthorizationAssistantController()

  @Published private(set) var isRequesting = false
  @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
  @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

  private var panel: PermissionAuthorizationAssistantPanel?
  private var requestTask: Task<Void, Never>?

  var isVisible: Bool {
    panel?.isVisible == true
  }

  func show(startRequests: Bool = false) {
    let panel = panel ?? makePanel()
    self.panel = panel
    refreshPermissionStates()
    position(panel)
    NSApp.activate(ignoringOtherApps: true)
    panel.orderFrontRegardless()

    if startRequests {
      requestAllPermissions(afterDelay: 250_000_000)
    }
  }

  func close() {
    requestTask?.cancel()
    requestTask = nil
    isRequesting = false
    panel?.orderOut(nil)
  }

  func requestAllPermissions() {
    requestAllPermissions(afterDelay: 0)
  }

  func refreshPermissionStates() {
    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    accessibilityGranted = AXIsProcessTrusted()
    Task {
      await ScreenCaptureManager.shared.checkPermission()
    }
  }

  func openSettings(_ target: PermissionAuthorizationSettingsTarget) {
    guard let url = URL(string: target.urlString) else { return }
    NSWorkspace.shared.open(url)

    // System Settings becomes the active application. Keep this non-activating
    // panel above it so the app icon remains available as a drag source.
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      self?.panel?.orderFrontRegardless()
    }
  }

  func windowShouldClose(_: NSWindow) -> Bool {
    close()
    return false
  }

  private func requestAllPermissions(afterDelay: UInt64) {
    guard !isRequesting else {
      panel?.orderFrontRegardless()
      return
    }

    isRequesting = true
    requestTask = Task { @MainActor [weak self] in
      guard let self else { return }

      if afterDelay > 0 {
        try? await Task.sleep(nanoseconds: afterDelay)
      }
      guard !Task.isCancelled else {
        finishRequest()
        return
      }

      let screenCaptureManager = ScreenCaptureManager.shared
      if !screenCaptureManager.hasPermission {
        _ = await screenCaptureManager.requestPermission()
      }
      guard !Task.isCancelled else {
        finishRequest()
        return
      }

      microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
      if microphoneStatus == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
      }
      guard !Task.isCancelled else {
        finishRequest()
        return
      }

      if !AXIsProcessTrusted() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityGranted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
      }

      await screenCaptureManager.checkPermission()
      microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
      accessibilityGranted = AXIsProcessTrusted()
      finishRequest()
    }
  }

  private func finishRequest() {
    isRequesting = false
    requestTask = nil
  }

  private func makePanel() -> PermissionAuthorizationAssistantPanel {
    let size = NSSize(width: 440, height: 500)
    let panel = PermissionAuthorizationAssistantPanel(
      contentRect: NSRect(origin: .zero, size: size)
    )
    panel.title = L10n.PreferencesPermissions.dragAppTitle
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
    let screen = ScreenUtility.activeScreen()
    let visibleFrame = screen.visibleFrame
    let panelFrame = panel.frame
    let origin = NSPoint(
      x: visibleFrame.minX + 24,
      y: visibleFrame.midY - panelFrame.height / 2
    )
    panel.setFrameOrigin(origin)
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
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    titlebarAppearsTransparent = true
    isMovableByWindowBackground = true
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

struct PermissionDraggableAppIcon: View {
  var size: CGFloat = 54

  private var appIcon: NSImage {
    NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
  }

  var body: some View {
    Image(nsImage: appIcon)
      .resizable()
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
      .contentShape(Rectangle())
      .onDrag {
        NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
      }
      .help(L10n.PreferencesPermissions.dragAppTitle)
      .accessibilityLabel(L10n.PreferencesPermissions.dragAppTitle)
      .accessibilityHint(L10n.PreferencesPermissions.dragAppDescription)
  }
}

private struct PermissionAuthorizationAssistantView: View {
  @ObservedObject var controller: PermissionAuthorizationAssistantController
  @ObservedObject private var screenCaptureManager = ScreenCaptureManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.md) {
        Image(systemName: "lock.shield.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 48, height: 48)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: Size.radiusLg))

        VStack(alignment: .leading, spacing: Spacing.xs) {
          Text(L10n.PreferencesPermissions.dragAppTitle)
            .font(.title3.weight(.semibold))
          Text(L10n.PreferencesPermissions.dragAppDescription)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HStack(spacing: Spacing.lg) {
        PermissionDraggableAppIcon(size: 78)

        VStack(alignment: .leading, spacing: Spacing.sm) {
          ForEach(PermissionAuthorizationSettingsTarget.dragSupportedTargets, id: \.self) { target in
            settingsButton(
              target: target,
              title: title(for: target),
              icon: icon(for: target)
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(Spacing.md)
      .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: Size.radiusLg))
      .overlay {
        RoundedRectangle(cornerRadius: Size.radiusLg)
          .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
      }

      VStack(spacing: Spacing.sm) {
        permissionStatusRow(
          icon: "rectangle.inset.filled.and.person.filled",
          title: L10n.Permission.screenRecording,
          state: screenRecordingState,
          target: .screenRecording
        )
        permissionStatusRow(
          icon: "mic.fill",
          title: L10n.Permission.microphone,
          state: microphoneState,
          target: .microphone
        )
        permissionStatusRow(
          icon: "hand.raised.fill",
          title: L10n.Permission.accessibility,
          state: accessibilityState,
          target: .accessibility
        )
      }

      Spacer(minLength: 0)

      HStack(spacing: Spacing.sm) {
        Button {
          controller.requestAllPermissions()
        } label: {
          HStack(spacing: Spacing.xs) {
            if controller.isRequesting {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "checkmark.shield")
            }
            Text(L10n.PreferencesPermissions.requestAllSystemPermissions)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(controller.isRequesting)

        Spacer()

        Button(L10n.Common.done) {
          controller.close()
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(Spacing.lg)
    .frame(width: 440, height: 500)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      controller.refreshPermissionStates()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      controller.refreshPermissionStates()
    }
  }

  private func settingsButton(
    target: PermissionAuthorizationSettingsTarget,
    title: String,
    icon: String
  ) -> some View {
    Button {
      controller.openSettings(target)
    } label: {
      Label(title, systemImage: icon)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
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

      if !state.isGranted {
        Button {
          controller.openSettings(target)
        } label: {
          Image(systemName: "arrow.up.forward.app")
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .help(L10n.Common.openSystemSettings)
        .accessibilityLabel(L10n.Common.openSystemSettings)
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.xs)
  }

  private var screenRecordingState: PermissionAssistantVisualState {
    switch screenCaptureManager.permissionStatus {
    case .granted:
      .granted
    case .notGranted:
      .notGranted
    case .grantedButUnavailableDueToAppIdentity:
      .unavailable
    }
  }

  private var microphoneState: PermissionAssistantVisualState {
    switch controller.microphoneStatus {
    case .authorized:
      .granted
    case .restricted:
      .restricted
    case .notDetermined, .denied:
      .notGranted
    @unknown default:
      .unavailable
    }
  }

  private var accessibilityState: PermissionAssistantVisualState {
    controller.accessibilityGranted ? .granted : .notGranted
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

  private func icon(for target: PermissionAuthorizationSettingsTarget) -> String {
    switch target {
    case .screenRecording:
      "rectangle.inset.filled.and.person.filled"
    case .microphone:
      "mic.fill"
    case .accessibility:
      "hand.raised.fill"
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
  static let unavailable = Self(
    label: L10n.Permission.unavailable,
    icon: "exclamationmark.triangle.fill",
    tint: .orange,
    isGranted: false
  )
}
