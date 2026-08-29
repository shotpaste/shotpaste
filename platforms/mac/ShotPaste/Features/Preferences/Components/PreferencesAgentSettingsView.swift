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
  @ObservedObject private var navigationState = PreferencesNavigationState.shared

  @AppStorage(PreferencesKeys.agentProviderEndpoint)
  private var endpoint = AgentProviderConfiguration.defaultEndpoint
  @AppStorage(PreferencesKeys.agentProviderModel)
  private var model = AgentProviderConfiguration.defaultModel
  @AppStorage(PreferencesKeys.agentProviderProtocol)
  private var apiProtocolRaw = AgentProviderAPIProtocol.openAICompatible.rawValue
  @AppStorage(PreferencesKeys.agentThinkingEnabled) private var thinkingEnabled = true
  @AppStorage(PreferencesKeys.agentProviderSendsImages) private var sendsImages = true
  @AppStorage(PreferencesKeys.agentScreenshotRetentionEnabled) private var retainsScreenshots = false
  @AppStorage(PreferencesKeys.agentMaxActions) private var maxActions = 30
  @AppStorage(PreferencesKeys.agentTranslationTimeoutSeconds) private var translationTimeoutSeconds = 15
  @AppStorage(PreferencesKeys.agentTranslationPromptMode) private var translationPromptModeRaw = TranslationPromptMode
    .builtin.rawValue
  @AppStorage(PreferencesKeys.agentTranslationPrompt) private var translationPrompt = ""
  @AppStorage(PreferencesKeys.agentTranslationSendsRecognizedText)
  private var sendsRecognizedText = TranslationSettingsMigration.sendRecognizedText()

  @State private var apiKey = ""
  @State private var maskedStoredKey = AgentCredentialStore.shared.maskedStoredAPIKey()
  @State private var keyOperationMessage: String?
  @State private var isImportingKey = false
  @State private var agentShortcut = KeyboardShortcutManager.shared.shortcut(for: .agentMode)
  @State private var shortcutIssue: ShortcutValidationIssue?
  @State private var accessibilityGranted = AXIsProcessTrusted()
  @State private var highlightsTranslation = false

  private let credentialStore = AgentCredentialStore.shared
  private let shortcutManager = KeyboardShortcutManager.shared
  private let shortcutValidator = ShortcutValidationService.shared

  var body: some View {
    ScrollViewReader { proxy in
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
            icon: "arrow.left.arrow.right",
            title: L10n.Agent.protocolTitle,
            description: ""
          ) {
            Picker("", selection: protocolBinding) {
              Text(L10n.Agent.protocolOpenAICompatible)
                .tag(AgentProviderAPIProtocol.openAICompatible)
              Text(L10n.Agent.protocolAnthropicMessages)
                .tag(AgentProviderAPIProtocol.anthropicMessages)
            }
            .labelsHidden()
            .frame(width: 300)
          }

          SettingRow(
            icon: "link",
            title: L10n.Agent.endpointTitle,
            description: endpointConfiguration.isValid ? endpointHost : AgentProviderError.invalidConfiguration
              .localizedDescription
          ) {
            TextField(
              AgentProviderConfiguration.defaultEndpoint(for: selectedProtocol),
              text: $endpoint
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)
          }

          SettingRow(
            icon: "cpu",
            title: L10n.Agent.modelTitle,
            description: ""
          ) {
            TextField(
              AgentProviderConfiguration.defaultModel(for: selectedProtocol),
              text: $model
            )
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

        Section(L10n.Agent.translationSection) {
          SettingRow(
            icon: "text.bubble",
            title: L10n.Agent.translationPromptModeTitle,
            description: L10n.Agent.translationPromptModeDescription
          ) {
            Picker("", selection: translationPromptModeBinding) {
              Text(L10n.Agent.translationPromptBuiltin).tag(TranslationPromptMode.builtin)
              Text(L10n.Agent.translationPromptCustom).tag(TranslationPromptMode.custom)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 300)
            .accessibilityIdentifier("agent-translation-prompt-mode")
          }

          VStack(alignment: .leading, spacing: 7) {
            Text(L10n.Agent.translationPromptTitle)
              .font(.headline)
            if translationPromptMode == .builtin {
              Text(TranslationPreferences.builtinUserPrompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            } else {
              TextEditor(text: $translationPrompt)
                .font(.body)
                .frame(minHeight: 96)
                .overlay(
                  RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .accessibilityIdentifier("agent-translation-custom-prompt")
              Text(L10n.Agent.translationPromptVariables)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(L10n.Agent.translationRestoreBuiltin) {
              translationPromptModeRaw = TranslationPromptMode.builtin.rawValue
              translationPrompt = ""
            }
            .buttonStyle(.bordered)
          }

          SettingRow(
            icon: "clock",
            title: L10n.Agent.translationTimeoutTitle,
            description: L10n.Agent.translationTimeoutDescription(translationTimeoutSeconds)
          ) {
            Stepper("", value: translationTimeoutBinding, in: TranslationPreferences.timeoutRange)
              .labelsHidden()
              .accessibilityIdentifier("agent-translation-timeout")
          }

          SettingRow(
            icon: "text.bubble",
            title: L10n.Agent.translationProviderModeTitle,
            description: L10n.Agent.translationProviderModeDescription
          ) {
            translationAvailabilityBadge
          }
          .accessibilityIdentifier("agent-translation-provider-mode")

          SettingRow(
            icon: "lock.shield",
            title: L10n.Agent.translationSendRecognizedTextTitle,
            description: L10n.Agent.translationSendRecognizedTextDescription
          ) {
            Toggle("", isOn: $sendsRecognizedText)
              .labelsHidden()
              .accessibilityIdentifier("agent-translation-send-recognized-text")
              .accessibilityLabel(L10n.Agent.translationSendRecognizedTextTitle)
          }

          Text(L10n.Agent.translationOCRCoverageDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("agent-translation-ocr-coverage")

          if !sendsRecognizedText {
            Text(L10n.Agent.translationSendRecognizedTextDisabled)
              .font(.caption)
              .foregroundStyle(.orange)
          } else if case .unavailable(let failure) = translationAvailability {
            Text(translationAvailabilityDescription(for: failure))
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        .id("agent-translation")
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(highlightsTranslation ? Color.accentColor.opacity(0.12) : .clear)
        )

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
      .onAppear {
        TranslationSettingsMigration.applyIfNeeded()
        sendsRecognizedText = TranslationSettingsMigration.sendRecognizedText()
        refreshState()
        revealTranslationIfRequested(using: proxy)
      }
      .onChange(of: navigationState.agentAnchor) { _ in
        revealTranslationIfRequested(using: proxy)
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
        refreshState()
      }
    }
  }

  private var modeEnabledBinding: Binding<Bool> {
    Binding(
      get: { agentMode.isEnabled },
      set: { agentMode.setEnabled($0) }
    )
  }

  /// 当前选中的 API 协议；存储层使用 rawValue 字符串。
  private var selectedProtocol: AgentProviderAPIProtocol {
    AgentProviderAPIProtocol(rawValue: apiProtocolRaw) ?? .openAICompatible
  }

  private var protocolBinding: Binding<AgentProviderAPIProtocol> {
    Binding(
      get: { selectedProtocol },
      set: { newProtocol in
        let values = AgentProviderConfiguration.connectionValues(
          switchingFrom: selectedProtocol,
          to: newProtocol,
          endpoint: endpoint,
          model: model
        )
        endpoint = values.endpoint
        model = values.model
        apiProtocolRaw = newProtocol.rawValue
      }
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
      maxActions: maxActions,
      apiProtocol: selectedProtocol
    )
  }

  private var translationPromptMode: TranslationPromptMode {
    TranslationPromptMode(rawValue: translationPromptModeRaw) ?? .builtin
  }

  private var translationPromptModeBinding: Binding<TranslationPromptMode> {
    Binding(
      get: { translationPromptMode },
      set: { translationPromptModeRaw = $0.rawValue }
    )
  }

  private var translationTimeoutBinding: Binding<Int> {
    Binding(
      get: {
        min(
          max(translationTimeoutSeconds, TranslationPreferences.timeoutRange.lowerBound),
          TranslationPreferences.timeoutRange.upperBound
        )
      },
      set: { value in
        translationTimeoutSeconds = min(
          max(value, TranslationPreferences.timeoutRange.lowerBound),
          TranslationPreferences.timeoutRange.upperBound
        )
      }
    )
  }

  private var translationAvailability: TranslationAvailability {
    let apiKey = try? credentialStore.resolvedAPIKey()
    return TranslationAvailability.evaluate(
      configuration: endpointConfiguration,
      apiKey: apiKey ?? nil,
      sendRecognizedText: sendsRecognizedText
    )
  }

  @ViewBuilder
  private var translationAvailabilityBadge: some View {
    switch translationAvailability {
    case .available:
      Label(L10n.Agent.translationProviderReady, systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.caption)
    case .unavailable(.recognizedTextSharingDisabled):
      Label(L10n.Agent.translationSendRecognizedTextDisabled, systemImage: "lock.shield.fill")
        .foregroundStyle(.orange)
        .font(.caption)
    case .unavailable:
      Label(L10n.Agent.translationProviderUnavailable, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .font(.caption)
    }
  }

  private func translationAvailabilityDescription(for failure: TranslationFailure) -> String {
    switch failure {
    case .recognizedTextSharingDisabled: L10n.Agent.translationSendRecognizedTextDisabled
    case .missingAPIKey: L10n.OneShot.translationMissingAPIKey
    case .invalidConfiguration: L10n.OneShot.translationInvalidConfiguration
    default: L10n.Agent.translationProviderUnavailable
    }
  }

  private func revealTranslationIfRequested(using proxy: ScrollViewProxy) {
    guard navigationState.agentAnchor == .translation else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      proxy.scrollTo("agent-translation", anchor: .center)
      highlightsTranslation = true
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
      withAnimation(.easeOut(duration: 0.35)) {
        highlightsTranslation = false
      }
    }
    navigationState.agentAnchor = nil
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
    refreshProviderDefaults()
    maskedStoredKey = credentialStore.maskedStoredAPIKey()
    accessibilityGranted = AXIsProcessTrusted()
    Task { await screenCaptureManager.checkPermission() }
  }

  /// @AppStorage 的声明默认值属于 OpenAI。字段从未保存时使用当前协议
  /// 默认值；只有端点和模型同时仍是另一协议的完整默认组合时才修复，
  /// 避免误改恰好与某个默认值相同的自定义单项。
  private func refreshProviderDefaults() {
    let defaults = UserDefaults.standard
    let endpointWasStored = defaults.object(forKey: PreferencesKeys.agentProviderEndpoint) != nil
    let modelWasStored = defaults.object(forKey: PreferencesKeys.agentProviderModel) != nil
    if !endpointWasStored {
      endpoint = AgentProviderConfiguration.defaultEndpoint(for: selectedProtocol)
    }
    if !modelWasStored {
      model = AgentProviderConfiguration.defaultModel(for: selectedProtocol)
    }

    if selectedProtocol == .openAICompatible,
       AgentProviderConfiguration.legacyOpenAIEndpoints.contains(
         endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
       ),
       model.trimmingCharacters(in: .whitespacesAndNewlines)
       == AgentProviderConfiguration.defaultModel {
      endpoint = AgentProviderConfiguration.defaultEndpoint
    }

    let otherProtocol: AgentProviderAPIProtocol = selectedProtocol == .openAICompatible
      ? .anthropicMessages : .openAICompatible
    if endpointWasStored, modelWasStored,
       endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
       == AgentProviderConfiguration.defaultEndpoint(for: otherProtocol),
       model.trimmingCharacters(in: .whitespacesAndNewlines)
       == AgentProviderConfiguration.defaultModel(for: otherProtocol) {
      endpoint = AgentProviderConfiguration.defaultEndpoint(for: selectedProtocol)
      model = AgentProviderConfiguration.defaultModel(for: selectedProtocol)
    }
  }
}
