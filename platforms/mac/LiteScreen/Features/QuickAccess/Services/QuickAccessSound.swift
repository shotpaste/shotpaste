//
//  QuickAccessSound.swift
//  LiteScreen
//
//  Sound feedback for QuickAccess actions - CleanShot X inspired
//

import AppKit

/// Sound effects for QuickAccess interactions
enum QuickAccessSound {
  case appear
  case dismiss
  case copy
  case save
  case delete
  case complete
  case failed

  // MARK: - Pre-cached sounds for instant playback (avoid disk loading on each play)

  private static let cachedSounds: [String: NSSound] = {
    var sounds: [String: NSSound] = [:]
    let soundNames = ["Pop", "Blow", "Funk", "Glass", "Basso"]
    for name in soundNames {
      if let sound = NSSound(named: name) {
        sounds[name] = sound
      }
    }
    return sounds
  }()

  /// Play the sound effect asynchronously (non-blocking)
  /// - Parameter reduceMotion: When true, sounds are disabled for accessibility
  func play(reduceMotion: Bool = false) {
    guard !reduceMotion else { return }
    let soundsEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.playSounds) as? Bool ?? true
    guard soundsEnabled else { return }
    let soundName = soundName
    let vol = volume
    // Fire-and-forget async playback - never blocks UI
    DispatchQueue.global(qos: .userInteractive).async {
      guard let sound = Self.cachedSounds[soundName]?.copy() as? NSSound else { return }
      sound.volume = vol
      sound.play()
    }
  }

  /// Sound name for cache lookup
  private var soundName: String {
    switch self {
    case .appear, .copy, .save:
      "Pop"
    case .dismiss:
      "Blow"
    case .delete:
      "Funk"
    case .complete:
      "Glass"
    case .failed:
      "Basso"
    }
  }

  /// Volume level for this sound (0.0 - 1.0)
  private var volume: Float {
    switch self {
    case .appear:
      0.3
    case .dismiss:
      0.4
    case .copy:
      0.5
    case .save:
      0.4
    case .delete:
      0.3
    case .complete:
      0.3
    case .failed:
      0.4
    }
  }
}
