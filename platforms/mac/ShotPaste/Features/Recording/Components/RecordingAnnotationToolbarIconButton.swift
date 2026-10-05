//
//  RecordingAnnotationToolbarIconButton.swift
//  ShotPaste
//
//  Reusable icon button for the recording annotation toolbar
//  Styled to match existing recording toolbar aesthetic
//

import SwiftUI

struct AnnotationToolbarIconButton: View {
  let systemName: String
  let isSelected: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(isSelected ? .white : (systemName == "trash" ? ShotPastePalette.danger : ShotPastePalette.text))
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: Size.radiusMd)
            .fill(backgroundColor)
        )
        .contentShape(RoundedRectangle(cornerRadius: Size.radiusMd))
        .animation(ToolbarConstants.hoverAnimation, value: isHovered)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }

  private var backgroundColor: Color {
    if isSelected {
      return ShotPastePalette.action
    } else if isHovered {
      return ShotPastePalette.hover
    }
    return .clear
  }
}
