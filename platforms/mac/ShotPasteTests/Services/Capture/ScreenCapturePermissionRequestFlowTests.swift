//
//  ScreenCapturePermissionRequestFlowTests.swift
//  ShotPasteTests
//
//  Regression coverage for the single-prompt screen-capture permission flow.
//

@testable import ShotPaste
import XCTest

final class ScreenCapturePermissionRequestFlowTests: XCTestCase {
  func testGrantedPreflightSkipsNativeRequest() {
    var preflightCount = 0
    var requestCount = 0

    let granted = ScreenCapturePermissionRequestFlow.requestAccess(
      preflight: {
        preflightCount += 1
        return true
      },
      request: {
        requestCount += 1
        return false
      }
    )

    XCTAssertTrue(granted)
    XCTAssertEqual(preflightCount, 1)
    XCTAssertEqual(requestCount, 0)
  }

  func testMissingPermissionPerformsExactlyOneNativeRequest() {
    var requestCount = 0

    let granted = ScreenCapturePermissionRequestFlow.requestAccess(
      preflight: { false },
      request: {
        requestCount += 1
        return true
      }
    )

    XCTAssertTrue(granted)
    XCTAssertEqual(requestCount, 1)
  }

  func testDeniedNativeRequestReturnsNotGrantedWithoutRetrying() {
    var requestCount = 0

    let granted = ScreenCapturePermissionRequestFlow.requestAccess(
      preflight: { false },
      request: {
        requestCount += 1
        return false
      }
    )

    XCTAssertFalse(granted)
    XCTAssertEqual(requestCount, 1)
  }

  func testAuthorizationLogSnapshotKeepsRawGrantAndIdentityBlockDistinct() {
    let snapshot = ScreenRecordingAuthorizationLogSnapshot(
      rawSystemGranted: true,
      effectiveStatus: .grantedButUnavailableDueToAppIdentity("invalid signature"),
      identityHealthy: false,
      identityIssueNames: ["invalid-bundle-signature"],
      resetOverrideActive: false
    )

    let context = snapshot.context(source: .applicationLaunch)

    XCTAssertEqual(context["rawTCCGranted"], "true")
    XCTAssertEqual(context["effectiveStatus"], "identity-blocked")
    XCTAssertEqual(context["identityHealthy"], "false")
    XCTAssertEqual(context["identityIssues"], "invalid-bundle-signature")
    XCTAssertEqual(context["source"], "application-launch")
  }

  func testAuthorizationLogSnapshotRecordsPermissionResetOverride() {
    let snapshot = ScreenRecordingAuthorizationLogSnapshot(
      rawSystemGranted: true,
      effectiveStatus: .notGranted,
      identityHealthy: true,
      identityIssueNames: [],
      resetOverrideActive: true
    )

    let context = snapshot.context(source: .permissionReset)

    XCTAssertEqual(context["rawTCCGranted"], "true")
    XCTAssertEqual(context["effectiveStatus"], "not-granted")
    XCTAssertEqual(context["resetOverrideActive"], "true")
    XCTAssertEqual(context["identityIssues"], "none")
  }
}
