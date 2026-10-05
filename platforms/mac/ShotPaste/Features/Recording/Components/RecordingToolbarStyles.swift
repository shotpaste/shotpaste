//
//  RecordingToolbarStyles.swift
//  ShotPaste
//
//  Design constants and button styles for the recording toolbar
//  Shared visual language for capture and recording controls
//

import SwiftUI

// MARK: - Toolbar Constants

enum ToolbarConstants {
  static let iconButtonSize: CGFloat = 32
  static let iconSize: CGFloat = 15
  static let buttonCornerRadius: CGFloat = Size.radiusMd
  static let toolbarCornerRadius: CGFloat = Size.radiusLg
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
      .fill(ShotPastePalette.border)
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
      .foregroundColor(systemName == "trash" ? ShotPastePalette.danger : ShotPastePalette.text)
      .frame(
        width: ToolbarConstants.iconButtonSize,
        height: ToolbarConstants.iconButtonSize
      )
      .background(
        RoundedRectangle(cornerRadius: ToolbarConstants.buttonCornerRadius)
          .fill(isHovered ? ShotPastePalette.hover : Color.clear)
      )
      .contentShape(RoundedRectangle(cornerRadius: ToolbarConstants.buttonCornerRadius))
      .animation(reduceMotion ? nil : ToolbarConstants.hoverAnimation, value: isHovered)
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
