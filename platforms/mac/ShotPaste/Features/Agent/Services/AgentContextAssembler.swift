//
//  AgentContextAssembler.swift
//  ShotPaste
//
//  Converts a clean display snapshot into provider-neutral OCR and
//  Accessibility context. Secure text values are never collected.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class AgentContextAssembler {
  private let maximumAccessibilityElements: Int
  private let maximumAccessibilityDepth: Int
  private let maximumOCRLines: Int

  init(
    maximumAccessibilityElements: Int = 180,
    maximumAccessibilityDepth: Int = 7,
    maximumOCRLines: Int = 160
  ) {
    self.maximumAccessibilityElements = maximumAccessibilityElements
    self.maximumAccessibilityDepth = maximumAccessibilityDepth
    self.maximumOCRLines = maximumOCRLines
  }

  func assemble(
    snapshot: FrozenDisplaySnapshot,
    anchor: AgentNormalizedPoint?,
    applicationHint: AgentApplicationContext? = nil
  ) async -> AgentContextAssembly {
    let displayBounds = CGDisplayBounds(snapshot.displayID)
    let application = resolveApplicationContext(hint: applicationHint)
    let accessibility = accessibilitySnapshot(
      application: application,
      displayBounds: displayBounds,
      anchor: anchor
    )
    let ocrLines = await recognizeOCRLines(
      in: snapshot.image,
      displayBounds: displayBounds
    )

    let display = AgentDisplayContext(
      displayID: snapshot.displayID,
      logicalWidth: max(1, Int(displayBounds.width.rounded())),
      logicalHeight: max(1, Int(displayBounds.height.rounded())),
      pixelWidth: snapshot.image.width,
      pixelHeight: snapshot.image.height,
      scaleFactor: Double(snapshot.pixelScaleFactor)
    )
    let observation = AgentObservation(
      id: UUID(),
      capturedAt: Date(),
      display: display,
      application: application,
      anchor: anchor,
      accessibilityElements: accessibility.snapshots,
      ocrLines: ocrLines,
      screenshot: snapshot.image
    )
    return AgentContextAssembly(
      observation: observation,
      accessibilityElements: accessibility.elements
    )
  }

  func currentApplicationContext() -> AgentApplicationContext {
    resolveApplicationContext(hint: nil)
  }

  private func resolveApplicationContext(
    hint: AgentApplicationContext?
  ) -> AgentApplicationContext {
    let runningApplication: NSRunningApplication? = if let hint, hint.processIdentifier > 0 {
      NSRunningApplication(
        processIdentifier: pid_t(hint.processIdentifier)
      ) ?? NSWorkspace.shared.frontmostApplication
    } else {
      NSWorkspace.shared.frontmostApplication
    }

    guard let runningApplication else { return hint ?? .unknown }
    let applicationElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
    let windowTitle = Self.stringAttribute(applicationElement, kAXFocusedWindowAttribute as CFString)
      ?? focusedWindowTitle(applicationElement)

    return AgentApplicationContext(
      processIdentifier: runningApplication.processIdentifier,
      bundleIdentifier: runningApplication.bundleIdentifier ?? hint?.bundleIdentifier,
      applicationName: runningApplication.localizedName ?? hint?.applicationName ?? "Unknown application",
      windowTitle: windowTitle ?? hint?.windowTitle
    )
  }

  private func focusedWindowTitle(_ applicationElement: AXUIElement) -> String? {
    guard let focusedWindow = Self.elementAttribute(
      applicationElement,
      kAXFocusedWindowAttribute as CFString
    ) else { return nil }
    return Self.stringAttribute(focusedWindow, kAXTitleAttribute as CFString)
  }

  private func accessibilitySnapshot(
    application: AgentApplicationContext,
    displayBounds: CGRect,
    anchor: AgentNormalizedPoint?
  ) -> (
    snapshots: [AgentAccessibilityElementSnapshot],
    elements: [String: AXUIElement]
  ) {
    guard AXIsProcessTrusted(), application.processIdentifier > 0 else {
      return ([], [:])
    }

    var snapshots: [AgentAccessibilityElementSnapshot] = []
    var elements: [String: AXUIElement] = [:]

    if let anchor,
       let anchorElement = elementAtAnchor(anchor, displayBounds: displayBounds) {
      appendElement(
        anchorElement,
        id: "ax:anchor",
        displayBounds: displayBounds,
        snapshots: &snapshots,
        elements: &elements
      )
    }

    let applicationElement = AXUIElementCreateApplication(pid_t(application.processIdentifier))
    let root = Self.elementAttribute(applicationElement, kAXFocusedWindowAttribute as CFString)
      ?? applicationElement
    walkAccessibilityTree(
      root,
      depth: 0,
      displayBounds: displayBounds,
      snapshots: &snapshots,
      elements: &elements
    )
    return (snapshots, elements)
  }

  private func walkAccessibilityTree(
    _ element: AXUIElement,
    depth: Int,
    displayBounds: CGRect,
    snapshots: inout [AgentAccessibilityElementSnapshot],
    elements: inout [String: AXUIElement]
  ) {
    guard depth <= maximumAccessibilityDepth,
          snapshots.count < maximumAccessibilityElements
    else { return }

    let id = "ax:\(snapshots.count)"
    appendElement(
      element,
      id: id,
      displayBounds: displayBounds,
      snapshots: &snapshots,
      elements: &elements
    )

    guard depth < maximumAccessibilityDepth,
          snapshots.count < maximumAccessibilityElements,
          let children = Self.elementsAttribute(element, kAXChildrenAttribute as CFString)
    else { return }

    for child in children {
      guard snapshots.count < maximumAccessibilityElements else { break }
      walkAccessibilityTree(
        child,
        depth: depth + 1,
        displayBounds: displayBounds,
        snapshots: &snapshots,
        elements: &elements
      )
    }
  }

  private func appendElement(
    _ element: AXUIElement,
    id: String,
    displayBounds: CGRect,
    snapshots: inout [AgentAccessibilityElementSnapshot],
    elements: inout [String: AXUIElement]
  ) {
    let role = Self.stringAttribute(element, kAXRoleAttribute as CFString) ?? "AXUnknown"
    let subrole = Self.stringAttribute(element, kAXSubroleAttribute as CFString)
    let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
    let title = Self.sanitized(Self.stringAttribute(element, kAXTitleAttribute as CFString))
    let elementDescription = Self.sanitized(
      Self.stringAttribute(element, kAXDescriptionAttribute as CFString)
    )
    let value = isSecure
      ? nil
      : Self.sanitized(Self.stringAttribute(element, kAXValueAttribute as CFString))
    let enabled = Self.boolAttribute(element, kAXEnabledAttribute as CFString) ?? true
    let focused = Self.boolAttribute(element, kAXFocusedAttribute as CFString) ?? false
    let frame = Self.frame(of: element)
    let normalizedFrame = frame.flatMap {
      Self.normalizedFrame($0, displayBounds: displayBounds)
    }

    snapshots.append(AgentAccessibilityElementSnapshot(
      id: id,
      role: role,
      subrole: subrole,
      title: title,
      elementDescription: elementDescription,
      value: value,
      enabled: enabled,
      focused: focused,
      normalizedFrame: normalizedFrame,
      isSecure: isSecure
    ))
    elements[id] = element
  }

  private func elementAtAnchor(
    _ anchor: AgentNormalizedPoint,
    displayBounds: CGRect
  ) -> AXUIElement? {
    guard anchor.isValid else { return nil }
    let point = CGPoint(
      x: displayBounds.minX + CGFloat(anchor.x) * displayBounds.width,
      y: displayBounds.minY + CGFloat(anchor.y) * displayBounds.height
    )
    var element: AXUIElement?
    let status = AXUIElementCopyElementAtPosition(
      AXUIElementCreateSystemWide(),
      Float(point.x),
      Float(point.y),
      &element
    )
    return status == .success ? element : nil
  }

  private func recognizeOCRLines(
    in image: CGImage,
    displayBounds _: CGRect
  ) async -> [AgentOCRLineSnapshot] {
    guard let result = try? await OCRService.shared.recognize(
      OCRRequest(image: image, preferredLanguageIdentifier: nil, contentType: .interfaceText)
    ) else {
      return []
    }

    return result.lines.prefix(maximumOCRLines).enumerated().map { index, line in
      let box = line.boundingBox
      let normalizedFrame = AgentNormalizedRect(
        x: Double(min(max(box.minX, 0), 1)),
        y: Double(min(max(1 - box.maxY, 0), 1)),
        width: Double(min(max(box.width, 0), 1)),
        height: Double(min(max(box.height, 0), 1))
      )
      return AgentOCRLineSnapshot(
        id: "ocr:\(index)",
        text: String(line.text.prefix(300)),
        confidence: line.confidence,
        normalizedFrame: normalizedFrame
      )
    }
  }

  private static func normalizedFrame(
    _ frame: CGRect,
    displayBounds: CGRect
  ) -> AgentNormalizedRect? {
    guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
    let intersection = frame.intersection(displayBounds)
    guard !intersection.isNull, !intersection.isEmpty else { return nil }
    return AgentNormalizedRect(
      x: Double((intersection.minX - displayBounds.minX) / displayBounds.width),
      y: Double((intersection.minY - displayBounds.minY) / displayBounds.height),
      width: Double(intersection.width / displayBounds.width),
      height: Double(intersection.height / displayBounds.height)
    )
  }

  static func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
          let sizeValue = attribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    let axPosition = unsafeBitCast(positionValue, to: AXValue.self)
    let axSize = unsafeBitCast(sizeValue, to: AXValue.self)
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(axPosition, .cgPoint, &position),
          AXValueGetValue(axSize, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
  }

  private static func sanitized(_ value: String?) -> String? {
    guard let value else { return nil }
    let collapsed = value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return nil }
    return String(collapsed.prefix(300))
  }

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

  private static func stringAttribute(
    _ element: AXUIElement,
    _ elementAttributeName: String
  ) -> String? {
    guard let child = elementAttribute(element, elementAttributeName as CFString) else {
      return nil
    }
    return stringAttribute(child, kAXTitleAttribute as CFString)
  }

  private static func boolAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> Bool? {
    attribute(element, name) as? Bool
  }

  private static func elementAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> AXUIElement? {
    guard let value = attribute(element, name),
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
  }

  private static func elementsAttribute(
    _ element: AXUIElement,
    _ name: CFString
  ) -> [AXUIElement]? {
    attribute(element, name) as? [AXUIElement]
  }
}
