//
//  KeystrokeMonitorService.swift
//  LiteScreen
//
//  Detects global keyboard events and builds human-readable keystroke
//  display strings (e.g. "⌘ ⇧ S") for the keystroke overlay.
//

import AppKit
import Foundation

@MainActor
final class KeystrokeMonitorService {
  private var globalKeyDownMonitor: Any?
  private var localKeyDownMonitor: Any?
  private var isRunning = false

  /// Called with the formatted keystroke string (e.g. "⌘ ⇧ S")
  var onKeystroke: ((String) -> Void)?

  private let visibility: KeystrokeOverlayVisibility

  init(visibility: KeystrokeOverlayVisibility = .specialAndShortcuts) {
    self.visibility = visibility
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true

    globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.keyDown]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleKeyDown(event)
      }
    }

    localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleKeyDown(event)
      }
      return event
    }
  }

  func stop() {
    isRunning = false

    if let m = globalKeyDownMonitor {
      NSEvent.removeMonitor(m)
    }
    if let m = localKeyDownMonitor {
      NSEvent.removeMonitor(m)
    }
    globalKeyDownMonitor = nil
    localKeyDownMonitor = nil
    onKeystroke = nil
  }

  // MARK: - Event Processing

  private func handleKeyDown(_ event: NSEvent) {
    // Ignore key repeats to avoid spamming
    guard !event.isARepeat else { return }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasCommand = flags.contains(.command)
    let hasOption = flags.contains(.option)
    let hasControl = flags.contains(.control)
    let hasShift = flags.contains(.shift)

    let hasModifier = hasCommand || hasOption || hasControl

    // Resolve key name from keyCode (reliable for both local and global monitors).
    // event.charactersIgnoringModifiers can return nil in global monitors when
    // multiple modifiers are held, so we use keyCode-based lookup as primary source.
    let keyName = Self.keyDisplayName(for: event.keyCode, event: event)

    let isSpecialKey = Self.isSpecialKey(event.keyCode)
    let shouldShow = switch visibility {
    case .all:
      true
    case .specialAndShortcuts:
      hasModifier || isSpecialKey
    case .shortcutsOnly:
      hasModifier
    case .specialOnly:
      isSpecialKey
    }
    guard shouldShow else { return }

    // Build display string: modifiers first, then key
    var parts: [String] = []
    if hasControl {
      parts.append("⌃")
    }
    if hasOption {
      parts.append("⌥")
    }
    if hasShift {
      parts.append("⇧")
    }
    if hasCommand {
      parts.append("⌘")
    }

    if let keyName {
      parts.append(keyName)
    }

    guard !parts.isEmpty else { return }
    let displayString = parts.joined(separator: " ")
    onKeystroke?(displayString)
  }

  // MARK: - Key Code Mapping

  /// Whether the keyCode is a special key (Return, Tab, arrows, function keys, etc.)
  private static func isSpecialKey(_ keyCode: UInt16) -> Bool {
    specialKeyName(for: keyCode) != nil
  }

  /// Resolve a display name for the given keyCode.
  /// Priority: special key symbol → ShortcutConfig keyCode map → charactersIgnoringModifiers fallback.
  private static func keyDisplayName(for keyCode: UInt16, event: NSEvent) -> String? {
    // 1. Special keys (Return, Tab, Arrows, F-keys, etc.)
    if let special = specialKeyName(for: keyCode) {
      return special
    }

    // 2. KeyCode-based lookup via ShortcutConfig using the active keyboard layout.
    let mapped = ShortcutConfig.keyCodeToDisplayString(UInt32(keyCode))
    if mapped != "?" {
      return mapped
    }

    // 3. Last resort: use event characters (may be nil in global monitors)
    if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
      return chars.uppercased()
    }

    return nil
  }

  /// Maps macOS virtual key codes to human-readable special key symbols
  private static func specialKeyName(for keyCode: UInt16) -> String? {
    switch keyCode {
    case 36: "⏎" // Return
    case 48: "⇥" // Tab
    case 49: "␣" // Space
    case 51: "⌫" // Delete
    case 53: "⎋" // Escape
    case 76: "⌤" // Enter (numpad)
    case 117: "⌦" // Forward Delete
    // Arrow keys
    case 123: "←"
    case 124: "→"
    case 125: "↓"
    case 126: "↑"
    // Function keys
    case 122: "F1"
    case 120: "F2"
    case 99: "F3"
    case 118: "F4"
    case 96: "F5"
    case 97: "F6"
    case 98: "F7"
    case 100: "F8"
    case 101: "F9"
    case 109: "F10"
    case 103: "F11"
    case 111: "F12"
    // Navigation
    case 115: "Home"
    case 119: "End"
    case 116: "PgUp"
    case 121: "PgDn"
    default: nil
    }
  }
}
