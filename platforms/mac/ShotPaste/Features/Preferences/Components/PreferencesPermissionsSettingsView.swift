//
//  PreferencesPermissionsSettingsView.swift
//  ShotPaste
//
//  Guided permission setup with status-aware system actions.
//

import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

struct PermissionGuideProgress: Equatable {
  let completedRequiredCount: Int
  let requiredCount: Int

  init(screenRecordingGranted: Bool, saveFolderGranted: Bool) {
    completedRequiredCount = [screenRecordingGranted, saveFolderGranted].filter { $0 }.count
    requiredCount = 2
  }

  var isReady: Bool {
    completedRequiredCount == requiredCount
  }
}

struct PermissionsSettingsView: View {
  private enum PermissionAction: Hashable {
    case screenRecording
    case saveFolder
    case microphone
    case accessibility
  }

  @ObservedObject private var screenCaptureManager = ScreenCaptureManager.shared
  @ObservedObject private var identityManager = AppIdentityManager.shared

  @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
  @State private var accessibilityGranted = AXIsProcessTrusted()
  @State private var saveFolderGranted = false
  @State private var isChecking = false
  @State private var activeAction: PermissionAction?
  @State private var hasAppeared = false
  @State private var didRequestScreenRecordingThisSession = false
  @State private var didRequestAccessibilityThisSession = false

  private let fileAccessManager = SandboxFileAccessManager.shared

