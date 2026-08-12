//
//  MacComputerDriver.swift
//  ShotPaste
//
//  Accessibility-first macOS computer control with marked CGEvent fallbacks.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
protocol ComputerDriver: AnyObject {
  func updateAccessibilityElements(_ elements: [String: AXUIElement])
  func execute(_ action: AgentToolAction) async throws -> AgentExecutionResult
  func cancelPendingInput()
}

@MainActor
final class MacComputerDriver: ComputerDriver {
  static let syntheticEventMarker: Int64 = 0x5348_5041_4745_4E54 // "SHPAGENT"

  private var accessibilityElements: [String: AXUIElement] = [:]
  private let eventSource: CGEventSource?
  private var isDragging = false

  init() {
    eventSource = CGEventSource(stateID: .combinedSessionState)
    eventSource?.userData = Self.syntheticEventMarker
  }

  func updateAccessibilityElements(_ elements: [String: AXUIElement]) {
    accessibilityElements = elements
  }

  func execute(_ action: AgentToolAction) async throws -> AgentExecutionResult {
    guard AXIsProcessTrusted() else {
      throw AgentDriverError.accessibilityPermissionRequired
    }

    switch action {
    case .activateApplication(let action):
      try await activateApplication(action)
      return AgentExecutionResult(summary: actionSummary(action))

    case .click(let action):
      try await click(action)
      return AgentExecutionResult(summary: AgentToolAction.click(action).safeSummary)

    case .typeText(let action):
      try await typeText(action)
      return AgentExecutionResult(summary: AgentToolAction.typeText(action).safeSummary)

    case .pressKeys(let action):
      try await pressKeys(action)
      return AgentExecutionResult(summary: AgentToolAction.pressKeys(action).safeSummary)

    case .scroll(let action):
      try scroll(action)
      return AgentExecutionResult(summary: AgentToolAction.scroll(action).safeSummary)

    case .drag(let action):
      try await drag(action)
      return AgentExecutionResult(summary: AgentToolAction.drag(action).safeSummary)

    case .wait(let milliseconds):
      try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
      return AgentExecutionResult(summary: "Waited \(milliseconds) ms")

    case .askUser, .complete:
      throw AgentDriverError.actionFailed("This action is handled by the Agent session coordinator.")
    }
  }

  func cancelPendingInput() {
    guard isDragging else { return }
    isDragging = false
    guard let event = CGEvent(
      mouseEventSource: eventSource,
      mouseType: .leftMouseUp,
      mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
      mouseButton: .left
    ) else { return }
    markAndPost(event)
  }

  static func isSynthetic(_ event: CGEvent?) -> Bool {
    event?.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
  }

  private func activateApplication(
    _ action: AgentActivateApplicationAction
  ) async throws {
    let runningApplications = NSWorkspace.shared.runningApplications
    let application = runningApplications.first { application in
      if let bundleIdentifier = action.bundleIdentifier,
         application.bundleIdentifier == bundleIdentifier {
        return true
      }
      if let name = action.applicationName,
         application.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame {
        return true
      }
      return false
    }
    guard let application else { throw AgentDriverError.applicationNotFound }
    guard application.activate(options: [.activateAllWindows]) else {
      throw AgentDriverError.actionFailed("macOS refused to activate the requested application.")
    }

    try await Task.sleep(nanoseconds: 180_000_000)
    guard let requestedWindowTitle = action.windowTitle,
          !requestedWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }

