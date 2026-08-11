//
//  SoundManager.swift
//  LiteScreen
//
//  Centralized sound playback gated by the user's "Play Sounds" preference
//

import AppKit

/// Gates all sound playback on the `playSounds` user preference.
enum SoundManager {
  private static let fallbackScreenshotSoundName = "Glass"
  private static let screenshotSoundTemplate: NSSound? = {
    let candidatePaths = [
      // Current macOS native screenshot sound.
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
      // Legacy fallback present on older systems.
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif",
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
    ]

    for path in candidatePaths {
      let url = URL(fileURLWithPath: path)
      if let sound = NSSound(contentsOf: url, byReference: true) {
        return sound
      }
    }

    return nil
  }()

  private static var soundsEnabled: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.playSounds) as? Bool ?? true
  }

  /// Play a named system sound only if the user hasn't disabled sounds.
  /// - Parameter name: System sound name (e.g. "Glass", "Pop", "Funk")
  static func play(_ name: String) {
    guard soundsEnabled else { return }
    NSSound(named: name)?.play()
  }

  /// Play the closest available native macOS screenshot sound.
  static func playScreenshotCapture() {
    guard soundsEnabled else { return }

    if let sound = screenshotSoundTemplate?.copy() as? NSSound, sound.play() {
      return
    }

    play(fallbackScreenshotSoundName)
  }
}
