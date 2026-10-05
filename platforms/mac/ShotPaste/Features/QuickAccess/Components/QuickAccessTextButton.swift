//
//  QuickAccessTextButton.swift
//  ShotPaste
//
//  Text-based action button for quick access screenshot cards
//

import SwiftUI

/// Text-based action button with hover effect for card overlays
struct QuickAccessTextButton: View {
  let label: String
  var isDestructive = false
  let action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(isDestructive ? ShotPastePalette.danger : ShotPastePalette.text)
        .lineLimit(1)
        .minimumScaleFactor(0.68)
        .allowsTightening(true)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: Size.radiusMd)
            .fill(buttonBackgroundColor)
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      guard isEnabled else {
        isHovering = false
        return
      }
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovering = hovering
      }
    }
  }

  private var buttonBackgroundColor: Color {
    guard isEnabled else {
      return ShotPastePalette.chrome.opacity(0.8)
    }
    return isHovering ? ShotPastePalette.hover : ShotPastePalette.chrome
  }
}
