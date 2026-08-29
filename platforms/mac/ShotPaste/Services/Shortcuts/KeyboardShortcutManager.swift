//
//  KeyboardShortcutManager.swift
//  ShotPaste
//
//  Manages global keyboard shortcuts for screen capture
//

import AppKit
import Carbon.HIToolbox

/// Represents a keyboard shortcut configuration
struct ShortcutConfig: Equatable, Codable {
  let keyCode: UInt32
  let modifiers: UInt32

  /// Custom bit used to store the Fn modifier flag.
  /// Carbon does not provide a native Fn constant, so we use an otherwise-unused bit internally.
  static let functionCarbonModifier: UInt32 = 0x2000

  /// Debug adds Option so its first-launch global shortcuts do not contend with
  /// the simultaneously running Release app. Release keeps its existing bindings.
  static func defaultModifiers(for variant: AppVariant) -> UInt32 {
    let releaseModifiers = UInt32(cmdKey | shiftKey)
    return variant == .debug
      ? releaseModifiers | UInt32(optionKey)
      : releaseModifiers
  }

  private static var defaultVariantModifiers: UInt32 {
    defaultModifiers(for: .current)
  }

  /// Memberwise initializer
  init(keyCode: UInt32, modifiers: UInt32) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  /// Suggested value only; the shortcut ships unbound (cleared) by default.
  static let defaultPauseResumeRecording = ShortcutConfig(
    keyCode: UInt32(kVK_Space),
    modifiers: defaultVariantModifiers
  )

