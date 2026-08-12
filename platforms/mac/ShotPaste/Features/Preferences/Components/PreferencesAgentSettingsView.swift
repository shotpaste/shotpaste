//
//  PreferencesAgentSettingsView.swift
//  ShotPaste
//

import AppKit
import ApplicationServices
import SwiftUI

struct AgentSettingsView: View {
  @ObservedObject private var agentMode = AgentModeController.shared
  @ObservedObject private var screenCaptureManager = ScreenCaptureManager.shared

  @AppStorage(PreferencesKeys.agentProviderEndpoint)
  private var endpoint = AgentProviderConfiguration.defaultEndpoint
  @AppStorage(PreferencesKeys.agentProviderModel)
  private var model = AgentProviderConfiguration.defaultModel
  @AppStorage(PreferencesKeys.agentThinkingEnabled) private var thinkingEnabled = true
  @AppStorage(PreferencesKeys.agentProviderSendsImages) private var sendsImages = true
  @AppStorage(PreferencesKeys.agentScreenshotRetentionEnabled) private var retainsScreenshots = false
  @AppStorage(PreferencesKeys.agentMaxActions) private var maxActions = 30

  @State private var apiKey = ""
  @State private var maskedStoredKey = AgentCredentialStore.shared.maskedStoredAPIKey()
  @State private var keyOperationMessage: String?
  @State private var isImportingKey = false
  @State private var agentShortcut = KeyboardShortcutManager.shared.shortcut(for: .agentMode)
  @State private var shortcutIssue: ShortcutValidationIssue?
  @State private var accessibilityGranted = AXIsProcessTrusted()

  private let credentialStore = AgentCredentialStore.shared
  private let shortcutManager = KeyboardShortcutManager.shared
  private let shortcutValidator = ShortcutValidationService.shared

