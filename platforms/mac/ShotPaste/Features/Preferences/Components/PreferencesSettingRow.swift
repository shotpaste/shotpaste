//
//  PreferencesSettingRow.swift
//  ShotPaste
//
//  Reusable settings row with icon, title, description, and trailing content
//

import SwiftUI

struct SettingRow<Content: View>: View {
  let icon: String
  let title: String
  let description: String?
  var tooltip: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .regular))
        .foregroundColor(ShotPastePalette.secondaryText)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        if let tooltip {
          Text(title)
            .font(ShotPasteTypography.body)
            .foregroundStyle(ShotPastePalette.text)
            .hint(tooltip, variant: .icon(.info))
        } else {
          Text(title)
            .font(ShotPasteTypography.body)
            .foregroundStyle(ShotPastePalette.text)
        }
        if let description {
          Text(description)
            .font(ShotPasteTypography.caption)
            .foregroundColor(ShotPastePalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .multilineTextAlignment(.leading)
      .layoutPriority(1)

      Spacer()
      content()
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(title)
        .accessibilityHint(description ?? "")
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }
}
