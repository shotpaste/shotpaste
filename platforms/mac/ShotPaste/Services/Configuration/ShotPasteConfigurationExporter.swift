//
//  ShotPasteConfigurationExporter.swift
//  ShotPaste
//
//  Builds deterministic TOML from current app configuration.
//

import AppKit
import Foundation

@MainActor
enum ShotPasteConfigurationExporter {
  static func exportTOML(defaults: UserDefaults = .standard) -> String {
    var writer = SimpleTOMLWriter()
    writer.root("schema_version", 1)
    writer.root(
      "shotpaste_min_version",
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    )

    writeGeneral(&writer, defaults: defaults)
    writeCapture(&writer, defaults: defaults)
    writeRecording(&writer, defaults: defaults)
    writeQuickAccess(&writer)
    writeHistory(&writer, defaults: defaults)
    writeShortcuts(&writer)

    return writer.output
  }

  private static func writeGeneral(_ writer: inout SimpleTOMLWriter, defaults: UserDefaults) {
    writer.section("general")
    writer.value("language", language(defaults: defaults))
    writer.value("appearance", appearance(defaults: defaults))
    writer.value("play_sounds", defaults.object(forKey: PreferencesKeys.playSounds) as? Bool ?? true)
    writer.value("url_scheme_enabled", defaults.object(forKey: PreferencesKeys.urlSchemeEnabled) as? Bool ?? true)
    writer.value("mcp_server_enabled", defaults.object(forKey: PreferencesKeys.mcpServerEnabled) as? Bool ?? false)
    writer.value(
      "mcp_server_port",
      defaults.integerValue(PreferencesKeys.mcpServerPort, default: ShotPasteMCPServer.defaultPort)
    )
    writer.value("show_menu_bar_icon", defaults.object(forKey: PreferencesKeys.showMenuBarIcon) as? Bool ?? true)
    writer.value("start_at_login", LoginItemManager.isEnabled)
    writer.value(
      "export_location",
      ShotPasteConfigurationPaths.collapsingHomePath(SandboxFileAccessManager.shared.exportLocationPath)
    )

    writer.section("diagnostics")
    writer.value("enabled", defaults.object(forKey: PreferencesKeys.diagnosticsEnabled) as? Bool ?? true)
    writer.value(
      "retention_days",
      defaults.object(forKey: PreferencesKeys.diagnosticsRetentionDays) as? Int
        ?? LogCleanupScheduler.defaultRetentionDays
    )
  }

  private static func writeCapture(_ writer: inout SimpleTOMLWriter, defaults: UserDefaults) {
    writer.section("capture")
    writer.value("hide_desktop_icons", defaults.boolValue(PreferencesKeys.hideDesktopIcons, default: false))
    writer.value("hide_desktop_widgets", defaults.boolValue(PreferencesKeys.hideDesktopWidgets, default: false))

    writer.section("capture.naming")
    writer.value("screenshot_template", CaptureOutputNaming.resolvedTemplate(for: .screenshot, defaults: defaults))
    writer.value("recording_template", CaptureOutputNaming.resolvedTemplate(for: .recording, defaults: defaults))

    writer.section("capture.screenshot")
    writer.value("format", defaults.string(forKey: PreferencesKeys.screenshotFormat) ?? ImageFormatOption.png.rawValue)
    writer.value("include_shotpaste", defaults.boolValue(PreferencesKeys.screenshotIncludeOwnApp, default: false))
    writer.value("show_cursor", defaults.boolValue(PreferencesKeys.screenshotShowCursor, default: false))
    writer.value("magnifier_enabled", defaults.boolValue(PreferencesKeys.screenshotMagnifierEnabled, default: true))
    writer.value("magnifier_zoom", defaults.integerValue(PreferencesKeys.screenshotMagnifierZoom, default: 1))
    writer.value("output_scale", defaults.integerValue(PreferencesKeys.screenshotScale, default: 0))
    writer.value("color_space", defaults.string(forKey: PreferencesKeys.screenshotColorSpace) ?? "auto")
    writer.value("lossy_quality", defaults.integerValue(PreferencesKeys.screenshotLossyQuality, default: 90))
    writer.value(
      "success_notification",
      defaults.boolValue(PreferencesKeys.screenshotSuccessNotificationEnabled, default: true)
    )

    writer.section("capture.scrolling")
    writer.value("show_hints", defaults.boolValue(PreferencesKeys.scrollingCaptureShowHints, default: true))

    writer.section("capture.ocr")
    writer.value(
      "success_notification",
      defaults.boolValue(PreferencesKeys.ocrSuccessNotificationEnabled, default: false)
    )
    writer.value("link_detection", defaults.boolValue(PreferencesKeys.ocrLinkDetectionEnabled, default: true))
    writer.value("language", defaults.string(forKey: PreferencesKeys.ocrRecognitionLanguage) ?? "auto")

    writeAfterCapture(&writer, type: .screenshot)
    writeAfterCapture(&writer, type: .recording)
  }

