//
//  AnnotateRenderSnapshot.swift
//  LiteScreen
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
  var editorMode: AnnotateState.EditorMode
  var isCombineMode: Bool
  var effectiveContentBounds: CGRect
  var cropRect: CGRect?
  var annotations: [AnnotationItem]
  var embeddedImages: [UUID: NSImage]
  var embeddedCGImages: [UUID: CGImage]

  var backgroundStyle: BackgroundStyle
  var isBlurredBackgroundEffectActive: Bool
  var blurredBackgroundEffect: BlurredBackgroundEffect

  var padding: CGFloat
  var cornerRadius: CGFloat
  var shadowIntensity: CGFloat
  var imageAlignment: ImageAlignment
  var aspectRatio: AspectRatioOption
  var aspectRatioOrientation: AspectRatioOrientation

  var mockupRotationX: CGFloat
  var mockupRotationY: CGFloat
  var mockupRotationZ: CGFloat
  var mockupPerspective: CGFloat
  var mockupShadowRadius: CGFloat
  var mockupShadowOffsetX: CGFloat
  var mockupShadowOffsetY: CGFloat
}
