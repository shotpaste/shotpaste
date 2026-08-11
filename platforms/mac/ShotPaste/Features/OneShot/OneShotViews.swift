//
//  OneShotViews.swift
//  ShotPaste
//
//  Shared macOS controls rendered over the frozen One Shot selection surface.
//

import AppKit
import AVFoundation
import SwiftUI

enum OneShotLayout {
  static let switcherHeight: CGFloat = 56
  static let switcherPreferredWidth: CGFloat = 520
  static let switcherScreenInset: CGFloat = 12
  static let switcherTopGap: CGFloat = 12
  static let modeToolbarGap: CGFloat = 12
  static let recordingPanelSize = CGSize(width: 410, height: 206)
  static let magnifierSize = CGSize(width: 188, height: 184)
}

struct OneShotTopSwitcher: View {
  @ObservedObject var state: OneShotSessionState
  let width: CGFloat
  let horizontalRange: ClosedRange<CGFloat>
  let onSelect: (OneShotTab) -> Void

  @State private var dragStartX: CGFloat?

  var body: some View {
    HStack(spacing: 4) {
      dragHandle

      ForEach(OneShotTab.allCases) { tab in
        Button {
          onSelect(tab)
        } label: {
          Label(tab.title, systemImage: tab.iconName)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .foregroundStyle(tab == state.activeTab ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
              RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tab == state.activeTab ? Color.white.opacity(0.96) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(tabOpacity(tab))
        .help(tabHelp(tab))
        .accessibilityIdentifier("oneshot-tab-\(tab.rawValue)")
        .accessibilityAddTraits(tab == state.activeTab ? .isSelected : [])
      }
    }
    .padding(6)
    .frame(width: width, height: OneShotLayout.switcherHeight)
    .background(OneShotHUDBackground(cornerRadius: 16))
    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("oneshot-top-switcher")
  }

  private var dragHandle: some View {
    Image(systemName: "circle.grid.3x3.fill")
      .font(.system(size: 15, weight: .medium))
      .foregroundStyle(Color.white.opacity(0.68))
      .frame(width: 34, height: 44)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            if dragStartX == nil {
              dragStartX = state.switcherX
            }
            state.moveSwitcher(
              to: (dragStartX ?? state.switcherX) + value.translation.width,
              within: horizontalRange
            )
          }
          .onEnded { _ in
            dragStartX = nil
          }
      )
      .help(L10n.OneShot.dragSwitcherHint)
      .accessibilityLabel(L10n.OneShot.dragSwitcherHint)
      .accessibilityIdentifier("oneshot-switcher-drag-handle")
  }

  private func tabOpacity(_ tab: OneShotTab) -> Double {
    guard state.phase == .committed, tab != state.activeTab else { return 1 }
    return 0.4
  }

  private func tabHelp(_ tab: OneShotTab) -> String {
    if state.phase == .committed, tab != state.activeTab {
      return L10n.OneShot.modeLockedHint
    }
    return tab.title
  }
}

struct OneShotScrollingControls: View {
  @ObservedObject var state: OneShotSessionState
  let onStart: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      if state.showsScrollingHelp {
        Text(L10n.OneShot.scrollingHelpMessage)
          .font(.system(size: 12))
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .frame(width: 330, alignment: .leading)
          .background(OneShotLightPanelBackground(cornerRadius: 11))
          .transition(.opacity)
          .accessibilityIdentifier("oneshot-scrolling-help-message")
      }

      HStack(spacing: 10) {
        Button(action: onStart) {
          Label(L10n.ScrollingCapture.startCapture, systemImage: "arrow.up.and.down")
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("oneshot-scrolling-start")

        Button {
          state.toggleScrollingHelp()
        } label: {
          Label(L10n.OneShot.help, systemImage: "questionmark.circle")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("oneshot-scrolling-help")
      }
      .padding(8)
      .background(OneShotLightPanelBackground(cornerRadius: 13))
      .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }
  }
}

struct OneShotRecordingControls: View {
  @ObservedObject var state: OneShotSessionState
  let onStart: () -> Void
  @State private var showMicrophonePermissionAlert = false

