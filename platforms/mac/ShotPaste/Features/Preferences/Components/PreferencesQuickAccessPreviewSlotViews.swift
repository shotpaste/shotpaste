//
//  PreferencesQuickAccessPreviewSlotViews.swift
//  ShotPaste
//
//  Slot views used by the Quick Access placement preview.
//

import SwiftUI

struct QuickAccessPreviewTextSlot: View {
  let slot: QuickAccessActionSlot
  let action: QuickAccessActionKind?
  let isEnabled: Bool
  let isTargeted: Bool
  let onHover: (Bool) -> Void

  var body: some View {
    content
      .overlay(slotTargetOverlay(cornerRadius: 24))
      .contentShape(RoundedRectangle(cornerRadius: 24))
      .onHover(perform: onHover)
  }

  @ViewBuilder
  private var content: some View {
    if let action {
      Text(action.settingsTitle)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.62)))
        .opacity(isEnabled ? 1 : 0.45)
        .help("\(action.settingsTitle) - \(slot.settingsTitle)")
    } else {
      RoundedRectangle(cornerRadius: 24)
        .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .overlay(plusIcon(size: 11))
        .frame(width: 44, height: 28)
        .help(slot.settingsTitle)
    }
  }

  private func slotTargetOverlay(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .stroke(
        isTargeted ? Color(nsColor: .controlAccentColor) : Color.clear,
        style: StrokeStyle(lineWidth: 2, dash: [5, 4])
      )
  }

  private func plusIcon(size: CGFloat) -> some View {
    Image(systemName: "plus")
      .font(.system(size: size, weight: .bold))
      .foregroundColor(.white.opacity(0.8))
  }
}

struct QuickAccessPreviewIconSlot: View {
  let slot: QuickAccessActionSlot
  let action: QuickAccessActionKind?
  let isEnabled: Bool
  let isTargeted: Bool
  let onHover: (Bool) -> Void

  var body: some View {
    Group {
      if let action {
        Image(systemName: action.systemImage)
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(.white)
          .frame(width: 20, height: 20)
          .background(Circle().fill(Color.black.opacity(0.62)))
          .opacity(isEnabled ? 1 : 0.45)
          .help("\(action.settingsTitle) - \(slot.settingsTitle)")
      } else {
        Circle()
          .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          .overlay(plusIcon)
          .frame(width: 20, height: 20)
          .help(slot.settingsTitle)
      }
    }
    .frame(width: 24, height: 24)
    .overlay(Circle().stroke(isTargeted ? Color(nsColor: .controlAccentColor) : Color.clear, lineWidth: 2))
    .contentShape(Circle())
    .onHover(perform: onHover)
  }

  private var plusIcon: some View {
    Image(systemName: "plus")
      .font(.system(size: 9, weight: .bold))
      .foregroundColor(.white.opacity(0.8))
  }
}

struct QuickAccessPreviewActionPopover: View {
  let action: QuickAccessActionKind
  let slot: QuickAccessActionSlot
  let isEnabled: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: action.systemImage)
        .font(.system(size: 12, weight: .semibold))
      VStack(alignment: .leading, spacing: 1) {
        Text(action.settingsTitle)
          .font(.caption.weight(.semibold))
        Text(slot.settingsTitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isEnabled ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.18), lineWidth: 1)
    )
    .opacity(isEnabled ? 1 : 0.72)
    .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
  }
}