  /// Cmd + Shift + 1 in Release; Debug also includes Option.
  static let defaultOneShot = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_1),
    modifiers: defaultVariantModifiers
  )

  /// Option + A. This binding is registered only while Agent Mode is enabled.
  static let defaultAgentMode = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_A),
    modifiers: UInt32(optionKey)
  )

  /// Suggested value only; audio recording ships unbound by default.
  static let defaultStartAudioRecording = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_A),
    modifiers: defaultVariantModifiers
  )

  /// Cmd + Shift + H in Release; Debug also includes Option.
  static let defaultHistory = ShortcutConfig(
    keyCode: UInt32(kVK_ANSI_H),
    modifiers: defaultVariantModifiers
  )

  var displayString: String {
    var parts: [String] = []

    if modifiers & UInt32(cmdKey) != 0 {
      parts.append("⌘")
    }
    if modifiers & UInt32(shiftKey) != 0 {
      parts.append("⇧")
    }
    if modifiers & UInt32(optionKey) != 0 {
      parts.append("⌥")
    }
    if modifiers & UInt32(controlKey) != 0 {
      parts.append("⌃")
    }
    if modifiers & Self.functionCarbonModifier != 0 {
      parts.append("fn")
    }

    let keyChar = Self.keyCodeToDisplayString(keyCode)

    parts.append(keyChar)
    return parts.joined(separator: " ")
  }

  /// Individual key parts for keycap-style rendering
  var displayParts: [String] {
    var parts: [String] = []
    if modifiers & UInt32(cmdKey) != 0 {
      parts.append("⌘")
    }
    if modifiers & UInt32(shiftKey) != 0 {
      parts.append("⇧")
    }
    if modifiers & UInt32(optionKey) != 0 {
      parts.append("⌥")
    }
    if modifiers & UInt32(controlKey) != 0 {
      parts.append("⌃")
    }
    if modifiers & Self.functionCarbonModifier != 0 {
      parts.append("fn")
    }
    parts.append(Self.keyCodeToDisplayString(keyCode))
    return parts
  }

  /// Initialize from NSEvent for shortcut recording
  init?(from event: NSEvent) {
    guard event.type == .keyDown else { return nil }

    // Convert Cocoa modifiers to Carbon modifiers
    var carbonModifiers: UInt32 = 0
    if event.modifierFlags.contains(.command) {
      carbonModifiers |= UInt32(cmdKey)
    }
    if event.modifierFlags.contains(.shift) {
      carbonModifiers |= UInt32(shiftKey)
    }
    if event.modifierFlags.contains(.option) {
      carbonModifiers |= UInt32(optionKey)
    }
    if event.modifierFlags.contains(.control) {
      carbonModifiers |= UInt32(controlKey)
    }
    if event.modifierFlags.contains(.function) {
      carbonModifiers |= Self.functionCarbonModifier
    }

    // Require at least one modifier
    guard carbonModifiers != 0 else { return nil }

    keyCode = UInt32(event.keyCode)
    modifiers = carbonModifiers
  }

  /// Modifier flags that participate in shortcut matching (excludes capsLock, numericPad, etc.).
  private static let matchableEventModifiers: NSEvent.ModifierFlags = [
    .command, .shift, .option, .control, .function,
  ]

  /// Whether a key event exactly matches this shortcut (keyCode + full modifier set, incl. Fn).
  func matches(event: NSEvent) -> Bool {
    guard UInt32(event.keyCode) == keyCode else { return false }
    let flags = event.modifierFlags.intersection(Self.matchableEventModifiers)
    var expected: NSEvent.ModifierFlags = []
    if modifiers & UInt32(cmdKey) != 0 {
      expected.insert(.command)
    }
    if modifiers & UInt32(shiftKey) != 0 {
      expected.insert(.shift)
    }
    if modifiers & UInt32(optionKey) != 0 {
      expected.insert(.option)
    }
    if modifiers & UInt32(controlKey) != 0 {
      expected.insert(.control)
    }
    if modifiers & Self.functionCarbonModifier != 0 {
      expected.insert(.function)
    }
    return flags == expected
  }

  /// Map key code to display character
  static func keyCodeToString(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_ANSI_0: "0"
    case kVK_ANSI_1: "1"
    case kVK_ANSI_2: "2"
    case kVK_ANSI_3: "3"
    case kVK_ANSI_4: "4"
    case kVK_ANSI_5: "5"
    case kVK_ANSI_6: "6"
    case kVK_ANSI_7: "7"
    case kVK_ANSI_8: "8"
    case kVK_ANSI_9: "9"
    case kVK_ANSI_A: "A"
    case kVK_ANSI_B: "B"
    case kVK_ANSI_C: "C"
    case kVK_ANSI_D: "D"
    case kVK_ANSI_E: "E"
    case kVK_ANSI_F: "F"
    case kVK_ANSI_G: "G"
    case kVK_ANSI_H: "H"
    case kVK_ANSI_I: "I"
    case kVK_ANSI_J: "J"
    case kVK_ANSI_K: "K"
    case kVK_ANSI_L: "L"
    case kVK_ANSI_M: "M"
    case kVK_ANSI_N: "N"
    case kVK_ANSI_O: "O"
    case kVK_ANSI_P: "P"
    case kVK_ANSI_Q: "Q"
    case kVK_ANSI_R: "R"
    case kVK_ANSI_S: "S"
    case kVK_ANSI_T: "T"
    case kVK_ANSI_U: "U"
    case kVK_ANSI_V: "V"
    case kVK_ANSI_W: "W"
    case kVK_ANSI_X: "X"
    case kVK_ANSI_Y: "Y"
    case kVK_ANSI_Z: "Z"
    case kVK_F1: "F1"
    case kVK_F2: "F2"
    case kVK_F3: "F3"
    case kVK_F4: "F4"
    case kVK_F5: "F5"
    case kVK_F6: "F6"
    case kVK_F7: "F7"
    case kVK_F8: "F8"
    case kVK_F9: "F9"
    case kVK_F10: "F10"
    case kVK_F11: "F11"
    case kVK_F12: "F12"
    case kVK_F13: "F13"
    case kVK_F14: "F14"
    case kVK_F15: "F15"
    case kVK_F16: "F16"
    case kVK_F17: "F17"
    case kVK_F18: "F18"
    case kVK_F19: "F19"
    case kVK_F20: "F20"
    case kVK_Space: "Space"
    case kVK_Return: "↩"
    case kVK_Tab: "⇥"
    case kVK_Delete: "⌫"
    case kVK_Escape: "⎋"
    case kVK_LeftArrow: "←"
    case kVK_RightArrow: "→"
    case kVK_UpArrow: "↑"
    case kVK_DownArrow: "↓"
    // Punctuation & symbol keys
    case kVK_ANSI_Semicolon: ";"
    case kVK_ANSI_Quote: "'"
    case kVK_ANSI_Comma: ","
    case kVK_ANSI_Period: "."
    case kVK_ANSI_Slash: "/"
    case kVK_ANSI_Backslash: "\\"
    case kVK_ANSI_LeftBracket: "["
    case kVK_ANSI_RightBracket: "]"
    case kVK_ANSI_Minus: "-"
    case kVK_ANSI_Equal: "="
    case kVK_ANSI_Grave: "`"
    // Keypad keys
    case kVK_ANSI_KeypadDecimal: "."
    case kVK_ANSI_KeypadMultiply: "*"
    case kVK_ANSI_KeypadPlus: "+"
    case kVK_ANSI_KeypadDivide: "/"
    case kVK_ANSI_KeypadMinus: "-"
    case kVK_ANSI_KeypadEquals: "="
    case kVK_ANSI_KeypadEnter: "↩"
    case kVK_ANSI_Keypad0: "0"
    case kVK_ANSI_Keypad1: "1"
    case kVK_ANSI_Keypad2: "2"
    case kVK_ANSI_Keypad3: "3"
    case kVK_ANSI_Keypad4: "4"
    case kVK_ANSI_Keypad5: "5"
    case kVK_ANSI_Keypad6: "6"
    case kVK_ANSI_Keypad7: "7"
    case kVK_ANSI_Keypad8: "8"
    case kVK_ANSI_Keypad9: "9"
    // Navigation keys
    case kVK_ForwardDelete: "⌦"
    case kVK_Home: "↖"
    case kVK_End: "↘"
    case kVK_PageUp: "⇞"
    case kVK_PageDown: "⇟"
    case 0x3F: "fn"
    default: "?"
    }
  }

  /// Map key code to the key label users see on their active keyboard layout.
  static func keyCodeToDisplayString(_ keyCode: UInt32) -> String {
    let fallback = keyCodeToString(keyCode)

    if fallback.count != 1, fallback != "?" {
      return fallback
    }

    return currentLayoutPrintableKeyDisplayString(for: keyCode) ?? fallback
  }
}