  var body: some View {
    VStack(spacing: 14) {
      Button(action: onStart) {
        Label(L10n.OneShot.startRecording, systemImage: "record.circle.fill")
          .font(.system(size: 14, weight: .semibold))
          .frame(maxWidth: .infinity, minHeight: 36)
      }
      .buttonStyle(.borderedProminent)
      .tint(.accentColor)
      .accessibilityIdentifier("oneshot-recording-start")

      Picker(L10n.RecordingToolbar.formatSection, selection: outputModeBinding) {
        Text(verbatim: "MP4").tag(RecordingOutputMode.video)
        Text(verbatim: "GIF").tag(RecordingOutputMode.gif)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("oneshot-recording-format")

      HStack(spacing: 18) {
        optionToggle(
          title: L10n.RecordingToolbar.showCursor,
          icon: "cursorarrow",
          isOn: cursorBinding,
          identifier: "oneshot-recording-cursor"
        )
        optionToggle(
          title: L10n.RecordingToolbar.systemAudio,
          icon: "speaker.wave.2",
          isOn: systemAudioBinding,
          identifier: "oneshot-recording-system-audio"
        )
        optionToggle(
          title: L10n.RecordingToolbar.microphoneInput,
          icon: "mic",
          isOn: microphoneBinding,
          identifier: "oneshot-recording-microphone"
        )
      }
    }
    .padding(18)
    .frame(
      width: OneShotLayout.recordingPanelSize.width, height: OneShotLayout.recordingPanelSize.height
    )
    .background(OneShotLightPanelBackground(cornerRadius: 16))
    .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("oneshot-recording-settings")
    .alert(L10n.Microphone.accessRequiredTitle, isPresented: $showMicrophonePermissionAlert) {
      Button(L10n.Common.openSystemSettings) {
        openMicrophoneSettings()
      }
      Button(L10n.Common.cancel, role: .cancel) {}
    } message: {
      Text(L10n.Microphone.preferencesMessage)
    }
  }

  private var outputModeBinding: Binding<RecordingOutputMode> {
    Binding(
      get: { state.recordingOptions.outputMode },
      set: { newValue in
        guard newValue != state.recordingOptions.outputMode else { return }
        var options = state.recordingOptions
        options.outputMode = newValue
        state.updateRecordingOptions(options, reason: .recordingOutputMode)
      }
    )
  }

  private var cursorBinding: Binding<Bool> {
    optionBinding(\.showsCursor, reason: .recordingCursor)
  }

  private var systemAudioBinding: Binding<Bool> {
    optionBinding(\.capturesSystemAudio, reason: .recordingSystemAudio)
  }

  private var microphoneBinding: Binding<Bool> {
    Binding(
      get: { state.recordingOptions.capturesMicrophone },
      set: { updateMicrophone($0) }
    )
  }

  private func updateMicrophone(_ enabled: Bool) {
    guard enabled != state.recordingOptions.capturesMicrophone else { return }
    setMicrophoneOption(enabled)
    guard enabled else { return }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
      Task { @MainActor in
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
          setMicrophoneOption(false)
          showMicrophonePermissionAlert = true
        }
      }
    case .authorized:
      break
    case .denied, .restricted:
      setMicrophoneOption(false)
      showMicrophonePermissionAlert = true
    @unknown default:
      break
    }
  }

  private func setMicrophoneOption(_ enabled: Bool) {
    var options = state.recordingOptions
    options.capturesMicrophone = enabled
    state.updateRecordingOptions(options, reason: .recordingMicrophone)
  }

  private func openMicrophoneSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func optionBinding(
    _ keyPath: WritableKeyPath<OneShotRecordingOptions, Bool>,
    reason: OneShotCommitReason
  ) -> Binding<Bool> {
    Binding(
      get: { state.recordingOptions[keyPath: keyPath] },
      set: { newValue in
        guard newValue != state.recordingOptions[keyPath: keyPath] else { return }
        var options = state.recordingOptions
        options[keyPath: keyPath] = newValue
        state.updateRecordingOptions(options, reason: reason)
      }
    )
  }

  private func optionToggle(
    title: String,
    icon: String,
    isOn: Binding<Bool>,
    identifier: String
  ) -> some View {
    Toggle(isOn: isOn) {
      VStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 17, weight: .medium))
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)
    }
    .toggleStyle(.button)
    .buttonStyle(.bordered)
    .accessibilityIdentifier(identifier)
  }
}

