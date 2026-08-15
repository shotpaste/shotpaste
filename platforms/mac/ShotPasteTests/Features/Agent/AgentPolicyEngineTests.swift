//
//  AgentPolicyEngineTests.swift
//  ShotPasteTests
//

import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class AgentPolicyEngineTests: XCTestCase {
  private let engine = AgentPolicyEngine()
  private let initialApplication = AgentApplicationContext(
    processIdentifier: 10,
    bundleIdentifier: "com.example.editor",
    applicationName: "Editor",
    windowTitle: "Document"
  )

  func testSecureFocusedFieldBlocksTypingWithoutElementID() {
    let decision = engine.evaluate(context(
      action: .typeText(AgentTypeTextAction(text: "not-a-real-secret", elementID: nil)),
      elements: [element(id: "ax:1", role: "AXSecureTextField", focused: true, secure: true)]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected typing into a focused secure field to be denied")
    }
  }

  func testPasswordIntentBlocksTypingEvenWithoutSecureMetadata() {
    let decision = engine.evaluate(context(
      userIntentText: "Enter my password in this form",
      action: .typeText(AgentTypeTextAction(text: "not-a-real-secret", elementID: nil))
    ))

    guard case .deny = decision else {
      return XCTFail("Expected password entry to be denied")
    }
  }

  func testKeystrokeIsBlockedWhileSecureFieldIsFocused() {
    let decision = engine.evaluate(context(
      action: .pressKeys(AgentKeyPressAction(keys: ["command", "v"])),
      elements: [element(id: "ax:1", role: "AXSecureTextField", focused: true, secure: true)]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected paste and key chords in secure fields to be denied")
    }
  }

  func testCrossApplicationActivationRequiresApplicationApproval() {
    let decision = engine.evaluate(context(action: .activateApplication(
      AgentActivateApplicationAction(
        bundleIdentifier: "com.apple.Safari",
        applicationName: "Safari",
        windowTitle: nil
      )
    )))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected cross-application approval")
    }
    XCTAssertEqual(request.risk, .crossApplication)
    XCTAssertEqual(request.proposedScope, .application(bundleIdentifier: "com.apple.Safari"))
  }

  func testNameOnlyCrossApplicationActivationStillRequiresApproval() {
    let decision = engine.evaluate(context(action: .activateApplication(
      AgentActivateApplicationAction(
        bundleIdentifier: nil,
        applicationName: "Safari",
        windowTitle: nil
      )
    )))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected name-only activation to be approval-gated")
    }
    XCTAssertEqual(request.risk, .crossApplication)
    XCTAssertEqual(request.proposedScope, .actionOnly)
  }

  func testApprovedApplicationMayReceiveSubsequentActions() {
    let safari = AgentApplicationContext(
      processIdentifier: 11,
      bundleIdentifier: "com.apple.Safari",
      applicationName: "Safari",
      windowTitle: "Example"
    )
    let decision = engine.evaluate(context(
      action: .scroll(AgentScrollAction(
        displayID: 1,
        point: AgentNormalizedPoint(x: 0.5, y: 0.5),
        deltaX: 0,
        deltaY: 120
      )),
      currentApplication: safari,
      approvedApplications: ["com.apple.Safari"]
    ))

    XCTAssertEqual(decision, .allow)
  }

  func testSendButtonClickRequiresConcreteApproval() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:send",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      elements: [element(id: "ax:send", role: "AXButton", title: "Send")]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected external communication approval")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
    XCTAssertTrue(request.detail.contains("Send"))
  }

  func testTerminalTextInputIsDeniedInsteadOfApprovalGated() {
    let terminal = AgentApplicationContext(
      processIdentifier: 12,
      bundleIdentifier: "com.apple.Terminal",
      applicationName: "Terminal",
      windowTitle: "zsh"
    )
    let decision = engine.evaluate(context(
      action: .typeText(AgentTypeTextAction(text: "echo unsafe", elementID: nil)),
      currentApplication: terminal,
      approvedApplications: ["com.apple.Terminal"]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected terminal input to remain prohibited after cross-app approval")
    }
  }

  func testAppleScriptApplicationActivationIsDenied() {
    let decision = engine.evaluate(context(action: .activateApplication(
      AgentActivateApplicationAction(
        bundleIdentifier: "com.apple.ScriptEditor2",
        applicationName: "Script Editor",
        windowTitle: nil
      )
    )))

    guard case .deny = decision else {
      return XCTFail("Expected AppleScript tools to be prohibited")
    }
  }

  func testFinderFileDeletionIsDenied() {
    let finder = AgentApplicationContext(
      processIdentifier: 13,
      bundleIdentifier: "com.apple.finder",
      applicationName: "Finder",
      windowTitle: "Documents"
    )
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:trash",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      currentApplication: finder,
      elements: [element(id: "ax:trash", role: "AXMenuItem", title: "Move to Trash")],
      approvedApplications: ["com.apple.finder"]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected file deletion to be prohibited")
    }
  }

  func testNonFileDeletionStillRequiresConfirmation() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:delete-message",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      elements: [element(id: "ax:delete-message", role: "AXButton", title: "Delete message")]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected non-file deletion to require confirmation")
    }
    XCTAssertEqual(request.risk, .deletion)
  }

  func testSafeSemanticClickIsAllowed() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:next",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      elements: [element(id: "ax:next", role: "AXButton", title: "Next")]
    ))

    XCTAssertEqual(decision, .allow)
  }

  func testCoordinateClickOverSendButtonRequiresApproval() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.5, y: 0.5),
      elements: [
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected coordinate click on Send to require approval")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
  }

  func testCoordinateClickUsesInnermostElementAsPrimaryTarget() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.5, y: 0.5),
      elements: [
        framedElement(
          id: "ax:window",
          role: "AXWindow",
          title: "Composer",
          frame: AgentNormalizedRect(x: 0, y: 0, width: 1, height: 1)
        ),
        framedElement(
          id: "ax:cancel",
          role: "AXButton",
          title: "Cancel",
          frame: AgentNormalizedRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        ),
      ]
    ))

    XCTAssertEqual(decision, .allow)
  }

  func testCoordinateClickOverSecureFieldIsDenied() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.5, y: 0.5),
      elements: [
        framedElement(
          id: "ax:password",
          role: "AXSecureTextField",
          title: "Password",
          secure: true,
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
      ]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected coordinate click on a secure field to be denied")
    }
  }

  func testCoordinateClickOverFinderTrashIsDenied() {
    let finder = AgentApplicationContext(
      processIdentifier: 13,
      bundleIdentifier: "com.apple.finder",
      applicationName: "Finder",
      windowTitle: "Documents"
    )
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.5, y: 0.5),
      currentApplication: finder,
      elements: [
        framedElement(
          id: "ax:trash",
          role: "AXMenuItem",
          title: "Move to Trash",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
      ],
      approvedApplications: ["com.apple.finder"]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected coordinate file deletion to be denied")
    }
  }

  func testCoordinateClickOnUnobservedDisplayRequiresApproval() {
    let decision = engine.evaluate(context(
      action: coordinateClick(displayID: 2, x: 0.5, y: 0.5)
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected unverified coordinate click to require approval")
    }
    XCTAssertEqual(request.risk, .unverifiedTarget)
    XCTAssertEqual(request.proposedScope, .actionOnly)
  }

  func testCoordinateClickWithNoObservedHitRequiresApproval() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.9, y: 0.9),
      elements: [
        framedElement(
          id: "ax:toolbar",
          role: "AXGroup",
          frame: AgentNormalizedRect(x: 0, y: 0, width: 0.5, height: 0.2)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected an unmatched coordinate click to require approval")
    }
    XCTAssertEqual(request.risk, .unverifiedTarget)
    XCTAssertEqual(request.proposedScope, .actionOnly)
  }

  func testInvalidCoordinateClickIsDenied() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 1.1, y: 0.5)
    ))

    guard case .deny = decision else {
      return XCTFail("Expected invalid coordinates to be denied")
    }
  }

  func testCoordinateClickWithUnknownElementIDFallsBackToCoordinates() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:missing",
        displayID: 1,
        point: AgentNormalizedPoint(x: 0.5, y: 0.5),
        button: .left,
        clickCount: 1
      )),
      elements: [
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected coordinate fallback on Send to require approval")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
  }

  func testFramelessElementFallbackInheritsCoordinateRisk() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:icon",
        displayID: 1,
        point: AgentNormalizedPoint(x: 0.5, y: 0.5),
        button: .right,
        clickCount: 1
      )),
      elements: [
        element(id: "ax:icon", role: "AXImage", title: "Attachment"),
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected frameless fallback over Send to require approval")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
  }

  func testFramelessElementFallbackWithNoObservedHitRequiresApproval() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:icon",
        displayID: 1,
        point: AgentNormalizedPoint(x: 0.9, y: 0.9),
        button: .left,
        clickCount: 2
      )),
      elements: [element(id: "ax:icon", role: "AXImage", title: "Preview")]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected unmatched frameless fallback to require approval")
    }
    XCTAssertEqual(request.risk, .unverifiedTarget)
  }

  func testFramelessElementFallbackToUnobservedDisplayIsDenied() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:icon",
        displayID: 2,
        point: AgentNormalizedPoint(x: 0.5, y: 0.5),
        button: .right,
        clickCount: 1
      )),
      elements: [element(id: "ax:icon", role: "AXImage", title: "Preview")]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected semantic target with cross-display fallback to be denied")
    }
  }

  func testFramelessSingleLeftClickMayUseAccessibilityPress() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:next",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      elements: [element(id: "ax:next", role: "AXButton", title: "Next")]
    ))

    XCTAssertEqual(decision, .allow)
  }

  func testFramelessPointerClicksWithoutFallbackCoordinatesAreDenied() {
    for action in [
      AgentClickAction(
        elementID: "ax:preview",
        displayID: nil,
        point: nil,
        button: .right,
        clickCount: 1
      ),
      AgentClickAction(
        elementID: "ax:preview",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 2
      ),
    ] {
      let decision = engine.evaluate(context(
        action: .click(action),
        elements: [element(id: "ax:preview", role: "AXImage", title: "Preview")]
      ))

      guard case .deny = decision else {
        return XCTFail("Expected right and double clicks without a pointer location to be denied")
      }
    }
  }

  func testCoordinateClickTextlessChildDoesNotMaskParentSendRisk() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.5, y: 0.5),
      elements: [
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
        framedElement(
          id: "ax:icon",
          role: "AXImage",
          frame: AgentNormalizedRect(x: 0.48, y: 0.48, width: 0.04, height: 0.04)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected parent Send risk to survive a text-less child")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
  }

  func testCoordinateClickDegenerateFrameDoesNotMaskRiskElement() {
    let decision = engine.evaluate(context(
      action: coordinateClick(x: 0.5, y: 0.5),
      elements: [
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
        framedElement(
          id: "ax:divider",
          role: "AXDivider",
          frame: AgentNormalizedRect(x: 0.5, y: 0.5, width: 0, height: 0.1)
        ),
        framedElement(
          id: "ax:ruler",
          role: "AXRuler",
          frame: AgentNormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected degenerate frames not to mask the Send risk")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
  }

  func testElementIDClickNestedInParentSendButtonRequiresApproval() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:send-icon",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      elements: [
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
        framedElement(
          id: "ax:send-icon",
          role: "AXImage",
          frame: AgentNormalizedRect(x: 0.48, y: 0.48, width: 0.04, height: 0.04)
        ),
      ]
    ))

    guard case .requireApproval(let request) = decision else {
      return XCTFail("Expected an element ID nested in Send to require approval")
    }
    XCTAssertEqual(request.risk, .externalCommunication)
  }

  func testCoordinateClickMissingBothTargetsIsDenied() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: nil,
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      ))
    ))

    guard case .deny = decision else {
      return XCTFail("Expected an unresolvable click to be denied")
    }
  }

  func testDisabledElementIDStaysPrimaryTargetDespiteEnabledChild() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:send",
        displayID: nil,
        point: nil,
        button: .left,
        clickCount: 1
      )),
      elements: [
        framedElement(
          id: "ax:send",
          role: "AXButton",
          title: "Send",
          enabled: false,
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
        framedElement(
          id: "ax:send-icon",
          role: "AXImage",
          frame: AgentNormalizedRect(x: 0.48, y: 0.48, width: 0.04, height: 0.04)
        ),
      ]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected a disabled requested element to be denied despite an enabled child")
    }
  }

  func testDisabledInnermostPointerTargetIsDenied() {
    let decision = engine.evaluate(context(
      action: .click(AgentClickAction(
        elementID: "ax:container",
        displayID: nil,
        point: nil,
        button: .right,
        clickCount: 1
      )),
      elements: [
        framedElement(
          id: "ax:container",
          role: "AXGroup",
          frame: AgentNormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        ),
        framedElement(
          id: "ax:disabled-child",
          role: "AXButton",
          title: "Next",
          enabled: false,
          frame: AgentNormalizedRect(x: 0.48, y: 0.48, width: 0.04, height: 0.04)
        ),
      ]
    ))

    guard case .deny = decision else {
      return XCTFail("Expected a disabled pointer target to be denied")
    }
  }

  private func context(
    userIntentText: String = "Format this document",
    action: AgentToolAction,
    currentApplication: AgentApplicationContext? = nil,
    elements: [AgentAccessibilityElementSnapshot] = [],
    approvedApplications: Set<String> = [],
    observationDisplayID: CGDirectDisplayID = 1
  ) -> AgentPolicyContext {
    AgentPolicyContext(
      userIntentText: userIntentText,
      initialApplication: initialApplication,
      currentApplication: currentApplication ?? initialApplication,
      action: action,
      accessibilityElements: elements,
      approvedApplicationBundleIdentifiers: approvedApplications,
      observationDisplayID: observationDisplayID
    )
  }

  private func coordinateClick(
    displayID: CGDirectDisplayID = 1,
    x: Double,
    y: Double
  ) -> AgentToolAction {
    .click(AgentClickAction(
      elementID: nil,
      displayID: displayID,
      point: AgentNormalizedPoint(x: x, y: y),
      button: .left,
      clickCount: 1
    ))
  }

  private func framedElement(
    id: String,
    role: String,
    title: String? = nil,
    secure: Bool = false,
    enabled: Bool = true,
    frame: AgentNormalizedRect
  ) -> AgentAccessibilityElementSnapshot {
    AgentAccessibilityElementSnapshot(
      id: id,
      role: role,
      subrole: nil,
      title: title,
      elementDescription: nil,
      value: nil,
      enabled: enabled,
      focused: false,
      normalizedFrame: frame,
      isSecure: secure
    )
  }

  private func element(
    id: String,
    role: String,
    title: String? = nil,
    focused: Bool = false,
    secure: Bool = false
  ) -> AgentAccessibilityElementSnapshot {
    AgentAccessibilityElementSnapshot(
      id: id,
      role: role,
      subrole: nil,
      title: title,
      elementDescription: nil,
      value: nil,
      enabled: true,
      focused: focused,
      normalizedFrame: nil,
      isSecure: secure
    )
  }
}