extension ShortcutConfig {
  var menuKeyEquivalent: String? {
    switch Int(keyCode) {
    case kVK_Space:
      " "
    case kVK_Return, kVK_ANSI_KeypadEnter:
      "\r"
    case kVK_Tab:
      "\t"
    case kVK_Delete:
      Self.unicodeScalarString(Int(NSDeleteCharacter))
    case kVK_Escape:
      "\u{1B}"
    case kVK_LeftArrow:
      Self.unicodeScalarString(Int(NSLeftArrowFunctionKey))
    case kVK_RightArrow:
      Self.unicodeScalarString(Int(NSRightArrowFunctionKey))
    case kVK_UpArrow:
      Self.unicodeScalarString(Int(NSUpArrowFunctionKey))
    case kVK_DownArrow:
      Self.unicodeScalarString(Int(NSDownArrowFunctionKey))
    case kVK_F1:
      Self.unicodeScalarString(Int(NSF1FunctionKey))
    case kVK_F2:
      Self.unicodeScalarString(Int(NSF2FunctionKey))
    case kVK_F3:
      Self.unicodeScalarString(Int(NSF3FunctionKey))
    case kVK_F4:
      Self.unicodeScalarString(Int(NSF4FunctionKey))
    case kVK_F5:
      Self.unicodeScalarString(Int(NSF5FunctionKey))
    case kVK_F6:
      Self.unicodeScalarString(Int(NSF6FunctionKey))
    case kVK_F7:
      Self.unicodeScalarString(Int(NSF7FunctionKey))
    case kVK_F8:
      Self.unicodeScalarString(Int(NSF8FunctionKey))
    case kVK_F9:
      Self.unicodeScalarString(Int(NSF9FunctionKey))
    case kVK_F10:
      Self.unicodeScalarString(Int(NSF10FunctionKey))
    case kVK_F11:
      Self.unicodeScalarString(Int(NSF11FunctionKey))
    case kVK_F12:
      Self.unicodeScalarString(Int(NSF12FunctionKey))
    case kVK_F13:
      Self.unicodeScalarString(Int(NSF13FunctionKey))
    case kVK_F14:
      Self.unicodeScalarString(Int(NSF14FunctionKey))
    case kVK_F15:
      Self.unicodeScalarString(Int(NSF15FunctionKey))
    case kVK_F16:
      Self.unicodeScalarString(Int(NSF16FunctionKey))
    case kVK_F17:
      Self.unicodeScalarString(Int(NSF17FunctionKey))
    case kVK_F18:
      Self.unicodeScalarString(Int(NSF18FunctionKey))
    case kVK_F19:
      Self.unicodeScalarString(Int(NSF19FunctionKey))
    case kVK_F20:
      Self.unicodeScalarString(Int(NSF20FunctionKey))
    case kVK_ForwardDelete:
      Self.unicodeScalarString(Int(NSDeleteFunctionKey))
    case kVK_Home:
      Self.unicodeScalarString(Int(NSHomeFunctionKey))
    case kVK_End:
      Self.unicodeScalarString(Int(NSEndFunctionKey))
    case kVK_PageUp:
      Self.unicodeScalarString(Int(NSPageUpFunctionKey))
    case kVK_PageDown:
      Self.unicodeScalarString(Int(NSPageDownFunctionKey))
    default:
      Self.currentLayoutPrintableKeyEquivalent(for: keyCode)
        ?? Self.fallbackPrintableKeyEquivalent(for: keyCode)
    }
  }

  var menuModifierFlags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers & UInt32(cmdKey) != 0 {
      flags.insert(.command)
    }
    if modifiers & UInt32(shiftKey) != 0 {
      flags.insert(.shift)
    }
    if modifiers & UInt32(optionKey) != 0 {
      flags.insert(.option)
    }
    if modifiers & UInt32(controlKey) != 0 {
      flags.insert(.control)
    }
    return flags
  }

  private static func currentLayoutPrintableKeyEquivalent(for keyCode: UInt32) -> String? {
    resolvePrintableKeyEquivalent(
      from: TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
      keyCode: keyCode
    ) ?? resolvePrintableKeyEquivalent(
      from: TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue(),
      keyCode: keyCode
    )
  }

  private static func resolvePrintableKeyEquivalent(
    from inputSource: TISInputSource,
    keyCode: UInt32
  ) -> String? {
    guard let layoutDataPointer = TISGetInputSourceProperty(
      inputSource,
      kTISPropertyUnicodeKeyLayoutData
    ) else { return nil }

    let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
    guard let keyboardLayoutBytes = CFDataGetBytePtr(layoutData) else { return nil }

    var deadKeyState: UInt32 = 0
    let maxLength = 4
    var actualLength = 0
    var unicodeChars = [UniChar](repeating: 0, count: Int(maxLength))

    let status = keyboardLayoutBytes.withMemoryRebound(
      to: UCKeyboardLayout.self,
      capacity: 1
    ) { keyboardLayout in
      UCKeyTranslate(
        keyboardLayout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysMask),
        &deadKeyState,
        maxLength,
        &actualLength,
        &unicodeChars
      )
    }

    guard status == noErr, actualLength > 0 else { return nil }

    let keyEquivalent = String(utf16CodeUnits: unicodeChars, count: Int(actualLength))
      .trimmingCharacters(in: .controlCharacters)
    guard let printable = keyEquivalent.first else { return nil }
    return String(printable).lowercased()
  }

  private static func currentLayoutPrintableKeyDisplayString(for keyCode: UInt32) -> String? {
    guard let keyEquivalent = currentLayoutPrintableKeyEquivalent(for: keyCode),
          let printable = keyEquivalent.first else { return nil }

    let keyLabel = String(printable)
    guard printable.isLetter else { return keyLabel }

    let uppercased = keyLabel.uppercased()
    return uppercased.count == 1 ? uppercased : keyLabel
  }

  private static func fallbackPrintableKeyEquivalent(for keyCode: UInt32) -> String? {
    let display = keyCodeToString(keyCode)
    guard display != "?", display.count == 1 else { return nil }
    return display.lowercased()
  }

  private static func unicodeScalarString(_ codePoint: Int) -> String? {
    guard let scalar = UnicodeScalar(codePoint) else { return nil }
    return String(Character(scalar))
  }
}

