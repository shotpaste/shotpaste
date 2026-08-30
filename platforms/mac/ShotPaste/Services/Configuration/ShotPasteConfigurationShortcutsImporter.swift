//
//  ShotPasteConfigurationShortcutsImporter.swift
//  ShotPaste
//
//  Shortcut import helpers for TOML configuration.
//

import Foundation

@MainActor
extension ShotPasteConfigurationImporter {
  static func collectShortcuts(
    _ reader: inout ShotPasteConfigurationReader,
    mutations: inout [() -> Void]
  ) {
    if let enabled = reader.bool("shortcuts", "enabled") {
      mutations.append {
        enabled ? KeyboardShortcutManager.shared.enable() : KeyboardShortcutManager.shared.disable()
      }
    }

    for kind in GlobalShortcutKind.allCases {
      collectGlobalShortcut(&reader, kind: kind, mutations: &mutations)
    }
  }

  static func quickAccessSlots(
    from reader: inout ShotPasteConfigurationReader
  ) -> [QuickAccessActionSlot: QuickAccessActionKind]? {
    var assignments: [QuickAccessActionSlot: QuickAccessActionKind] = [:]
    var sawValue = false

    for slot in QuickAccessActionSlot.allCases {
      guard let raw = reader.string(["quick_access", "slots", slot.configKey]) else { continue }
      sawValue = true
      if raw.isEmpty {
        continue
      }
      guard let action = QuickAccessActionKind(rawValue: raw) else {
        reader.error("quick_access.slots.\(slot.configKey) is not a known Quick Access action")
        continue
      }
      assignments[slot] = action
    }

    return sawValue ? assignments : nil
  }

  private static func collectGlobalShortcut(
    _ reader: inout ShotPasteConfigurationReader,
    kind: GlobalShortcutKind,
    mutations: inout [() -> Void]
  ) {
    let path = ["shortcuts", "global", kind.configKey]
    let key = reader.string(path + ["key"])
    let modifiers = reader.stringArray(path + ["modifiers"])
    let enabled = reader.bool(path + ["enabled"])

    guard key != nil || modifiers != nil || enabled != nil else { return }
    guard key != nil || modifiers == nil else {
      reader.error("shortcuts.global.\(kind.configKey).modifiers requires key")
      return
    }

    if let key, key.isEmpty {
      mutations.append {
        KeyboardShortcutManager.shared.setShortcut(nil, for: kind)
        KeyboardShortcutManager.shared.setShortcutEnabled(false, for: kind)
      }
      return
    }

    if let key {
      guard let shortcut = ShotPasteConfigurationShortcutCodec.shortcut(
        key: key,
        modifiers: modifiers ?? [],
        requireModifier: true
      ) else {
        reader.error("shortcuts.global.\(kind.configKey) has an invalid shortcut")
        return
      }
      mutations.append { KeyboardShortcutManager.shared.setShortcut(shortcut, for: kind) }
    }

    if let enabled {
      mutations.append { KeyboardShortcutManager.shared.setShortcutEnabled(enabled, for: kind) }
    }
  }
}

extension QuickAccessActionSlot {
  var configKey: String {
    switch self {
    case .centerTop: "center_top"
    case .centerBottom: "center_bottom"
    case .topTrailing: "top_trailing"
    case .topLeading: "top_leading"
    case .bottomLeading: "bottom_leading"
    case .bottomTrailing: "bottom_trailing"
    }
  }
}

extension GlobalShortcutKind {
  var configKey: String {
    switch self {
    case .oneShot: "one_shot"
    case .translation: "translation"
    case .agentMode: "agent_mode"
    case .pauseResumeRecording: "pause_resume_recording"
    case .togglePenRecording: "toggle_pen_recording"
    case .restartRecording: "restart_recording"
    case .deleteRecording: "delete_recording"
    case .history: "history"
    }
  }
}

@MainActor
private extension KeyboardShortcutManager {
  func setShortcut(_ config: ShortcutConfig?, for kind: GlobalShortcutKind) {
    switch kind {
    case .oneShot:
      setOneShotShortcut(config)
    case .translation:
      setTranslationShortcut(config)
    case .agentMode:
      setAgentModeShortcut(config)
    case .pauseResumeRecording:
      setPauseResumeRecordingShortcut(config)
    case .togglePenRecording:
      setTogglePenRecordingShortcut(config)
    case .restartRecording:
      setRestartRecordingShortcut(config)
    case .deleteRecording:
      setDeleteRecordingShortcut(config)
    case .history:
      setHistoryShortcut(config)
    }
  }
}
