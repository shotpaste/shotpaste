//
//  PreferencesCaptureSettingsView.swift
//  ShotPaste
//
//  Capture preferences tab combining screenshot behavior, recording settings, and post-capture actions
//

import AVFoundation
import SwiftUI

private enum CaptureSettingsPane: CaseIterable, Hashable, Identifiable {
  case general
  case screenshot
  case recording

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .general:
      L10n.Preferences.generalTab
    case .screenshot:
      CaptureType.screenshot.displayName
    case .recording:
      CaptureType.recording.displayName
    }
  }
}

struct CaptureSettingsView: View {
  // Screenshot behavior
  @AppStorage(PreferencesKeys.hideDesktopIcons) private var hideDesktopIcons = false
  @AppStorage(PreferencesKeys.hideDesktopWidgets) private var hideDesktopWidgets = false
  @AppStorage(PreferencesKeys.screenshotIncludeOwnApp) private var includeOwnAppInScreenshots = false
  @AppStorage(PreferencesKeys.screenshotShowCursor) private var screenshotShowCursor = false
  @AppStorage(PreferencesKeys.screenshotMagnifierEnabled) private var screenshotMagnifierEnabled = true
  @AppStorage(PreferencesKeys.screenshotMagnifierZoom) private var screenshotMagnifierZoom = 1
  @AppStorage(PreferencesKeys.screenshotScale) private var screenshotScale = 0
  @AppStorage(PreferencesKeys.screenshotColorSpace) private var screenshotColorSpace = "auto"
  @AppStorage(PreferencesKeys.screenshotLossyQuality) private var screenshotLossyQuality = 90
  @AppStorage(PreferencesKeys.screenshotSuccessNotificationEnabled)
  private var screenshotSuccessNotification = true

  @AppStorage(PreferencesKeys.screenshotFormat) private var screenshotFormat = "png"
  @AppStorage(PreferencesKeys.scrollingCaptureShowHints) private var scrollingCaptureShowHints = true
  @AppStorage(PreferencesKeys.ocrSuccessNotificationEnabled) private var ocrSuccessNotification = false
  @AppStorage(PreferencesKeys.ocrLinkDetectionEnabled) private var ocrLinkDetection = true
  @AppStorage(PreferencesKeys.ocrRecognitionLanguage) private var ocrRecognitionLanguage = "auto"
  @AppStorage(PreferencesKeys.screenshotFileNameTemplate)
  private var screenshotFileNameTemplate = CaptureOutputKind.screenshot.defaultTemplate

  /// Recording settings
  @AppStorage(PreferencesKeys.recordingFormat) private var format = "mov"
  @AppStorage(PreferencesKeys.recordingFileNameTemplate)
  private var recordingFileNameTemplate = CaptureOutputKind.recording.defaultTemplate
  @AppStorage(PreferencesKeys.recordingFPS) private var fps = 30
  @AppStorage(PreferencesKeys.recordingVideoCodec) private var recordingVideoCodec = "h264"
  @AppStorage(PreferencesKeys.recordingGIFFPS) private var recordingGIFFPS = 15
  @AppStorage(PreferencesKeys.recordingCaptureAudio) private var captureAudio = true
  @AppStorage(PreferencesKeys.recordingCaptureMicrophone) private var captureMicrophone = false
  @AppStorage(PreferencesKeys.recordingSystemAudioVolume) private var recordingSystemAudioVolume = 0.8
  @AppStorage(PreferencesKeys.recordingMicrophoneVolume) private var recordingMicrophoneVolume = 0.8
  @AppStorage(PreferencesKeys.recordingIncludeOwnApp) private var includeOwnAppInRecordings = false
  @AppStorage(PreferencesKeys.recordingShowCursor) private var recordingShowCursor = true
  @AppStorage(PreferencesKeys.recordingDimNonSelectedArea) private var recordingDimNonSelectedArea = true
  @AppStorage(PreferencesKeys.recordingHoverBarVisible) private var recordingHoverBarVisible = true
  @AppStorage(PreferencesKeys.recordingShowTimeOnMenuBar) private var recordingShowTimeOnMenuBar = true
  @AppStorage(PreferencesKeys.recordingHighlightClicks) private var recordingHighlightClicks = false
  @AppStorage(PreferencesKeys.recordingShowKeystrokes) private var recordingShowKeystrokes = false

