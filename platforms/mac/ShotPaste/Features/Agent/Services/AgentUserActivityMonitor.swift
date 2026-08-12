//
//  AgentUserActivityMonitor.swift
//  ShotPaste
//
//  Pauses Agent Mode when the user takes control and reserves Escape as an
//  emergency stop while an Agent session is running.
//

import AppKit
import Carbon.HIToolbox

@MainActor
final class AgentUserActivityMonitor {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var onUserActivity: (() -> Void)?
  private var onEmergencyStop: (() -> Void)?

  var isRunning: Bool {
    globalMonitor != nil || localMonitor != nil
  }

  func start(
    onUserActivity: @escaping () -> Void,
    onEmergencyStop: @escaping () -> Void
  ) {
    stop()
    self.onUserActivity = onUserActivity
    self.onEmergencyStop = onEmergencyStop

    let eventMask: NSEvent.EventTypeMask = [
      .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .keyDown, .scrollWheel,
    ]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
      Task { @MainActor in
        self?.handle(event)
      }
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handle(event)
      }
      return event
    }
  }

  func stop() {
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    onUserActivity = nil
    onEmergencyStop = nil
  }

  private func handle(_ event: NSEvent) {
    guard !MacComputerDriver.isSynthetic(event.cgEvent) else { return }
    if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
      onEmergencyStop?()
      return
    }
    onUserActivity?()
  }
}
