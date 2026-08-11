//
//  ShotPasteConfigurationShortcutCodec.swift
//  ShotPaste
//
//  Friendly TOML shortcut key/modifier conversion.
//

import Carbon.HIToolbox
import Foundation

enum ShotPasteConfigurationShortcutCodec {
  static func exportKey(_ config: ShortcutConfig) -> String {
    ShortcutConfig.keyCodeToString(config.keyCode)
  }

  static func exportModifiers(_ config: ShortcutConfig) -> [String] {
    var values: [String] = []
    if config.modifiers & UInt32(cmdKey) != 0 {
      values.append("command")
    }
    if config.modifiers & UInt32(shiftKey) != 0 {
      values.append("shift")
    }
    if config.modifiers & UInt32(optionKey) != 0 {
      values.append("option")
    }
    if config.modifiers & UInt32(controlKey) != 0 {
      values.append("control")
    }
    return values
  }

  static func shortcut(key: String, modifiers: [String], requireModifier: Bool) -> ShortcutConfig? {
    guard let keyCode = keyCode(for: key) else { return nil }
    guard let carbonModifiers = carbonModifiers(from: modifiers) else { return nil }
    guard !requireModifier || carbonModifiers != 0 else { return nil }
    return ShortcutConfig(keyCode: keyCode, modifiers: carbonModifiers)
  }

  private static func carbonModifiers(from modifiers: [String]) -> UInt32? {
    var carbonModifiers: UInt32 = 0
    for modifier in modifiers.map({ $0.lowercased() }) {
      switch modifier {
      case "command", "cmd":
        carbonModifiers |= UInt32(cmdKey)
      case "shift":
        carbonModifiers |= UInt32(shiftKey)
      case "option", "alt":
        carbonModifiers |= UInt32(optionKey)
      case "control", "ctrl":
        carbonModifiers |= UInt32(controlKey)
      default:
        return nil
      }
    }
    return carbonModifiers
  }

  private static func keyCode(for key: String) -> UInt32? {
    switch key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "0": UInt32(kVK_ANSI_0)
    case "1": UInt32(kVK_ANSI_1)
    case "2": UInt32(kVK_ANSI_2)
    case "3": UInt32(kVK_ANSI_3)
    case "4": UInt32(kVK_ANSI_4)
    case "5": UInt32(kVK_ANSI_5)
    case "6": UInt32(kVK_ANSI_6)
    case "7": UInt32(kVK_ANSI_7)
    case "8": UInt32(kVK_ANSI_8)
    case "9": UInt32(kVK_ANSI_9)
    case "A": UInt32(kVK_ANSI_A)
    case "B": UInt32(kVK_ANSI_B)
    case "C": UInt32(kVK_ANSI_C)
    case "D": UInt32(kVK_ANSI_D)
    case "E": UInt32(kVK_ANSI_E)
    case "F": UInt32(kVK_ANSI_F)
    case "G": UInt32(kVK_ANSI_G)
    case "H": UInt32(kVK_ANSI_H)
    case "I": UInt32(kVK_ANSI_I)
    case "J": UInt32(kVK_ANSI_J)
    case "K": UInt32(kVK_ANSI_K)
    case "L": UInt32(kVK_ANSI_L)
    case "M": UInt32(kVK_ANSI_M)
    case "N": UInt32(kVK_ANSI_N)
    case "O": UInt32(kVK_ANSI_O)
    case "P": UInt32(kVK_ANSI_P)
    case "Q": UInt32(kVK_ANSI_Q)
    case "R": UInt32(kVK_ANSI_R)
    case "S": UInt32(kVK_ANSI_S)
    case "T": UInt32(kVK_ANSI_T)
    case "U": UInt32(kVK_ANSI_U)
    case "V": UInt32(kVK_ANSI_V)
    case "W": UInt32(kVK_ANSI_W)
    case "X": UInt32(kVK_ANSI_X)
    case "Y": UInt32(kVK_ANSI_Y)
    case "Z": UInt32(kVK_ANSI_Z)
    case "SPACE": UInt32(kVK_Space)
    default: nil
    }
  }
}
