//
//  PermissionGuideTests.swift
//  ShotPasteTests
//

import AVFoundation
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

  func testAuthorizationAssistantExposesDraggablePrivacyTargets() {
    XCTAssertEqual(
      PermissionAuthorizationSettingsTarget.dragSupportedTargets,
      [.screenRecording, .accessibility]
    )

    for target in PermissionAuthorizationSettingsTarget.allCases {
      let url = URL(string: target.urlString)
      XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
    }
  }

  func testAuthorizationGuideSkipsPermissionsAlreadyGranted() {
    let snapshot = PermissionAuthorizationSnapshot(
      screenRecordingGranted: true,
      microphoneGranted: false,
      accessibilityGranted: true
    )

    XCTAssertEqual(
      PermissionAuthorizationGuidePolicy.firstMissingTarget(in: snapshot),
      .microphone
    )
    XCTAssertFalse(snapshot.allGranted)
  }

  func testAuthorizationGuideUsesNativePromptForUndeterminedMicrophonePermission() {
    XCTAssertEqual(
      PermissionAuthorizationGuidePolicy.authorizationAction(
        for: .microphone,
        microphoneStatus: .notDetermined
      ),
      .requestMicrophoneAccess
    )
    XCTAssertEqual(
      PermissionAuthorizationGuidePolicy.authorizationAction(
        for: .microphone,
        microphoneStatus: .denied
      ),
      .openSystemSettings
    )
    XCTAssertEqual(
      PermissionAuthorizationGuidePolicy.authorizationAction(
        for: .microphone,
        microphoneStatus: .restricted
      ),
      .none
    )
    XCTAssertFalse(PermissionAuthorizationSettingsTarget.microphone.supportsDragging)
  }

  func testAuthorizationGuideDoesNothingWhenEveryPermissionIsGranted() {
    let snapshot = PermissionAuthorizationSnapshot(
      screenRecordingGranted: true,
      microphoneGranted: true,
      accessibilityGranted: true
    )

    XCTAssertNil(PermissionAuthorizationGuidePolicy.firstMissingTarget(in: snapshot))
    XCTAssertTrue(snapshot.allGranted)
  }

  func testSystemSettingsHighlightStaysInsideContentArea() {
    let settingsFrame = CGRect(x: 100, y: 80, width: 1_000, height: 700)
    let highlightFrame = PermissionSettingsHighlightGeometry.highlightFrame(
      in: settingsFrame
    )

    XCTAssertGreaterThan(highlightFrame.minX, settingsFrame.midX - 150)
    XCTAssertGreaterThanOrEqual(highlightFrame.minY, settingsFrame.minY)
    XCTAssertLessThanOrEqual(highlightFrame.maxX, settingsFrame.maxX)
    XCTAssertLessThanOrEqual(highlightFrame.maxY, settingsFrame.maxY)
  }

  func testSystemSettingsHighlightOnlyShowsWhileSettingsIsFrontmost() {
    XCTAssertTrue(PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: true,
      isSystemSettingsFrontmost: true,
      hasSystemSettingsWindow: true
    ))
    XCTAssertFalse(PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: true,
      isSystemSettingsFrontmost: false,
      hasSystemSettingsWindow: true
    ))
    XCTAssertFalse(PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: true,
      isSystemSettingsFrontmost: true,
      hasSystemSettingsWindow: false
    ))
    XCTAssertFalse(PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: false,
      isSystemSettingsFrontmost: true,
      hasSystemSettingsWindow: true
    ))
    XCTAssertFalse(PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: true,
      isSystemSettingsFrontmost: true,
      hasSystemSettingsWindow: true,
      hasModalWindow: true
    ))
    XCTAssertFalse(PermissionSettingsHighlightVisibilityPolicy.shouldShow(
      isGuideActive: true,
      isSystemSettingsFrontmost: true,
      hasSystemSettingsWindow: true,
      isInteractionSuppressed: true
    ))
  }

  func testPermissionAssistantPanelSitsBesideSettingsWindowWhenSpaceAllows() {
    let origin = PermissionAssistantPanelGeometry.origin(
      settingsWindowFrame: CGRect(x: 600, y: 100, width: 800, height: 700),
      panelSize: CGSize(width: 400, height: 540),
      visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 900)
    )

    XCTAssertEqual(origin.x + 400, 588)
    XCTAssertEqual(origin.y, 180)
  }

  func testPermissionAssistantPanelRemainsOnSettingsScreenWhenSpaceIsTight() {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let origin = PermissionAssistantPanelGeometry.origin(
      settingsWindowFrame: CGRect(x: 200, y: 60, width: 800, height: 680),
      panelSize: CGSize(width: 460, height: 540),
      visibleFrame: visibleFrame
    )

    XCTAssertGreaterThanOrEqual(origin.x, visibleFrame.minX + 12)
    XCTAssertLessThanOrEqual(origin.x + 460, visibleFrame.maxX - 12)
    XCTAssertGreaterThanOrEqual(origin.y, visibleFrame.minY + 12)
    XCTAssertLessThanOrEqual(origin.y + 540, visibleFrame.maxY - 12)
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
