//
//  RecordingMicrophoneDevice.swift
//  ShotPaste
//
//  Microphone input choices for screen recordings.
//

import AVFoundation
import Foundation

nonisolated enum RecordingMicrophoneDeviceProvider {
  static let systemDefaultID = "system-default"

  static func storedDeviceID(defaults: UserDefaults = .standard) -> String {
    let value = defaults.string(forKey: PreferencesKeys.recordingMicrophoneDeviceID)
    return normalizedStoredDeviceID(value)
  }

  static func normalizedCaptureDeviceID(_ deviceID: String?) -> String? {
    guard let deviceID, !deviceID.isEmpty, deviceID != systemDefaultID else {
      return nil
    }
    return deviceID
  }

  static func captureDevice(matching deviceID: String?) -> AVCaptureDevice? {
    if let deviceID = normalizedCaptureDeviceID(deviceID),
       let device = captureDevices().first(where: { $0.uniqueID == deviceID }) {
      return device
    }

    return AVCaptureDevice.default(for: .audio) ?? captureDevices().first
  }

  static func captureDevices() -> [AVCaptureDevice] {
    let session = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInMicrophone, .externalUnknown],
      mediaType: .audio,
      position: .unspecified
    )
    return session.devices.sorted { lhs, rhs in
      lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
    }
  }

  private static func normalizedStoredDeviceID(_ value: String?) -> String {
    guard let value, !value.isEmpty else {
      return systemDefaultID
    }
    return value
  }
}
