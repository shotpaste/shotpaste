//
//  AgentPolicyEngineTests.swift
//  ShotPasteTests
//

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

  private func context(
    userIntentText: String = "Format this document",
    action: AgentToolAction,
    currentApplication: AgentApplicationContext? = nil,
    elements: [AgentAccessibilityElementSnapshot] = [],
    approvedApplications: Set<String> = []
  ) -> AgentPolicyContext {
    AgentPolicyContext(
      userIntentText: userIntentText,
      initialApplication: initialApplication,
      currentApplication: currentApplication ?? initialApplication,
      action: action,
      accessibilityElements: elements,
      approvedApplicationBundleIdentifiers: approvedApplications
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
