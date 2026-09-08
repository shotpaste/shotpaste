//
//  AudioRecordingCoordinatorPolicyTests.swift
//  ShotPaste
//

import Foundation
@testable import ShotPaste
import XCTest

final class AudioRecordingCoordinatorPolicyTests: XCTestCase {
  func testAudioStateListContainsIndependentCaptureAndProcessingStates() {
    XCTAssertEqual(
      AudioRecordingCoordinatorState.allCases.map(\.rawValue),
      [
        "idle", "presenting", "preparing", "recording", "paused", "saving",
        "transcribing", "polishing", "organizing", "completed",
        "recoverable", "failed",
      ]
    )
  }

  func testDisplayRecoveryAllowsOnlyOneAutomaticAttempt() {
    XCTAssertTrue(AudioRecordingDisplayRecoveryPolicy.shouldAttempt(recoveryCount: 0))
    XCTAssertFalse(AudioRecordingDisplayRecoveryPolicy.shouldAttempt(recoveryCount: 1))
    XCTAssertEqual(AudioRecordingDisplayRecoveryPolicy.timeout, 3)
  }

  func testSaveToastDescribesMissingActualRole() {
    XCTAssertEqual(
      AudioRecordingSaveToastPolicy.notice(
        requestedRoles: [.system, .microphone],
        effectiveRoles: [.system],
        endedEarly: false
      ),
      .savedWithoutMicrophone
    )
    XCTAssertEqual(
      AudioRecordingSaveToastPolicy.notice(
        requestedRoles: [.system, .microphone],
        effectiveRoles: [.microphone],
        endedEarly: true
      ),
      .savedWithoutSystemAudio
    )
    XCTAssertEqual(
      AudioRecordingSaveToastPolicy.notice(
        requestedRoles: [.system, .microphone],
        effectiveRoles: [.system, .microphone],
        endedEarly: true
      ),
      .endedEarlySaved
    )
  }
}
