//
//  QuickAccessTrackpadSwipeModeStore.swift
//  ShotPaste
//
//  Persisted trackpad swipe direction mode for Quick Access cards.
//

import Combine
import Foundation

final class QuickAccessTrackpadSwipeModeStore: ObservableObject {
  static let shared = QuickAccessTrackpadSwipeModeStore()

  @Published private(set) var mode: QuickAccessTrackpadSwipeMode

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults

    if let rawValue = defaults.string(forKey: PreferencesKeys.quickAccessTrackpadSwipeMode),
       let storedMode = QuickAccessTrackpadSwipeMode(rawValue: rawValue) {
      mode = storedMode
    } else {
      mode = .inverted
    }
  }

  /// Persisted value storage has no actor-bound teardown work.
  nonisolated deinit {}

  func setMode(_ newMode: QuickAccessTrackpadSwipeMode) {
    guard mode != newMode else { return }
    mode = newMode
    defaults.set(newMode.rawValue, forKey: PreferencesKeys.quickAccessTrackpadSwipeMode)
  }

  func resetToDefault() {
    setMode(.inverted)
  }
}
