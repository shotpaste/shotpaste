//
//  KeystrokeOverlayConfiguration.swift
//  ShotPaste
//
//  Configuration for the keystroke overlay badge.
//  Reads persisted values from UserDefaults with sensible defaults.
//

import Foundation

/// Position of the keystroke badge relative to the recording area
nonisolated enum KeystrokeOverlayPosition: String, CaseIterable, Identifiable {
  case bottomCenter
  case bottomLeft
  case bottomRight
  case topCenter
  case topLeft
  case topRight

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .bottomCenter: L10n.KeystrokePosition.bottomCenter
    case .bottomLeft: L10n.KeystrokePosition.bottomLeft
    case .bottomRight: L10n.KeystrokePosition.bottomRight
    case .topCenter: L10n.KeystrokePosition.topCenter
    case .topLeft: L10n.KeystrokePosition.topLeft
    case .topRight: L10n.KeystrokePosition.topRight
    }
  }
}

nonisolated enum KeystrokeOverlayVisibility: String, CaseIterable, Identifiable {
  case all
  case specialAndShortcuts
  case shortcutsOnly
  case specialOnly

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .all: L10n.Recording.keystrokeVisibilityAll
    case .specialAndShortcuts: L10n.Recording.keystrokeVisibilitySpecialAndShortcuts
    case .shortcutsOnly: L10n.Recording.keystrokeVisibilityShortcutsOnly
    case .specialOnly: L10n.Recording.keystrokeVisibilitySpecialOnly
    }
  }
}

nonisolated struct KeystrokeOverlayConfiguration {
  /// Font size for the keystroke text
  let fontSize: CGFloat

  /// Position of the badge within the recording area
  let position: KeystrokeOverlayPosition

  /// How long the badge remains visible before fading (seconds)
  let displayDuration: Double

  /// Which key events are shown in the recording.
  let visibility: KeystrokeOverlayVisibility

  /// Distance from the nearest edge (px)
  let edgeOffset: CGFloat

  // MARK: - Defaults

  static let defaultFontSize: CGFloat = 18
  static let defaultPosition: KeystrokeOverlayPosition = .bottomCenter
  static let defaultDisplayDuration: Double = 1.25
  static let defaultVisibility: KeystrokeOverlayVisibility = .specialAndShortcuts
  static let defaultEdgeOffset: CGFloat = 40

  // MARK: - Init from UserDefaults

  init(defaults: UserDefaults = .standard) {
    let ud = defaults

    let size = ud.object(forKey: PreferencesKeys.keystrokeFontSize) as? CGFloat
    fontSize = size ?? Self.defaultFontSize

    if let raw = ud.string(forKey: PreferencesKeys.keystrokePosition),
       let pos = KeystrokeOverlayPosition(rawValue: raw) {
      position = pos
    } else {
      position = Self.defaultPosition
    }

    displayDuration = ud.object(forKey: PreferencesKeys.keystrokeDisplayDuration) as? Double
      ?? Self.defaultDisplayDuration

    if let raw = ud.string(forKey: PreferencesKeys.keystrokeVisibility),
       let storedVisibility = KeystrokeOverlayVisibility(rawValue: raw) {
      visibility = storedVisibility
    } else {
      visibility = Self.defaultVisibility
    }

    edgeOffset = Self.defaultEdgeOffset
  }
}
