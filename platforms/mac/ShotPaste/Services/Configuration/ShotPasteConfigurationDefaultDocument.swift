//
//  ShotPasteConfigurationDefaultDocument.swift
//  ShotPaste
//
//  Builds a complete default TOML configuration for restore-defaults flows.
//

import AppKit
import Foundation

@MainActor
enum ShotPasteConfigurationDefaultDocument {
  static func toml() -> String {
    var writer = SimpleTOMLWriter()
    writer.root("schema_version", 1)
    writer.root(
      "shotpaste_min_version",
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    )

    writeGeneral(&writer)
    writeCapture(&writer)
    writeRecording(&writer)
    writeQuickAccess(&writer)
    writeHistory(&writer)
    writeShortcuts(&writer)

    return writer.output
  }

  private static func writeGeneral(_ writer: inout SimpleTOMLWriter) {
    writer.section("general")
    writer.value("language", "system")
    writer.value("appearance", "system")
    writer.value("play_sounds", true)
    writer.value("url_scheme_enabled", true)
    writer.value("show_menu_bar_icon", true)
    writer.value("start_at_login", false)
    writer.value("export_location", SandboxFileAccessManager.shared.defaultExportDirectory.path)

    writer.section("updates")
    writer.value("check_automatically", true)
    writer.value("download_automatically", false)

    writer.section("diagnostics")
    writer.value("enabled", true)
    writer.value("retention_days", LogCleanupScheduler.defaultRetentionDays)
  }

  private static func writeCapture(_ writer: inout SimpleTOMLWriter) {
    writer.section("capture")
    writer.value("hide_desktop_icons", false)
    writer.value("hide_desktop_widgets", false)

    writer.section("capture.naming")
    writer.value("screenshot_template", CaptureOutputKind.screenshot.defaultTemplate)
    writer.value("recording_template", CaptureOutputKind.recording.defaultTemplate)

    writer.section("capture.screenshot")
    writer.value("format", ImageFormatOption.png.rawValue)
    writer.value("include_shotpaste", false)
    writer.value("show_cursor", false)
    writer.value("window_targeting", true)
    writer.value("magnifier_enabled", true)
    writer.value("magnifier_zoom", 1)
    writer.value("output_scale", 0)
    writer.value("color_space", "auto")
    writer.value("lossy_quality", 90)
    writer.value("success_notification", true)

    writer.section("capture.scrolling")
    writer.value("show_hints", true)

    writer.section("capture.ocr")
    writer.value("success_notification", false)
    writer.value("link_detection", true)
    writer.value("language", "auto")

    writer.section("capture.object_cutout")
    writer.value("auto_crop", true)

    writeAfterCapture(&writer, type: .screenshot)
    writeAfterCapture(&writer, type: .recording)
  }

  private static func writeRecording(_ writer: inout SimpleTOMLWriter) {
    writer.section("recording")
    writer.value("format", VideoFormat.mov.rawValue)
    writer.value("quality", VideoQuality.high.rawValue)
    writer.value("fps", 30)
    writer.value("video_codec", "h264")
    writer.value("gif_fps", 15)
    writer.value("output_mode", RecordingOutputMode.video.rawValue)
    writer.value("capture_system_audio", true)
    writer.value("capture_microphone", false)
    writer.value("system_audio_volume", 0.8)
    writer.value("microphone_volume", 0.8)
    writer.value("microphone_device_id", "")
    writer.value("include_shotpaste", false)
    writer.value("show_cursor", true)
    writer.value("highlight_clicks", false)
    writer.value("show_keystrokes", false)
    writer.section("recording.mouse_highlight")
    writer.value("size", 48)
    writer.value("animation_duration", 0.42)
    writer.value(
      "left_color",
      ShotPasteConfigurationColor.hexString(from: MouseHighlightConfiguration.defaultLeftHighlightColor)
    )
    writer.value(
      "right_color",
      ShotPasteConfigurationColor.hexString(from: MouseHighlightConfiguration.defaultRightHighlightColor)
    )
    writer.value("opacity", 0.72)
    writer.value("ripple_count", 2)

    writer.section("recording.keystrokes")
    writer.value("font_size", Double(KeystrokeOverlayConfiguration.defaultFontSize))
    writer.value("position", KeystrokeOverlayConfiguration.defaultPosition.rawValue)
    writer.value("display_duration", KeystrokeOverlayConfiguration.defaultDisplayDuration)
    writer.value("visibility", KeystrokeOverlayConfiguration.defaultVisibility.rawValue)

    writer.section("recording.annotation")
    writer.value("color", ShotPasteConfigurationColor.hexString(from: RecordingAnnotationPreferences.defaultColor))
    writer.value("width", RecordingAnnotationPreferences.defaultWidth)
    writer.value("clear_mode", "manual")
    writer.value("clear_seconds", RecordingAnnotationPreferences.defaultClearSeconds)
    writer.value("max_count", RecordingAnnotationPreferences.defaultMaxCount)
    writer.value("fade_enabled", true)
    writer.value("fade_duration", 0.35)
    writer.value("temporary_modifier", RecordingAnnotationTemporaryModifier.shift.rawValue)
    writer.value("temporary_clear_mode", "manual")
  }

