//
//  AudioRecordingCoordinatorRecoveryTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

final class AudioRecordingCoordinatorRecoveryTests: XCTestCase {
  func testAudioShortcutTOMLKeyAndDefaultAreUnbound() {
    XCTAssertEqual(GlobalShortcutKind.startAudioRecording.configKey, "start_audio_recording")
  }

  @MainActor
  func testDefaultTOMLContainsClearedAudioShortcut() {
    let toml = ShotPasteConfigurationDefaultDocument.toml()
    guard let section = toml.range(of: "[shortcuts.global.start_audio_recording]") else {
      return XCTFail("missing audio shortcut TOML section")
    }
    let remainder = toml[section.upperBound...]
    let sectionBody: String
    if let nextSection = remainder.range(of: "\n\n[") {
      sectionBody = String(remainder[..<nextSection.lowerBound])
    } else {
      sectionBody = String(remainder)
    }
    XCTAssertTrue(sectionBody.contains("key = \"\""))
    XCTAssertTrue(sectionBody.contains("modifiers = []"))
  }

  func testAudioConfigurationRequiresSourceAndCouplesAIToTranscription() {
    let noSource = AudioRecordingConfiguration(
      capturesSystemAudio: false,
      capturesMicrophone: false,
      automaticTranscription: true,
      automaticAI: true
    )
    XCTAssertFalse(noSource.hasAudioSource)

    let aiWithoutTranscription = AudioRecordingConfiguration(
      capturesSystemAudio: true,
      capturesMicrophone: false,
      automaticTranscription: false,
      automaticAI: true
    )
    XCTAssertFalse(aiWithoutTranscription.automaticAI)
  }

  func testSegmentOutputBindsByNewestSegmentID() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("shotpaste-audio-segment-binding-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AudioAdapterSessionStore(sessionsDirectory: root)
    let created = try store.createSession(selectedAudioSources: .system)
    _ = try store.transition(sessionID: created.sessionID, to: .preparing)
    _ = try store.transition(sessionID: created.sessionID, to: .recording)
    _ = try store.transition(sessionID: created.sessionID, to: .stopping)
    let first = try store.recordCaptureOutput(
      sessionID: created.sessionID,
      relativePath: "capture.mov",
      durationSeconds: 2,
      trackIDsByRole: [.system: 1],
      segmentID: created.manifest.segments[0].id
    )
    let second = try store.appendSegment(
      sessionID: created.sessionID,
      capturePath: "capture-1.mov",
      sequence: 1,
      timelineStartSeconds: 2,
      trackRoles: [.system]
    )
    _ = try store.transition(sessionID: created.sessionID, to: .failed)
    _ = try store.transition(sessionID: created.sessionID, to: .preparing)
    _ = try store.transition(sessionID: created.sessionID, to: .recording)
    _ = try store.transition(sessionID: created.sessionID, to: .stopping)

    let updated = try store.recordCaptureOutput(
      sessionID: created.sessionID,
      relativePath: "capture-1.mov",
      durationSeconds: 3,
      trackIDsByRole: [.system: 2],
      segmentID: second.manifest.segments[1].id
    )
    XCTAssertEqual(updated.manifest.segments[0].capturePath, "capture.mov")
    XCTAssertEqual(updated.manifest.segments[0].durationSeconds, 2)
    XCTAssertEqual(updated.manifest.segments[1].capturePath, "capture-1.mov")
    XCTAssertEqual(updated.manifest.segments[1].durationSeconds, 3)
    XCTAssertEqual(updated.manifest.segments[1].trackIDsByRole, [.system: 2])
    XCTAssertEqual(first.manifest.segments[0].id, updated.manifest.segments[0].id)
  }

  func testHistoryProcessingStatusIsDurableMetadataOnly() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("shotpaste-audio-history-status-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AudioHistoryProcessingStatusStore(
      indexURL: root.appendingPathComponent("history-processing-index.json")
    )
    let historyID = UUID()
    let sessionID = UUID()
    let taskID = UUID()
    store.associate(
      historyRecordID: historyID,
      sessionID: sessionID,
      taskID: taskID,
      stage: AudioProcessingTaskStage.transcribing.rawValue
    )
    XCTAssertEqual(store.status(for: historyID), .transcribing)
    store.update(
      sessionID: sessionID,
      taskID: taskID,
      stage: AudioProcessingTaskStage.waitingForModel.rawValue
    )
    XCTAssertEqual(store.status(for: historyID), .waitingForModel)
    let data = try Data(contentsOf: root.appendingPathComponent("history-processing-index.json"))
    let serialized = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(serialized.contains("prompt"))
    XCTAssertFalse(serialized.contains("transcript"))
    XCTAssertFalse(serialized.contains("file://"))
  }

  func testStreamFailurePolicyQueuesOrDefersAtStartBoundary() {
    let event = RecordingStreamFailureEvent(
      generation: 1,
      purpose: .audioAdapter,
      wasFirstVideoFrameReady: true,
      wasCapturing: true,
      errorType: "test",
      wasAdapterStartClaimed: true
    )
    XCTAssertTrue(
      AudioRecordingStreamFailurePolicy.shouldDeferUntilStartReturns(
        state: .preparing,
        event: event
      )
    )
    XCTAssertTrue(
      AudioRecordingStreamFailurePolicy.shouldQueueStop(
        state: .recording,
        event: event
      )
    )
    XCTAssertFalse(
      AudioRecordingStreamFailurePolicy.shouldQueueStop(
        state: .idle,
        event: event
      )
    )
  }

  func testAsyncValidationRejectsStaleManifestSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("shotpaste-audio-store-snapshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let validatorStarted = XCTestExpectation(description: "validator started")
    let store = AudioAdapterSessionStore(
      sessionsDirectory: root,
      outputValidator: { _ in
        validatorStarted.fulfill()
        try? await Task.sleep(nanoseconds: 50_000_000)
        return AudioAssetValidationResult(
          duration: 1,
          audioTrackCount: 1,
          videoTrackCount: 0,
          rejection: nil
        )
      }
    )
    let created = try store.createSession(selectedAudioSources: .system)
    _ = try store.transition(sessionID: created.sessionID, to: .preparing)
    _ = try store.transition(sessionID: created.sessionID, to: .recording)
    _ = try store.transition(sessionID: created.sessionID, to: .stopping)
    _ = try store.recordCaptureOutput(
      sessionID: created.sessionID,
      relativePath: "capture.mov",
      durationSeconds: 1,
      trackIDsByRole: [.system: 1],
      segmentID: created.manifest.segments[0].id
    )
    _ = try store.update(sessionID: created.sessionID) { manifest in
      manifest.finalPaths.mixed = "mixed.m4a"
      manifest.internalPaths.mixed = "mixed.m4a"
    }
    try Data("capture".utf8).write(to: try created.url(for: "capture.mov"))
    try Data("audio".utf8).write(to: try created.url(for: "mixed.m4a"))
    _ = try store.transition(sessionID: created.sessionID, to: .extracting)

    let validationTask = Task {
      try await store.markFinalAudioValidated(sessionID: created.sessionID)
    }
    await fulfillment(of: [validatorStarted], timeout: 1)
    _ = try store.update(sessionID: created.sessionID) { manifest in
      manifest.checksums["concurrent"] = "mutation"
    }

    do {
      _ = try await validationTask.value
      XCTFail("stale validation must not open the gate")
    } catch AudioAdapterSessionStoreError.invalidManifest {
      // Expected: the manifest changed while AV validation was suspended.
    }
  }
}