  private static func writeRecording(_ writer: inout SimpleTOMLWriter, defaults: UserDefaults) {
    writer.section("recording")
    writer.value("format", RecordingToolbarPreferences.selectedFormat(defaults: defaults).rawValue)
    writer.value("quality", RecordingToolbarPreferences.selectedQuality(defaults: defaults).rawValue)
    writer.value("fps", defaults.integerValue(PreferencesKeys.recordingFPS, default: 30))
    writer.value("video_codec", defaults.string(forKey: PreferencesKeys.recordingVideoCodec) ?? "h264")
    writer.value("gif_fps", defaults.integerValue(PreferencesKeys.recordingGIFFPS, default: 15))
    writer.value("output_mode", RecordingToolbarPreferences.outputMode(defaults: defaults).rawValue)
    writer.value("capture_system_audio", RecordingToolbarPreferences.captureAudio(defaults: defaults))
    writer.value("capture_microphone", RecordingToolbarPreferences.captureMicrophone(defaults: defaults))
    writer.value("system_audio_volume", defaults.doubleValue(PreferencesKeys.recordingSystemAudioVolume, default: 0.8))
    writer.value("microphone_volume", defaults.doubleValue(PreferencesKeys.recordingMicrophoneVolume, default: 0.8))
    writer.value("microphone_device_id", RecordingToolbarPreferences.microphoneDeviceID(defaults: defaults))
    writer.value("include_shotpaste", defaults.boolValue(PreferencesKeys.recordingIncludeOwnApp, default: false))
    writer.value("show_cursor", RecordingToolbarPreferences.showCursor(defaults: defaults))
    writer.value("dim_non_selected_area", RecordingToolbarPreferences.dimNonSelectedArea(defaults: defaults))
    writer.value("highlight_clicks", RecordingToolbarPreferences.highlightClicks(defaults: defaults))
    writer.value("show_keystrokes", RecordingToolbarPreferences.showKeystrokes(defaults: defaults))
    writer.section("recording.mouse_highlight")
    let leftColor = storedColor(
      key: PreferencesKeys.mouseHighlightLeftColor,
      fallback: MouseHighlightConfiguration.defaultLeftHighlightColor,
      defaults: defaults
    )
    let rightColor = storedColor(
      key: PreferencesKeys.mouseHighlightRightColor,
      fallback: MouseHighlightConfiguration.defaultRightHighlightColor,
      defaults: defaults
    )
    writer.value("size", defaults.doubleValue(PreferencesKeys.mouseHighlightSize, default: 48))
    writer.value(
      "animation_duration",
      defaults.doubleValue(PreferencesKeys.mouseHighlightAnimationDuration, default: 0.42)
    )
    writer.value("left_color", ShotPasteConfigurationColor.hexString(from: leftColor))
    writer.value("right_color", ShotPasteConfigurationColor.hexString(from: rightColor))
    writer.value("opacity", defaults.doubleValue(PreferencesKeys.mouseHighlightOpacity, default: 0.72))
    writer.value("ripple_count", defaults.integerValue(PreferencesKeys.mouseHighlightRippleCount, default: 2))

    writer.section("recording.keystrokes")
    writer.value("font_size", defaults.doubleValue(PreferencesKeys.keystrokeFontSize, default: 18))
    writer.value(
      "position",
      defaults.string(forKey: PreferencesKeys.keystrokePosition) ?? KeystrokeOverlayPosition.bottomCenter.rawValue
    )
    writer.value("display_duration", defaults.doubleValue(PreferencesKeys.keystrokeDisplayDuration, default: 1.25))
    writer.value(
      "visibility",
      defaults.string(forKey: PreferencesKeys.keystrokeVisibility)
        ?? KeystrokeOverlayVisibility.specialAndShortcuts.rawValue
    )

    writer.section("recording.annotation")
    let annotationColor = storedColor(
      key: PreferencesKeys.recordingAnnotationColor,
      fallback: RecordingAnnotationPreferences.defaultColor,
      defaults: defaults
    )
    writer.value("color", ShotPasteConfigurationColor.hexString(from: annotationColor))
    writer.value("width", defaults.doubleValue(PreferencesKeys.recordingAnnotationWidth, default: 4))
    writer.value("clear_mode", defaults.string(forKey: PreferencesKeys.recordingAnnotationClearMode) ?? "manual")
    writer.value("clear_seconds", defaults.doubleValue(PreferencesKeys.recordingAnnotationClearSeconds, default: 5))
    writer.value("max_count", defaults.integerValue(PreferencesKeys.recordingAnnotationMaxCount, default: 12))
    writer.value("fade_enabled", defaults.boolValue(PreferencesKeys.recordingAnnotationFadeEnabled, default: true))
    writer.value("fade_duration", defaults.doubleValue(PreferencesKeys.recordingAnnotationFadeDuration, default: 0.35))
    writer.value(
      "temporary_modifier",
      defaults.string(forKey: PreferencesKeys.recordingAnnotationTemporaryModifier) ?? "shift"
    )
    writer.value(
      "temporary_clear_mode",
      defaults.string(forKey: PreferencesKeys.recordingAnnotationTemporaryClearMode) ?? "manual"
    )
  }