  // Mouse Highlight settings
  @AppStorage(PreferencesKeys.mouseHighlightSize) private var mouseHighlightSize: Double = 48
  @AppStorage(PreferencesKeys.mouseHighlightAnimationDuration) private var mouseHighlightAnimDuration: Double = 0.42
  @AppStorage(PreferencesKeys.mouseHighlightRippleCount) private var mouseHighlightRippleCount: Int = 2
  @AppStorage(PreferencesKeys.mouseHighlightOpacity) private var mouseHighlightOpacity: Double = 0.72

  // Keystroke Overlay settings
  @AppStorage(PreferencesKeys.keystrokeFontSize) private var keystrokeFontSize: Double = 18
  @AppStorage(PreferencesKeys.keystrokePosition) private var keystrokePosition: String = KeystrokeOverlayPosition
    .bottomCenter.rawValue
  @AppStorage(PreferencesKeys.keystrokeDisplayDuration) private var keystrokeDisplayDuration: Double = 1.25
  @AppStorage(PreferencesKeys.keystrokeVisibility)
  private var keystrokeVisibility = KeystrokeOverlayVisibility.specialAndShortcuts.rawValue

  // Recording annotation settings
  @AppStorage(PreferencesKeys.recordingAnnotationWidth) private var recordingAnnotationWidth = 4.0
  @AppStorage(PreferencesKeys.recordingAnnotationClearMode) private var recordingAnnotationClearMode = "manual"
  @AppStorage(PreferencesKeys.recordingAnnotationClearSeconds) private var recordingAnnotationClearSeconds = 5.0
  @AppStorage(PreferencesKeys.recordingAnnotationMaxCount) private var recordingAnnotationMaxCount = 12
  @AppStorage(PreferencesKeys.recordingAnnotationFadeEnabled) private var recordingAnnotationFadeEnabled = true
  @AppStorage(PreferencesKeys.recordingAnnotationFadeDuration) private var recordingAnnotationFadeDuration = 0.35
  @AppStorage(PreferencesKeys.recordingAnnotationTemporaryModifier)
  private var recordingAnnotationTemporaryModifier = RecordingAnnotationTemporaryModifier.shift.rawValue
  @AppStorage(PreferencesKeys.recordingAnnotationTemporaryClearMode)
  private var recordingAnnotationTemporaryClearMode = "manual"

