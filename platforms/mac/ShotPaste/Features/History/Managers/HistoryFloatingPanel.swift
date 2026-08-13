//
//  HistoryFloatingPanel.swift
//  ShotPaste
//
//  NSPanel subclass for the floating history panel
//

import AppKit
import Foundation

/// Non-activating floating panel for capture history
final class HistoryFloatingPanel: NSPanel {
  var onDidResignKey: (() -> Void)?

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configurePanel()
  }

  private func configurePanel() {
    level = .floating
    isFloatingPanel = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    // Clipboard History is user content that should remain visible in screenshots.
    // ScreenCaptureManager keeps this window as an explicit exception when the
    // rest of ShotPaste is excluded from capture.
    sharingType = .readOnly
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = false
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }

  private var isTextInputActive: Bool {
    guard let responder = firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }

  override func resignKey() {
    super.resignKey()

    DispatchQueue.main.async { [weak self] in
      self?.onDidResignKey?()
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else {
      return super.performKeyEquivalent(with: event)
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if event.keyCode == 8, flags == .command {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }

      NotificationCenter.default.post(name: .historyCopySelection, object: self)
      return true
    }

    if event.keyCode == 0, flags == .command {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }

      NotificationCenter.default.post(name: .historySelectAll, object: self)
      return true
    }

    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if !isTextInputActive, flags.isEmpty {
      let move: HistorySelectionMove? = switch event.keyCode {
      case 123: .left
      case 124: .right
      case 125: .down
      case 126: .up
      default: nil
      }
      if let move {
        NotificationCenter.default.post(
          name: .historyMoveSelection,
          object: self,
          userInfo: ["move": move]
        )
        return
      }
    }

    if !isTextInputActive, flags.isEmpty, [51, 117].contains(event.keyCode) {
      NotificationCenter.default.post(name: .historyDeleteSelection, object: self)
      return
    }

    if !isTextInputActive, flags.isEmpty, [36, 76].contains(event.keyCode) {
      NotificationCenter.default.post(name: .historyActivateSelection, object: self)
      return
    }

    super.keyDown(with: event)
  }
}
