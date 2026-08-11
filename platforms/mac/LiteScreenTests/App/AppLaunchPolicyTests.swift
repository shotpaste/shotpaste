//
//  AppLaunchPolicyTests.swift
//  LiteScreenTests
//
//  Unit tests for deciding whether the host app should start interactive UI.
//

import AppKit
@testable import LiteScreen
import XCTest

@MainActor
final class AppLaunchPolicyTests: XCTestCase {
  func testShouldStartInteractiveApplication_underXCTestSkipsBeforeScreenAccess() {
    var didRequestScreenCount = false
    let policy = AppLaunchPolicy(
      environment: ["XCTestConfigurationFilePath": "/tmp/LiteScreenTests.xctestconfiguration"],
      screenCountProvider: {
        didRequestScreenCount = true
        return 1
      }
    )

    XCTAssertFalse(policy.shouldStartInteractiveApplication)
    XCTAssertFalse(didRequestScreenCount)
  }

  func testShouldStartInteractiveApplication_headlessDisplaySessionReturnsFalse() {
    let policy = AppLaunchPolicy(
      environment: [:],
      screenCountProvider: { 0 }
    )

    XCTAssertTrue(policy.isHeadlessDisplaySession)
    XCTAssertFalse(policy.shouldStartInteractiveApplication)
  }

  func testShouldStartInteractiveApplication_interactiveDisplaySessionReturnsTrue() {
    let policy = AppLaunchPolicy(
      environment: [:],
      screenCountProvider: { 1 }
    )

    XCTAssertFalse(policy.isRunningUnderXCTest)
    XCTAssertFalse(policy.isHeadlessDisplaySession)
    XCTAssertTrue(policy.shouldStartInteractiveApplication)
  }

  func testShouldStartInteractiveApplication_canOptInInteractiveXCTestHost() {
    let policy = AppLaunchPolicy(
      environment: [
        "XCTestConfigurationFilePath": "/tmp/LiteScreenTests.xctestconfiguration",
        "LITESCREEN_ALLOW_INTERACTIVE_XCTEST_HOST": "1",
      ],
      screenCountProvider: { 1 }
    )

    XCTAssertTrue(policy.shouldStartInteractiveApplication)
  }
}