  @State private var showPermissionDeniedAlert = false
  @State private var selectedPane: CaptureSettingsPane = .general
  private func storedColorBinding(key: String, fallback: NSColor) -> Binding<Color> {
    Binding<Color>(
      get: {
        Color(nsColor: RecordingOverlayColorPreferences.color(forKey: key, default: fallback))
      },
      set: { newColor in
        RecordingOverlayColorPreferences.set(NSColor(newColor), forKey: key)
      }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()

        Picker("", selection: $selectedPane) {
          ForEach(CaptureSettingsPane.allCases) { pane in
            Text(pane.title).tag(pane)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 560)

        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 8)

      Form {
        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.appWindowsSection) {
            SettingRow(
              icon: "photo.on.rectangle",
              title: L10n.PreferencesCapture.includeInScreenshotsTitle,
              description: L10n.PreferencesCapture.includeInScreenshotsDescription
            ) {
              Toggle("", isOn: $includeOwnAppInScreenshots)
                .labelsHidden()
            }
          }
        }

        // MARK: - Desktop

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.desktopSection) {
            SettingRow(
              icon: "eye.slash",
              title: L10n.PreferencesCapture.hideDesktopIconsTitle,
              description: L10n.PreferencesCapture.hideDesktopIconsDescription
            ) {
              Toggle("", isOn: $hideDesktopIcons)
                .labelsHidden()
            }

            SettingRow(
              icon: "widget.small",
              title: L10n.PreferencesCapture.hideDesktopWidgetsTitle,
              description: L10n.PreferencesCapture.hideDesktopWidgetsDescription
            ) {
              Toggle("", isOn: $hideDesktopWidgets)
                .labelsHidden()
            }
          }
        }

        // MARK: - Screenshot Format

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.screenshotFormatSection) {
            SettingRow(
              icon: "cursorarrow",
              title: L10n.PreferencesCapture.showCursorTitle,
              description: L10n.PreferencesCapture.showCursorDescription
            ) {
              Toggle("", isOn: $screenshotShowCursor)
                .labelsHidden()
            }

            SettingRow(
              icon: "magnifyingglass",
              title: L10n.PreferencesCapture.pixelMagnifierTitle,
              description: L10n.PreferencesCapture.pixelMagnifierDescription
            ) {
              Toggle("", isOn: $screenshotMagnifierEnabled)
                .labelsHidden()
            }

            if screenshotMagnifierEnabled {
              SettingRow(
                icon: "plus.magnifyingglass",
                title: L10n.PreferencesCapture.magnifierZoomTitle,
                description: L10n.PreferencesCapture.magnifierZoomDescription
              ) {
                Stepper(value: $screenshotMagnifierZoom, in: 1 ... 20) {
                  Text("\(screenshotMagnifierZoom)×")
                    .monospacedDigit()
                }
                .frame(width: 110)
              }
            }

            SettingRow(
              icon: "photo",
              title: L10n.PreferencesCapture.imageFormatTitle,
              description: L10n.PreferencesCapture.imageFormatDescription
            ) {
              Picker("", selection: $screenshotFormat) {
                ForEach(ImageFormatOption.allCases, id: \.self) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            if screenshotFormat != ImageFormatOption.png.rawValue {
              SettingRow(
                icon: "slider.horizontal.3",
                title: L10n.PreferencesCapture.lossyQualityTitle,
                description: L10n.PreferencesCapture.lossyQualityDescription
              ) {
                Stepper(value: $screenshotLossyQuality, in: 1 ... 100) {
                  Text("\(screenshotLossyQuality)")
                    .monospacedDigit()
                }
                .frame(width: 112)
              }
            }

            SettingRow(
              icon: "arrow.up.left.and.arrow.down.right",
              title: L10n.PreferencesCapture.outputScaleTitle,
              description: L10n.PreferencesCapture.outputScaleDescription
            ) {
              Picker("", selection: $screenshotScale) {
                Text(L10n.Common.automatic).tag(0)
                Text("1×").tag(1)
                Text("2×").tag(2)
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            SettingRow(
              icon: "paintpalette",
              title: L10n.PreferencesCapture.colorSpaceTitle,
              description: L10n.PreferencesCapture.colorSpaceDescription
            ) {
              Picker("", selection: $screenshotColorSpace) {
                Text(L10n.Common.automatic).tag("auto")
                Text("sRGB").tag("srgb")
                Text("Display P3").tag("displayP3")
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            if screenshotFormat == ImageFormatOption.webp.rawValue {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundColor(.orange)
                  .font(.system(size: 12))
                  .padding(.top, 1)
                Text(L10n.PreferencesCapture.webpWarning)
                  .font(.system(size: 11))
                  .foregroundColor(.orange)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 4)
            }

            if screenshotFormat == ImageFormatOption.jpeg.rawValue {
              HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                  .foregroundColor(.blue)
                  .font(.system(size: 12))
                  .padding(.top, 1)
                Text(L10n.PreferencesCapture.jpegCutoutNote)
                  .font(.system(size: 11))
                  .foregroundColor(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.vertical, 4)
            }
          }
        }

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.screenshotPresetSection) {
            PreferencesScreenshotDefaultPresetPicker()
          }
        }

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.scrollingCaptureSection) {
            SettingRow(
              icon: "lightbulb",
              title: L10n.PreferencesCapture.showSessionHintsTitle,
              description: L10n.PreferencesCapture.showSessionHintsDescription
            ) {
              Toggle("", isOn: $scrollingCaptureShowHints)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
                .font(.system(size: 12))
                .padding(.top, 1)
              Text(L10n.PreferencesCapture.scrollingCaptureInfo)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
          }
        }

        // MARK: - OCR

        if selectedPane == .screenshot {
          Section(L10n.PreferencesCapture.ocrSection) {
            SettingRow(
              icon: "checkmark.circle",
              title: L10n.PreferencesCapture.captureSuccessNotificationTitle,
              description: L10n.PreferencesCapture.captureSuccessNotificationDescription
            ) {
              Toggle("", isOn: $screenshotSuccessNotification)
                .labelsHidden()
            }

            SettingRow(
              icon: "bell.badge",
              title: L10n.PreferencesCapture.ocrSuccessNotificationTitle,
              description: L10n.PreferencesCapture.ocrSuccessNotificationDescription
            ) {
              Toggle("", isOn: $ocrSuccessNotification)
                .labelsHidden()
            }

            SettingRow(
              icon: "link",
              title: L10n.PreferencesCapture.ocrLinkDetectionTitle,
              description: L10n.PreferencesCapture.ocrLinkDetectionDescription
            ) {
              Toggle("", isOn: $ocrLinkDetection)
                .labelsHidden()
            }

            SettingRow(
              icon: "character.book.closed",
              title: L10n.PreferencesCapture.ocrLanguageTitle,
              description: L10n.PreferencesCapture.ocrLanguageDescription
            ) {
              Picker("", selection: $ocrRecognitionLanguage) {
                Text(L10n.PreferencesCapture.followAppLanguage).tag("auto")
                ForEach(AppLanguageOption.supported) { option in
                  Text(option.displayName).tag(option.identifier)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(width: 180)
            }
          }
        }

        if selectedPane == .general {
          Section(L10n.PreferencesCapture.outputNamingSection) {
            SettingRow(
              icon: "textformat",
              title: L10n.PreferencesCapture.screenshotTemplateTitle,
              description: L10n.PreferencesCapture.screenshotTemplateDescription
            ) {
              TextField("", text: $screenshotFileNameTemplate)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }

            SettingRow(
              icon: "textformat.abc",
              title: L10n.PreferencesCapture.recordingTemplateTitle,
              description: L10n.PreferencesCapture.recordingTemplateDescription
            ) {
              TextField("", text: $recordingFileNameTemplate)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            }

            HStack(alignment: .top, spacing: 6) {
              Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
                .padding(.top, 1)
              Text(L10n.PreferencesCapture.availableTokens)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
              Text(L10n.PreferencesCapture.screenshotPreview(screenshotFilenamePreview))
              Text(L10n.PreferencesCapture.recordingPreview(recordingFilenamePreview))
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.top, 2)

            HStack {
              Spacer()
              Button(L10n.PreferencesCapture.resetNamingDefaults) {
                resetOutputNamingDefaults()
              }
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .buttonStyle(.plain)
            }
          }
        }

        // MARK: - Recording

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingFormatSection) {
            SettingRow(
              icon: "film",
              title: L10n.PreferencesCapture.videoFormatTitle,
              description: L10n.PreferencesCapture.videoFormatDescription
            ) {
              Picker("", selection: $format) {
                Text(verbatim: "MOV").tag("mov")
                Text(verbatim: "MP4").tag("mp4")
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            SettingRow(
              icon: "cpu",
              title: L10n.PreferencesCapture.videoCodecTitle,
              description: L10n.PreferencesCapture.videoCodecDescription
            ) {
              Picker("", selection: $recordingVideoCodec) {
                Text("H.264").tag("h264")
                Text("HEVC / H.265").tag("hevc")
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingQualitySection) {
            SettingRow(
              icon: "gauge.with.dots.needle.33percent",
              title: L10n.PreferencesCapture.frameRateTitle,
              description: L10n.PreferencesCapture.frameRateDescription
            ) {
              Picker("", selection: $fps) {
                Text("15 FPS").tag(15)
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            SettingRow(
              icon: "photo.stack",
              title: L10n.PreferencesCapture.gifFrameRateTitle,
              description: L10n.PreferencesCapture.gifFrameRateDescription
            ) {
              Picker("", selection: $recordingGIFFPS) {
                ForEach([10, 15, 20, 30], id: \.self) { option in
                  Text("\(option) FPS").tag(option)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingBehaviorSection) {
            SettingRow(
              icon: "cursorarrow",
              title: L10n.PreferencesCapture.showCursorTitle,
              description: L10n.PreferencesCapture.recordingShowCursorDescription
            ) {
              Toggle("", isOn: $recordingShowCursor)
                .labelsHidden()
            }

            SettingRow(
              icon: "cursorarrow.click.2",
              title: L10n.PreferencesCapture.highlightMouseClicksTitle,
              description: L10n.PreferencesCapture.highlightMouseClicksDescription
            ) {
              Toggle("", isOn: $recordingHighlightClicks)
                .labelsHidden()
            }

            SettingRow(
              icon: "keyboard",
              title: L10n.PreferencesCapture.showKeystrokesTitle,
              description: L10n.PreferencesCapture.showKeystrokesDescription
            ) {
              Toggle("", isOn: $recordingShowKeystrokes)
                .labelsHidden()
            }

            SettingRow(
              icon: "video.badge.plus",
              title: L10n.PreferencesCapture.includeInRecordingsTitle,
              description: L10n.PreferencesCapture.includeInRecordingsDescription
            ) {
              Toggle("", isOn: $includeOwnAppInRecordings)
                .labelsHidden()
            }

            SettingRow(
              icon: "rectangle.center.inset.filled",
              title: L10n.PreferencesCapture.recordingDimNonSelectedAreaTitle,
              description: L10n.PreferencesCapture.recordingDimNonSelectedAreaDescription
            ) {
              Toggle("", isOn: $recordingDimNonSelectedArea)
                .labelsHidden()
            }
          }
        }

        // MARK: - Recording Controls

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.recordingControlsSection) {
            SettingRow(
              icon: "menubar.rectangle",
              title: L10n.PreferencesCapture.hoverBarVisibleTitle,
              description: L10n.PreferencesCapture.hoverBarVisibleDescription
            ) {
              Toggle("", isOn: $recordingHoverBarVisible)
                .labelsHidden()
            }

            SettingRow(
              icon: "timer",
              title: L10n.PreferencesCapture.menuBarTimeTitle,
              description: L10n.PreferencesCapture.menuBarTimeDescription
            ) {
              Toggle("", isOn: $recordingShowTimeOnMenuBar)
                .labelsHidden()
            }
          }
        }

        // MARK: - Recording Overlays

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.mouseHighlightSection) {
            SettingRow(
              icon: "cursorarrow.click.2",
              title: L10n.PreferencesCapture.highlightSizeTitle,
              description: L10n.PreferencesCapture.highlightSizeDescription(Int(mouseHighlightSize))
            ) {
              Slider(value: $mouseHighlightSize.stepped(by: 2, in: 12 ... 192), in: 12 ... 192)
                .frame(width: 140)
            }

            SettingRow(
              icon: "timer",
              title: L10n.PreferencesCapture.animationDurationTitle,
              description: L10n.PreferencesCapture.animationDurationDescription(
                String(format: "%.1f", mouseHighlightAnimDuration)
              )
            ) {
              Slider(value: $mouseHighlightAnimDuration.stepped(by: 0.05, in: 0.1 ... 3.0), in: 0.1 ... 3.0)
                .frame(width: 140)
            }

            SettingRow(
              icon: "circle.grid.3x3",
              title: L10n.PreferencesCapture.rippleCountTitle,
              description: L10n.PreferencesCapture.rippleCountDescription
            ) {
              Picker("", selection: $mouseHighlightRippleCount) {
                ForEach(1 ... 5, id: \.self) { count in
                  Text("\(count)").tag(count)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(width: 80)
            }

            SettingRow(
              icon: "paintpalette",
              title: L10n.PreferencesCapture.leftClickColorTitle,
              description: L10n.PreferencesCapture.leftClickColorDescription
            ) {
              ColorPicker(
                "",
                selection: storedColorBinding(
                  key: PreferencesKeys.mouseHighlightLeftColor,
                  fallback: MouseHighlightConfiguration.defaultLeftHighlightColor
                ),
                supportsOpacity: false
              )
              .labelsHidden()
            }

            SettingRow(
              icon: "paintpalette.fill",
              title: L10n.PreferencesCapture.rightClickColorTitle,
              description: L10n.PreferencesCapture.rightClickColorDescription
            ) {
              ColorPicker(
                "",
                selection: storedColorBinding(
                  key: PreferencesKeys.mouseHighlightRightColor,
                  fallback: MouseHighlightConfiguration.defaultRightHighlightColor
                ),
                supportsOpacity: false
              )
              .labelsHidden()
            }

            SettingRow(
              icon: "circle.lefthalf.filled",
              title: L10n.PreferencesCapture.opacityTitle,
              description: L10n.PreferencesCapture.opacityDescription(Int(mouseHighlightOpacity * 100))
            ) {
              Slider(value: $mouseHighlightOpacity.stepped(by: 0.05, in: 0.1 ... 1.0), in: 0.1 ... 1.0)
                .frame(width: 140)
            }

            HStack {
              Spacer()
              Button(L10n.Common.resetToDefault) {
                resetMouseHighlightDefaults()
              }
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .buttonStyle(.plain)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.keystrokeOverlaySection) {
            SettingRow(
              icon: "textformat.size",
              title: L10n.PreferencesCapture.fontSizeTitle,
              description: L10n.PreferencesCapture.fontSizeDescription(Int(keystrokeFontSize))
            ) {
              Slider(value: $keystrokeFontSize.stepped(by: 1, in: 12 ... 32), in: 12 ... 32)
                .frame(width: 140)
            }

            SettingRow(
              icon: "square.and.arrow.down.on.square",
              title: L10n.PreferencesCapture.positionTitle,
              description: L10n.PreferencesCapture.positionDescription
            ) {
              Picker("", selection: $keystrokePosition) {
                ForEach(KeystrokeOverlayPosition.allCases) { pos in
                  Text(pos.displayName).tag(pos.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(width: 140)
            }

            SettingRow(
              icon: "clock",
              title: L10n.PreferencesCapture.displayDurationTitle,
              description: L10n.PreferencesCapture.displayDurationDescription(
                String(format: "%.2g", keystrokeDisplayDuration)
              )
            ) {
              Slider(value: $keystrokeDisplayDuration.stepped(by: 0.25, in: 0.25 ... 10.0), in: 0.25 ... 10.0)
                .frame(width: 140)
            }

            SettingRow(
              icon: "line.3.horizontal.decrease.circle",
              title: L10n.PreferencesCapture.visibilityRuleTitle,
              description: L10n.PreferencesCapture.visibilityRuleDescription
            ) {
              Picker("", selection: $keystrokeVisibility) {
                ForEach(KeystrokeOverlayVisibility.allCases) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .frame(width: 190)
            }

            HStack {
              Spacer()
              Button(L10n.Common.resetToDefault) {
                resetKeystrokeDefaults()
              }
              .font(.system(size: 11))
              .foregroundColor(.secondary)
              .buttonStyle(.plain)
            }
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.audioSection) {
            SettingRow(
              icon: "speaker.wave.3.fill",
              title: L10n.PreferencesCapture.systemAudioTitle,
              description: L10n.PreferencesCapture.systemAudioDescription
            ) {
              Toggle("", isOn: $captureAudio)
                .labelsHidden()
            }

            if captureAudio {
              SettingRow(
                icon: "speaker.wave.2",
                title: L10n.PreferencesCapture.systemAudioVolumeTitle,
                description: L10n.PreferencesCapture.systemAudioVolumeDescription
              ) {
                Slider(value: $recordingSystemAudioVolume, in: 0 ... 1)
                  .frame(width: 150)
              }
            }

            SettingRow(
              icon: "mic.fill",
              title: L10n.Permission.microphone,
              description: L10n.PreferencesCapture.microphoneDescription
            ) {
              Toggle("", isOn: Binding(
                get: { captureMicrophone },
                set: { newValue in
                  if newValue {
                    handleMicrophoneEnable()
                  } else {
                    captureMicrophone = false
                  }
                }
              ))
              .labelsHidden()
            }

            if captureMicrophone {
              SettingRow(
                icon: "mic.and.signal.meter",
                title: L10n.PreferencesCapture.microphoneVolumeTitle,
                description: L10n.PreferencesCapture.microphoneVolumeDescription
              ) {
                Slider(value: $recordingMicrophoneVolume, in: 0 ... 1)
                  .frame(width: 150)
              }
            }
          }
          .alert(L10n.Microphone.accessRequiredTitle, isPresented: $showPermissionDeniedAlert) {
            Button(L10n.Common.openSystemSettings) {
              openMicrophoneSettings()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
          } message: {
            Text(L10n.Microphone.preferencesMessage)
          }
        }

        if selectedPane == .recording {
          Section(L10n.PreferencesCapture.liveAnnotationSection) {
            SettingRow(
              icon: "paintbrush.pointed",
              title: L10n.PreferencesCapture.annotationDefaultColorTitle,
              description: L10n.PreferencesCapture.annotationDefaultColorDescription
            ) {
              ColorPicker(
                "",
                selection: storedColorBinding(
                  key: PreferencesKeys.recordingAnnotationColor,
                  fallback: RecordingAnnotationPreferences.defaultColor
                ),
                supportsOpacity: false
              )
              .labelsHidden()
            }

            SettingRow(
              icon: "lineweight",
              title: L10n.PreferencesCapture.annotationDefaultWidthTitle,
              description: L10n.PreferencesCapture.annotationDefaultWidthDescription
            ) {
              Slider(value: $recordingAnnotationWidth, in: 1 ... 20, step: 1)
                .frame(width: 150)
            }

            SettingRow(
              icon: "trash.slash",
              title: L10n.PreferencesCapture.annotationClearModeTitle,
              description: L10n.PreferencesCapture.annotationClearModeDescription
            ) {
              Picker("", selection: $recordingAnnotationClearMode) {
                Text(L10n.PreferencesCapture.clearModeManual).tag("manual")
                Text(L10n.PreferencesCapture.clearModeAfterTime).tag("afterSeconds")
                Text(L10n.PreferencesCapture.clearModeMaximumCount).tag("maximumCount")
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            if recordingAnnotationClearMode == "afterSeconds" {
              SettingRow(
                icon: "timer",
                title: L10n.PreferencesCapture.clearDelayTitle,
                description: L10n.PreferencesCapture.clearDelayDescription
              ) {
                Stepper(value: $recordingAnnotationClearSeconds, in: 1 ... 300, step: 1) {
                  Text("\(Int(recordingAnnotationClearSeconds)) s")
                    .monospacedDigit()
                }
                .frame(width: 120)
              }
            }

            if recordingAnnotationClearMode == "maximumCount" {
              SettingRow(
                icon: "number",
                title: L10n.PreferencesCapture.annotationMaxCountTitle,
                description: L10n.PreferencesCapture.annotationMaxCountDescription
              ) {
                Stepper(value: $recordingAnnotationMaxCount, in: 1 ... 100) {
                  Text("\(recordingAnnotationMaxCount)")
                    .monospacedDigit()
                }
                .frame(width: 110)
              }
            }

            SettingRow(
              icon: "circle.dotted",
              title: L10n.PreferencesCapture.fadeBeforeClearingTitle,
              description: L10n.PreferencesCapture.fadeBeforeClearingDescription
            ) {
              Toggle("", isOn: $recordingAnnotationFadeEnabled)
                .labelsHidden()
            }

            if recordingAnnotationFadeEnabled {
              SettingRow(
                icon: "clock.arrow.circlepath",
                title: L10n.PreferencesCapture.fadeDurationTitle,
                description: L10n.PreferencesCapture.fadeDurationDescription
              ) {
                Slider(value: $recordingAnnotationFadeDuration, in: 0.05 ... 3, step: 0.05)
                  .frame(width: 150)
              }
            }

            SettingRow(
              icon: "option",
              title: L10n.PreferencesCapture.temporaryModifierTitle,
              description: L10n.PreferencesCapture.temporaryModifierDescription
            ) {
              Picker("", selection: $recordingAnnotationTemporaryModifier) {
                ForEach(RecordingAnnotationTemporaryModifier.allCases) { option in
                  Text(option.displayName).tag(option.rawValue)
                }
              }
              .labelsHidden()
              .pickerStyle(.menu)
            }

            if recordingAnnotationTemporaryModifier != RecordingAnnotationTemporaryModifier.none.rawValue {
              SettingRow(
                icon: "arrow.triangle.2.circlepath",
                title: L10n.PreferencesCapture.temporaryClearModeTitle,
                description: L10n.PreferencesCapture.temporaryClearModeDescription
              ) {
                Picker("", selection: $recordingAnnotationTemporaryClearMode) {
                  Text(L10n.PreferencesCapture.clearModeManual).tag("manual")
                  Text(L10n.PreferencesCapture.clearModeAfterTime).tag("afterSeconds")
                  Text(L10n.PreferencesCapture.clearModeMaximumCount).tag("maximumCount")
                }
                .labelsHidden()
                .pickerStyle(.menu)
              }
            }
          }
        }

        // MARK: - After Capture

        if selectedPane == .general {
          Section(L10n.PreferencesCapture.afterCaptureSection) {
            AfterCaptureMatrixView()
          }
        }
      }
      .formStyle(.grouped)
    }
  }

  // MARK: - Helpers

  private var screenshotFilenamePreview: String {
    let sampleContext = CaptureContext(appName: "Safari", windowTitle: "GitHub")
    let baseName = CaptureOutputNaming.resolveTemplateBaseName(
      previewTemplate(screenshotFileNameTemplate, kind: .screenshot),
      kind: .screenshot,
      context: sampleContext
    )
    return "\(baseName).\(screenshotFileExtension)"
  }

  private var recordingFilenamePreview: String {
    let sampleContext = CaptureContext(appName: "Safari", windowTitle: "GitHub")
    let baseName = CaptureOutputNaming.resolveTemplateBaseName(
      previewTemplate(recordingFileNameTemplate, kind: .recording),
      kind: .recording,
      context: sampleContext
    )
    return "\(baseName).\(recordingFileExtension)"
  }

  private func previewTemplate(_ template: String, kind: CaptureOutputKind) -> String {
    template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? kind.defaultTemplate
      : template
  }

  private var screenshotFileExtension: String {
    ImageFormatOption(rawValue: screenshotFormat)?.format.fileExtension ?? "png"
  }

  private var recordingFileExtension: String {
    VideoFormat(rawValue: format)?.fileExtension ?? "mov"
  }

  private func handleMicrophoneEnable() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)

    switch status {
    case .notDetermined:
      Task {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
          if granted {
            captureMicrophone = true
          } else {
            showPermissionDeniedAlert = true
          }
        }
      }
    case .authorized:
      captureMicrophone = true
    case .denied, .restricted:
      showPermissionDeniedAlert = true
    @unknown default:
      captureMicrophone = true
    }
  }

  private func openMicrophoneSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Reset Defaults

  private func resetOutputNamingDefaults() {
    screenshotFileNameTemplate = CaptureOutputKind.screenshot.defaultTemplate
    recordingFileNameTemplate = CaptureOutputKind.recording.defaultTemplate
  }

  private func resetMouseHighlightDefaults() {
    mouseHighlightSize = MouseHighlightConfiguration.defaultHighlightSize
    mouseHighlightAnimDuration = MouseHighlightConfiguration.defaultAnimationDuration
    mouseHighlightRippleCount = MouseHighlightConfiguration.defaultRippleCount
    mouseHighlightOpacity = MouseHighlightConfiguration.defaultHighlightOpacity
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.mouseHighlightLeftColor)
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.mouseHighlightRightColor)
  }

  private func resetKeystrokeDefaults() {
    keystrokeFontSize = KeystrokeOverlayConfiguration.defaultFontSize
    keystrokePosition = KeystrokeOverlayConfiguration.defaultPosition.rawValue
    keystrokeDisplayDuration = KeystrokeOverlayConfiguration.defaultDisplayDuration
    keystrokeVisibility = KeystrokeOverlayConfiguration.defaultVisibility.rawValue
  }
}

#Preview {
  CaptureSettingsView()
    .frame(width: 600, height: 550)
}
