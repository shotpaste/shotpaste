//
//  DesignTokens.swift
//  ShotPaste
//
//  Shared visual tokens for native controls and floating capture surfaces.
//

import AppKit
import SwiftUI

enum Spacing {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 16
  static let lg: CGFloat = 24
}

enum Size {
  static let radiusMd: CGFloat = 8
  static let radiusLg: CGFloat = 12
}

/// Keep app chrome distinct from captured content and annotation colors.
enum ShotPastePalette {
  static let nsLightWindow = rgb(0xF6F7FB)
  static let nsDarkWindow = rgb(0x171B24)
  static let nsWindow = adaptive("window", light: 0xF6F7FB, dark: 0x171B24)
  static let nsChrome = adaptive("chrome", light: 0xFBFCFF, dark: 0x222835)
  static let nsCard = adaptive("card", light: 0xFFFFFF, dark: 0x252C3A)
  static let window = Color(nsColor: nsWindow)
  static let chrome = Color(nsColor: nsChrome)
  static let card = Color(nsColor: nsCard)
  static let text = color("text", light: 0x202534, dark: 0xF3F5FA)
  static let secondaryText = color("secondaryText", light: 0x606978, dark: 0xADB7C8)
  static let border = color("border", light: 0xDCE1EA, dark: 0x394355)
  static let hover = color("hover", light: 0xEDF1F8, dark: 0x30394A)
  static let selected = color("selected", light: 0xE8F0FF, dark: 0x2C3A55)
  static let accent = color("accent", light: 0x2563EB, dark: 0x78A7FF)
  // This darker blue preserves contrast for white, small button labels.
  static let action = Color(nsColor: rgb(0x2563EB))
  static let danger = color("danger", light: 0xC92A3A, dark: 0xFF8792)
  static let shadow = Color(nsColor: NSColor(name: NSColor.Name("ShotPaste.shadow")) { appearance in
    NSColor.black.withAlphaComponent(
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.28 : 0.13
    )
  })

  private static func color(_ name: String, light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: adaptive(name, light: light, dark: dark))
  }

  private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: NSColor.Name("ShotPaste.\(name)")) { appearance in
      rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    }
  }

  private static func rgb(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}

enum ShotPasteTypography {
  static let body = Font.system(size: 13)
  static let label = Font.system(size: 13, weight: .medium)
  static let caption = Font.system(size: 12)
  static let selected = Font.system(size: 13, weight: .semibold)
}

struct ShotPastePanelBackground: View {
  var cornerRadius: CGFloat = Size.radiusLg
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(ShotPastePalette.chrome)
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(
            contrast == .increased ? ShotPastePalette.secondaryText : ShotPastePalette.border,
            lineWidth: contrast == .increased ? 1.5 : 1
          )
      )
  }
}
