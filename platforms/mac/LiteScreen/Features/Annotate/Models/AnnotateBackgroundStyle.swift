//
//  AnnotateBackgroundStyle.swift
//  LiteScreen
//
//  Background style types and presets for annotation canvas
//

import Foundation
import SwiftUI

/// Background style types
nonisolated enum BackgroundStyle: Equatable, Sendable {
  case none
  case gradient(GradientPreset)
  case solidColor(Color)

  var supportsBlurredBackgroundEffect: Bool {
    switch self {
    case .solidColor:
      true
    case .none, .gradient:
      false
    }
  }
}

/// Blur presets for applying a soft effect to the selected background layer.
nonisolated enum BlurredBackgroundEffect: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
  case soft
  case frosted
  case vivid
  case dim

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .soft:
      L10n.AnnotateUI.blurredBackgroundSoft
    case .frosted:
      L10n.AnnotateUI.blurredBackgroundFrosted
    case .vivid:
      L10n.AnnotateUI.blurredBackgroundVivid
    case .dim:
      L10n.AnnotateUI.blurredBackgroundDim
    }
  }

  var blurRadius: CGFloat {
    switch self {
    case .soft:
      18
    case .frosted:
      30
    case .vivid:
      22
    case .dim:
      24
    }
  }

  var saturation: Double {
    switch self {
    case .soft:
      1.0
    case .frosted:
      0.85
    case .vivid:
      1.35
    case .dim:
      0.9
    }
  }

  var brightness: Double {
    switch self {
    case .soft:
      0
    case .frosted:
      0.06
    case .vivid:
      0.02
    case .dim:
      -0.06
    }
  }

  var tintColor: Color {
    switch self {
    case .soft, .frosted:
      .white
    case .vivid:
      .orange
    case .dim:
      .black
    }
  }

  var tintOpacity: Double {
    switch self {
    case .soft:
      0.08
    case .frosted:
      0.28
    case .vivid:
      0.10
    case .dim:
      0.24
    }
  }
}

/// Predefined gradient presets
nonisolated enum GradientPreset: String, CaseIterable, Identifiable, Sendable {
  case pinkOrange
  case bluePurple
  case greenBlue
  case orangeRed
  case purplePink
  case blueGreen
  case yellowOrange
  case cyanBlue

  var id: String {
    rawValue
  }

  var colors: [Color] {
    switch self {
    case .pinkOrange: [.pink, .orange]
    case .bluePurple: [.blue, .purple]
    case .greenBlue: [.green, .blue]
    case .orangeRed: [.orange, .red]
    case .purplePink: [.purple, .pink]
    case .blueGreen: [.blue, .green]
    case .yellowOrange: [.yellow, .orange]
    case .cyanBlue: [.cyan, .blue]
    }
  }
}

/// Image alignment within background
nonisolated enum ImageAlignment: String, CaseIterable, Sendable {
  case topLeft, top, topRight
  case left, center, right
  case bottomLeft, bottom, bottomRight
}

/// Orientation for fixed aspect ratio presets.
nonisolated enum AspectRatioOrientation: String, CaseIterable, Identifiable, Sendable {
  case horizontal
  case vertical

  var id: String {
    rawValue
  }

  var systemImageName: String {
    switch self {
    case .horizontal:
      "rectangle"
    case .vertical:
      "rectangle.portrait"
    }
  }
}

/// Aspect ratio options for export.
nonisolated enum AspectRatioOption: String, CaseIterable, Identifiable, Sendable {
  case auto = "Auto"
  case free = "Free"
  case square = "1:1"
  case ratio4x3 = "4:3"
  case ratio3x2 = "3:2"
  case ratio16x9 = "16:9"

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .auto:
      L10n.Common.original
    case .free:
      L10n.Common.free
    case .square, .ratio4x3, .ratio16x9, .ratio3x2:
      rawValue
    }
  }

  var supportsOrientation: Bool {
    switch self {
    case .ratio4x3, .ratio16x9, .ratio3x2:
      true
    case .auto, .free, .square:
      false
    }
  }

  func effectiveDisplayName(orientation: AspectRatioOrientation) -> String {
    guard orientation == .vertical else {
      return displayName
    }

    switch self {
    case .ratio4x3:
      return "3:4"
    case .ratio3x2:
      return "2:3"
    case .ratio16x9:
      return "9:16"
    case .auto, .free, .square:
      return displayName
    }
  }

  func targetRatio(
    for foregroundSize: CGSize,
    orientation: AspectRatioOrientation = .horizontal
  ) -> CGFloat? {
    let baseRatio: CGFloat?
    switch self {
    case .auto:
      guard foregroundSize.width > 0, foregroundSize.height > 0 else { return nil }
      baseRatio = foregroundSize.width / foregroundSize.height
    case .free:
      baseRatio = nil
    case .square:
      baseRatio = 1
    case .ratio4x3:
      baseRatio = 4.0 / 3.0
    case .ratio16x9:
      baseRatio = 16.0 / 9.0
    case .ratio3x2:
      baseRatio = 3.0 / 2.0
    }

    guard let baseRatio else { return nil }
    if supportsOrientation, orientation == .vertical {
      return 1 / baseRatio
    }
    return baseRatio
  }

  func canvasSize(
    for foregroundSize: CGSize,
    padding: CGFloat,
    alignmentSpace: CGFloat,
    orientation: AspectRatioOrientation = .horizontal
  ) -> CGSize {
    let normalizedWidth = max(foregroundSize.width, 1)
    let normalizedHeight = max(foregroundSize.height, 1)
    let minimumWidth = normalizedWidth + max(padding, 0) * 2 + max(alignmentSpace, 0)
    let minimumHeight = normalizedHeight + max(padding, 0) * 2 + max(alignmentSpace, 0)

    guard let targetRatio = targetRatio(
      for: CGSize(width: normalizedWidth, height: normalizedHeight),
      orientation: orientation
    ),
      targetRatio > 0 else {
      return CGSize(width: minimumWidth, height: minimumHeight)
    }

    let minimumRatio = minimumWidth / minimumHeight
    if minimumRatio < targetRatio {
      return CGSize(width: minimumHeight * targetRatio, height: minimumHeight)
    }

    return CGSize(width: minimumWidth, height: minimumWidth / targetRatio)
  }
}