  private let screenRecordingURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  private let microphoneURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
  private let accessibilityURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.md) {
        overviewCard

        permissionSection(title: L10n.PreferencesPermissions.requiredSection) {
          PermissionGuideRow(
            icon: "rectangle.inset.filled.and.person.filled",
            name: L10n.Permission.screenRecording,
            description: screenRecordingDescription,
            requirementLabel: L10n.PermissionRow.required,
            requirementTint: .orange,
            state: screenRecordingVisualState,
            actionTitle: screenRecordingActionTitle,
            isPerformingAction: activeAction == .screenRecording,
            action: handleScreenRecordingAction
          )

          PermissionGuideRow(
            icon: "folder.fill",
            name: L10n.Permission.saveFolder,
            description: L10n.Permission.saveFolderDescription,
            requirementLabel: L10n.PermissionRow.required,
            requirementTint: .orange,
            state: saveFolderVisualState,
            actionTitle: saveFolderGranted ? nil : L10n.FileAccess.chooseFolderPrompt,
            isPerformingAction: activeAction == .saveFolder,
            action: chooseSaveFolder
          )
        }

        permissionSection(title: L10n.PreferencesPermissions.optionalSection) {
          PermissionGuideRow(
            icon: "mic.fill",
            name: L10n.Permission.microphone,
            description: L10n.Permission.optionalForVoiceRecording,
            requirementLabel: L10n.PermissionRow.optional,
            requirementTint: .secondary,
            state: microphoneVisualState,
            actionTitle: microphoneActionTitle,
            isPerformingAction: activeAction == .microphone,
            action: handleMicrophoneAction
          )

          PermissionGuideRow(
            icon: "hand.raised.fill",
            name: L10n.Permission.accessibility,
            description: L10n.Permission.optionalForGlobalShortcuts,
            requirementLabel: L10n.PermissionRow.optional,
            requirementTint: .secondary,
            state: accessibilityVisualState,
            actionTitle: accessibilityActionTitle,
            isPerformingAction: activeAction == .accessibility,
            action: handleAccessibilityAction
          )
        }

        if !identityManager.health.isHealthy {
          identityWarning
        }

        footer
      }
      .padding(Spacing.md)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      hasAppeared = true
      checkAllPermissions()
    }
    .onDisappear {
      hasAppeared = false
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      guard hasAppeared else { return }
      checkAllPermissions()
    }
  }

  private var progress: PermissionGuideProgress {
    PermissionGuideProgress(
      screenRecordingGranted: screenCaptureManager.hasPermission,
      saveFolderGranted: saveFolderGranted
    )
  }

  private var overviewCard: some View {
    HStack(spacing: Spacing.md) {
      Image(systemName: progress.isReady ? "checkmark.shield.fill" : "lock.shield.fill")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(progress.isReady ? Color.green : Color.accentColor)
        .frame(width: 52, height: 52)
        .background(
          (progress.isReady ? Color.green : Color.accentColor).opacity(0.12),
          in: RoundedRectangle(cornerRadius: Size.radiusLg)
        )

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(progress.isReady
          ? L10n.PreferencesPermissions.readyTitle
          : L10n.PreferencesPermissions.setupTitle)
          .font(.title3.weight(.semibold))

        Text(progress.isReady
          ? L10n.PreferencesPermissions.readyDescription
          : L10n.PreferencesPermissions.setupDescription)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: Spacing.md)

      VStack(alignment: .trailing, spacing: Spacing.sm) {
        Text(L10n.PreferencesPermissions.progress(
          progress.completedRequiredCount,
          progress.requiredCount
        ))
        .font(.caption.weight(.semibold))
        .foregroundStyle(progress.isReady ? Color.green : Color.secondary)

        ProgressView(
          value: Double(progress.completedRequiredCount),
          total: Double(progress.requiredCount)
        )
        .tint(progress.isReady ? .green : .accentColor)
        .frame(width: 150)
      }
    }
    .padding(Spacing.md)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Size.radiusLg))
    .overlay {
      RoundedRectangle(cornerRadius: Size.radiusLg)
        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
    }
  }

  private func permissionSection(
    title: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.leading, Spacing.xs)

      VStack(spacing: Spacing.sm) {
        content()
      }
    }
  }

  private var identityWarning: some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(L10n.Permission.buildIdentityNeedsAttention)
          .font(.caption.weight(.semibold))

        Text(L10n.Permission.screenRecordingIdentityBlocked)
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(identityManager.health.issues, id: \.self) { issue in
          Text("• \(issue.description)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Size.radiusLg))
    .overlay {
      RoundedRectangle(cornerRadius: Size.radiusLg)
        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
    }
  }

  private var footer: some View {
    HStack(spacing: Spacing.sm) {
      Label(L10n.PreferencesPermissions.privacyNote, systemImage: "hand.raised.fill")
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      Button {
        checkAllPermissions()
      } label: {
        HStack(spacing: Spacing.xs) {
          if isChecking {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
          Text(L10n.Permission.refreshStatus)
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isChecking || activeAction != nil)
    }
    .padding(.horizontal, Spacing.xs)
  }

  // MARK: - Permission state

  private var screenRecordingDescription: String {
    switch screenCaptureManager.permissionStatus {
    case .granted:
      L10n.Permission.requiredForCaptures
    case .notGranted:
      didRequestScreenRecordingThisSession
        ? L10n.Permission.screenRecordingFinishInSettings
        : L10n.Permission.requiredForCaptures
    case .grantedButUnavailableDueToAppIdentity:
      L10n.Permission.screenRecordingIdentityBlocked
    }
  }

  private var screenRecordingVisualState: PermissionGuideRow.VisualState {
    switch screenCaptureManager.permissionStatus {
    case .granted:
      grantedVisualState
    case .notGranted:
      notGrantedVisualState
    case .grantedButUnavailableDueToAppIdentity:
      PermissionGuideRow.VisualState(
        label: L10n.Permission.unavailable,
        icon: "exclamationmark.triangle.fill",
        tint: .orange
      )
    }
  }

  private var saveFolderVisualState: PermissionGuideRow.VisualState {
    saveFolderGranted ? grantedVisualState : notGrantedVisualState
  }

  private var microphoneVisualState: PermissionGuideRow.VisualState {
    switch microphoneStatus {
    case .authorized:
      grantedVisualState
    case .notDetermined:
      notEnabledVisualState
    case .denied:
      notGrantedVisualState
    case .restricted:
      restrictedVisualState
    @unknown default:
      restrictedVisualState
    }
  }

  private var accessibilityVisualState: PermissionGuideRow.VisualState {
    accessibilityGranted ? grantedVisualState : notEnabledVisualState
  }

  private var grantedVisualState: PermissionGuideRow.VisualState {
    PermissionGuideRow.VisualState(
      label: L10n.PermissionRow.granted,
      icon: "checkmark.circle.fill",
      tint: .green
    )
  }

  private var notGrantedVisualState: PermissionGuideRow.VisualState {
    PermissionGuideRow.VisualState(
      label: L10n.Common.notGranted,
      icon: "exclamationmark.circle.fill",
      tint: .orange
    )
  }

  private var notEnabledVisualState: PermissionGuideRow.VisualState {
    PermissionGuideRow.VisualState(
      label: L10n.PermissionRow.notEnabled,
      icon: "circle.dashed",
      tint: .secondary
    )
  }

  private var restrictedVisualState: PermissionGuideRow.VisualState {
    PermissionGuideRow.VisualState(
      label: L10n.PermissionRow.restricted,
      icon: "minus.circle.fill",
      tint: .red
    )
  }

  private var screenRecordingActionTitle: String? {
    switch screenCaptureManager.permissionStatus {
    case .granted:
      nil
    case .notGranted:
      didRequestScreenRecordingThisSession
        ? L10n.Common.openSystemSettings
        : L10n.Permission.grantAccess
    case .grantedButUnavailableDueToAppIdentity:
      L10n.Permission.refreshStatus
    }
  }

  private var microphoneActionTitle: String? {
    switch microphoneStatus {
    case .authorized, .restricted:
      nil
    case .notDetermined:
      L10n.Permission.grantAccess
    case .denied:
      L10n.Common.openSystemSettings
    @unknown default:
      nil
    }
  }

  private var accessibilityActionTitle: String? {
    guard !accessibilityGranted else { return nil }
    return didRequestAccessibilityThisSession
      ? L10n.Common.openSystemSettings
      : L10n.Permission.grantAccess
  }

  // MARK: - Permission actions

  private func handleScreenRecordingAction() {
    switch screenCaptureManager.permissionStatus {
    case .granted:
      return
    case .notGranted where didRequestScreenRecordingThisSession:
      openSystemSettings(screenRecordingURL)
    case .notGranted:
      activeAction = .screenRecording
      didRequestScreenRecordingThisSession = true
      Task {
        _ = await screenCaptureManager.requestPermission()
        activeAction = nil
        checkAllPermissions()
      }
    case .grantedButUnavailableDueToAppIdentity:
      checkAllPermissions()
    }
  }

  private func chooseSaveFolder() {
    activeAction = .saveFolder
    defer { activeAction = nil }

    _ = fileAccessManager.chooseExportDirectory(
      message: L10n.PreferencesGeneral.chooseSaveLocationMessage,
      prompt: L10n.PreferencesGeneral.saveHereButton,
      directoryURL: fileAccessManager.resolvedExportDirectoryURL()
    )
    checkSaveFolderPermission()
  }

  private func handleMicrophoneAction() {
    switch microphoneStatus {
    case .authorized, .restricted:
      return
    case .denied:
      openSystemSettings(microphoneURL)
    case .notDetermined:
      activeAction = .microphone
      Task {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        activeAction = nil
      }
    @unknown default:
      return
    }
  }

  private func handleAccessibilityAction() {
    guard !accessibilityGranted else { return }

    if didRequestAccessibilityThisSession {
      openSystemSettings(accessibilityURL)
      return
    }

    activeAction = .accessibility
    didRequestAccessibilityThisSession = true
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    accessibilityGranted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    activeAction = nil
  }

  // MARK: - Refresh

  private func checkAllPermissions() {
    guard !isChecking else { return }
    isChecking = true

    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    accessibilityGranted = AXIsProcessTrusted()
    checkSaveFolderPermission()

    Task {
      AppIdentityManager.shared.refresh()
      await screenCaptureManager.checkPermission()
      isChecking = false
    }
  }

  private func checkSaveFolderPermission() {
    fileAccessManager.ensureExportLocationInitialized()
    saveFolderGranted = fileAccessManager.hasPersistedExportPermission
  }

  private func openSystemSettings(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct PermissionGuideRow: View {
  struct VisualState {
    let label: String
    let icon: String
    let tint: Color
  }

  let icon: String
  let name: String
  let description: String
  let requirementLabel: String
  let requirementTint: Color
  let state: VisualState
  let actionTitle: String?
  let isPerformingAction: Bool
  let action: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: Spacing.md) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(state.tint)
        .frame(width: 38, height: 38)
        .background(state.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: Size.radiusMd))

      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.sm) {
          Text(name)
            .font(.body.weight(.semibold))

          StatusBadge(
            label: requirementLabel,
            tint: requirementTint
          )
        }

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: Spacing.sm)

      StatusBadge(
        label: state.label,
        systemImage: state.icon,
        tint: state.tint
      )

      if let actionTitle {
        Button(action: action) {
          HStack(spacing: Spacing.xs) {
            if isPerformingAction {
              ProgressView()
                .controlSize(.small)
            }
            Text(actionTitle)
          }
          .frame(minWidth: 88)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isPerformingAction)
      }
    }
    .padding(Spacing.md)
    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: Size.radiusLg))
    .overlay {
      RoundedRectangle(cornerRadius: Size.radiusLg)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
  }
}

#Preview {
  PermissionsSettingsView()
    .frame(width: 760, height: 550)
}
