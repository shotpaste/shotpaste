//
//  ShotPasteConfigurationShortcutsExporter.swift
//  ShotPaste
//
//  Shortcut TOML export helpers.
//

import Foundation

@MainActor
extension ShotPasteConfigurationExporter {
  static func writeShortcuts(_ writer: inout SimpleTOMLWriter) {
    let manager = KeyboardShortcutManager.shared
    writer.section("shortcuts")
    writer.value("enabled", manager.isEnabled)

    for kind in GlobalShortcutKind.allCases {
      writeGlobalShortcut(&writer, kind: kind, manager: manager)
    }
  }

  private static func writeGlobalShortcut(
    _ writer: inout SimpleTOMLWriter,
    kind: GlobalShortcutKind,
    manager: KeyboardShortcutManager
  ) {
    writer.section("shortcuts.global.\(kind.configKey)")
    writer.value("enabled", manager.isShortcutEnabled(for: kind))

    guard let shortcut = manager.shortcut(for: kind) else {
      writer.value("key", "")
      writer.stringArray("modifiers", [])
      return
    }

    writer.value("key", ShotPasteConfigurationShortcutCodec.exportKey(shortcut))
    writer.stringArray("modifiers", ShotPasteConfigurationShortcutCodec.exportModifiers(shortcut))
  }
}

extension GlobalShortcutKind {
  var configKey: String {
    switch self {
    case .oneShot: "one_shot"
    case .pauseResumeRecording: "pause_resume_recording"
    case .togglePenRecording: "toggle_pen_recording"
    case .restartRecording: "restart_recording"
    case .deleteRecording: "delete_recording"
    case .history: "history"
    }
  }
}
