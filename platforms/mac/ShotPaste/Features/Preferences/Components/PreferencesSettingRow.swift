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
        .font(.title2)
        .foregroundColor(.secondary)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 2) {
        if let tooltip {
          Text(title)
            .fontWeight(.medium)
            .hint(tooltip, variant: .icon(.info))
        } else {
          Text(title)
            .fontWeight(.medium)
        }
        if let description {
          Text(description)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .multilineTextAlignment(.leading)
      .layoutPriority(1)

      Spacer()
      content()
        .fixedSize(horizontal: true, vertical: false)
    }
    .padding(.vertical, 4)
  }
}
