//
//  PermissionGuideTests.swift
//  ShotPasteTests
//

@testable import ShotPaste
import XCTest

final class PermissionGuideTests: XCTestCase {
  func testProgressIsReadyOnlyWhenEveryRequiredItemIsComplete() {
    XCTAssertFalse(PermissionGuideProgress(
      screenRecordingGranted: false,
      saveFolderGranted: false
    ).isReady)
    XCTAssertFalse(PermissionGuideProgress(
      screenRecordingGranted: true,
      saveFolderGranted: false
    ).isReady)
    XCTAssertTrue(PermissionGuideProgress(
      screenRecordingGranted: true,
      saveFolderGranted: true
    ).isReady)
  }

  func testProgressCountsOnlyRequiredItems() {
    let progress = PermissionGuideProgress(
      screenRecordingGranted: false,
      saveFolderGranted: true
    )

    XCTAssertEqual(progress.completedRequiredCount, 1)
    XCTAssertEqual(progress.requiredCount, 2)
  }

  func testLaunchPolicyPresentsMissingPermissionGuideOnce() {
    let defaults = UserDefaultsFactory.make()
    let policy = PermissionGuideLaunchPolicy(defaults: defaults)

    XCTAssertTrue(policy.consumePresentationIfNeeded(
      hasUsableScreenRecordingPermission: false
    ))
    XCTAssertFalse(policy.consumePresentationIfNeeded(
      hasUsableScreenRecordingPermission: false
    ))
    XCTAssertEqual(
      defaults.integer(forKey: PreferencesKeys.permissionGuidePresentedVersion),
      PermissionGuideLaunchPolicy.currentVersion
    )
  }

  func testLaunchPolicyConsumesVersionWithoutInterruptingAuthorizedUser() {
    let defaults = UserDefaultsFactory.make()
    let policy = PermissionGuideLaunchPolicy(defaults: defaults)

    XCTAssertFalse(policy.consumePresentationIfNeeded(
      hasUsableScreenRecordingPermission: true
    ))

    // Revoking access later must not turn one-time onboarding into a recurring prompt.
    XCTAssertFalse(policy.consumePresentationIfNeeded(
      hasUsableScreenRecordingPermission: false
    ))
  }

  func testLaunchPolicyPresentsAgainAfterGuideVersionIncreases() {
    let defaults = UserDefaultsFactory.make()
    defaults.set(
      PermissionGuideLaunchPolicy.currentVersion - 1,
      forKey: PreferencesKeys.permissionGuidePresentedVersion
    )

    XCTAssertTrue(PermissionGuideLaunchPolicy(defaults: defaults)
      .consumePresentationIfNeeded(hasUsableScreenRecordingPermission: false))
  }
}
