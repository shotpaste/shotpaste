//
//  AudioRecordingPreparationPanel.swift
//  ShotPaste
//
//  Non-activating preparation panel for audio capture. It intentionally has
//  no video, region, cursor, or output-format controls.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AudioRecordingPreparationPanel: NSPanel {
  var onStart: ((AudioRecordingConfiguration) -> Void)?
  var onCancel: (() -> Void)?

  private var hostingView: NSHostingView<AudioRecordingPreparationView>?

  init(configuration: AudioRecordingConfiguration) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 410, height: 440),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    title = L10n.AudioRecording.preparationTitle
    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    hasShadow = true
    appearance = ThemeManager.shared.nsAppearance
    setConfiguration(configuration)
    center()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func setConfiguration(_ configuration: AudioRecordingConfiguration) {
    let view = AudioRecordingPreparationView(
      configuration: configuration,
      onStart: { [weak self] configuration in
        self?.onStart?(configuration)
      },
      onCancel: { [weak self] in
        self?.onCancel?()
      }
    )
    let host = NSHostingView(rootView: view)
    hostingView = host
    contentView = host
  }

  func showPreparingWithoutActivating() {
    let host = NSHostingView(rootView: AudioRecordingPreparingView())
    contentView = host
    setContentSize(NSSize(width: 320, height: 120))
    center()
    orderFrontRegardless()
    makeKey()
  }

  override func performClose(_ sender: Any?) {
    onCancel?()
  }

  func showWithoutActivating() {
    orderFrontRegardless()
    makeKey()
  }
}

private struct AudioRecordingPreparingView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)
      Text(L10n.AudioRecording.preparing)
        .font(.headline)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(22)
  }
}

struct AudioRecordingPreparationView: View {
  @State private var configuration: AudioRecordingConfiguration

  let onStart: (AudioRecordingConfiguration) -> Void
  let onCancel: () -> Void

  init(
    configuration: AudioRecordingConfiguration,
    onStart: @escaping (AudioRecordingConfiguration) -> Void,
    onCancel: @escaping () -> Void
  ) {
    _configuration = State(initialValue: configuration)
    self.onStart = onStart
    self.onCancel = onCancel
  }

  private var microphoneDevices: [AVCaptureDevice] {
    RecordingMicrophoneDeviceProvider.captureDevices()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.AudioRecording.preparationTitle)
        .font(.title3.weight(.semibold))

      Form {
        Section {
          Toggle(L10n.AudioRecording.systemAudio, isOn: $configuration.capturesSystemAudio)
          Toggle(L10n.AudioRecording.microphone, isOn: $configuration.capturesMicrophone)

          if configuration.capturesMicrophone {
            Picker(L10n.AudioRecording.microphoneDevice, selection: microphoneSelection) {
              Text(L10n.AudioRecording.microphoneDevice).tag(Optional<String>.none)
              ForEach(microphoneDevices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(Optional(device.uniqueID))
              }
            }
          }
        }

        Section {
          Picker(L10n.AudioRecording.primaryLanguage, selection: $configuration.primaryLanguage) {
            ForEach(AudioRecordingLanguage.allCases, id: \.rawValue) { language in
              Text(languageLabel(language)).tag(language)
            }
          }

          Picker(L10n.AudioRecording.template, selection: $configuration.template) {
            Text(L10n.AudioRecording.templateInterviewQA)
              .tag(AudioOrganizationTemplate.interviewQA)
            Text(L10n.AudioRecording.templateGeneralNotes)
              .tag(AudioOrganizationTemplate.generalNotes)
            Text(L10n.AudioRecording.templateTranscriptOnly)
              .tag(AudioOrganizationTemplate.transcriptOnly)
          }

          Toggle(
            L10n.AudioRecording.automaticTranscription,
            isOn: automaticTranscriptionBinding
          )
          Toggle(L10n.AudioRecording.automaticAI, isOn: automaticAIBinding)
            .disabled(!configuration.automaticTranscription)
        }
      }
      .formStyle(.grouped)

      HStack {
        Text(L10n.AudioRecording.privacyDisclosure)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(L10n.Common.cancel, action: onCancel)
        Button(L10n.AudioRecording.startButton) {
          AudioRecordingPreferences.save(configuration)
          onStart(configuration)
        }
        .disabled(!configuration.hasAudioSource)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(18)
    .frame(minWidth: 410, minHeight: 430)
  }

  private var microphoneSelection: Binding<String?> {
    Binding(
      get: { configuration.microphoneDeviceID },
      set: { configuration.microphoneDeviceID = $0 }
    )
  }

  private var automaticAIBinding: Binding<Bool> {
    Binding(
      get: { configuration.automaticAI && configuration.automaticTranscription },
      set: { configuration.automaticAI = $0 && configuration.automaticTranscription }
    )
  }

  private var automaticTranscriptionBinding: Binding<Bool> {
    Binding(
      get: { configuration.automaticTranscription },
      set: {
        configuration.automaticTranscription = $0
        if !$0 { configuration.automaticAI = false }
      }
    )
  }

  private func languageLabel(_ language: AudioRecordingLanguage) -> String {
    switch language {
    case .auto: "Auto"
    case .en: "English"
    case .zhHans: "简体中文"
    case .zhHant: "繁體中文"
    case .ja: "日本語"
    case .ko: "한국어"
    case .de: "Deutsch"
    case .es: "Español"
    case .fr: "Français"
    case .ru: "Русский"
    case .vi: "Tiếng Việt"
    }
  }
}
