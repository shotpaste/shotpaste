//
//  PreferencesShortcutsSettingsView.swift
//  ShotPaste
//
//  Keyboard shortcuts configuration tab
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutsSettingsView: View {
  @State private var oneShotShortcut: ShortcutConfig?
  @State private var translationShortcut: ShortcutConfig?
  @State private var pauseResumeRecordingShortcut: ShortcutConfig?
  @State private var togglePenRecordingShortcut: ShortcutConfig?
  @State private var restartRecordingShortcut: ShortcutConfig?
  @State private var deleteRecordingShortcut: ShortcutConfig?
  @State private var historyShortcut: ShortcutConfig?
  @State private var globalShortcutEnabled: [GlobalShortcutKind: Bool]
  @State private var globalValidationIssues: [GlobalShortcutKind: ShortcutValidationIssue] = [:]
  @State private var shortcutsEnabled: Bool
  @State private var showDisableConfirmation: Bool = false
  @State private var isConfirmedDisable: Bool = false
  @State private var hasSystemConflict: Bool = false
  @State private var isRefreshingConflict: Bool = false
  @State private var accessibilityGranted: Bool = AXIsProcessTrusted()

  private let manager = KeyboardShortcutManager.shared
  private let validator = ShortcutValidationService.shared

  init() {
    _oneShotShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .oneShot))
    _translationShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .translation)
    )
    _pauseResumeRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .pauseResumeRecording)
    )
    _togglePenRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .togglePenRecording)
    )
    _restartRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .restartRecording)
    )
    _deleteRecordingShortcut = State(
      initialValue: KeyboardShortcutManager.shared.shortcut(for: .deleteRecording)
    )
    _historyShortcut = State(initialValue: KeyboardShortcutManager.shared.shortcut(for: .history))
    _globalShortcutEnabled = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: GlobalShortcutKind.allCases.map {
          ($0, KeyboardShortcutManager.shared.isShortcutEnabled(for: $0))
        }
      )
    )
    _shortcutsEnabled = State(initialValue: KeyboardShortcutManager.shared.isEnabled)
    _hasSystemConflict = State(
      initialValue: SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    )
  }

  var body: some View {
    Form {
      // System shortcut conflict status
      if shortcutsEnabled {
        if hasSystemConflict {
          Section {
            VStack(alignment: .leading, spacing: 12) {
              // Header
              HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .font(.system(size: 18))
                  .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 2) {
                  Text(L10n.PreferencesShortcuts.systemConflictTitle)
                    .font(.system(size: 13, weight: .semibold))
                  Text(L10n.PreferencesShortcuts.systemConflictDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
              }

              // Step-by-step guide
              VStack(alignment: .leading, spacing: 6) {
                Text(L10n.PreferencesShortcuts.howToDisable)
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundColor(.secondary)
                  .tracking(0.8)

                PreferencesGuideStep(
                  step: "1",
                  text: L10n.ShortcutGuidance.guideStep1
                )
                PreferencesGuideStep(
                  step: "2",
                  text: L10n.ShortcutGuidance.guideStep2
                )
                PreferencesGuideStep(
                  step: "3",
                  text: L10n.ShortcutGuidance.guideStep3
                )
              }
              .padding(10)
              .background(
                RoundedRectangle(cornerRadius: 8)
                  .fill(Color.orange.opacity(0.06))
              )

              // Action buttons
              HStack(spacing: 8) {
                Button {
                  SystemScreenshotShortcutManager.shared.openSystemScreenshotSettings()
                } label: {
                  HStack {
                    Image(systemName: "gear")
                      .font(.system(size: 12))
                    Text(L10n.PreferencesShortcuts.openKeyboardShortcutsSettings)
                      .font(.system(size: 12, weight: .medium))
                  }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                  refreshSystemConflict()
                } label: {
                  HStack(spacing: 4) {
                    Image(
                      systemName: isRefreshingConflict
                        ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                    )
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(isRefreshingConflict ? 360 : 0))
                    .animation(
                      isRefreshingConflict
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                      value: isRefreshingConflict
                    )
                    Text(L10n.Common.refresh)
                      .font(.system(size: 12, weight: .medium))
                  }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
              }
            }
            .padding(.vertical, 4)
          } header: {
            Label(L10n.PreferencesShortcuts.actionRequired, systemImage: "exclamationmark.circle.fill")
              .foregroundColor(.orange)
          }
        } else {
          // Success badge — no conflicts
          Section {
            HStack(spacing: 10) {
              Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)

              VStack(alignment: .leading, spacing: 2) {
                Text(L10n.PreferencesShortcuts.noConflictsDetected)
                  .font(.system(size: 13, weight: .semibold))
                Text(L10n.PreferencesShortcuts.noConflictsDescription)
                  .font(.system(size: 11))
                  .foregroundColor(.secondary)
              }

              Spacer()

              Button {
                refreshSystemConflict()
              } label: {
                Image(
                  systemName: isRefreshingConflict
                    ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
                )
                .font(.system(size: 12))
                .rotationEffect(.degrees(isRefreshingConflict ? 360 : 0))
                .animation(
                  isRefreshingConflict
                    ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                    : .default,
                  value: isRefreshingConflict
                )
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
          } header: {
            Label(L10n.PreferencesShortcuts.systemShortcuts, systemImage: "checkmark.seal.fill")
              .foregroundColor(.green)
          }
        }
      }

      Section(L10n.PreferencesShortcuts.globalSection) {
        Text(L10n.PreferencesShortcuts.globalSectionDescription)
          .font(.caption)
          .foregroundColor(.secondary)

        SettingRow(
          icon: "keyboard",
          title: L10n.PreferencesShortcuts.enableShortcutsTitle,
          description: L10n.PreferencesShortcuts.enableShortcutsDescription
        ) {
          Toggle("", isOn: $shortcutsEnabled)
            .labelsHidden()
            .onChange(of: shortcutsEnabled) { newValue in
              if newValue {
                manager.enable()
                // Re-check system conflicts when enabling
                hasSystemConflict =
                  SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
              } else {
                if isConfirmedDisable {
                  // User confirmed disable, proceed
                  isConfirmedDisable = false
                  manager.disable()
                } else {
                  // Revert toggle and show confirmation
                  shortcutsEnabled = true
                  showDisableConfirmation = true
                }
              }
            }
        }
        .alert(L10n.PreferencesShortcuts.disableShortcutsTitle, isPresented: $showDisableConfirmation) {
          Button(L10n.Common.cancel, role: .cancel) {}
          Button(L10n.Common.disable, role: .destructive) {
            isConfirmedDisable = true
            shortcutsEnabled = false
          }
        } message: {
          Text(L10n.PreferencesShortcuts.disableShortcutsMessage)
        }

        if showsFnAccessibilityHint {
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 14))
              .foregroundColor(.orange)

            Text(L10n.PreferencesShortcuts.fnAccessibilityHint)
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(L10n.Common.openSettings) {
              if let url =
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
              }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .padding(.vertical, 2)
        }
      }

      if shortcutsEnabled {
        Section {
          ShortcutRecorderView(
            label: L10n.Actions.oneShot,
            icon: "camera.aperture",
            description: L10n.OneShot.shortcutDescription,
            shortcut: $oneShotShortcut,
            defaultShortcut: .defaultOneShot,
            isEnabled: globalEnabledBinding(for: .oneShot),
            validationIssue: globalValidationIssues[.oneShot],
            onShortcutChanged: { handleGlobalShortcutChange($0, for: .oneShot) }
          )

          ShortcutRecorderView(
            label: L10n.OneShot.translationTab,
            icon: "translate",
            description: L10n.OneShot.shortcutDescription,
            shortcut: $translationShortcut,
            defaultShortcut: nil,
            isEnabled: globalEnabledBinding(for: .translation),
            validationIssue: globalValidationIssues[.translation],
            onShortcutChanged: { handleGlobalShortcutChange($0, for: .translation) }
          )

        } header: {
          HStack {
            Text(L10n.PreferencesShortcuts.captureSection)
            Spacer()
            Button(L10n.Common.reset) {
              resetCaptureSection()
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }
        }

        Section {
          VStack(alignment: .leading, spacing: 4) {
            ShortcutRecorderView(
              label: L10n.Actions.pauseResumeRecording,
              icon: "pause.circle",
              description: L10n.PreferencesShortcuts.pauseResumeRecordingDescription,
              shortcut: $pauseResumeRecordingShortcut,
              defaultShortcut: nil,
              isEnabled: globalEnabledBinding(for: .pauseResumeRecording),
              validationIssue: globalValidationIssues[.pauseResumeRecording],
              onShortcutChanged: { handleGlobalShortcutChange($0, for: .pauseResumeRecording) }
            )

            ShortcutRecorderView(
              label: L10n.Actions.togglePenRecording,
              icon: "pencil.tip.crop.circle",
              description: L10n.PreferencesShortcuts.togglePenRecordingDescription,
              shortcut: $togglePenRecordingShortcut,
              defaultShortcut: nil,
              isEnabled: globalEnabledBinding(for: .togglePenRecording),
              validationIssue: globalValidationIssues[.togglePenRecording],
              onShortcutChanged: { handleGlobalShortcutChange($0, for: .togglePenRecording) }
            )

            ShortcutRecorderView(
              label: L10n.Actions.restartRecording,
              icon: "arrow.counterclockwise.circle",
              description: L10n.PreferencesShortcuts.restartRecordingDescription,
              shortcut: $restartRecordingShortcut,
              defaultShortcut: nil,
              isEnabled: globalEnabledBinding(for: .restartRecording),
              validationIssue: globalValidationIssues[.restartRecording],
              onShortcutChanged: { handleGlobalShortcutChange($0, for: .restartRecording) }
            )

            ShortcutRecorderView(
              label: L10n.Actions.deleteRecording,
              icon: "trash.circle",
              description: L10n.PreferencesShortcuts.deleteRecordingDescription,
              shortcut: $deleteRecordingShortcut,
              defaultShortcut: nil,
              isEnabled: globalEnabledBinding(for: .deleteRecording),
              validationIssue: globalValidationIssues[.deleteRecording],
              onShortcutChanged: { handleGlobalShortcutChange($0, for: .deleteRecording) }
            )
          }
          .padding(.vertical, 2)
        } header: {
          HStack {
            Text(L10n.PreferencesShortcuts.recordingSection)
            Spacer()
            Button(L10n.Common.reset) {
              resetRecordingSection()
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }
        }

        Section {
          Text(L10n.PreferencesShortcuts.historySectionDescription)
            .font(.caption)
            .foregroundColor(.secondary)

          ShortcutRecorderView(
            label: L10n.Actions.openHistory,
            icon: "clock.arrow.circlepath",
            description: L10n.PreferencesShortcuts.openHistoryDescription,
            shortcut: $historyShortcut,
            defaultShortcut: .defaultHistory,
            isEnabled: globalEnabledBinding(for: .history),
            validationIssue: globalValidationIssues[.history],
            onShortcutChanged: { handleGlobalShortcutChange($0, for: .history) }
          )

        } header: {
          HStack {
            Text(L10n.PreferencesShortcuts.historySection)
            Spacer()
            Button(L10n.Common.reset) {
              resetHistorySection()
            }
            .buttonStyle(.borderless)
            .font(.caption)
          }
        }

        Section(L10n.ShortcutOverlay.annotateReference) {
          ReadOnlyShortcutRow(icon: "square.and.arrow.down", label: L10n.ShortcutOverlay.saveDone, shortcut: "⌘ S")
          ReadOnlyShortcutRow(icon: "arrow.uturn.backward", label: L10n.ShortcutOverlay.undo, shortcut: "⌘ Z")
          ReadOnlyShortcutRow(icon: "arrow.uturn.forward", label: L10n.ShortcutOverlay.redo, shortcut: "⌘ ⇧ Z")
          ReadOnlyShortcutRow(icon: "trash", label: L10n.ShortcutOverlay.deleteAnnotation, shortcut: "⌫")
          ReadOnlyShortcutRow(icon: "escape", label: L10n.ShortcutOverlay.cancelDeselect, shortcut: "⎋")
          ReadOnlyShortcutRow(
            icon: "arrow.up.arrow.down.arrow.left.arrow.right",
            label: L10n.ShortcutOverlay.nudgeAnnotation,
            shortcut: "← → ↑ ↓"
          )
          ReadOnlyShortcutRow(
            icon: "arrow.up.arrow.down.arrow.left.arrow.right",
            label: L10n.ShortcutOverlay.nudgeTenPixels,
            shortcut: "⇧ ← → ↑ ↓"
          )
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      accessibilityGranted = AXIsProcessTrusted()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      accessibilityGranted = AXIsProcessTrusted()
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        Spacer()
        Button(L10n.PreferencesShortcuts.resetToDefaults) {
          resetToDefaults()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding()
      }
    }
  }

  // MARK: - Actions

  /// Show the Accessibility hint only when an Fn-based binding exists and the
  /// permission the Fn key monitors rely on is missing.
  private var showsFnAccessibilityHint: Bool {
    shortcutsEnabled && manager.hasFnBoundShortcuts && !accessibilityGranted
  }

  private func resetCaptureSection(refresh: Bool = true) {
    oneShotShortcut = .defaultOneShot
    translationShortcut = nil

    let captureKinds: [GlobalShortcutKind] = [.oneShot, .translation]
    for kind in captureKinds {
      globalShortcutEnabled[kind] = true
      manager.setShortcutEnabled(true, for: kind)
      globalValidationIssues.removeValue(forKey: kind)
    }

    manager.setOneShotShortcut(.defaultOneShot)
    manager.setTranslationShortcut(nil)

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetRecordingSection(refresh: Bool = true) {
    pauseResumeRecordingShortcut = nil
    togglePenRecordingShortcut = nil
    restartRecordingShortcut = nil
    deleteRecordingShortcut = nil

    globalShortcutEnabled[.pauseResumeRecording] = true
    globalShortcutEnabled[.togglePenRecording] = true
    globalShortcutEnabled[.restartRecording] = true
    globalShortcutEnabled[.deleteRecording] = true

    manager.setShortcutEnabled(true, for: .pauseResumeRecording)
    manager.setShortcutEnabled(true, for: .togglePenRecording)
    manager.setShortcutEnabled(true, for: .restartRecording)
    manager.setShortcutEnabled(true, for: .deleteRecording)

    globalValidationIssues.removeValue(forKey: .pauseResumeRecording)
    globalValidationIssues.removeValue(forKey: .togglePenRecording)
    globalValidationIssues.removeValue(forKey: .restartRecording)
    globalValidationIssues.removeValue(forKey: .deleteRecording)

    manager.setPauseResumeRecordingShortcut(nil)
    manager.setTogglePenRecordingShortcut(nil)
    manager.setRestartRecordingShortcut(nil)
    manager.setDeleteRecordingShortcut(nil)

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetHistorySection(refresh: Bool = true) {
    historyShortcut = .defaultHistory
    globalShortcutEnabled[.history] = true
    manager.setShortcutEnabled(true, for: .history)
    globalValidationIssues.removeValue(forKey: .history)
    manager.setHistoryShortcut(.defaultHistory)

    if refresh {
      manager.refreshShortcutRegistration()
      hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
    }
  }

  private func resetToDefaults() {
    resetCaptureSection(refresh: false)
    resetRecordingSection(refresh: false)

    manager.refreshShortcutRegistration()
    hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
  }

  /// Re-check system shortcut conflict status with spinner animation
  private func refreshSystemConflict() {
    isRefreshingConflict = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      withAnimation(.easeInOut(duration: 0.3)) {
        hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
      }
      isRefreshingConflict = false
    }
  }

  private func globalEnabledBinding(for kind: GlobalShortcutKind) -> Binding<Bool> {
    Binding(
      get: { globalShortcutEnabled[kind] ?? true },
      set: { newValue in
        if newValue {
          switch validator.validateGlobalShortcut(manager.shortcut(for: kind), for: kind) {
          case .accept(let issue):
            globalValidationIssues[kind] = issue
          case .reject(let issue):
            globalValidationIssues[kind] = issue
            return
          }
        }

        globalShortcutEnabled[kind] = newValue
        manager.setShortcutEnabled(newValue, for: kind)
        if !newValue {
          globalValidationIssues.removeValue(forKey: kind)
        }
        if kind.isSystemConflictRelevant {
          hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
        }
      }
    )
  }

  private func handleGlobalShortcutChange(_ config: ShortcutConfig?, for kind: GlobalShortcutKind) -> Bool {
    switch validator.validateGlobalShortcut(config, for: kind) {
    case .accept(let issue):
      globalValidationIssues[kind] = issue
      switch kind {
      case .oneShot:
        oneShotShortcut = config
        manager.setOneShotShortcut(config)
      case .translation:
        translationShortcut = config
        manager.setTranslationShortcut(config)
      case .agentMode:
        manager.setAgentModeShortcut(config)
      case .pauseResumeRecording:
        pauseResumeRecordingShortcut = config
        manager.setPauseResumeRecordingShortcut(config)
      case .togglePenRecording:
        togglePenRecordingShortcut = config
        manager.setTogglePenRecordingShortcut(config)
      case .restartRecording:
        restartRecordingShortcut = config
        manager.setRestartRecordingShortcut(config)
      case .deleteRecording:
        deleteRecordingShortcut = config
        manager.setDeleteRecordingShortcut(config)
      case .history:
        historyShortcut = config
        manager.setHistoryShortcut(config)
      }

      if kind.isSystemConflictRelevant {
        hasSystemConflict = SystemScreenshotShortcutManager.shared.hasConflictingSystemShortcuts()
      }
      return true
    case .reject(let issue):
      globalValidationIssues[kind] = issue
      return false
    }
  }
}

// MARK: - Guide Step Component

private struct PreferencesGuideStep: View {
  let step: String
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      Text(step)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(.orange)
        .frame(width: 18, height: 18)
        .background(
          Circle()
            .fill(Color.orange.opacity(0.15))
        )

      Text(.init(text)) // Supports **bold** markdown
        .font(.system(size: 12))
        .foregroundColor(.primary)
    }
  }
}

#Preview {
  ShortcutsSettingsView()
    .frame(width: 600, height: 500)
}

// MARK: - Read-Only Shortcut Row

private struct ReadOnlyShortcutRow: View {
  let icon: String
  let label: String
  let shortcut: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundColor(.secondary)
        .frame(width: 24)

      Text(label)
        .frame(minWidth: 100, alignment: .leading)

      Spacer()

      if shouldUseKeycaps {
        KeyCapGroupView(parts: shortcutParts)
      } else {
        Text(shortcut)
          .font(.system(.body, design: .monospaced))
          .foregroundColor(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.gray.opacity(0.1))
          )
      }
    }
    .padding(.vertical, 2)
  }

  /// Split the display string (e.g. "⌘ ⇧ Z" or "← → ↑ ↓") into individual parts
  private var shortcutParts: [String] {
    shortcut
      .split(separator: " ")
      .map(String.init)
  }

  private var shouldUseKeycaps: Bool {
    shortcutParts.filter { !modifierTokens.contains($0) }.count <= 1
  }

  private var modifierTokens: Set<String> {
    ["⌘", "⇧", "⌥", "⌃"]
  }
}