  private static func writeQuickAccess(_ writer: inout SimpleTOMLWriter) {
    let manager = QuickAccessManager.shared
    let actionStore = QuickAccessActionConfigurationStore.shared

    writer.section("quick_access")
    writer.value("enabled", manager.isEnabled)
    writer.value("position", manager.position.rawValue)
    writer.value("auto_dismiss", manager.autoDismissEnabled)
    writer.value("auto_dismiss_delay", manager.autoDismissDelay)
    writer.value("pause_countdown_on_hover", manager.pauseCountdownOnHover)
    writer.value("overlay_scale", manager.overlayScale)
    writer.value("drag_drop", manager.dragDropEnabled)
    writer.value("two_finger_swipe_to_dismiss", manager.twoFingerSwipeToDismissEnabled)
    writer.value("swipe_sensitivity", manager.swipeSensitivity)
    writer.value("trackpad_swipe_mode", QuickAccessTrackpadSwipeModeStore.shared.mode.rawValue)
    writer.value("swipe_left_action", QuickAccessSwipeActionStore.shared.swipeLeftAction?.rawValue ?? "none")
    writer.value("swipe_right_action", QuickAccessSwipeActionStore.shared.swipeRightAction?.rawValue ?? "none")
    writer.value("hide_card_when_window_open", manager.hideCardWhenWindowOpen)
    writer.value("animation_style", manager.animationStyle.rawValue)
    writer.stringArray("actions_order", actionStore.actionOrder.map(\.rawValue))
    writer.stringArray("enabled_actions", actionStore.enabledActions.map(\.rawValue).sorted())

    writer.section("quick_access.slots")
    for slot in QuickAccessActionSlot.allCases {
      writer.value(slot.configKey, actionStore.slotAssignments[slot]?.rawValue ?? "")
    }
  }

  private static func writeHistory(_ writer: inout SimpleTOMLWriter, defaults: UserDefaults) {
    let manager = HistoryFloatingManager.shared
    writer.section("history")
    writer.value("enabled", defaults.boolValue(PreferencesKeys.historyEnabled, default: true))
    writer.value(
      "retention_days",
      defaults.integerValue(
        PreferencesKeys.historyRetentionDays,
        default: PreferencesKeys.defaultHistoryRetentionDays
      )
    )
    writer.value(
      "max_count",
      defaults.integerValue(PreferencesKeys.historyMaxCount, default: PreferencesKeys.defaultHistoryMaxCount)
    )
    writer.value("media_clipboard_enabled", defaults.boolValue(PreferencesKeys.mediaClipboardEnabled, default: true))
    writer.value("background_style", HistoryBackgroundStyle.currentStoredStyle(userDefaults: defaults).rawValue)

    writer.section("history.floating")
    writer.value("position", manager.position.rawValue)
    writer.value("default_filter", manager.defaultFilter?.rawValue ?? CaptureHistoryCategory.clipboard.rawValue)
    writer.value("scale", manager.panelScale)
  }

  private static func language(defaults: UserDefaults) -> String {
    guard
      let languages = defaults.array(forKey: "AppleLanguages") as? [String],
      let first = languages.first,
      let normalized = AppLanguageManager.normalizedLanguageIdentifier(from: first)
    else {
      return "system"
    }
    return normalized
  }

  private static func appearance(defaults: UserDefaults) -> String {
    switch defaults.string(forKey: PreferencesKeys.appearanceMode) {
    case AppearanceMode.light.rawValue: "light"
    case AppearanceMode.dark.rawValue: "dark"
    default: "system"
    }
  }

  private static func writeAfterCapture(_ writer: inout SimpleTOMLWriter, type: CaptureType) {
    writer.section("capture.after.\(type.rawValue)")
    let manager = PreferencesManager.shared
    writer.value("save", manager.isActionEnabled(.save, for: type))
    writer.value("quick_access", manager.isActionEnabled(.showQuickAccess, for: type))
    writer.value("copy_file", manager.isActionEnabled(.copyFile, for: type))
  }

  private static func storedColor(key: String, fallback: NSColor, defaults: UserDefaults) -> NSColor {
    guard let data = defaults.data(forKey: key),
          let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
      return fallback
    }
    return color
  }
}

private extension UserDefaults {
  func boolValue(_ key: String, default defaultValue: Bool) -> Bool {
    object(forKey: key) as? Bool ?? defaultValue
  }

  func integerValue(_ key: String, default defaultValue: Int) -> Int {
    object(forKey: key) as? Int ?? defaultValue
  }

  func doubleValue(_ key: String, default defaultValue: Double) -> Double {
    object(forKey: key) as? Double ?? defaultValue
  }
}
