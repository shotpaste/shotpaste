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
  @State private var endpointDraft = ""
  @State private var modelDraft = ""
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
            .fixedSize()
            .frame(width: 300, alignment: .trailing)
          }

          SettingRow(
            icon: "link",
            title: L10n.Agent.endpointTitle,
            description: L10n.Agent.endpointExample(endpointDomainExample)
          ) {
            InlineEditableSettingField(
              value: endpoint,
              draft: $endpointDraft,
              accessibilityLabel: L10n.Agent.endpointTitle,
              onSave: { endpoint = $0 }
            )
          }

          SettingRow(
            icon: "cpu",
            title: L10n.Agent.modelTitle,
            description: ""
          ) {
            InlineEditableSettingField(
              value: model,
              draft: $modelDraft,
              accessibilityLabel: L10n.Agent.modelTitle,
              onSave: { model = $0 }
            )
          }

          SettingRow(
            icon: "key.fill",
            title: L10n.Agent.apiKeyTitle,
            description: keyOperationMessage ?? L10n.Agent.apiKeyDescription
          ) {
            InlineEditableSettingField(
              value: maskedStoredKey ?? "",
              draft: $apiKey,
              accessibilityLabel: L10n.Agent.apiKeyTitle,
              isSecure: true,
              onSave: saveAPIKey
            )
          }

          SettingRow(
            icon: "brain.head.profile",
            title: L10n.Agent.thinkingTitle,
            description: ""
          ) {
            Toggle("", isOn: $thinkingEnabled)
              .labelsHidden()
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

        Section(L10n.Agent.settingsSection) {
          if agentMode.isEnabled {
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

            SettingRow(
              icon: "photo",
              title: L10n.Agent.sendImagesTitle,
              description: L10n.Agent.sendImagesDescription
            ) {
              Toggle("", isOn: $sendsImages)
                .labelsHidden()
            }

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

          HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
              .font(.title2)
              .foregroundStyle(.secondary)
              .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 6) {
                Text(L10n.Agent.modeTitle)
                  .fontWeight(.medium)
                Text(L10n.Agent.betaBadge)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(Color.purple)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.purple.opacity(0.12), in: Capsule())
              }
              Text(L10n.Agent.modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

              if agentMode.isEnabled {
                Text("\(L10n.Agent.modeEnabledStatus) · \(agentMode.statusMessage)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            Spacer()
            Toggle("", isOn: modeEnabledBinding)
              .labelsHidden()
              .accessibilityLabel(L10n.Agent.modeTitle)
          }
          .padding(.vertical, 4)
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

  private var endpointDomainExample: String {
    switch selectedProtocol {
    case .openAICompatible: "https://api.openai.com/v1"
    case .anthropicMessages: "https://api.anthropic.com"
    }
  }

  private var permissionDescription: String {
    let screen = screenCaptureManager.hasPermission ? "Screen ✓" : "Screen —"
    let accessibility = accessibilityGranted ? "Accessibility ✓" : "Accessibility —"
    return "\(L10n.Agent.permissionDescription) · \(screen) · \(accessibility)"
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

  private func saveAPIKey(_ value: String) {
    do {
      try credentialStore.saveAPIKey(value)
      apiKey = ""
      maskedStoredKey = credentialStore.maskedStoredAPIKey()
      keyOperationMessage = L10n.Agent.keyStored
    } catch {
      keyOperationMessage = error.localizedDescription
    }
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

private struct InlineEditableSettingField: View {
  private static let fieldWidth: CGFloat = 300
  private static let fieldHeight: CGFloat = 32
  private static let textAreaWidth: CGFloat = 254
  private static let actionAreaWidth: CGFloat = 46

  let value: String
  @Binding var draft: String
  let accessibilityLabel: String
  var isSecure = false
  let onSave: (String) -> Void

  @State private var isEditing = false

  var body: some View {
    HStack(spacing: 0) {
      LeftAlignedAppKitField(
        text: $draft,
        isSecure: isSecure,
        isEditing: isEditing,
        onSubmit: save
      )
      .padding(.leading, 8)
      .frame(
        width: Self.textAreaWidth,
        height: Self.fieldHeight,
        alignment: .leading
      )
      .allowsHitTesting(isEditing)

      if isEditing {
        HStack(spacing: 4) {
          iconButton("checkmark", action: save)
            .disabled(trimmedDraft.isEmpty)
          iconButton("xmark", action: cancel)
        }
        .frame(width: Self.actionAreaWidth, height: Self.fieldHeight)
      } else {
        Color.clear
          .frame(width: Self.actionAreaWidth, height: Self.fieldHeight)
      }
    }
    .frame(width: Self.fieldWidth, height: Self.fieldHeight)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
          isEditing ? Color.accentColor : Color.secondary.opacity(0.3),
          lineWidth: isEditing ? 2 : 1
        )
    )
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture {
      guard !isEditing else { return }
      beginEditing()
    }
    .onAppear(perform: synchronizeDisplayValue)
    .onChange(of: value) { _ in
      guard !isEditing else { return }
      synchronizeDisplayValue()
    }
    .accessibilityLabel(accessibilityLabel)
  }

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func beginEditing() {
    draft = isSecure ? "" : value
    isEditing = true
  }

  private func save() {
    guard !trimmedDraft.isEmpty else { return }
    onSave(trimmedDraft)
    isEditing = false
  }

  private func cancel() {
    synchronizeDisplayValue()
    isEditing = false
  }

  private func synchronizeDisplayValue() {
    draft = value
  }

  private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .frame(width: 18, height: 18)
    }
    .buttonStyle(.plain)
  }
}

private struct LeftAlignedAppKitField: NSViewRepresentable {
  @Binding var text: String
  let isSecure: Bool
  let isEditing: Bool
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSTextField {
    let textField: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
    textField.delegate = context.coordinator
    textField.isBordered = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.alignment = .left
    textField.usesSingleLineMode = true
    textField.lineBreakMode = .byTruncatingTail
    textField.font = .systemFont(ofSize: NSFont.systemFontSize)
    textField.textColor = .labelColor
    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return textField
  }

  func updateNSView(_ textField: NSTextField, context: Context) {
    context.coordinator.parent = self
    if textField.stringValue != text {
      textField.stringValue = text
    }
    textField.alignment = .left
    textField.isEditable = isEditing
    textField.isSelectable = isEditing

    if isEditing, textField.window?.firstResponder !== textField.currentEditor() {
      DispatchQueue.main.async {
        textField.window?.makeFirstResponder(textField)
      }
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: LeftAlignedAppKitField

    init(parent: LeftAlignedAppKitField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let textField = notification.object as? NSTextField else { return }
      parent.text = textField.stringValue
    }

    func control(
      _: NSControl,
      textView _: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
      parent.onSubmit()
      return true
    }
  }
}
