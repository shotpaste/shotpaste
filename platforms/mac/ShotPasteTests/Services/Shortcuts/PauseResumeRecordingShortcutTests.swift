//
//  PauseResumeRecordingShortcutTests.swift
//  ShotPasteTests
//
//  Unit tests for the optional pause/resume recording global shortcut
//  and the start/stop toggle eligibility on RecordingState.
//

import AppKit
import Carbon.HIToolbox
@testable import ShotPaste
import XCTest

final class PauseResumeRecordingShortcutTests: XCTestCase {
  // MARK: - RecordingState.isPauseResumeEligible

  func testRecordingStateIsPauseResumeEligible_trueForActiveStates() {
    XCTAssertTrue(RecordingState.recording.isPauseResumeEligible)
    XCTAssertTrue(RecordingState.paused.isPauseResumeEligible)
  }

  func testRecordingStateIsPauseResumeEligible_falseForInactiveStates() {
    XCTAssertFalse(RecordingState.idle.isPauseResumeEligible)
    XCTAssertFalse(RecordingState.preparing.isPauseResumeEligible)
    XCTAssertFalse(RecordingState.stopping.isPauseResumeEligible)
  }

  func testRecordingCancellationOutcomeOnlySucceedsWhenOutputIsNotLeftBehind() {
    XCTAssertTrue(RecordingCancellationOutcome.disposed.succeeded)
    XCTAssertTrue(RecordingCancellationOutcome.noOutput.succeeded)
    XCTAssertFalse(
      RecordingCancellationOutcome.preserved(
        URL(fileURLWithPath: "/tmp/preserved-recording.mov")
      ).succeeded
    )
  }

  // MARK: - ShortcutConfig.defaultPauseResumeRecording

  func testDefaultPauseResumeRecordingShortcut_matchesCurrentVariantRecommendation() {
    let config = ShortcutConfig.defaultPauseResumeRecording
    XCTAssertEqual(config.keyCode, UInt32(kVK_Space))
    XCTAssertEqual(config.modifiers, ShortcutConfig.defaultModifiers(for: .current))
  }

  // MARK: - GlobalShortcutKind

  func testPauseResumeRecordingKind_isPresentInAllCases() {
    XCTAssertTrue(GlobalShortcutKind.allCases.contains(.pauseResumeRecording))
  }

  func testPauseResumeRecordingKind_isNotSystemConflictRelevant() {
    XCTAssertFalse(GlobalShortcutKind.pauseResumeRecording.isSystemConflictRelevant)
  }

  func testPauseResumeRecordingKind_hasNonEmptyDisplayName() {
    let name = GlobalShortcutKind.pauseResumeRecording.displayName
    XCTAssertFalse(name.isEmpty)
  }

  // MARK: - KeyboardShortcutManager default state

  @MainActor
  func testKeyboardShortcutManager_pauseResumeRecording_resolvesNilWhenCleared() {
    // The pause/resume shortcut ships cleared/unbound. Verify the contract deterministically:
    // clearing it must make `shortcut(for:)` resolve to nil even though a recommended backing
    // value (`defaultPauseResumeRecording`) is seeded internally. Restore prior state on teardown
    // so the shared singleton is not mutated across tests.
    let manager = KeyboardShortcutManager.shared
    let initial = manager.shortcut(for: .pauseResumeRecording)
    addTeardownBlock { @MainActor in
      manager.setPauseResumeRecordingShortcut(initial)
    }

    manager.setPauseResumeRecordingShortcut(nil)
    XCTAssertNil(
      manager.shortcut(for: .pauseResumeRecording),
      "Clearing the pause/resume shortcut must resolve to nil, never the seeded recommended combo"
    )
  }

  @MainActor
  func testKeyboardShortcutManager_setPauseResumeRecordingShortcut_persistsThenClears() {
    let manager = KeyboardShortcutManager.shared
    let initial = manager.shortcut(for: .pauseResumeRecording)
    addTeardownBlock { @MainActor in
      manager.setPauseResumeRecordingShortcut(initial)
    }

    let defaultsKey = "pauseResumeRecordingShortcut"
    let combo = ShortcutConfig(keyCode: UInt32(kVK_F8), modifiers: UInt32(cmdKey | controlKey))
    manager.setPauseResumeRecordingShortcut(combo)
    XCTAssertEqual(manager.shortcut(for: .pauseResumeRecording), combo)
    XCTAssertNotNil(UserDefaults.standard.data(forKey: defaultsKey))

    manager.setPauseResumeRecordingShortcut(nil)
    XCTAssertNil(manager.shortcut(for: .pauseResumeRecording))
    // Clearing must drop the persisted value entirely (no stale "ghost" combo left behind).
    XCTAssertNil(
      UserDefaults.standard.data(forKey: defaultsKey),
      "Cleared pause/resume shortcut must not leave a ghost value in UserDefaults"
    )
  }
}