    let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
    let windows = Self.elementsAttribute(applicationElement, kAXWindowsAttribute as CFString) ?? []
    guard let window = windows.first(where: { window in
      let title = Self.stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
      return title.localizedCaseInsensitiveContains(requestedWindowTitle)
    }) else {
      throw AgentDriverError.elementUnavailable
    }
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  }

  private func click(_ action: AgentClickAction) async throws {
    if action.button == .left,
       action.clickCount == 1,
       let elementID = action.elementID,
       let element = accessibilityElements[elementID] {
      let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
      if status == .success {
        return
      }
    }

    let point: CGPoint
    if let elementID = action.elementID,
       let element = accessibilityElements[elementID],
       let frame = AgentContextAssembler.frame(of: element) {
      point = CGPoint(x: frame.midX, y: frame.midY)
    } else if let displayID = action.displayID, let normalizedPoint = action.point {
      point = try screenPoint(displayID: displayID, normalized: normalizedPoint)
    } else {
      throw AgentDriverError.elementUnavailable
    }

    let mouseButton: CGMouseButton = action.button == .right ? .right : .left
    let downType: CGEventType = action.button == .right ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = action.button == .right ? .rightMouseUp : .leftMouseUp

    for clickIndex in 1 ... action.clickCount {
      guard let down = CGEvent(
        mouseEventSource: eventSource,
        mouseType: downType,
        mouseCursorPosition: point,
        mouseButton: mouseButton
      ), let up = CGEvent(
        mouseEventSource: eventSource,
        mouseType: upType,
        mouseCursorPosition: point,
        mouseButton: mouseButton
      ) else {
        throw AgentDriverError.actionFailed("Unable to create the requested mouse event.")
      }
      down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      markAndPost(down)
      markAndPost(up)
      if action.clickCount == 2, clickIndex == 1 {
        try await Task.sleep(nanoseconds: 90_000_000)
      }
    }
  }

  private func typeText(_ action: AgentTypeTextAction) async throws {
    if let elementID = action.elementID {
      guard let element = accessibilityElements[elementID] else {
        throw AgentDriverError.elementUnavailable
      }
      let status = AXUIElementSetAttributeValue(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
      )
      guard status == .success || status == .attributeUnsupported else {
        throw AgentDriverError.actionFailed("The requested text field could not be focused.")
      }
    }

    for chunk in action.text.utf16Chunks(maximumCount: 24) {
      try Task.checkCancellation()
      guard let keyDown = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 0,
        keyDown: true
      ), let keyUp = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 0,
        keyDown: false
      ) else {
        throw AgentDriverError.actionFailed("Unable to create a text input event.")
      }
      chunk.withUnsafeBufferPointer { buffer in
        keyDown.keyboardSetUnicodeString(
          stringLength: buffer.count,
          unicodeString: buffer.baseAddress
        )
        keyUp.keyboardSetUnicodeString(
          stringLength: buffer.count,
          unicodeString: buffer.baseAddress
        )
      }
      markAndPost(keyDown)
      markAndPost(keyUp)
      await Task.yield()
    }
  }

  private func pressKeys(_ action: AgentKeyPressAction) async throws {
    let normalized = action.keys.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    var flags: CGEventFlags = []
    for key in normalized {
      switch key {
      case "command", "cmd", "⌘": flags.insert(.maskCommand)
      case "shift", "⇧": flags.insert(.maskShift)
      case "option", "alt", "⌥": flags.insert(.maskAlternate)
      case "control", "ctrl", "⌃": flags.insert(.maskControl)
      case "fn", "function": flags.insert(.maskSecondaryFn)
      default: break
      }
    }

    let nonModifierKeys = normalized.filter { !Self.modifierNames.contains($0) }
    guard nonModifierKeys.count == 1,
          let keyName = nonModifierKeys.first,
          let keyCode = Self.keyCode(for: keyName)
    else {
      throw AgentDriverError.unsupportedKey(nonModifierKeys.joined(separator: "+"))
    }
    guard let keyDown = CGEvent(
      keyboardEventSource: eventSource,
      virtualKey: keyCode,
      keyDown: true
    ), let keyUp = CGEvent(
      keyboardEventSource: eventSource,
      virtualKey: keyCode,
      keyDown: false
    ) else {
      throw AgentDriverError.actionFailed("Unable to create the requested keyboard event.")
    }
    keyDown.flags = flags
    keyUp.flags = flags
    markAndPost(keyDown)
    do {
      try await Task.sleep(nanoseconds: 35_000_000)
    } catch {
      markAndPost(keyUp)
      throw error
    }
    markAndPost(keyUp)
  }

  private func scroll(_ action: AgentScrollAction) throws {
    let point = try screenPoint(displayID: action.displayID, normalized: action.point)
    guard let event = CGEvent(
      scrollWheelEvent2Source: eventSource,
      units: .pixel,
      wheelCount: 2,
      wheel1: -action.deltaY,
      wheel2: -action.deltaX,
      wheel3: 0
    ) else {
      throw AgentDriverError.actionFailed("Unable to create the requested scroll event.")
    }
    event.location = point
    markAndPost(event)
  }

  private func drag(_ action: AgentDragAction) async throws {
    let start = try screenPoint(displayID: action.displayID, normalized: action.start)
    let end = try screenPoint(displayID: action.displayID, normalized: action.end)
    guard let down = CGEvent(
      mouseEventSource: eventSource,
      mouseType: .leftMouseDown,
      mouseCursorPosition: start,
      mouseButton: .left
    ) else {
      throw AgentDriverError.actionFailed("Unable to create the requested drag event.")
    }
    markAndPost(down)
    isDragging = true

    let stepCount = max(4, min(60, action.durationMilliseconds / 16))
    let stepDelay = UInt64(action.durationMilliseconds * 1_000_000 / stepCount)
    for step in 1 ... stepCount {
      try Task.checkCancellation()
      let progress = CGFloat(step) / CGFloat(stepCount)
      let point = CGPoint(
        x: start.x + (end.x - start.x) * progress,
        y: start.y + (end.y - start.y) * progress
      )
      guard let dragged = CGEvent(
        mouseEventSource: eventSource,
        mouseType: .leftMouseDragged,
        mouseCursorPosition: point,
        mouseButton: .left
      ) else {
        cancelPendingInput()
        throw AgentDriverError.actionFailed("Unable to continue the requested drag event.")
      }
      markAndPost(dragged)
      try await Task.sleep(nanoseconds: stepDelay)
    }

    guard let up = CGEvent(
      mouseEventSource: eventSource,
      mouseType: .leftMouseUp,
      mouseCursorPosition: end,
      mouseButton: .left
    ) else {
      cancelPendingInput()
      throw AgentDriverError.actionFailed("Unable to finish the requested drag event.")
    }
    markAndPost(up)
    isDragging = false
  }

  private func screenPoint(
    displayID: CGDirectDisplayID,
    normalized: AgentNormalizedPoint
  ) throws -> CGPoint {
    guard normalized.isValid else { throw AgentDriverError.invalidCoordinates }
    let bounds = CGDisplayBounds(displayID)
    guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
      throw AgentDriverError.invalidCoordinates
    }
    return CGPoint(
      x: bounds.minX + CGFloat(normalized.x) * bounds.width,
      y: bounds.minY + CGFloat(normalized.y) * bounds.height
    )
  }

  private func markAndPost(_ event: CGEvent) {
    event.setIntegerValueField(
      .eventSourceUserData,
      value: Self.syntheticEventMarker
    )
    event.post(tap: .cghidEventTap)
  }

  private func actionSummary(_ action: AgentActivateApplicationAction) -> String {
    AgentToolAction.activateApplication(action).safeSummary
  }

  private static func keyCode(for key: String) -> CGKeyCode? {
    if key.count == 1, let character = key.first {
      let map: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
      ]
      if let value = map[character] {
        return CGKeyCode(value)
      }
    }

    let named: [String: Int] = [
      "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
      "space": kVK_Space, "escape": kVK_Escape, "esc": kVK_Escape,
      "delete": kVK_ForwardDelete, "backspace": kVK_Delete,
      "left": kVK_LeftArrow, "right": kVK_RightArrow,
      "up": kVK_UpArrow, "down": kVK_DownArrow,
      "home": kVK_Home, "end": kVK_End,
      "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    ]
    return named[key].map(CGKeyCode.init)
  }

  private static let modifierNames: Set<String> = [
    "command", "cmd", "⌘", "shift", "⇧", "option", "alt", "⌥",
    "control", "ctrl", "⌃", "fn", "function",
  ]

  private static func attribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
      return nil
    }
    return value
  }

  private static func stringAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> String? {
    attribute(element, name) as? String
  }

  private static func elementsAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> [AXUIElement]? {
    attribute(element, name) as? [AXUIElement]
  }
}

private extension String {
  func utf16Chunks(maximumCount: Int) -> [[UniChar]] {
    let units = Array(utf16)
    guard maximumCount > 0, !units.isEmpty else { return units.isEmpty ? [] : [units] }
    return stride(from: 0, to: units.count, by: maximumCount).map { start in
      Array(units[start ..< min(start + maximumCount, units.count)])
    }
  }
}
