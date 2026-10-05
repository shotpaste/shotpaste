//
//  QuickAccessIconButton.swift
//  ShotPaste
//
//  Reusable icon button with hover effect and cursor state for quick access cards
//

import AppKit
import SwiftUI

/// Icon button with hover effect and pointer cursor for card action buttons
struct QuickAccessIconButton: View {
  let icon: String
  let action: () -> Void
  var helpText: String?

  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false
  @State private var isPressed = false

  var body: some View {
    Button(action: {
      guard isEnabled else { return }
      // Immediate visual feedback before action
      withAnimation(.easeOut(duration: 0.05)) {
        isPressed = true
      }
      // Execute action immediately
      action()
      // Reset press state
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        isPressed = false
      }
    }) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(icon.contains("trash") ? ShotPastePalette.danger : ShotPastePalette.text)
        .frame(width: 20, height: 20)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(buttonBackgroundColor)
        )
        .scaleEffect(isPressed ? 0.85 : 1.0)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      guard isEnabled else {
        isHovering = false
        NSCursor.arrow.set()
        return
      }
      withAnimation(.easeInOut(duration: 0.1)) {
        isHovering = hovering
      }
      if hovering {
        NSCursor.pointingHand.set()
      } else {
        NSCursor.arrow.set()
      }
    }
    .if(helpText != nil) { view in
      view.help(helpText!)
    }
  }

  private var buttonBackgroundColor: Color {
    if !isEnabled {
      ShotPastePalette.chrome.opacity(0.8)
    } else if isPressed {
      ShotPastePalette.selected
    } else if isHovering {
      ShotPastePalette.hover
    } else {
      ShotPastePalette.chrome
    }
  }
}
