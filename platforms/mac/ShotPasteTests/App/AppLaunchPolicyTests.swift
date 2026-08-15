//
//  AppLaunchPolicyTests.swift
//  ShotPasteTests
//
//  Unit tests for deciding whether the host app should start interactive UI.
//

import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class AppLaunchPolicyTests: XCTestCase {
  func testShouldStartInteractiveApplication_underXCTestSkipsBeforeScreenAccess() {
    var didRequestScreenCount = false
    let policy = AppLaunchPolicy(
      environment: ["XCTestConfigurationFilePath": "/tmp/ShotPasteTests.xctestconfiguration"],
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
        "XCTestConfigurationFilePath": "/tmp/ShotPasteTests.xctestconfiguration",
        "SHOTPASTE_ALLOW_INTERACTIVE_XCTEST_HOST": "1",
      ],
      screenCountProvider: { 1 }
    )

    XCTAssertTrue(policy.shouldStartInteractiveApplication)
  }

  func testSingleInstanceProtection_requiresEnabledInfoPlistBoolean() {
    XCTAssertTrue(
      SingleInstanceProtection.isEnabled(in: [
        SingleInstanceProtection.infoPlistKey: true,
      ])
    )
    XCTAssertFalse(
      SingleInstanceProtection.isEnabled(in: [
        SingleInstanceProtection.infoPlistKey: false,
      ])
    )
    XCTAssertFalse(SingleInstanceProtection.isEnabled(in: [:]))
  }

  func testApplicationReopenPolicy_opensPreferencesOnlyAfterLaunchCompletes() {
    XCTAssertFalse(ApplicationReopenPolicy.shouldOpenPreferences(didFinishLaunching: false))
    XCTAssertTrue(ApplicationReopenPolicy.shouldOpenPreferences(didFinishLaunching: true))
  }

  func testApplicationReopenPolicy_opensPreferencesForDefaultLaunch() {
    XCTAssertTrue(
      ApplicationReopenPolicy.shouldOpenPreferencesAfterLaunch(
        isDefaultLaunch: true,
        didSchedulePermissionGuide: false
      )
    )
  }

  func testApplicationReopenPolicy_doesNotInterruptNonDefaultOrPermissionGuideLaunch() {
    XCTAssertFalse(
      ApplicationReopenPolicy.shouldOpenPreferencesAfterLaunch(
        isDefaultLaunch: true,
        didSchedulePermissionGuide: true
      )
    )
    XCTAssertFalse(
      ApplicationReopenPolicy.shouldOpenPreferencesAfterLaunch(
        isDefaultLaunch: false,
        didSchedulePermissionGuide: false
      )
    )
  }

  func testRelaunchPlan_waitsForCurrentProcessAndDoesNotForceDuplicateInstance() {
    let bundleURL = URL(fileURLWithPath: "/Applications/Shot Paste.app")

    let plan = AppRelaunchPlan(bundleURL: bundleURL, processIdentifier: 42)

    XCTAssertEqual(plan.executableURL.path, "/bin/sh")
    XCTAssertEqual(plan.arguments[0], "-c")
    XCTAssertEqual(plan.arguments[2], "shotpaste-relaunch")
    XCTAssertEqual(plan.arguments[3], "42")
    XCTAssertEqual(plan.arguments[4], bundleURL.path)
    XCTAssertFalse(plan.arguments.contains("-n"))
    XCTAssertTrue(plan.arguments[1].contains("kill -0 \"$1\""))
    XCTAssertTrue(plan.arguments[1].contains("open \"$2\""))
  }
}