enum GlobalShortcutKind: String, CaseIterable, Codable {
  case oneShot
  case translation
  case agentMode
  case startAudioRecording
  case pauseResumeRecording
  case togglePenRecording
  case restartRecording
  case deleteRecording
  case history

  var isSystemConflictRelevant: Bool {
    self == .oneShot
  }
}

extension GlobalShortcutKind {
  var displayName: String {
    switch self {
    case .oneShot:
      L10n.Actions.oneShot
    case .translation:
      L10n.OneShot.translationTab
    case .agentMode:
      L10n.Agent.shortcutTitle
    case .startAudioRecording:
      L10n.AudioRecording.startMenu
    case .pauseResumeRecording:
      L10n.Actions.pauseResumeRecording
    case .togglePenRecording:
      L10n.Actions.togglePenRecording
    case .restartRecording:
      L10n.Actions.restartRecording
    case .deleteRecording:
      L10n.Actions.deleteRecording
    case .history:
      L10n.Actions.openHistory
    }
  }
}

/// Shortcut action types
enum ShortcutAction {
  case startOneShot
  case startTranslation
  case startAgentIntent
  case startAudioRecording
  case pauseResumeRecording
  case togglePenRecording
  case restartRecording
  case deleteRecording
  case openHistory
}

/// Protocol for handling shortcut events
protocol KeyboardShortcutDelegate: AnyObject {
  func shortcutTriggered(_ action: ShortcutAction)
}

/// Manager for registering and handling global keyboard shortcuts
@MainActor
final class KeyboardShortcutManager {
  static let shared = KeyboardShortcutManager()

  weak var delegate: KeyboardShortcutDelegate?

  private(set) var oneShotShortcut: ShortcutConfig
  private(set) var translationShortcut: ShortcutConfig
  private(set) var agentModeShortcut: ShortcutConfig
  private(set) var startAudioRecordingShortcut: ShortcutConfig
  /// Backing value holds the recommended `defaultPauseResumeRecording` combo even while the shortcut
  /// is unbound. The shortcut ships cleared (in `clearedShortcuts`), so always resolve the effective
  /// binding through `shortcut(for: .pauseResumeRecording)` — which returns nil when cleared — never
  /// this property directly.
  private(set) var pauseResumeRecordingShortcut: ShortcutConfig
  private(set) var historyShortcut: ShortcutConfig
  private(set) var togglePenRecordingShortcut: ShortcutConfig
  private(set) var restartRecordingShortcut: ShortcutConfig
  private(set) var deleteRecordingShortcut: ShortcutConfig
  private(set) var isEnabled: Bool = false
  private(set) var isAgentModeRegistrationEnabled = false
  private var disabledShortcuts: Set<GlobalShortcutKind> = []
  private var clearedShortcuts: Set<GlobalShortcutKind> = []
  private var temporarySuspensionCount: Int = 0

  private var oneShotHotkeyRef: EventHotKeyRef?
  private var translationHotkeyRef: EventHotKeyRef?
  private var agentModeHotkeyRef: EventHotKeyRef?
  private var startAudioRecordingHotkeyRef: EventHotKeyRef?
  private var pauseResumeRecordingHotkeyRef: EventHotKeyRef?
  private var historyHotkeyRef: EventHotKeyRef?
  private var togglePenRecordingHotkeyRef: EventHotKeyRef?
  private var restartRecordingHotkeyRef: EventHotKeyRef?
  private var deleteRecordingHotkeyRef: EventHotKeyRef?

  /// Fn-containing bindings can't be expressed via Carbon `RegisterEventHotKey`;
  /// they are dispatched through key event monitors instead.
  private var fnBindings: [(id: UInt32, config: ShortcutConfig)] = []
  private var fnGlobalMonitor: Any?
  private var fnLocalMonitor: Any?

  // Hotkey IDs
  private let historyHotkeyID = EventHotKeyID(signature: OSType(0x5A53_4642), id: 11) // "ZSFB"
  private let pauseResumeRecordingHotkeyID = EventHotKeyID(signature: OSType(0x5A53_4648), id: 17) // "ZSFH"
  private let togglePenRecordingHotkeyID = EventHotKeyID(signature: OSType(0x5A53_4649), id: 18) // "ZSFI"
  private let restartRecordingHotkeyID = EventHotKeyID(signature: OSType(0x5A53_464A), id: 19) // "ZSFJ"
  private let deleteRecordingHotkeyID = EventHotKeyID(signature: OSType(0x5A53_464B), id: 20) // "ZSFK"
  private let oneShotHotkeyID = EventHotKeyID(signature: OSType(0x5A53_464C), id: 21) // "ZSFL"
  private let agentModeHotkeyID = EventHotKeyID(signature: OSType(0x5A53_464D), id: 22) // "ZSFM"
  private let translationHotkeyID = EventHotKeyID(signature: OSType(0x5A53_464E), id: 23) // "ZSFN"
  // Keep audio distinct from Agent Mode (id 22) and Translation (id 23).
  private let startAudioRecordingHotkeyID = EventHotKeyID(signature: OSType(0x5A53_464F), id: 24) // "ZSFO"

  private var eventHandler: EventHandlerRef?