  var body: some View {
    Form {
      Section {
        SettingRow(
          icon: "cursorarrow.motionlines",
          title: L10n.Agent.modeTitle,
          description: L10n.Agent.modeDescription
        ) {
          Toggle("", isOn: modeEnabledBinding)
            .labelsHidden()
        }

        HStack(spacing: 8) {
          Circle()
            .fill(agentMode.isEnabled ? Color.purple : Color.secondary)
            .frame(width: 8, height: 8)
          Text(agentMode.isEnabled ? L10n.Agent.modeEnabledStatus : L10n.Agent.modeDisabledStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
          if agentMode.isEnabled {
            Text("· \(agentMode.statusMessage)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section(L10n.Agent.controlsSection) {
        ShortcutRecorderView(
          label: L10n.Agent.shortcutTitle,
          icon: "keyboard",
          description: L10n.Agent.shortcutDescription,
          shortcut: $agentShortcut,
          defaultShortcut: .defaultAgentMode,
          isEnabled: shortcutEnabledBinding,
          validationIssue: shortcutIssue,
          onShortcutChanged: updateShortcut
        )

        SettingRow(
          icon: "number.circle",
          title: L10n.Agent.maxActionsTitle,
          description: "\(maxActions)"
        ) {
          Stepper("", value: $maxActions, in: 1 ... 100)
            .labelsHidden()
        }
      }

      Section(L10n.Agent.providerSection) {
        SettingRow(
          icon: "link",
          title: L10n.Agent.endpointTitle,
          description: endpointConfiguration.isValid ? endpointHost : AgentProviderError.invalidConfiguration
            .localizedDescription
        ) {
          TextField(AgentProviderConfiguration.defaultEndpoint, text: $endpoint)
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)
        }

        SettingRow(
          icon: "cpu",
          title: L10n.Agent.modelTitle,
          description: ""
        ) {
          TextField(AgentProviderConfiguration.defaultModel, text: $model)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }

        SettingRow(
          icon: "brain.head.profile",
          title: L10n.Agent.thinkingTitle,
          description: ""
        ) {
          Toggle("", isOn: $thinkingEnabled)
            .labelsHidden()
        }

        SettingRow(
          icon: "photo",
          title: L10n.Agent.sendImagesTitle,
          description: L10n.Agent.sendImagesDescription
        ) {
          Toggle("", isOn: $sendsImages)
            .labelsHidden()
        }

        VStack(alignment: .leading, spacing: 10) {
          SettingRow(
            icon: "key.fill",
            title: L10n.Agent.apiKeyTitle,
            description: L10n.Agent.apiKeyDescription
          ) {
            SecureField(maskedStoredKey ?? "API key", text: $apiKey)
              .textFieldStyle(.roundedBorder)
              .frame(width: 220)
            Button(L10n.Agent.saveKey, action: saveAPIKey)
              .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }

          HStack(spacing: 10) {
            Text(storedKeyStatus)
              .font(.caption)
              .foregroundStyle(maskedStoredKey == nil ? Color.secondary : Color.green)
            Spacer()
            Button(L10n.Agent.importKey) {
              importAPIKeyFromShell()
            }
            .disabled(isImportingKey)
            Button(L10n.Agent.removeKey, action: removeAPIKey)
              .disabled(maskedStoredKey == nil)
          }

          if let keyOperationMessage {
            Text(keyOperationMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section(L10n.Agent.safetySection) {
        SettingRow(
          icon: "externaldrive.badge.timemachine",
          title: L10n.Agent.retainScreenshotsTitle,
          description: L10n.Agent.retainScreenshotsDescription
        ) {
          Toggle("", isOn: $retainsScreenshots)
            .labelsHidden()
        }

        SettingRow(
          icon: "lock.shield",
          title: L10n.Agent.permissionTitle,
          description: permissionDescription
        ) {
          Button(L10n.Agent.openPermissions) {
            AppStatusBarController.shared.openPreferencesWindow(tab: .permissions)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refreshState)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      refreshState()
    }
  }

  private var modeEnabledBinding: Binding<Bool> {
    Binding(
      get: { agentMode.isEnabled },
      set: { agentMode.setEnabled($0) }
    )
  }

  private var shortcutEnabledBinding: Binding<Bool> {
    Binding(
      get: { shortcutManager.isShortcutEnabled(for: .agentMode) },
      set: { shortcutManager.setShortcutEnabled($0, for: .agentMode) }
    )
  }

  private var endpointConfiguration: AgentProviderConfiguration {
    AgentProviderConfiguration(
      endpoint: endpoint,
      model: model,
      thinkingEnabled: thinkingEnabled,
      sendsImages: sendsImages,
      maxActions: maxActions
    )
  }

  private var endpointHost: String {
    endpointConfiguration.endpointURL?.host ?? endpoint
  }

  private var permissionDescription: String {
    let screen = screenCaptureManager.hasPermission ? "Screen ✓" : "Screen —"
    let accessibility = accessibilityGranted ? "Accessibility ✓" : "Accessibility —"
    return "\(L10n.Agent.permissionDescription) · \(screen) · \(accessibility)"
  }

  private var storedKeyStatus: String {
    guard let maskedStoredKey else { return L10n.Agent.keyNotStored }
    return "\(L10n.Agent.keyStored): \(maskedStoredKey)"
  }

  private func updateShortcut(_ shortcut: ShortcutConfig?) -> Bool {
    switch shortcutValidator.validateGlobalShortcut(shortcut, for: .agentMode) {
    case .accept(let issue):
      shortcutIssue = issue
      agentShortcut = shortcut
      shortcutManager.setAgentModeShortcut(shortcut)
      return true
    case .reject(let issue):
      shortcutIssue = issue
      return false
    }
  }

  private func saveAPIKey() {
    do {
      try credentialStore.saveAPIKey(apiKey)
      apiKey = ""
      maskedStoredKey = credentialStore.maskedStoredAPIKey()
      keyOperationMessage = L10n.Agent.keyStored
    } catch {
      keyOperationMessage = error.localizedDescription
    }
  }

  private func importAPIKeyFromShell() {
    guard !isImportingKey else { return }
    isImportingKey = true
    keyOperationMessage = nil
    Task {
      defer { isImportingKey = false }
      do {
        let key = try await AgentShellEnvironmentImporter.importLLMAPIKey()
        try credentialStore.saveAPIKey(key)
        apiKey = ""
        maskedStoredKey = credentialStore.maskedStoredAPIKey()
        keyOperationMessage = L10n.Agent.keyStored
      } catch {
        keyOperationMessage = error.localizedDescription
      }
    }
  }

  private func removeAPIKey() {
    credentialStore.deleteAPIKey()
    apiKey = ""
    maskedStoredKey = nil
    keyOperationMessage = L10n.Agent.keyNotStored
  }

  private func refreshState() {
    maskedStoredKey = credentialStore.maskedStoredAPIKey()
    accessibilityGranted = AXIsProcessTrusted()
    Task { await screenCaptureManager.checkPermission() }
  }
}
