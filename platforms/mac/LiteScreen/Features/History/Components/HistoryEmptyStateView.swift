//
//  HistoryEmptyStateView.swift
//  LiteScreen
//
//  Empty state placeholder for capture history
//

import SwiftUI

struct HistoryEmptyStateView: View {
  @Environment(\.colorScheme) private var colorScheme

  let filter: CaptureHistoryCategory?
  let hasSearch: Bool

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: iconName)
        .font(.system(size: 48))
        .foregroundColor(.secondary.opacity(0.5))

      Text(title)
        .font(.title3)
        .fontWeight(.semibold)

      Text(subtitle)
        .font(.body)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
    }
    .padding(.horizontal, 30)
    .padding(.vertical, 26)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var iconName: String {
    if hasSearch {
      return "magnifyingglass"
    }
    switch filter {
    case .screenshot: return CaptureHistoryCategory.screenshot.systemIconName
    case .scrollingScreenshot: return CaptureHistoryCategory.scrollingScreenshot.systemIconName
    case .recording: return CaptureHistoryCategory.recording.systemIconName
    case .clipboard: return CaptureHistoryCategory.clipboard.systemIconName
    case nil: return "square.grid.2x2"
    }
  }

  private var title: String {
    if hasSearch {
      return "No matches found"
    }
    switch filter {
    case .screenshot: return "No screenshots yet"
    case .scrollingScreenshot: return "No scrolling screenshots yet"
    case .recording: return "No recordings yet"
    case .clipboard: return "No clipboard items yet"
    case nil: return "No captures yet"
    }
  }

  private var subtitle: String {
    if hasSearch {
      return "Try a different search term."
    }
    return "Take a screenshot or record your screen to see them here."
  }
}
