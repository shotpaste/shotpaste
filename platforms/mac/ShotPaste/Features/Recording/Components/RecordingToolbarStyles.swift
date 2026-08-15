//
//  RecordingToolbarStyles.swift
//  ShotPaste
//
//  Design constants and button styles for the recording toolbar
//  Styled to match Apple's native macOS recording toolbar aesthetic
//

import SwiftUI

// MARK: - Toolbar Constants

enum ToolbarConstants {
  static let iconButtonSize: CGFloat = 32
  static let iconSize: CGFloat = 15
  static let buttonCornerRadius: CGFloat = 6
  static let toolbarCornerRadius: CGFloat = 14
  static let dividerHeight: CGFloat = 20
  static let itemSpacing: CGFloat = 4
  static let groupSpacing: CGFloat = 2
  static let horizontalPadding: CGFloat = 10
  static let verticalPadding: CGFloat = 6
  static let hoverAnimation: Animation = .easeInOut(duration: 0.15)
  static let pressAnimation: Animation = .easeInOut(duration: 0.1)
}

// MARK: - Recording Toolbar Divider

struct RecordingToolbarDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.15))
      .frame(width: 1, height: ToolbarConstants.dividerHeight)
      .padding(.horizontal, 4)
  }
}

struct ToolbarIconButtonLabel: View {
  let systemName: String
  var iconSize: CGFloat = ToolbarConstants.iconSize
  let isHovered: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: systemName)
      .font(.system(size: iconSize, weight: .medium))
      .foregroundColor(.primary.opacity(isHovered ? 1.0 : 0.85))
      .frame(
        width: ToolbarConstants.iconButtonSize,
        height: ToolbarConstants.iconButtonSize
      )
      .background(
        RoundedRectangle(cornerRadius: ToolbarConstants.buttonCornerRadius)
          .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
      )
      .contentShape(RoundedRectangle(cornerRadius: ToolbarConstants.buttonCornerRadius))
      .animation(reduceMotion ? nil : ToolbarConstants.hoverAnimation, value: isHovered)
  }
}

// MARK: - Stop Button Style (native monochrome, no red pill)

struct StopButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .regular))
      .foregroundColor(.primary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: ToolbarConstants.buttonCornerRadius)
          .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
      )
      .contentShape(RoundedRectangle(cornerRadius: ToolbarConstants.buttonCornerRadius))
      .animation(reduceMotion ? nil : ToolbarConstants.pressAnimation, value: configuration.isPressed)
  }
}

// MARK: - Previews

#Preview("Toolbar Divider") {
  HStack {
    Text(L10n.PreferencesQuickAccess.left)
    RecordingToolbarDivider()
    Text(L10n.PreferencesQuickAccess.right)
  }
  .padding()
}
