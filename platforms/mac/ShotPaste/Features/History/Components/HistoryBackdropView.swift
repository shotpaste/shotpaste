//
//  HistoryBackdropView.swift
//  ShotPaste
//
//  Shared background used by the live history panel and its settings preview.
//

import SwiftUI

struct HistoryBackdropView: View {
  let style: HistoryBackgroundStyle
  var cornerRadius: CGFloat = 0
  var compact = false

  @ObservedObject private var themeManager = ThemeManager.shared
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      if compact {
        switch style {
        case .hud:
          Color(white: 0.15)
        case .solid:
          Color(nsColor: WindowSurfacePalette.backgroundColor(for: themeManager.preferredAppearance))
        }
      } else {
        switch style {
        case .hud:
          Rectangle().fill(.ultraThinMaterial)
          Rectangle().fill(hudTint)
          glow(
            color: Color.white.opacity(colorScheme == .dark ? 0.06 : 0.38),
            width: 220,
            height: 220,
            x: -170,
            y: -120
          )
          glow(
            color: Color.black.opacity(colorScheme == .dark ? 0.08 : 0.03),
            width: 240,
            height: 240,
            x: 180,
            y: 130
          )
        case .solid:
          Color(nsColor: WindowSurfacePalette.backgroundColor(for: themeManager.preferredAppearance))
        }

        if style == .hud {
          Rectangle()
            .fill(surfaceTint)
        }
      }

      if compact {
        compactPreviewOverlay
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }

  private var hudTint: LinearGradient {
    LinearGradient(
      colors: colorScheme == .dark
        ? [
          Color.white.opacity(0.05),
          Color.black.opacity(0.12),
          Color.white.opacity(0.03),
        ]
        : [
          Color.white.opacity(0.18),
          Color.black.opacity(0.05),
          Color.white.opacity(0.12),
        ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var surfaceTint: LinearGradient {
    LinearGradient(
      colors: [
        Color.white.opacity(colorScheme == .dark ? 0.05 : 0.24),
        Color.clear,
        Color.black.opacity(colorScheme == .dark ? 0.1 : 0.03),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var compactPreviewOverlay: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        HStack(spacing: 3) {
          Circle().fill(Color.red.opacity(0.9)).frame(width: 3.5, height: 3.5)
          Circle().fill(Color.yellow.opacity(0.9)).frame(width: 3.5, height: 3.5)
          Circle().fill(Color.green.opacity(0.9)).frame(width: 3.5, height: 3.5)
        }
        .padding(.leading, 6)

        Spacer()

        HStack(spacing: 3) {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: 10, height: 5)
          Capsule()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
            .frame(width: 10, height: 5)
          Capsule()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
            .frame(width: 10, height: 5)
        }

        Spacer()

        Circle()
          .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
          .frame(width: 5, height: 5)
          .padding(.trailing, 6)
      }
      .frame(height: 14)
      .background(previewToolbarFill)

      HStack(spacing: 6) {
        ForEach(0 ..< 3, id: \.self) { index in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(previewCardFill.opacity(index == 0 ? 1.0 : 0.68))
            .frame(width: 16, height: 26)
            .overlay(
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(previewWindowStroke, lineWidth: 0.5)
            )
        }
      }
      .padding(.horizontal, 6)
      .padding(.top, 6)

      Spacer(minLength: 0)
    }
  }

  private var previewCardFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.78)
  }

  private var previewWindowStroke: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
  }

  private var previewToolbarFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
  }

  private func glow(
    color: Color,
    width: CGFloat,
    height: CGFloat,
    x: CGFloat,
    y: CGFloat
  ) -> some View {
    Ellipse()
      .fill(color)
      .frame(width: width, height: height)
      .blur(radius: compact ? 18 : 90)
      .offset(x: x, y: y)
  }
}
