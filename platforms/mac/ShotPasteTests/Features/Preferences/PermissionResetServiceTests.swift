//
//  PermissionResetServiceTests.swift
//  ShotPasteTests
//

@testable import ShotPaste
import XCTest

final class PermissionResetServiceTests: XCTestCase {
  func testCommandArgumentsResetOnlyShotPasteManagedServices() {
    let bundleIdentifier = "com.example.ShotPaste"

    XCTAssertEqual(
      PermissionResetService.commandArguments(bundleIdentifier: bundleIdentifier),
      [
        ["reset", "ScreenCapture", bundleIdentifier],
        ["reset", "Microphone", bundleIdentifier],
        ["reset", "Accessibility", bundleIdentifier],
      ]
    )
  }

  func testReportSucceedsOnlyWhenEveryResetCommandSucceeded() {
    XCTAssertTrue(PermissionResetReport(failures: []).succeeded)
    XCTAssertFalse(PermissionResetReport(failures: [
      .init(service: "ScreenCapture", terminationStatus: 1),
    ]).succeeded)
  }
}
