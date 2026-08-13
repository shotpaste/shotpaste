//
//  QuickAccessPanel.swift
//  ShotPaste
//
//  NSPanel subclass for quick access screenshot overlay
//

import AppKit
import Foundation

/// Non-activating floating panel for screenshot previews
@MainActor
final class QuickAccessPanel: NSPanel {
  private var visibleItemCount = 0
  private var overlayScale: CGFloat = 1
  private var localMouseMonitor: Any?
  private var globalMouseMonitor: Any?
  private var isMouseInteractionActive = false
  private var keyboardFocusActive = false
  private weak var previouslyActiveApplication: NSRunningApplication?

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    configurePanel()
    installMouseMonitors()
  }

  private var isMonitorsSuspended = false

  override func close() {
    if !isMonitorsSuspended {
      removeMouseMonitors()
    }
    isMonitorsSuspended = false
    keyboardFocusActive = false
    super.close()
  }

  func setKeyboardFocusActive(_ active: Bool, restorePreviousApplication: Bool = true) {
    guard keyboardFocusActive != active else { return }
    keyboardFocusActive = active

    if active {
      let frontmostApplication = NSWorkspace.shared.frontmostApplication
      if frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
        previouslyActiveApplication = frontmostApplication
      }
      ignoresMouseEvents = false
      makeKeyAndOrderFront(nil)
    } else {
      if isKeyWindow {
        resignKey()
      }
      refreshMousePassthrough()
      if restorePreviousApplication {
        previouslyActiveApplication?.activate(options: [.activateIgnoringOtherApps])
      }
      previouslyActiveApplication = nil
    }
  }

  func suspendMouseMonitors() {
    guard !isMonitorsSuspended else { return }
    isMonitorsSuspended = true
    removeMouseMonitors()
  }

  func resumeMouseMonitors() {
    guard isMonitorsSuspended else { return }
    isMonitorsSuspended = false
    installMouseMonitors()
  }

  /// Reinstall monitors after a runloop stall. macOS can silently disable the global
  /// event tap when delivery stalls (no re-enable notification reaches the app),
  /// which leaves hover dead until the monitors are recreated. No-op while suspended
  /// (e.g. during an active capture session).
  func reinstallMouseMonitors() {
    guard !isMonitorsSuspended else { return }
    removeMouseMonitors()
    installMouseMonitors()
  }

  func updatePassthroughRegion(itemCount: Int, scale: CGFloat) {
    visibleItemCount = max(0, itemCount)
    overlayScale = max(0.1, scale)
    refreshMousePassthrough()
  }

  func containsInteractivePoint(_ screenPoint: NSPoint) -> Bool {
    guard visibleItemCount > 0 else { return false }

    let activeHeight = Self.interactiveContentHeight(
      itemCount: visibleItemCount,
      scale: overlayScale,
      panelHeight: frame.height
    )
    let interactiveRect = NSRect(
      x: frame.minX,
      y: frame.minY,
      width: frame.width,
      height: activeHeight
    )
    return interactiveRect.contains(screenPoint)
  }

  static func interactiveContentHeight(itemCount: Int, scale: CGFloat, panelHeight: CGFloat) -> CGFloat {
    guard itemCount > 0 else { return 0 }

    let itemCount = max(0, itemCount)
    let scale = max(0.1, scale)
    let cardHeight = QuickAccessLayout.scaledCardHeight(scale)
    let spacing = CGFloat(max(0, itemCount - 1)) * QuickAccessLayout.cardSpacing
    let contentHeight = CGFloat(itemCount) * cardHeight + spacing + QuickAccessLayout.containerPadding * 2
    return min(panelHeight, contentHeight)
  }

  private func configurePanel() {
    level = .floating
    isFloatingPanel = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false // Cards have their own shadows
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    sharingType = .none
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = false
  }

  private func installMouseMonitors() {
    let mask: NSEvent.EventTypeMask = [
      .leftMouseDown,
      .leftMouseUp,
      .mouseMoved,
      .leftMouseDragged,
      .rightMouseDragged,
      .otherMouseDragged,
    ]

    if localMouseMonitor == nil {
      localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
        MainActor.assumeIsolated {
          self?.handleLocalMouseEvent(event)
        }
        return event
      }
    }

    if globalMouseMonitor == nil {
      globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
        Task { @MainActor in
          self?.handleGlobalMouseEvent(event)
        }
      }
    }
  }

  private func removeMouseMonitors() {
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
      self.localMouseMonitor = nil
    }
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
  }

  private func refreshMousePassthrough() {
    if keyboardFocusActive {
      ignoresMouseEvents = false
      return
    }

    if isMouseInteractionActive, NSEvent.pressedMouseButtons & 1 == 0 {
      isMouseInteractionActive = false
    }

    if isMouseInteractionActive {
      ignoresMouseEvents = false
      return
    }

    ignoresMouseEvents = !containsInteractivePoint(NSEvent.mouseLocation)
  }

  private func handleLocalMouseEvent(_ event: NSEvent) {
    if event.window === self {
      switch event.type {
      case .leftMouseDown:
        isMouseInteractionActive = containsInteractivePoint(NSEvent.mouseLocation)
      case .leftMouseUp:
        isMouseInteractionActive = false
      default:
        break
      }
    }

    refreshMousePassthrough()
  }

  private func handleGlobalMouseEvent(_ event: NSEvent) {
    if event.type == .leftMouseUp {
      isMouseInteractionActive = false
    }

    refreshMousePassthrough()
  }

  override var canBecomeKey: Bool {
    keyboardFocusActive
  }

  override var canBecomeMain: Bool {
    false
  }

  override func resignKey() {
    super.resignKey()
    guard keyboardFocusActive else { return }
    keyboardFocusActive = false
    previouslyActiveApplication = nil
    Task { @MainActor in
      QuickAccessManager.shared.keyboardFocusDidResign()
    }
  }

  override func keyDown(with event: NSEvent) {
    guard keyboardFocusActive else {
      super.keyDown(with: event)
      return
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags == .command, event.keyCode == 8 {
      QuickAccessManager.shared.copyKeyboardFocusedItem()
      return
    }
    if flags == .command, event.keyCode == 1 {
      QuickAccessManager.shared.saveKeyboardFocusedItem()
      return
    }

    guard flags.isEmpty || flags == .shift else {
      super.keyDown(with: event)
      return
    }

    switch event.keyCode {
    case 53:
      QuickAccessManager.shared.deactivateKeyboardFocus()
    case 48:
      QuickAccessManager.shared.moveKeyboardFocus(by: flags.contains(.shift) ? -1 : 1)
    case 123, 126:
      QuickAccessManager.shared.moveKeyboardFocus(by: -1)
    case 124, 125:
      QuickAccessManager.shared.moveKeyboardFocus(by: 1)
    case 36, 76:
      QuickAccessManager.shared.openKeyboardFocusedItem()
    case 51, 117:
      QuickAccessManager.shared.deleteKeyboardFocusedItem()
    default:
      super.keyDown(with: event)
    }
  }
}

enum QuickAccessKeyboardNavigation {
  static func destinationIndex(from currentIndex: Int, delta: Int, itemCount: Int) -> Int? {
    guard itemCount > 0 else { return nil }
    return min(max(currentIndex + delta, 0), itemCount - 1)
  }
}
