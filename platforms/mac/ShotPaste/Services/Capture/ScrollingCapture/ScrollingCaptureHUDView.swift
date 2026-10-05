//
//  ScrollingCaptureHUDView.swift
//  ShotPaste
//
//  SwiftUI content for the scrolling capture control HUD.
//

import SwiftUI

struct ScrollingCaptureHUDView: View {
  @ObservedObject var model: ScrollingCaptureSessionModel
  let onStart: () -> Void
  let onDone: () -> Void
  let onCancel: () -> Void
  @ObservedObject private var themeManager = ThemeManager.shared

  var body: some View {
    actionButtons
      .fixedSize(horizontal: true, vertical: false)
      .padding(8)
      .foregroundStyle(ShotPastePalette.text)
      .tint(ShotPastePalette.action)
      .background(ShotPastePanelBackground())
      .preferredColorScheme(themeManager.systemAppearance)
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      if model.phase == .ready {
        Button(L10n.ScrollingCapture.startCapture, action: onStart)
          .buttonStyle(.borderedProminent)
          .tint(ShotPastePalette.action)
          .controlSize(.small)
          .disabled(!model.canStartCapture)

        iconButton(systemImage: "xmark", help: L10n.Common.cancel, action: onCancel)
      } else {
        iconButton(systemImage: "xmark", help: L10n.Common.cancel, action: onCancel)
          .disabled(!model.canCancelSession)

        iconButton(systemImage: "checkmark", help: L10n.Common.done, action: onDone)
          .tint(ShotPastePalette.action)
          .disabled(!model.canFinishCapture)
      }
    }
  }

  private func iconButton(
    systemImage: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: 16, height: 16)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help(help)
    .accessibilityLabel(help)
  }
}

struct ScrollingCaptureAutoScrollView: View {
  @ObservedObject var model: ScrollingCaptureSessionModel
  let onToggleAutoScroll: () -> Void
  @ObservedObject private var themeManager = ThemeManager.shared

  var body: some View {
    Button(action: onToggleAutoScroll) {
      Label(
        model.isAutoScrolling ? L10n.ScrollingCapture.stopAutoScroll : L10n.ScrollingCapture.autoScroll,
        systemImage: model.isAutoScrolling ? "stop.circle.fill" : "play.circle.fill"
      )
      .font(ShotPasteTypography.caption)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .foregroundStyle(model.isAutoScrolling ? ShotPastePalette.accent : ShotPastePalette.text)
    .background(ShotPastePanelBackground(cornerRadius: Size.radiusMd))
    .preferredColorScheme(themeManager.systemAppearance)
    .opacity(model.canToggleAutoScroll ? 1 : 0.65)
    .disabled(!model.canToggleAutoScroll)
    .help(model.isAutoScrolling ? L10n.ScrollingCapture.stopAutoScroll : L10n.ScrollingCapture.autoScroll)
  }
}
