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

  var body: some View {
    actionButtons
      .fixedSize(horizontal: true, vertical: false)
      .padding(8)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.white.opacity(0.2))
      )
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      if model.phase == .ready {
        Button(L10n.ScrollingCapture.startCapture, action: onStart)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(!model.canStartCapture)

        iconButton(systemImage: "xmark", help: L10n.Common.cancel, action: onCancel)
      } else {
        iconButton(systemImage: "xmark", help: L10n.Common.cancel, action: onCancel)
          .disabled(!model.canCancelSession)

        iconButton(systemImage: "checkmark", help: L10n.Common.done, action: onDone)
          .tint(.green)
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

  var body: some View {
    Button(action: onToggleAutoScroll) {
      Label(
        model.isAutoScrolling ? L10n.ScrollingCapture.stopAutoScroll : L10n.ScrollingCapture.autoScroll,
        systemImage: model.isAutoScrolling ? "stop.circle.fill" : "play.circle.fill"
      )
      .font(.system(size: 11, weight: .medium))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .strokeBorder(Color.white.opacity(0.24))
    )
    .opacity(model.canToggleAutoScroll ? 1 : 0.65)
    .disabled(!model.canToggleAutoScroll)
    .help(model.isAutoScrolling ? L10n.ScrollingCapture.stopAutoScroll : L10n.ScrollingCapture.autoScroll)
  }
}
