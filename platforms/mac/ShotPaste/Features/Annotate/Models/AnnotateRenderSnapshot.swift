//
//  AnnotateRenderSnapshot.swift
//  ShotPaste
//
//  Immutable value-type snapshot of everything final-image rendering needs.
//

import AppKit

/// Frozen copy of every `AnnotateState` input used by `AnnotateExporter` rendering.
/// Built on the main actor with lazy caches pre-warmed, then consumed from any queue —
/// rendering never touches live state.
///
/// Contract: the referenced `NSImage` instances are treated as immutable during render
/// (state replaces rather than mutates them post-load).
struct AnnotateRenderSnapshot {
  var sourceImage: NSImage
  var annotations: [AnnotationItem]

  var backgroundStyle: BackgroundStyle
  var isBlurredBackgroundEffectActive: Bool
  var blurredBackgroundEffect: BlurredBackgroundEffect

  var padding: CGFloat
  var cornerRadius: CGFloat
  var shadowIntensity: CGFloat
  var imageAlignment: ImageAlignment
  var aspectRatio: AspectRatioOption
  var aspectRatioOrientation: AspectRatioOrientation
}
