//
//  PreferencesAfterCaptureMatrixView.swift
//  LiteScreen
//
//  Grid component for configuring post-capture actions
//

import SwiftUI

struct AfterCaptureMatrixView: View {
  @ObservedObject private var manager = PreferencesManager.shared

  var body: some View {
    VStack(spacing: 0) {
      // Column headers
      HStack(spacing: 12) {
        Spacer()
          .frame(width: 28)
        Spacer()
        HStack(spacing: 16) {
          Text(CaptureType.screenshot.displayName)
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(width: 70)
          Text(CaptureType.recording.displayName)
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(width: 70)
        }
      }
      .padding(.bottom, 4)

      ForEach(AfterCaptureAction.allCases, id: \.self) { action in
        actionRow(for: action)
      }
    }
  }

  private func actionRow(for action: AfterCaptureAction) -> some View {
    HStack(spacing: 12) {
      Image(systemName: iconName(for: action))
        .font(.title2)
        .foregroundColor(.secondary)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(action.displayName)
          .fontWeight(.medium)
        Text(description(for: action))
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer()

      HStack(spacing: 16) {
        toggleColumn(captureType: .screenshot, action: action)
        toggleColumn(captureType: .recording, action: action)
      }
    }
    .padding(.vertical, 4)
  }

  private func toggleColumn(captureType: CaptureType, action: AfterCaptureAction) -> some View {
    Toggle("", isOn: binding(for: action, type: captureType))
      .labelsHidden()
      .accessibilityLabel(L10n.AfterCapture.accessibilityLabel(
        action.displayName,
        captureKind: captureType.displayName
      ))
      .frame(width: 70)
  }

  private func iconName(for action: AfterCaptureAction) -> String {
    switch action {
    case .showQuickAccess:
      "rectangle.on.rectangle.angled"
    case .copyFile:
      "doc.on.clipboard"
    case .save:
      "square.and.arrow.down"
    }
  }

  private func description(for action: AfterCaptureAction) -> String {
    switch action {
    case .showQuickAccess:
      L10n.AfterCapture.showQuickAccessDescription
    case .copyFile:
      L10n.AfterCapture.copyFileDescription
    case .save:
      L10n.AfterCapture.saveDescription
    }
  }

  private func binding(for action: AfterCaptureAction, type: CaptureType) -> Binding<Bool> {
    Binding(
      get: { manager.isActionEnabled(action, for: type) },
      set: { manager.setAction(action, for: type, enabled: $0) }
    )
  }
}

#Preview {
  AfterCaptureMatrixView()
    .padding()
}
