//
//  PreferencesQuickAccessPreviewThumbnail.swift
//  LiteScreen
//
//  Screenshot-like thumbnail used by the Quick Access settings preview.
//

import SwiftUI

struct QuickAccessSettingsPreviewThumbnail: View {
  let width: CGFloat
  let height: CGFloat

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      previewBackground

      LinearGradient(
        colors: [
          Color.black.opacity(0.04),
          Color.black.opacity(0.22),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
    .frame(width: width, height: height)
    .clipped()
  }

  private var previewBackground: some View {
    ZStack {
      LinearGradient(
        colors: gradientColors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RoundedRectangle(cornerRadius: height * 0.7)
        .fill(
          LinearGradient(
            colors: [
              Color(red: 0.82, green: 0.72, blue: 1.0).opacity(0.52),
              Color(red: 0.14, green: 0.54, blue: 1.0).opacity(0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: width * 0.78, height: height * 1.34)
        .rotationEffect(.degrees(-24))
        .offset(x: width * 0.28, y: -height * 0.08)
        .blur(radius: 5)
    }
  }

  private var gradientColors: [Color] {
    switch colorScheme {
    case .dark:
      return [
        Color(red: 0.02, green: 0.03, blue: 0.24),
        Color(red: 0.04, green: 0.26, blue: 0.78),
        Color(red: 0.58, green: 0.42, blue: 0.94),
      ]
    case .light:
      return [
        Color(red: 0.68, green: 0.84, blue: 0.98),
        Color(red: 0.88, green: 0.94, blue: 0.98),
        Color(red: 0.78, green: 0.74, blue: 0.96),
      ]
    @unknown default:
      return [
        Color(red: 0.68, green: 0.84, blue: 0.98),
        Color(red: 0.88, green: 0.94, blue: 0.98),
        Color(red: 0.78, green: 0.74, blue: 0.96),
      ]
    }
  }
}