  // UserDefaults keys
  private let oneShotShortcutKey = PreferencesKeys.oneShotShortcut
  private let translationShortcutKey = PreferencesKeys.translationShortcut
  private let agentModeShortcutKey = PreferencesKeys.agentShortcut
  private let startAudioRecordingShortcutKey = PreferencesKeys.startAudioRecordingShortcut
  private let pauseResumeRecordingShortcutKey = "pauseResumeRecordingShortcut"
  private let historyShortcutKey = "historyShortcut"
  private let togglePenRecordingShortcutKey = "togglePenRecordingShortcut"
  private let restartRecordingShortcutKey = "restartRecordingShortcut"
  private let deleteRecordingShortcutKey = "deleteRecordingShortcut"
  private let shortcutsEnabledKey = "shortcutsEnabled"
  private let disabledShortcutsKey = PreferencesKeys.disabledGlobalShortcuts
  private let clearedShortcutsKey = PreferencesKeys.clearedGlobalShortcuts

  private init() {
    oneShotShortcut = .defaultOneShot
    translationShortcut = ShortcutConfig(keyCode: 0, modifiers: 0)
    agentModeShortcut = .defaultAgentMode
    startAudioRecordingShortcut = .defaultStartAudioRecording
    pauseResumeRecordingShortcut = .defaultPauseResumeRecording
    historyShortcut = .defaultHistory
    togglePenRecordingShortcut = ShortcutConfig(keyCode: 0, modifiers: 0)
    restartRecordingShortcut = ShortcutConfig(keyCode: 0, modifiers: 0)
    deleteRecordingShortcut = ShortcutConfig(keyCode: 0, modifiers: 0)
    loadShortcuts()
    loadDisabledShortcuts()
    loadClearedShortcuts()
    seedDefaultClearedShortcutsOnFirstLaunchIfNeeded()
    setupEventHandler()

    // Enable on first launch and auto-enable if previously enabled
    if UserDefaults.standard.object(forKey: shortcutsEnabledKey) == nil
      || UserDefaults.standard.bool(forKey: shortcutsEnabledKey) {
      enable()
    }
  }

  // MARK: - Public API

  /// Enable global shortcuts
  func enable() {
    guard !isEnabled else { return }
    isEnabled = true
    UserDefaults.standard.set(true, forKey: shortcutsEnabledKey)
    refreshShortcutRegistration()
  }

  /// Disable global shortcuts
  func disable() {
    guard isEnabled else { return }
    isEnabled = false
    UserDefaults.standard.set(false, forKey: shortcutsEnabledKey)
    refreshShortcutRegistration()
  }

  /// Temporarily suspend registered hotkeys without mutating the persisted enabled setting.
  func beginTemporaryShortcutSuppression() {
    temporarySuspensionCount += 1
    refreshShortcutRegistration()
  }

  /// Resume registered hotkeys once all temporary suppression requests are released.
  func endTemporaryShortcutSuppression() {
    guard temporarySuspensionCount > 0 else { return }
    temporarySuspensionCount -= 1
    refreshShortcutRegistration()
  }

  var isTemporarilySuspended: Bool {
    temporarySuspensionCount > 0
  }

  /// Agent Mode owns the lifecycle of its shortcut. Keeping this false while
  /// the mode is off prevents Option+A from consuming normal text input.
  func setAgentModeRegistrationEnabled(_ enabled: Bool) {
    guard isAgentModeRegistrationEnabled != enabled else { return }
    isAgentModeRegistrationEnabled = enabled
    refreshShortcutRegistration()
  }

  private var shouldRegisterShortcuts: Bool {
    isEnabled && !isTemporarilySuspended
  }

  func refreshShortcutRegistration() {
    unregisterAllShortcuts()
    fnBindings.removeAll()

    if shouldRegisterShortcuts {
      registerShortcuts()
    }

    updateFnMonitors()
  }

  /// Exposed for the shortcuts settings UI: true when at least one enabled binding
  /// relies on the Fn modifier (and therefore on Accessibility permission).
  var hasFnBoundShortcuts: Bool {
    GlobalShortcutKind.allCases.contains { kind in
      guard isShortcutEnabled(for: kind), let config = shortcut(for: kind) else { return false }
      return config.modifiers & ShortcutConfig.functionCarbonModifier != 0
    }
  }

  func shortcut(for kind: GlobalShortcutKind) -> ShortcutConfig? {
    guard !clearedShortcuts.contains(kind) else { return nil }

    switch kind {
    case .oneShot: return oneShotShortcut
    case .translation: return translationShortcut
    case .agentMode: return agentModeShortcut
    case .startAudioRecording: return startAudioRecordingShortcut
    case .pauseResumeRecording: return pauseResumeRecordingShortcut
    case .togglePenRecording: return togglePenRecordingShortcut
    case .restartRecording: return restartRecordingShortcut
    case .deleteRecording: return deleteRecordingShortcut
    case .history: return historyShortcut
    }
  }

  func isShortcutEnabled(for kind: GlobalShortcutKind) -> Bool {
    !disabledShortcuts.contains(kind)
  }

  func setShortcutEnabled(_ enabled: Bool, for kind: GlobalShortcutKind) {
    guard isShortcutEnabled(for: kind) != enabled else { return }
    mutateShortcutRegistration {
      if enabled {
        disabledShortcuts.remove(kind)
      } else {
        disabledShortcuts.insert(kind)
      }
      saveDisabledShortcuts()
    }
  }