  private static func writeQuickAccess(_ writer: inout SimpleTOMLWriter) {
    writer.section("quick_access")
    writer.value("enabled", true)
    writer.value("position", QuickAccessPosition.bottomRight.rawValue)
    writer.value("auto_dismiss", true)
    writer.value("auto_dismiss_delay", 10)
    writer.value("pause_countdown_on_hover", true)
    writer.value("overlay_scale", 1.0)
    writer.value("drag_drop", true)
    writer.value("two_finger_swipe_to_dismiss", true)
    writer.value("swipe_sensitivity", 1.0)
    writer.value("trackpad_swipe_mode", QuickAccessTrackpadSwipeMode.inverted.rawValue)
    writer.value("swipe_left_action", "dismiss")
    writer.value("swipe_right_action", "dismiss")
    writer.value("hide_card_when_window_open", true)
    writer.value("animation_style", "slide")
    writer.stringArray("actions_order", QuickAccessActionKind.defaultOrder.map(\.rawValue))
    writer.stringArray("enabled_actions", QuickAccessActionKind.defaultEnabledActions.map(\.rawValue).sorted())

    writer.section("quick_access.slots")
    for slot in QuickAccessActionSlot.allCases {
      writer.value(slot.configKey, QuickAccessActionSlot.defaultAssignments[slot]?.rawValue ?? "")
    }
  }

  private static func writeHistory(_ writer: inout SimpleTOMLWriter) {
    writer.section("history")
    writer.value("enabled", true)
    writer.value("media_clipboard_enabled", true)
    writer.value("retention_days", 0)
    writer.value("max_count", 0)
    writer.value("background_style", HistoryBackgroundStyle.defaultStyle.rawValue)

    writer.section("history.floating")
    writer.value("enabled", true)
    writer.value("position", HistoryPanelPosition.topCenter.rawValue)
    writer.value("default_filter", CaptureHistoryCategory.clipboard.rawValue)
    writer.value("max_displayed_items", 10)
    writer.value("scale", HistoryFloatingLayout.defaultScale)
  }

  private static func writeShortcuts(_ writer: inout SimpleTOMLWriter) {
    writer.section("shortcuts")
    writer.value("enabled", false)

    for kind in GlobalShortcutKind.allCases {
      writeGlobalShortcut(&writer, kind: kind)
    }
  }

  private static func writeAfterCapture(_ writer: inout SimpleTOMLWriter, type: CaptureType) {
    writer.section("capture.after.\(type.rawValue)")
    writer.value("save", true)
    writer.value("quick_access", true)
    writer.value("copy_file", true)
  }

  private static func writeGlobalShortcut(_ writer: inout SimpleTOMLWriter, kind: GlobalShortcutKind) {
    writer.section("shortcuts.global.\(kind.configKey)")
    writer.value("enabled", true)
    writeShortcutValues(&writer, shortcut: globalShortcut(for: kind))
  }

  private static func writeShortcutValues(_ writer: inout SimpleTOMLWriter, shortcut: ShortcutConfig?) {
    guard let shortcut else {
      writer.value("key", "")
      writer.stringArray("modifiers", [])
      return
    }

    writer.value("key", ShotPasteConfigurationShortcutCodec.exportKey(shortcut))
    writer.stringArray("modifiers", ShotPasteConfigurationShortcutCodec.exportModifiers(shortcut))
  }

  private static func globalShortcut(for kind: GlobalShortcutKind) -> ShortcutConfig? {
    switch kind {
    case .oneShot: .defaultOneShot
    case .pauseResumeRecording: nil
    case .togglePenRecording: nil
    case .restartRecording: nil
    case .deleteRecording: nil
    case .history: .defaultHistory
    }
  }
}