struct OneShotMagnifierSample {
  let image: NSImage
  let globalPoint: CGPoint
  let hex: String
  let rgb: String

  func value(for format: OneShotColorFormat) -> String {
    format == .hex ? hex : rgb
  }
}

enum OneShotMagnifierSampler {
  static func sample(
    image: CGImage,
    localPoint: CGPoint,
    displaySize: CGSize,
    globalPoint: CGPoint,
    sampleRadius: Int = 7
  ) -> OneShotMagnifierSample? {
    guard displaySize.width > 0, displaySize.height > 0,
          image.width > 0, image.height > 0
    else { return nil }

    let x = min(
      max(Int(localPoint.x / displaySize.width * CGFloat(image.width)), 0), image.width - 1
    )
    let y = min(
      max(Int(localPoint.y / displaySize.height * CGFloat(image.height)), 0), image.height - 1
    )
    let minX = max(0, x - sampleRadius)
    let minY = max(0, y - sampleRadius)
    let maxX = min(image.width, x + sampleRadius + 1)
    let maxY = min(image.height, y + sampleRadius + 1)
    guard
      let crop = image.cropping(
        to: CGRect(
          x: minX,
          y: minY,
          width: maxX - minX,
          height: maxY - minY
        )
      ), let color = color(atX: x, y: y, in: image)
    else { return nil }

    return OneShotMagnifierSample(
      image: NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height)),
      globalPoint: globalPoint,
      hex: String(format: "#%02X%02X%02X", color.red, color.green, color.blue),
      rgb: String(format: "RGB(%d, %d, %d)", color.red, color.green, color.blue)
    )
  }

  private static func color(atX x: Int, y: Int, in image: CGImage) -> (
    red: UInt8, green: UInt8, blue: UInt8
  )? {
    guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
      return nil
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    else { return nil }
    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    return (data[0], data[1], data[2])
  }
}

struct OneShotMagnifierView: View {
  let sample: OneShotMagnifierSample
  let format: OneShotColorFormat

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Image(nsImage: sample.image)
          .interpolation(.none)
          .resizable()
          .scaledToFill()
          .frame(width: OneShotLayout.magnifierSize.width, height: 112)
          .clipped()

        Rectangle()
          .stroke(Color.red, lineWidth: 1.5)
          .frame(width: 12, height: 12)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(L10n.OneShot.coordinates(Int(sample.globalPoint.x), Int(sample.globalPoint.y)))
        Text(verbatim: "\(format.rawValue): \(sample.value(for: format))")
        Text(L10n.OneShot.copyColorHint)
        Text(L10n.OneShot.switchColorHint)
      }
      .font(.system(size: 10.5, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.white)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .background(Color.black.opacity(0.86))
    }
    .frame(width: OneShotLayout.magnifierSize.width, height: OneShotLayout.magnifierSize.height)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.white.opacity(0.35), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("oneshot-magnifier")
  }
}

private struct OneShotHUDBackground: View {
  let cornerRadius: CGFloat

  var body: some View {
    ZStack {
      OneShotVisualEffect(material: .hudWindow, blendingMode: .withinWindow)
      Color.black.opacity(0.35)
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

private struct OneShotLightPanelBackground: View {
  let cornerRadius: CGFloat

  var body: some View {
    OneShotVisualEffect(material: .popover, blendingMode: .withinWindow)
      .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.38))
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      )
  }
}

struct OneShotSizeLabelBackground: View {
  var body: some View {
    OneShotVisualEffect(material: .popover, blendingMode: .withinWindow)
      .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.62))
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(Color.primary.opacity(0.14), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
  }
}

struct OneShotVisualEffect: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context _: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context _: Context) {
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
  }
}

private extension OneShotTab {
  var title: String {
    switch self {
    case .screenshot: L10n.CaptureKind.screenshot
    case .scrolling: L10n.Actions.scrollingCapture
    case .recording: L10n.CaptureKind.recording
    case .clipboard: L10n.OneShot.clipboard
    }
  }

  var iconName: String {
    switch self {
    case .screenshot: "camera"
    case .scrolling: "arrow.up.and.down"
    case .recording: "record.circle"
    case .clipboard: "clipboard"
    }
  }
}
