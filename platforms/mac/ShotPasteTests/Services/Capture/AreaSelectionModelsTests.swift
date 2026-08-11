//
//  AreaSelectionModelsTests.swift
//  ShotPasteTests
//
//  Unit tests for the One Shot area-selection result model.
//

import AppKit
@testable import ShotPaste
import XCTest

final class AreaSelectionModelsTests: XCTestCase {
  func testAreaSelectionResult_defaultsToPrimaryDisplay() {
    let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
    let result = AreaSelectionResult(rect: rect, displayID: 1)

    XCTAssertEqual(result.rect, rect)
    XCTAssertEqual(result.displayIDs, [1])
    XCTAssertFalse(result.spansMultipleDisplays)
  }

  func testAreaSelectionResult_tracksMultipleDisplays() {
    let result = AreaSelectionResult(
      rect: CGRect(x: 0, y: 0, width: 100, height: 100),
      displayID: 1,
      displayIDs: [1, 2]
    )

    XCTAssertEqual(result.displayIDs, [1, 2])
    XCTAssertTrue(result.spansMultipleDisplays)
  }
}

final class CaptureViewModelTests: XCTestCase {
  func testHiddenWindowSession_restore_postsSyntheticMouseMovedEvent() throws {
    let policy = AppLaunchPolicy()
    let isCI = ProcessInfo.processInfo.environment["CI"] != nil || ProcessInfo.processInfo
      .environment["GITHUB_ACTIONS"] != nil
    if isCI || policy.isHeadlessDisplaySession || NSScreen.screens.isEmpty {
      throw XCTSkip("Skipping window restore test in CI or headless display session")
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    defer {
      window.orderOut(nil)
      window.close()
    }
    window.orderFront(nil)

    let session = ScreenCaptureViewModel.HiddenWindowSession(
      windows: [window],
      keyWindow: nil,
      mainWindow: nil,
      shouldReactivateApp: false
    )

    let expectation = XCTestExpectation(description: "Synthetic mouse event posted")
    ScreenCaptureViewModel.HiddenWindowSession.onPostSyntheticMouseEvent = { event in
      if event.windowNumber == 0 {
        expectation.fulfill()
      }
    }
    defer {
      ScreenCaptureViewModel.HiddenWindowSession.onPostSyntheticMouseEvent = nil
    }

    session.restore()
    wait(for: [expectation], timeout: 2.0)
  }
}
