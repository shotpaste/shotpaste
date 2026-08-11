//
//  QuickAccessPanelControllerTests.swift
//  LiteScreenTests
//
//  Regression tests for the panel show/hide transition wedge:
//  a show() landing during the exit animation (or any dropped NSAnimationContext
//  completion) previously left captures with no visible Quick Access panel until
//  the stack fully drained or the app restarted.
//

@testable import LiteScreen
import SwiftUI
import XCTest

@MainActor
final class QuickAccessPanelControllerTests: XCTestCase {
  private var controller: QuickAccessPanelController?

  override func setUp() async throws {
    try await super.setUp()
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      throw XCTSkip("Slide-transition paths are disabled under Reduce Motion")
    }
    guard !NSScreen.screens.isEmpty else {
      throw XCTSkip("No screen available in this environment")
    }
    controller = QuickAccessPanelController()
  }

  override func tearDown() async throws {
    controller?.hide()
    controller = nil
    try await super.tearDown()
  }

  private func showPanel() {
    controller?.show(
      Text("card"),
      size: CGSize(width: 200, height: 400),
      itemCount: 1,
      scale: 1
    )
  }

  /// The previous stack's 0.25s exit animation must never swallow the show()
  /// of a newly captured card that lands mid-exit.
  func testShowDuringExitTransitionStillEndsWithVisiblePanel() async throws {
    showPanel()
    XCTAssertNotNil(controller?.window)
    try await Task.sleep(nanoseconds: 600_000_000) // let the enter finish

    controller?.hide()
    // Exit animation is in flight; the next capture's panel request lands now.
    showPanel()

    // Wait past exit (0.25s) + enter (0.4s) + watchdog slack.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertNotNil(controller?.window, "Panel must exist after show-during-exit")
    XCTAssertTrue(controller?.window?.isVisible ?? false)
  }

  /// Removing the last card while the enter animation is still running must
  /// close the panel instead of leaving a stuck empty window on screen.
  func testHideDuringEnterTransitionClosesPanel() async throws {
    showPanel()
    controller?.hide()

    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertNil(controller?.window, "Hide during enter must close the panel")
  }

  /// Back-to-back hides (e.g. removeItem then dismissAll) must not wedge the
  /// transition state or resurrect the panel.
  func testDoubleHideKeepsPanelClosed() async throws {
    showPanel()
    try await Task.sleep(nanoseconds: 600_000_000) // let the enter finish

    controller?.hide()
    controller?.hide()

    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertNil(controller?.window)
  }

  /// A full cycle followed by a fresh capture must show the panel again —
  /// the steady-state path after all transitions have settled.
  func testShowAfterCompletedCycleShowsPanelAgain() async throws {
    showPanel()
    try await Task.sleep(nanoseconds: 600_000_000)
    controller?.hide()
    try await Task.sleep(nanoseconds: 900_000_000)
    XCTAssertNil(controller?.window)

    showPanel()
    XCTAssertNotNil(controller?.window)
    XCTAssertTrue(controller?.window?.isVisible ?? false)
  }
}
