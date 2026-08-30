//
//  MacComputerDriverTests.swift
//  ShotPasteTests
//

@testable import ShotPaste
import XCTest

final class MacComputerDriverTests: XCTestCase {
  func testNativeSemanticControlsPreferAccessibilityPress() {
    for role in ["AXButton", "AXCheckBox", "AXMenuItem", "AXRadioButton", "AXSlider"] {
      XCTAssertTrue(AgentClickDispatchPolicy.prefersAccessibilityPress(
        button: .left,
        clickCount: 1,
        role: role,
        hasUsableFrame: true
      ))
    }
  }

  func testCustomFrameBackedSurfacesPreferPointerEvents() {
    for role in [
      "AXRow", "AXCell", "AXGroup", "AXStaticText", "AXImage", "AXList", "AXWebArea", "AXUnknown",
    ] {
      XCTAssertFalse(AgentClickDispatchPolicy.prefersAccessibilityPress(
        button: .left,
        clickCount: 1,
        role: role,
        hasUsableFrame: true
      ))
    }
  }

  func testFramelessElementKeepsAccessibilityAsOnlySemanticRoute() {
    XCTAssertTrue(AgentClickDispatchPolicy.prefersAccessibilityPress(
      button: .left,
      clickCount: 1,
      role: "AXGroup",
      hasUsableFrame: false
    ))
  }

  func testRightAndDoubleClicksRequirePointerEvents() {
    XCTAssertFalse(AgentClickDispatchPolicy.prefersAccessibilityPress(
      button: .right,
      clickCount: 1,
      role: "AXButton",
      hasUsableFrame: true
    ))
    XCTAssertFalse(AgentClickDispatchPolicy.prefersAccessibilityPress(
      button: .left,
      clickCount: 2,
      role: "AXButton",
      hasUsableFrame: true
    ))
  }

  func testPromptTreatsDispatchAsDistinctFromUISuccess() {
    XCTAssertTrue(AgentLLMPromptBuilder.systemPrompt.contains(
      "An action result confirms only that input was dispatched"
    ))
    XCTAssertTrue(AgentLLMPromptBuilder.systemPrompt.contains(
      "do not repeat the same element_id"
    ))
  }
}
