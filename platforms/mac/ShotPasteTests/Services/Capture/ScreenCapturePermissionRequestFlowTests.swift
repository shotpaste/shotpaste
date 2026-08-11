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
}
