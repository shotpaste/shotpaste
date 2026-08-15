//
//  RGBAColor.swift
//  ShotPaste
//
//  Codable sRGB color used by persisted annotation defaults.
//

import AppKit
import SwiftUI

struct RGBAColor: Codable, Equatable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double) {
    self.red = min(max(red, 0), 1)
    self.green = min(max(green, 0), 1)
    self.blue = min(max(blue, 0), 1)
    self.alpha = min(max(alpha, 0), 1)
  }

  init?(color: Color) {
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
      return nil
    }

    self.init(
      red: Double(srgb.redComponent),
      green: Double(srgb.greenComponent),
      blue: Double(srgb.blueComponent),
      alpha: Double(srgb.alphaComponent)
    )
  }

  var color: Color {
    Color(
      nsColor: NSColor(
        srgbRed: red,
        green: green,
        blue: blue,
        alpha: alpha
      )
    )
  }
}
