//
//  NSApplication+Activation.swift
//  ShotPaste
//
//  Coordinated activation policy changes for multi-window management.
//

import AppKit

extension NSApplication {
  /// Revert activation policy to .accessory if no visible normal windows remain
  @MainActor
  func revertActivationPolicyToAccessoryIfNeeded(excluding closingWindow: NSWindow? = nil) {
    let visibleWindows = windows.filter { window in
      window.isVisible &&
        window !== closingWindow &&
        window.className != "NSStatusBarWindow" &&
        window.level == .normal
    }

    if visibleWindows.isEmpty, activationPolicy() != .accessory {
      PerfSignpost.measure("policyRevert") {
        _ = setActivationPolicy(.accessory)
      }
      DiagnosticLogger.shared.log(.debug, .ui, "Activation policy restored to accessory coordinates")
    }
  }
}
