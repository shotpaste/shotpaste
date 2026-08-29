//
//  AudioRecordingControlBarWindow.swift
//  ShotPaste
//
//  Dedicated audio-only floating controls. It never exposes annotation,
//  mouse, keyboard, region, or video-format controls.
//

import AppKit
import SwiftUI

@MainActor
final class AudioRecordingControlBarWindow: NSPanel {
  var onPauseResume: (() -> Void)?
  var onRestart: (() -> Void)?
  var onDelete: (() -> Void)?
  var onStop: (() -> Void)?

  init(coordinator: AudioRecordingCoordinator) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 470, height: 72),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isOpaque = false
    backgroundColor = .clear
    isReleasedWhenClosed = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hasShadow = true
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isMovableByWindowBackground = true
    appearance = ThemeManager.shared.nsAppearance

    let view = AudioRecordingControlBarView(
      coordinator: coordinator,
      recorder: ScreenRecordingManager.shared,
      onPauseResume: { [weak self] in self?.onPauseResume?() },
      onRestart: { [weak self] in self?.onRestart?() },
      onDelete: { [weak self] in self?.onDelete?() },
      onStop: { [weak self] in self?.onStop?() }
    )
    contentView = NSHostingView(rootView: view)
    positionOnMainScreen()
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  func showWithoutActivating() {
    orderFrontRegardless()
  }

  private func positionOnMainScreen() {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let frame = screen.visibleFrame
    setFrameOrigin(
      CGPoint(
        x: frame.midX - self.frame.size.width / 2,
        y: frame.minY + 24
      )
    )
  }
}

struct AudioRecordingControlBarView: View {
  @ObservedObject var coordinator: AudioRecordingCoordinator
  @ObservedObject var recorder: ScreenRecordingManager

  let onPauseResume: () -> Void
  let onRestart: () -> Void
  let onDelete: () -> Void
  let onStop: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isPaused: Bool { coordinator.state == .paused }
  private var isActive: Bool { coordinator.state == .recording }

  var body: some View {
    HStack(spacing: 11) {
      Circle()
        .fill(.red)
        .frame(width: 8, height: 8)
        .opacity(isPaused ? 0.35 : 1)
        .accessibilityHidden(true)

      Text(coordinator.formattedElapsed)
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .frame(minWidth: 54, alignment: .leading)

      audioActivity(
        icon: "speaker.wave.2.fill",
        active: coordinator.configuration.capturesSystemAudio,
        label: coordinator.configuration.capturesSystemAudio
          ? L10n.AudioRecording.systemActive : L10n.AudioRecording.systemInactive
      )
      audioActivity(
        icon: "mic.fill",
        active: coordinator.configuration.capturesMicrophone,
        label: coordinator.configuration.capturesMicrophone
          ? L10n.AudioRecording.microphoneActive : L10n.AudioRecording.microphoneInactive
      )

      RecordingWaveformView(
        level: recorder.audioLevelMeter.level,
        isActive: isActive && !reduceMotion
      )
      .frame(width: 84, height: 34)
      .clipShape(RoundedRectangle(cornerRadius: 7))

      Divider().frame(height: 22)

      Button(action: onPauseResume) {
        Image(systemName: isPaused ? "play.fill" : "pause.fill")
      }
      .audioControlLabel(isPaused ? L10n.AudioRecording.resume : L10n.AudioRecording.pause)

      Button(action: onRestart) {
        Image(systemName: "arrow.counterclockwise")
      }
      .audioControlLabel(L10n.AudioRecording.restart)

      Button(action: onDelete) {
        Image(systemName: "trash")
      }
      .audioControlLabel(L10n.AudioRecording.delete)

      Button(action: onStop) {
        Text(L10n.AudioRecording.stop)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .controlSize(.small)
      .accessibilityLabel(L10n.AudioRecording.stop)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
    .overlay(
      RoundedRectangle(cornerRadius: 15)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(statusLabel)
  }

  private var statusLabel: String {
    switch coordinator.state {
    case .recording: L10n.AudioRecording.recording
    case .paused: L10n.AudioRecording.paused
    case .saving: L10n.AudioRecording.saving
    case .transcribing: L10n.AudioRecording.transcribing
    case .polishing:
      coordinator.isWaitingForModel ? L10n.AudioRecording.modelUnavailable : L10n.AudioRecording.polishing
    case .organizing: L10n.AudioRecording.organizingInterviewQA
    case .completed: L10n.AudioRecording.completed
    default: L10n.AudioRecording.recording
    }
  }

  private func audioActivity(icon: String, active: Bool, label: String) -> some View {
    Image(systemName: icon)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.35))
      .accessibilityLabel(label)
  }
}

private extension View {
  func audioControlLabel(_ label: String) -> some View {
    buttonStyle(.borderless)
      .controlSize(.small)
      .accessibilityLabel(label)
      .frame(width: 22, height: 22)
  }
}
