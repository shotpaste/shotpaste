//
//  AnnotationCanvasEffects.swift
//  LiteScreen
//
//  Shared canvas-effect values used by inline annotation and screenshot presets.
//

import AppKit

enum AnnotateCanvasDefaults {
  static let cornerRadius: CGFloat = 0
}

struct AnnotationCanvasEffects {
  var backgroundStyle: BackgroundStyle = .none
  var isBlurredBackgroundEnabled: Bool = false
  var blurredBackgroundEffect: BlurredBackgroundEffect = .soft
  var padding: CGFloat = 0
  var inset: CGFloat = 0
  var autoBalance: Bool = true
  var shadowIntensity: CGFloat = 0.3
  var cornerRadius: CGFloat = AnnotateCanvasDefaults.cornerRadius
  var imageAlignment: ImageAlignment = .center
  var aspectRatio: AspectRatioOption = .auto
  var aspectRatioOrientation: AspectRatioOrientation = .horizontal
}
