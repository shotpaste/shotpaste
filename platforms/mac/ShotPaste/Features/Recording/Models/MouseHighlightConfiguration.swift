//
//  MouseHighlightConfiguration.swift
//  ShotPaste
//
//  Configuration for the mouse click highlight overlay.
//  Reads persisted values from UserDefaults with sensible defaults.
//

import AppKit
import Foundation

nonisolated struct MouseHighlightConfiguration {
  /// Maximum diameter of each expanding ripple ring (px)
  let highlightSize: CGFloat

  /// Diameter of the persistent hold circle while mouse is pressed (px)
  let holdCircleSize: CGFloat

  /// Stroke width for rings and the hold circle
  let ringWidth: CGFloat

  /// Duration of each ripple ring's expand animation (seconds)
  let animationDuration: Double

  /// Number of concentric ripple rings spawned on each click
  let rippleCount: Int

  /// Stroke colors for left- and right-button rings.
  let leftHighlightColor: NSColor
  let rightHighlightColor: NSColor

  /// Alpha applied to the highlight stroke color
  let highlightOpacity: Double

  // MARK: - Defaults

  static let defaultHighlightSize: CGFloat = 48
  static let defaultHoldCircleSize: CGFloat = 36
  static let defaultRingWidth: CGFloat = 2
  static let defaultAnimationDuration: Double = 0.42
  static let defaultRippleCount: Int = 2
  static let defaultHighlightOpacity: Double = 0.72

  static let defaultLeftHighlightColor = NSColor(
    srgbRed: 124.0 / 255.0, green: 58.0 / 255.0, blue: 237.0 / 255.0, alpha: 1.0
  )
  static let defaultRightHighlightColor = NSColor(
    srgbRed: 1.0, green: 159.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0
  )

  // MARK: - Init from UserDefaults

  init(defaults: UserDefaults = .standard) {
    let ud = defaults

    highlightSize = ud.object(forKey: PreferencesKeys.mouseHighlightSize) as? CGFloat
      ?? Self.defaultHighlightSize

    // Hold circle is proportionally scaled from highlight size
    holdCircleSize = (highlightSize / Self.defaultHighlightSize) * Self.defaultHoldCircleSize

    ringWidth = Self.defaultRingWidth

    animationDuration = ud.object(forKey: PreferencesKeys.mouseHighlightAnimationDuration) as? Double
      ?? Self.defaultAnimationDuration

    let count = ud.integer(forKey: PreferencesKeys.mouseHighlightRippleCount)
    rippleCount = count > 0 ? count : Self.defaultRippleCount

    highlightOpacity = ud.object(forKey: PreferencesKeys.mouseHighlightOpacity) as? Double
      ?? Self.defaultHighlightOpacity

    leftHighlightColor = RecordingOverlayColorPreferences.color(
      forKey: PreferencesKeys.mouseHighlightLeftColor,
      default: Self.defaultLeftHighlightColor,
      defaults: ud
    )
    rightHighlightColor = RecordingOverlayColorPreferences.color(
      forKey: PreferencesKeys.mouseHighlightRightColor,
      default: Self.defaultRightHighlightColor,
      defaults: ud
    )
  }

  func highlightColor(for button: MouseClickButton) -> NSColor {
    button == .right ? rightHighlightColor : leftHighlightColor
  }
}

nonisolated enum MouseClickButton {
  case left
  case right
}

nonisolated enum RecordingOverlayColorPreferences {
  static func color(forKey key: String, default fallback: NSColor, defaults: UserDefaults = .standard) -> NSColor {
    guard let data = defaults.data(forKey: key),
          let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
      return fallback
    }
    return color
  }

  static func set(_ color: NSColor, forKey key: String, defaults: UserDefaults = .standard) {
    guard let data = try? NSKeyedArchiver.archivedData(
      withRootObject: color,
      requiringSecureCoding: true
    ) else { return }
    defaults.set(data, forKey: key)
  }
}
