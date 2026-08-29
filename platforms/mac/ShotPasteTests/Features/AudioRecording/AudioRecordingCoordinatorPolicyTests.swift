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

  func testTransactionGatesAreStrictlyOrdered() {
    XCTAssertEqual(
      AudioRecordingTransactionGatePolicy.nextStep(
        finalAudioValidated: false,
        historyPersisted: false,
        transcriptionTaskPersisted: false
      ),
      .extract
    )
    XCTAssertEqual(
      AudioRecordingTransactionGatePolicy.nextStep(
        finalAudioValidated: true,
        historyPersisted: false,
        transcriptionTaskPersisted: false
      ),
      .history
    )
    XCTAssertEqual(
      AudioRecordingTransactionGatePolicy.nextStep(
        finalAudioValidated: true,
        historyPersisted: true,
        transcriptionTaskPersisted: false
      ),
      .transcriptionTask
    )
    XCTAssertEqual(
      AudioRecordingTransactionGatePolicy.nextStep(
        finalAudioValidated: true,
        historyPersisted: true,
        transcriptionTaskPersisted: true
      ),
      .deleteInternalVideo
    )
    XCTAssertTrue(
      AudioRecordingTransactionGatePolicy.canDelete(
        finalAudioValidated: true,
        historyPersisted: true,
        transcriptionTaskPersisted: true
      )
    )
    XCTAssertFalse(
      AudioRecordingTransactionGatePolicy.canDelete(
        finalAudioValidated: true,
        historyPersisted: true,
        transcriptionTaskPersisted: false
      )
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