  /// Update the unified One Shot shortcut.
  func setOneShotShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .oneShot) {
        oneShotShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update the optional shortcut that opens One Shot on the Translation tab.
  func setTranslationShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .translation) {
        translationShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  func setAgentModeShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .agentMode) {
        agentModeShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update the independent audio-recording shortcut. Nil means "None" and
  /// is the clean-install default; it never aliases One Shot.
  func setStartAudioRecordingShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .startAudioRecording) {
        startAudioRecordingShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update pause/resume recording shortcut. Ships unbound; nil means "None".
  func setPauseResumeRecordingShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .pauseResumeRecording) {
        pauseResumeRecordingShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update toggle pen recording shortcut. Ships unbound; nil means "None".
  func setTogglePenRecordingShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .togglePenRecording) {
        togglePenRecordingShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update restart recording shortcut. Ships unbound; nil means "None".
  func setRestartRecordingShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .restartRecording) {
        restartRecordingShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update delete recording shortcut. Ships unbound; nil means "None".
  func setDeleteRecordingShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .deleteRecording) {
        deleteRecordingShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  /// Update history shortcut
  func setHistoryShortcut(_ config: ShortcutConfig?) {
    mutateShortcutRegistration {
      setShortcut(config, for: .history) {
        historyShortcut = $0
      }
      saveShortcuts()
      saveClearedShortcuts()
    }
  }

  private func setShortcut(
    _ config: ShortcutConfig?,
    for kind: GlobalShortcutKind,
    assign: (ShortcutConfig) -> Void
  ) {
    if let config {
      assign(config)
      clearedShortcuts.remove(kind)
    } else {
      clearedShortcuts.insert(kind)
    }
  }

  // MARK: - Persistence

  private func saveShortcuts() {
    let encoder = JSONEncoder()
    if let oneShotData = try? encoder.encode(oneShotShortcut) {
      UserDefaults.standard.set(oneShotData, forKey: oneShotShortcutKey)
    }
    if clearedShortcuts.contains(.translation) {
      UserDefaults.standard.removeObject(forKey: translationShortcutKey)
    } else if let data = try? encoder.encode(translationShortcut) {
      UserDefaults.standard.set(data, forKey: translationShortcutKey)
    }
    if let agentModeData = try? encoder.encode(agentModeShortcut) {
      UserDefaults.standard.set(agentModeData, forKey: agentModeShortcutKey)
    }
    if clearedShortcuts.contains(.startAudioRecording) {
      UserDefaults.standard.removeObject(forKey: startAudioRecordingShortcutKey)
    } else if let data = try? encoder.encode(startAudioRecordingShortcut) {
      UserDefaults.standard.set(data, forKey: startAudioRecordingShortcutKey)
    }
    if clearedShortcuts.contains(.pauseResumeRecording) {
      UserDefaults.standard.removeObject(forKey: pauseResumeRecordingShortcutKey)
    } else if let pauseResumeRecordingData = try? encoder.encode(pauseResumeRecordingShortcut) {
      UserDefaults.standard.set(pauseResumeRecordingData, forKey: pauseResumeRecordingShortcutKey)
    }
    if clearedShortcuts.contains(.togglePenRecording) {
      UserDefaults.standard.removeObject(forKey: togglePenRecordingShortcutKey)
    } else if let data = try? encoder.encode(togglePenRecordingShortcut) {
      UserDefaults.standard.set(data, forKey: togglePenRecordingShortcutKey)
    }
    if clearedShortcuts.contains(.restartRecording) {
      UserDefaults.standard.removeObject(forKey: restartRecordingShortcutKey)
    } else if let data = try? encoder.encode(restartRecordingShortcut) {
      UserDefaults.standard.set(data, forKey: restartRecordingShortcutKey)
    }
    if clearedShortcuts.contains(.deleteRecording) {
      UserDefaults.standard.removeObject(forKey: deleteRecordingShortcutKey)
    } else if let data = try? encoder.encode(deleteRecordingShortcut) {
      UserDefaults.standard.set(data, forKey: deleteRecordingShortcutKey)
    }
    if let historyData = try? encoder.encode(historyShortcut) {
      UserDefaults.standard.set(historyData, forKey: historyShortcutKey)
    }
  }

  private func loadShortcuts() {
    let decoder = JSONDecoder()
    if let oneShotData = UserDefaults.standard.data(forKey: oneShotShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: oneShotData) {
      oneShotShortcut = config
    }
    if let data = UserDefaults.standard.data(forKey: translationShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: data) {
      translationShortcut = config
    }
    if let agentModeData = UserDefaults.standard.data(forKey: agentModeShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: agentModeData) {
      agentModeShortcut = config
    }
    if let data = UserDefaults.standard.data(forKey: startAudioRecordingShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: data) {
      startAudioRecordingShortcut = config
    }
    if let pauseResumeRecordingData = UserDefaults.standard.data(forKey: pauseResumeRecordingShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: pauseResumeRecordingData) {
      pauseResumeRecordingShortcut = config
    }
    if let togglePenRecordingData = UserDefaults.standard.data(forKey: togglePenRecordingShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: togglePenRecordingData) {
      togglePenRecordingShortcut = config
    }
    if let restartRecordingData = UserDefaults.standard.data(forKey: restartRecordingShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: restartRecordingData) {
      restartRecordingShortcut = config
    }
    if let deleteRecordingData = UserDefaults.standard.data(forKey: deleteRecordingShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: deleteRecordingData) {
      deleteRecordingShortcut = config
    }
    if let historyData = UserDefaults.standard.data(forKey: historyShortcutKey),
       let config = try? decoder.decode(ShortcutConfig.self, from: historyData) {
      historyShortcut = config
    }
  }

  private func saveDisabledShortcuts() {
    let rawValues = disabledShortcuts.map(\.rawValue).sorted()
    UserDefaults.standard.set(rawValues, forKey: disabledShortcutsKey)
  }

  private func saveClearedShortcuts() {
    let rawValues = clearedShortcuts.map(\.rawValue).sorted()
    UserDefaults.standard.set(rawValues, forKey: clearedShortcutsKey)
  }

  private func loadDisabledShortcuts() {
    let rawValues = UserDefaults.standard.array(forKey: disabledShortcutsKey) as? [String]
    disabledShortcuts = Self.disabledShortcutSet(from: rawValues)
  }

  static func disabledShortcutSet(from rawValues: [String]?) -> Set<GlobalShortcutKind> {
    Set((rawValues ?? []).compactMap(GlobalShortcutKind.init(rawValue:)))
  }

  private func loadClearedShortcuts() {
    guard let rawValues = UserDefaults.standard.array(forKey: clearedShortcutsKey) as? [String] else {
      clearedShortcuts = []
      return
    }
    clearedShortcuts = Set(rawValues.compactMap(GlobalShortcutKind.init(rawValue:)))
  }

  /// Ensure new optional-by-default shortcuts ship as unbound on a clean install,
  /// without overriding any user-configured value once they have been touched.
  private func seedDefaultClearedShortcutsOnFirstLaunchIfNeeded() {
    var didMutate = false
    if UserDefaults.standard.data(forKey: translationShortcutKey) == nil,
       !clearedShortcuts.contains(.translation) {
      clearedShortcuts.insert(.translation)
      didMutate = true
    }
    if UserDefaults.standard.data(forKey: startAudioRecordingShortcutKey) == nil,
       !clearedShortcuts.contains(.startAudioRecording) {
      clearedShortcuts.insert(.startAudioRecording)
      didMutate = true
    }
    if UserDefaults.standard.data(forKey: pauseResumeRecordingShortcutKey) == nil,
       !clearedShortcuts.contains(.pauseResumeRecording) {
      clearedShortcuts.insert(.pauseResumeRecording)
      didMutate = true
    }
    if UserDefaults.standard.data(forKey: togglePenRecordingShortcutKey) == nil,
       !clearedShortcuts.contains(.togglePenRecording) {
      clearedShortcuts.insert(.togglePenRecording)
      didMutate = true
    }
    if UserDefaults.standard.data(forKey: restartRecordingShortcutKey) == nil,
       !clearedShortcuts.contains(.restartRecording) {
      clearedShortcuts.insert(.restartRecording)
      didMutate = true
    }
    if UserDefaults.standard.data(forKey: deleteRecordingShortcutKey) == nil,
       !clearedShortcuts.contains(.deleteRecording) {
      clearedShortcuts.insert(.deleteRecording)
      didMutate = true
    }
    if didMutate {
      saveClearedShortcuts()
    }
  }

  // MARK: - Private Methods

  private func setupEventHandler() {
    // Install Carbon event handler for hotkey events
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
    )

    let handlerBlock: EventHandlerUPP = { _, event, _ -> OSStatus in
      var hotkeyID = EventHotKeyID()
      let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
      )

      guard status == noErr else { return status }

      // Dispatch to main actor
      Task { @MainActor in
        KeyboardShortcutManager.shared.handleHotkey(id: hotkeyID.id)
      }

      return noErr
    }

    InstallEventHandler(
      GetApplicationEventTarget(),
      handlerBlock,
      1,
      &eventType,
      nil,
      &eventHandler
    )
  }

  private func mutateShortcutRegistration(_ mutation: () -> Void) {
    mutation()
    refreshShortcutRegistration()
  }

  private func handleHotkey(id: UInt32) {
    let actionName: String
    let action: ShortcutAction

    switch id {
    case oneShotHotkeyID.id:
      actionName = "one-shot"
      action = .startOneShot
    case translationHotkeyID.id:
      actionName = "translation"
      action = .startTranslation
    case agentModeHotkeyID.id:
      guard isAgentModeRegistrationEnabled else { return }
      actionName = "agent-mode"
      action = .startAgentIntent
    case startAudioRecordingHotkeyID.id:
      actionName = "start-audio-recording"
      action = .startAudioRecording
    case pauseResumeRecordingHotkeyID.id:
      actionName = "pause-resume-recording"
      action = .pauseResumeRecording
    case togglePenRecordingHotkeyID.id:
      actionName = "toggle-pen-recording"
      action = .togglePenRecording
    case restartRecordingHotkeyID.id:
      actionName = "restart-recording"
      action = .restartRecording
    case deleteRecordingHotkeyID.id:
      actionName = "delete-recording"
      action = .deleteRecording
    case historyHotkeyID.id:
      actionName = "history"
      action = .openHistory
    default:
      return
    }

    DiagnosticLogger.shared.log(.info, .action, "Shortcut triggered: \(actionName)")

    guard let delegate else {
      DiagnosticLogger.shared.log(.warning, .action, "Shortcut \(actionName) ignored: delegate is nil")
      return
    }

    delegate.shortcutTriggered(action)
  }

  private func registerShortcuts() {
    guard shouldRegisterShortcuts else { return }

    registerShortcutIfNeeded(
      kind: .oneShot,
      config: shortcut(for: .oneShot),
      hotkeyID: oneShotHotkeyID,
      ref: &oneShotHotkeyRef
    )
    registerShortcutIfNeeded(
      kind: .translation,
      config: shortcut(for: .translation),
      hotkeyID: translationHotkeyID,
      ref: &translationHotkeyRef
    )
    if isAgentModeRegistrationEnabled {
      registerShortcutIfNeeded(
        kind: .agentMode,
        config: shortcut(for: .agentMode),
        hotkeyID: agentModeHotkeyID,
        ref: &agentModeHotkeyRef
      )
    }
    registerShortcutIfNeeded(
      kind: .startAudioRecording,
      config: shortcut(for: .startAudioRecording),
      hotkeyID: startAudioRecordingHotkeyID,
      ref: &startAudioRecordingHotkeyRef
    )
    registerShortcutIfNeeded(
      kind: .pauseResumeRecording,
      config: shortcut(for: .pauseResumeRecording),
      hotkeyID: pauseResumeRecordingHotkeyID,
      ref: &pauseResumeRecordingHotkeyRef
    )
    registerShortcutIfNeeded(
      kind: .togglePenRecording,
      config: shortcut(for: .togglePenRecording),
      hotkeyID: togglePenRecordingHotkeyID,
      ref: &togglePenRecordingHotkeyRef
    )
    registerShortcutIfNeeded(
      kind: .restartRecording,
      config: shortcut(for: .restartRecording),
      hotkeyID: restartRecordingHotkeyID,
      ref: &restartRecordingHotkeyRef
    )
    registerShortcutIfNeeded(
      kind: .deleteRecording,
      config: shortcut(for: .deleteRecording),
      hotkeyID: deleteRecordingHotkeyID,
      ref: &deleteRecordingHotkeyRef
    )
    registerShortcutIfNeeded(
      kind: .history,
      config: shortcut(for: .history),
      hotkeyID: historyHotkeyID,
      ref: &historyHotkeyRef
    )
  }

  private func registerShortcutIfNeeded(
    kind: GlobalShortcutKind,
    config: ShortcutConfig?,
    hotkeyID: EventHotKeyID,
    ref: inout EventHotKeyRef?
  ) {
    guard isShortcutEnabled(for: kind), let config else { return }

    // Carbon cannot express the Fn modifier. Fn bindings are dispatched through
    // key event monitors (see updateFnMonitors) instead of RegisterEventHotKey,
    // so the non-Fn combo keeps working and Fn-only combos actually fire.
    guard config.modifiers & ShortcutConfig.functionCarbonModifier == 0 else {
      fnBindings.append((id: hotkeyID.id, config: config))
      return
    }

    guard config.modifiers != 0 else { return }

    let status = RegisterEventHotKey(
      config.keyCode,
      config.modifiers,
      hotkeyID,
      GetApplicationEventTarget(),
      0,
      &ref
    )

    if status != noErr || ref == nil {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "Failed to register shortcut \(kind.rawValue)",
        context: ["status": String(status)]
      )
      ref = nil
      return
    }
  }

  // MARK: - Fn Shortcut Dispatch

  /// Installs/removes the key event monitors used to dispatch Fn-containing
  /// shortcuts, based on the current registration state.
  private func updateFnMonitors() {
    guard shouldRegisterShortcuts, !fnBindings.isEmpty else {
      removeFnMonitors()
      return
    }
    installFnMonitorsIfNeeded()
  }

  private func installFnMonitorsIfNeeded() {
    if fnGlobalMonitor == nil {
      fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        MainActor.assumeIsolated {
          self?.handleFnKeyDown(event)
        }
      }
    }

    if fnLocalMonitor == nil {
      fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        MainActor.assumeIsolated {
          self?.handleFnKeyDown(event)
        }
        // Passive: never consume the event, unlike Carbon hotkeys.
        return event
      }
    }
  }

  private func removeFnMonitors() {
    if let monitor = fnGlobalMonitor {
      NSEvent.removeMonitor(monitor)
      fnGlobalMonitor = nil
    }
    if let monitor = fnLocalMonitor {
      NSEvent.removeMonitor(monitor)
      fnLocalMonitor = nil
    }
  }

  private func handleFnKeyDown(_ event: NSEvent) {
    guard !event.isARepeat else { return }
    guard let binding = fnBindings.first(where: { $0.config.matches(event: event) }) else {
      return
    }
    handleHotkey(id: binding.id)
  }

  private func unregisterAllShortcuts() {
    if let ref = oneShotHotkeyRef {
      UnregisterEventHotKey(ref)
      oneShotHotkeyRef = nil
    }
    if let ref = translationHotkeyRef {
      UnregisterEventHotKey(ref)
      translationHotkeyRef = nil
    }
    if let ref = agentModeHotkeyRef {
      UnregisterEventHotKey(ref)
      agentModeHotkeyRef = nil
    }
    if let ref = startAudioRecordingHotkeyRef {
      UnregisterEventHotKey(ref)
      startAudioRecordingHotkeyRef = nil
    }
    if let ref = pauseResumeRecordingHotkeyRef {
      UnregisterEventHotKey(ref)
      pauseResumeRecordingHotkeyRef = nil
    }
    if let ref = togglePenRecordingHotkeyRef {
      UnregisterEventHotKey(ref)
      togglePenRecordingHotkeyRef = nil
    }
    if let ref = restartRecordingHotkeyRef {
      UnregisterEventHotKey(ref)
      restartRecordingHotkeyRef = nil
    }
    if let ref = deleteRecordingHotkeyRef {
      UnregisterEventHotKey(ref)
      deleteRecordingHotkeyRef = nil
    }
    if let ref = historyHotkeyRef {
      UnregisterEventHotKey(ref)
      historyHotkeyRef = nil
    }
  }
}
