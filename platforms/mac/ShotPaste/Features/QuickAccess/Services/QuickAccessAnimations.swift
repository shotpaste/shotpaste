//
//  QuickAccessAnimations.swift
//  ShotPaste
//
//  Shared animation constants for QuickAccess panel - CleanShot X inspired
//

import SwiftUI

/// Centralized animation definitions for QuickAccess feature
enum QuickAccessAnimations {
  // MARK: - Panel Animations

  /// Panel enter duration for NSAnimationContext
  static let panelEnterDuration: TimeInterval = 0.4

  /// Panel exit duration for NSAnimationContext
  static let panelExitDuration: TimeInterval = 0.25

  // MARK: - Card Animations

  /// Card insertion animation — smooth easeOut to avoid bouncy repositioning
  static let cardInsert = Animation.easeOut(duration: 0.25)

  // MARK: - Hover Animations

  /// Hover overlay fade in/out
  static let hoverOverlay = Animation.easeOut(duration: 0.15)

  /// Button reveal with bounce
  static let buttonReveal = Animation.spring(response: 0.25, dampingFraction: 0.6)

  /// Delay between button reveals (stagger effect)
  static let buttonStaggerDelay: Double = 0.05

  // MARK: - Progress Animations

  /// Progress ring rotation
  static let progressRotation = Animation.linear(duration: 1.0).repeatForever(autoreverses: false)

  // MARK: - Accessibility

  /// Reduced motion alternative - simple fade
  static let reducedFade = Animation.easeInOut(duration: 0.2)

  /// Returns appropriate animation based on accessibility settings
  static func animation(for base: Animation, reduceMotion: Bool) -> Animation {
    reduceMotion ? reducedFade : base
  }
}
