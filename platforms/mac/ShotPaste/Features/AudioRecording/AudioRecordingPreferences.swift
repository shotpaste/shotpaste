//
//  AudioRecordingPreferences.swift
//  ShotPaste
//
//  User-facing configuration for the audio-only capture flow. Audio never
//  reads the screen-recording format/region/cursor preferences: this model is
//  the single boundary between the preparation panel and UserDefaults.
//

import Foundation

nonisolated struct AudioRecordingConfiguration: Codable, Equatable, Sendable {
  var capturesSystemAudio: Bool
  var capturesMicrophone: Bool
  var microphoneDeviceID: String?
  var primaryLanguage: AudioRecordingLanguage
  var template: AudioOrganizationTemplate
  var automaticTranscription: Bool
  var automaticAI: Bool

  init(
    capturesSystemAudio: Bool = true,
    capturesMicrophone: Bool = true,
    microphoneDeviceID: String? = nil,
    primaryLanguage: AudioRecordingLanguage = .auto,
    template: AudioOrganizationTemplate = .transcriptOnly,
    automaticTranscription: Bool = true,
    automaticAI: Bool = false
  ) {
    self.capturesSystemAudio = capturesSystemAudio
    self.capturesMicrophone = capturesMicrophone
    self.microphoneDeviceID = microphoneDeviceID
    self.primaryLanguage = primaryLanguage
    self.template = template
    self.automaticTranscription = automaticTranscription
    self.automaticAI = automaticAI && automaticTranscription
  }

  var hasAudioSource: Bool {
    capturesSystemAudio || capturesMicrophone
  }

  /// Keeps the AI/transcription invariant true even when a SwiftUI binding or
  /// a future non-UI caller mutates the struct after initialization.
  var normalized: AudioRecordingConfiguration {
    var copy = self
    copy.automaticAI = copy.automaticAI && copy.automaticTranscription
    return copy
  }

  var adapterConfiguration: TinyRegionRecordingAdapter.Configuration {
    TinyRegionRecordingAdapter.Configuration(
      capturesSystemAudio: capturesSystemAudio,
      capturesMicrophone: capturesMicrophone,
      microphoneDeviceID: microphoneDeviceID
    )
  }
}

nonisolated enum AudioRecordingPreferences {
  static func configuration(defaults: UserDefaults = .standard) -> AudioRecordingConfiguration {
    let defaultDeviceID = defaults.string(
      forKey: PreferencesKeys.audioRecordingMicrophoneDeviceID
    ) ?? RecordingMicrophoneDeviceProvider.systemDefaultID
    let language = defaults.string(forKey: PreferencesKeys.audioRecordingPrimaryLanguage)
      .flatMap(AudioRecordingLanguage.init(rawValue:)) ?? .auto
    let template = defaults.string(forKey: PreferencesKeys.audioRecordingTemplate)
      .flatMap(AudioOrganizationTemplate.init(rawValue:)) ?? .transcriptOnly

    let automaticTranscription = defaults.object(
      forKey: PreferencesKeys.audioRecordingAutomaticTranscription
    ) as? Bool ?? true

    return AudioRecordingConfiguration(
      capturesSystemAudio: defaults.object(forKey: PreferencesKeys.audioRecordingSystemAudio) as? Bool
        ?? true,
      capturesMicrophone: defaults.object(forKey: PreferencesKeys.audioRecordingMicrophone) as? Bool
        ?? true,
      microphoneDeviceID: defaultDeviceID == RecordingMicrophoneDeviceProvider.systemDefaultID
        ? nil : defaultDeviceID,
      primaryLanguage: language,
      template: template,
      automaticTranscription: automaticTranscription,
      automaticAI: (defaults.object(forKey: PreferencesKeys.audioRecordingAutomaticAI) as? Bool
        ?? false) && automaticTranscription
    )
  }

  static func save(
    _ configuration: AudioRecordingConfiguration,
    defaults: UserDefaults = .standard
  ) {
    let configuration = configuration.normalized
    defaults.set(configuration.capturesSystemAudio, forKey: PreferencesKeys.audioRecordingSystemAudio)
    defaults.set(configuration.capturesMicrophone, forKey: PreferencesKeys.audioRecordingMicrophone)
    defaults.set(
      configuration.microphoneDeviceID ?? RecordingMicrophoneDeviceProvider.systemDefaultID,
      forKey: PreferencesKeys.audioRecordingMicrophoneDeviceID
    )
    defaults.set(
      configuration.primaryLanguage.rawValue,
      forKey: PreferencesKeys.audioRecordingPrimaryLanguage
    )
    defaults.set(configuration.template.rawValue, forKey: PreferencesKeys.audioRecordingTemplate)
    defaults.set(
      configuration.automaticTranscription,
      forKey: PreferencesKeys.audioRecordingAutomaticTranscription
    )
    defaults.set(
      configuration.automaticAI && configuration.automaticTranscription,
      forKey: PreferencesKeys.audioRecordingAutomaticAI
    )
  }
}
