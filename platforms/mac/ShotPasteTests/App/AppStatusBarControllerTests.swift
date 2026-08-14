//
//  AppStatusBarControllerTests.swift
//  ShotPasteTests
//
//  Unit tests for AppStatusBarController activation policy.
//

import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class AppStatusBarControllerTests: XCTestCase {
  private var controller: AppStatusBarController!
  private var initialPolicy: NSApplication.ActivationPolicy!

  override func setUp() {
    super.setUp()
    controller = AppStatusBarController.shared
    initialPolicy = NSApp.activationPolicy()
  }

  override func tearDown() {
    // Restore initial state
    NSApp.setActivationPolicy(initialPolicy)
    controller.didElevateForSettingsForTesting = false
    controller.trackedPreferencesWindowForTesting = nil
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.recordingHoverBarVisible)
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.recordingShowTimeOnMenuBar)
    super.tearDown()
  }

  // MARK: - Recording UI preference defaults (issue #351)

  func testRecordingUIPreferences_defaultToTrueWhenUnset() {
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.recordingHoverBarVisible)
    UserDefaults.standard.removeObject(forKey: PreferencesKeys.recordingShowTimeOnMenuBar)

    // Defaults must preserve prior behavior: hover bar visible, time shown.
    XCTAssertTrue(controller.isHoverBarVisibleForTesting)
    XCTAssertTrue(controller.showsRecordingTimeOnMenuBarForTesting)
  }

  func testRecordingUIPreferences_reflectStoredFalseValues() {
    UserDefaults.standard.set(false, forKey: PreferencesKeys.recordingHoverBarVisible)
    UserDefaults.standard.set(false, forKey: PreferencesKeys.recordingShowTimeOnMenuBar)

    XCTAssertFalse(controller.isHoverBarVisibleForTesting)
    XCTAssertFalse(controller.showsRecordingTimeOnMenuBarForTesting)
  }

  // MARK: - Menu bar title gating (issue #351)

  func testMenuBarTitle_hiddenWhenTimeDisplayOff_forAllStates() {
    for state in [RecordingState.recording, .paused, .idle, .preparing, .stopping] {
      let title = AppStatusBarController.menuBarTitleString(for: state, duration: "01:23", showTime: false)
      XCTAssertEqual(title, "", "expected empty title for \(state) when time display off")
    }
  }

  func testMenuBarTitle_showsDurationWhileRecording() {
    XCTAssertEqual(
      AppStatusBarController.menuBarTitleString(for: .recording, duration: "01:23", showTime: true),
      "01:23"
    )
  }

  func testMenuBarTitle_prefixesPauseMarkerWhilePaused() {
    XCTAssertEqual(
      AppStatusBarController.menuBarTitleString(for: .paused, duration: "01:23", showTime: true),
      "|| 01:23"
    )
  }

  func testMenuBarTitle_emptyWhenIdleEvenWithTimeOn() {
    for state in [RecordingState.idle, .preparing, .stopping] {
      XCTAssertEqual(
        AppStatusBarController.menuBarTitleString(for: state, duration: "01:23", showTime: true),
        "",
        "expected empty title for non-active state \(state)"
      )
    }
  }

  func testIdleMenuBarTooltipIdentifiesOnlyDebugVariant() {
    XCTAssertEqual(AppStatusBarController.idleMenuBarTooltip(for: .debug), "ShotPaste Debug")
    XCTAssertEqual(AppStatusBarController.idleMenuBarTooltip(for: .release), "ShotPaste")
  }

  func testWindowDidClose_revertsActivationPolicyWhenNoOtherVisibleWindows() {
    // 1. Setup initial elevated state
    controller.didElevateForSettingsForTesting = true
    NSApp.setActivationPolicy(.regular)

    // 2. Create a mock closing window and make it visible
    let closingWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    closingWindow.animationBehavior = .none
    closingWindow.isReleasedWhenClosed = false
    closingWindow.title = "Settings"
    closingWindow.orderFront(nil)
    controller.trackedPreferencesWindowForTesting = closingWindow

    // 3. Post notification/Simulate close
    let notification = Notification(
      name: NSWindow.willCloseNotification,
      object: closingWindow
    )
    controller.simulateWindowDidClose(notification: notification)

    // 4. Verify that activation policy reverted to .accessory
    XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    XCTAssertFalse(controller.didElevateForSettingsForTesting)
    XCTAssertNil(controller.trackedPreferencesWindowForTesting)

    // 5. Cleanup window to prevent leakage
    closingWindow.orderOut(nil)
    closingWindow.close()
  }
}
