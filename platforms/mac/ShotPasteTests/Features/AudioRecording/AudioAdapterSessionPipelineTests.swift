//
//  AudioAdapterSessionPipelineTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

final class AudioAdapterSessionPipelineTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var store: AudioAdapterSessionStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shotpaste-audio-adapter-tests-\(UUID().uuidString)", isDirectory: true)
    store = AudioAdapterSessionStore(
      sessionsDirectory: temporaryDirectory,
      outputValidator: { _ in
        AudioAssetValidationResult(
          duration: 2,
          audioTrackCount: 1,
          videoTrackCount: 0,
          rejection: nil
        )
      }
    )
  }

  override func tearDownWithError() throws {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
    store = nil
    temporaryDirectory = nil
    try super.tearDownWithError()
  }

  func testTinyRegionGeometryUsesPhysicalPixelsAndNegativeDisplayOrigin() throws {
    let rect = try TinyRegionRecordingAdapter.recordingRect(
      in: CGRect(x: -1_920, y: -1_080, width: 1_920, height: 1_080),
      backingScaleFactor: 2
    )

    XCTAssertEqual(rect.origin.x, -1_916, accuracy: 0.0001)
    XCTAssertEqual(rect.origin.y, -1_076, accuracy: 0.0001)
    XCTAssertEqual(rect.width, 16, accuracy: 0.0001)
    XCTAssertEqual(rect.height, 16, accuracy: 0.0001)
    XCTAssertEqual(rect.maxX, -1_900, accuracy: 0.0001)
    XCTAssertEqual(rect.maxY, -1_060, accuracy: 0.0001)
  }

  func testTinyRegionGeometryAtOneXIsInsideFrame() throws {
    let frame = CGRect(x: 0, y: 0, width: 1_280, height: 800)
    let rect = try TinyRegionRecordingAdapter.recordingRect(in: frame, backingScaleFactor: 1)

    XCTAssertEqual(rect, CGRect(x: 8, y: 8, width: 32, height: 32))
    XCTAssertTrue(frame.contains(rect))
  }

  func testTinyRegionRejectsInvalidScaleAndTooSmallScreen() {
    XCTAssertThrowsError(
      try TinyRegionRecordingAdapter.recordingRect(
        in: CGRect(x: 0, y: 0, width: 100, height: 100),
        backingScaleFactor: 0
      )
    ) { error in
      XCTAssertEqual(error as? TinyRegionRecordingAdapterError, .invalidScaleFactor)
    }
    XCTAssertThrowsError(
      try TinyRegionRecordingAdapter.recordingRect(
        in: CGRect(x: 0, y: 0, width: 40, height: 40),
        backingScaleFactor: 1
      )
    ) { error in
      XCTAssertEqual(error as? TinyRegionRecordingAdapterError, .screenTooSmall)
    }
  }

  func testStorePersistsManifestAndUsesCanonicalTypedPaths() throws {
    let session = try store.createSession(
      selectedAudioSources: .systemAndMicrophone,
      startedAt: Date(timeIntervalSince1970: 123)
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.manifestURL.path))
    XCTAssertTrue(session.manifest.hasSafeRelativePaths)

    let loaded = try store.load(sessionID: session.sessionID)
    XCTAssertEqual(loaded.manifest.schemaVersion, AudioAdapterSessionManifest.currentSchemaVersion)
    XCTAssertEqual(loaded.manifest.trackRoles, [.system, .microphone])
    XCTAssertEqual(loaded.manifest.internalPaths.capture, "capture.mov")
    XCTAssertFalse(loaded.manifest.finalAudioValidated)
    XCTAssertFalse(loaded.manifest.historyPersisted)
    XCTAssertFalse(loaded.manifest.transcriptionTaskPersisted)

    XCTAssertThrowsError(try session.url(for: "../outside.mov")) { error in
      guard case AudioAdapterSessionStoreError.unsafePath = error else {
        return XCTFail("Expected unsafe path error, got \(error)")
      }
    }
    XCTAssertFalse(AudioAdapterSessionManifest.isCaptureRelativePath("capture.m4a"))
    XCTAssertFalse(AudioAdapterSessionManifest.isFinalRelativePath("capture.mov"))
    XCTAssertFalse(AudioAdapterSessionManifest.isSafeRelativePath("foo//bar.m4a"))
  }

  func testStoreStateMachineRequiresOrderedOutputStages() throws {
    let created = try store.createSession(selectedAudioSources: .systemAndMicrophone)
    _ = try store.transition(sessionID: created.sessionID, to: .preparing)
    _ = try store.transition(sessionID: created.sessionID, to: .recording)
    _ = try store.transition(sessionID: created.sessionID, to: .paused)
    _ = try store.transition(sessionID: created.sessionID, to: .recording)
    _ = try store.transition(sessionID: created.sessionID, to: .stopping)
    let mapping: [AudioAdapterTrackRole: Int32] = [.system: 1, .microphone: 2]
    let updated = try store.recordCaptureOutput(
      sessionID: created.sessionID,
      relativePath: "capture.mov",
      durationSeconds: 2,
      trackIDsByRole: mapping,
      segmentID: created.manifest.segments[0].id
    )
    XCTAssertEqual(updated.manifest.segments[0].trackIDsByRole, mapping)
    let extracting = try store.transition(sessionID: created.sessionID, to: .extracting)
    XCTAssertEqual(extracting.manifest.stage, .extracting)
    XCTAssertThrowsError(try store.transition(sessionID: created.sessionID, to: .completed)) { error in
      guard case AudioAdapterSessionStoreError.invalidStateTransition = error else {
        return XCTFail("Expected invalid transition, got \(error)")
      }
    }
  }

  func testThreeIndependentPersistenceGatesNeverOpenEarly() async throws {
    let created = try store.createSession(selectedAudioSources: .system)
    _ = try store.transition(sessionID: created.sessionID, to: .preparing)
    _ = try store.transition(sessionID: created.sessionID, to: .recording)
    _ = try store.transition(sessionID: created.sessionID, to: .stopping)
    _ = try store.recordCaptureOutput(
      sessionID: created.sessionID,
      relativePath: "capture.mov",
      durationSeconds: 2,
      trackIDsByRole: [.system: 1],
      segmentID: created.manifest.segments[0].id
    )
    _ = try store.update(sessionID: created.sessionID) { manifest in
      manifest.finalPaths = AudioAdapterSessionPaths(
        capture: nil,
        mixed: "mixed.m4a",
        system: nil,
        microphone: nil
      )
      manifest.internalPaths.mixed = "mixed.m4a"
      manifest.internalPaths.system = nil
    }
    try Data("capture".utf8).write(to: try created.url(for: "capture.mov"))
    try Data("m4a".utf8).write(to: try created.url(for: "mixed.m4a"))
    _ = try store.transition(sessionID: created.sessionID, to: .extracting)
    XCTAssertThrowsError(try store.update(sessionID: created.sessionID) { manifest in
      manifest.finalAudioValidated = true
      manifest.finalAudioValidatedAt = Date()
    })
    _ = try await store.markFinalAudioValidated(sessionID: created.sessionID)
    _ = try store.transition(sessionID: created.sessionID, to: .awaitingHistory)
    var current = try store.load(sessionID: created.sessionID)
    XCTAssertTrue(current.manifest.finalAudioValidated)
    XCTAssertFalse(current.manifest.historyPersisted)
    XCTAssertFalse(current.manifest.transcriptionTaskPersisted)
    XCTAssertFalse(current.manifest.canDeleteInternalVideo)

    let emptyReference = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    XCTAssertThrowsError(
      try store.markHistoryPersisted(
        sessionID: created.sessionID,
        reference: emptyReference
      )
    )
    _ = try store.markHistoryPersisted(sessionID: created.sessionID, reference: UUID())
    current = try store.load(sessionID: created.sessionID)
    XCTAssertEqual(current.manifest.stage, .awaitingTranscription)
    XCTAssertTrue(current.manifest.historyPersisted)
    XCTAssertFalse(current.manifest.transcriptionTaskPersisted)
    XCTAssertFalse(current.manifest.canDeleteInternalVideo)

    _ = try store.markTranscriptionTaskPersisted(sessionID: created.sessionID, reference: UUID())
    current = try store.load(sessionID: created.sessionID)
    XCTAssertEqual(current.manifest.stage, .completed)
    XCTAssertTrue(current.manifest.transcriptionTaskPersisted)
    // Content validation is still required before deletion can be authorized.
    XCTAssertFalse(current.manifest.canDeleteInternalVideo)
  }

  func testManifestRejectsOutputOverlapBadExtensionAndSymlink() throws {
    let session = try store.createSession(selectedAudioSources: .system)
    let captureURL = try session.url(for: "capture.mov")
    try Data("not a movie".utf8).write(to: captureURL)

    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.finalPaths.mixed = "capture.mov"
    })
    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.finalPaths.mixed = "mixed.mov"
    })

    let external = temporaryDirectory.appendingPathComponent("external.mov")
    try Data("outside".utf8).write(to: external)
    let alias = session.directoryURL.appendingPathComponent("alias.mov")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.segments[0].capturePath = "alias.mov"
    })
  }

  func testCaptureSegmentRoleMappingAndSingleSourcePolicy() {
    let single = AudioAdapterSessionManifest(
      selectedAudioSources: .system,
      segments: [AudioAdapterCaptureSegment(
        sequence: 0,
        capturePath: "capture.mov",
        trackRoles: [.system],
        trackIDsByRole: [.system: 7]
      )]
    )
    XCTAssertEqual(single.trackRoles, [.system])
    XCTAssertTrue(single.hasValidSemanticInvariants)

    var duplicate = single
    duplicate.segments[0].trackIDsByRole = [.system: 0]
    XCTAssertFalse(duplicate.hasValidSemanticInvariants)

    var wrongRole = single
    wrongRole.segments[0].trackIDsByRole = [.microphone: 7]
    XCTAssertFalse(wrongRole.hasValidSemanticInvariants)
  }

  func testEffectiveRolesUseIntersectionAndReportMissingRequestedRoles() {
    let manifest = AudioAdapterSessionManifest(
      selectedAudioSources: .systemAndMicrophone,
      segments: [
        AudioAdapterCaptureSegment(
          sequence: 0,
          capturePath: "system-only.mov",
          durationSeconds: 2,
          trackRoles: [.system],
          trackIDsByRole: [.system: 7]
        ),
        AudioAdapterCaptureSegment(
          sequence: 1,
          capturePath: "dual.mov",
          timelineStartSeconds: 2,
          durationSeconds: 2,
          trackRoles: [.system, .microphone],
          trackIDsByRole: [.system: 9, .microphone: 10]
        ),
      ]
    )

    XCTAssertEqual(manifest.effectiveCapturedTrackRoles, [.system])
    XCTAssertEqual(manifest.missingRequestedTrackRoles, [.microphone])
    XCTAssertTrue(manifest.hasValidSemanticInvariants)
  }

  func testCompletedSegmentMayUseTrustedRequestedSubsetButUnresolvedIsNewestOnly() {
    let valid = AudioAdapterSessionManifest(
      selectedAudioSources: .systemAndMicrophone,
      segments: [
        AudioAdapterCaptureSegment(
          sequence: 0,
          capturePath: "capture.mov",
          durationSeconds: 2,
          trackRoles: [.system],
          trackIDsByRole: [.system: 1]
        ),
        AudioAdapterCaptureSegment(
          sequence: 1,
          capturePath: "capture-1.mov",
          timelineStartSeconds: 2,
          trackRoles: [.system, .microphone]
        ),
      ]
    )
    XCTAssertTrue(valid.hasValidSemanticInvariants)

    var nonNewestUnresolved = valid
    nonNewestUnresolved.segments[1].durationSeconds = 2
    nonNewestUnresolved.segments[1].trackIDsByRole = [.system: 2, .microphone: 3]
    nonNewestUnresolved.segments[0].durationSeconds = nil
    XCTAssertFalse(nonNewestUnresolved.hasValidSemanticInvariants)
  }

  func testDuplicateSequenceAndTimelineOverlapAreRejectedByManifest() {
    let segments = [
      AudioAdapterCaptureSegment(
        sequence: 0,
        capturePath: "a.mov",
        timelineStartSeconds: 0,
        durationSeconds: 2,
        trackRoles: [.system],
        trackIDsByRole: [.system: 1]
      ),
      AudioAdapterCaptureSegment(
        sequence: 0,
        capturePath: "b.mov",
        timelineStartSeconds: 1,
        durationSeconds: 2,
        trackRoles: [.system],
        trackIDsByRole: [.system: 2]
      ),
    ]
    let duplicate = AudioAdapterSessionManifest(selectedAudioSources: .system, segments: segments)
    XCTAssertFalse(duplicate.hasValidSemanticInvariants)

    var gap = duplicate
    gap.segments[1].sequence = 1
    XCTAssertFalse(gap.hasValidSemanticInvariants)
    XCTAssertFalse(gap.hasNonOverlappingTimeline)
    gap.segments[1].timelineStartSeconds = 2
    XCTAssertTrue(gap.hasValidSemanticInvariants)
    XCTAssertTrue(gap.hasNonOverlappingTimeline)
  }

  func testRecoveryScansAwaitingStagesAndCorruptManifestMetadata() async throws {
    let session = try store.createSession(selectedAudioSources: .system)
    _ = try store.transition(sessionID: session.sessionID, to: .preparing)
    _ = try store.transition(sessionID: session.sessionID, to: .recording)
    _ = try store.transition(sessionID: session.sessionID, to: .stopping)
    _ = try store.recordCaptureOutput(
      sessionID: session.sessionID,
      relativePath: "capture.mov",
      durationSeconds: 2,
      trackIDsByRole: [.system: 1],
      segmentID: session.manifest.segments[0].id
    )
    _ = try store.update(sessionID: session.sessionID) { manifest in
      manifest.finalPaths.mixed = "mixed.m4a"
      manifest.internalPaths.mixed = "mixed.m4a"
    }
    try Data("capture".utf8).write(to: try session.url(for: "capture.mov"))
    try Data("m4a".utf8).write(to: try session.url(for: "mixed.m4a"))
    _ = try store.transition(sessionID: session.sessionID, to: .extracting)
    _ = try await store.markFinalAudioValidated(sessionID: session.sessionID)
    _ = try store.transition(sessionID: session.sessionID, to: .awaitingHistory)
    XCTAssertEqual(store.scanSessions().count, 1)
    XCTAssertEqual(AudioRecordingRecoveryService(store: store).scanUnfinishedSessions().count, 1)

    let corrupt = try store.createSession(selectedAudioSources: .system)
    try Data("{ definitely not json".utf8).write(to: corrupt.manifestURL)
    let service = AudioRecordingRecoveryService(store: store)
    let report = await service.recover()
    XCTAssertTrue(report.actions.contains {
      if case .damagedSession(let id, let code, _) = $0 {
        return id == corrupt.sessionID && code == "manifest_unreadable"
      }
      return false
    })
  }

  func testSchemaMigrationDefaultsNewGatesAndRejectsFuture() throws {
    let sessionID = UUID()
    let manifest = AudioAdapterSessionManifest(sessionID: sessionID, selectedAudioSources: .none)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try XCTUnwrap(try? encoder.encode(manifest))
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["schemaVersion"] = 1
    object.removeValue(forKey: "finalAudioValidated")
    object.removeValue(forKey: "historyPersisted")
    object.removeValue(forKey: "transcriptionTaskPersisted")
    let oldData = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let migrated = try decoder.decode(AudioAdapterSessionManifest.self, from: oldData)
    XCTAssertEqual(migrated.schemaVersion, AudioAdapterSessionManifest.currentSchemaVersion)
    XCTAssertFalse(migrated.finalAudioValidated)
    XCTAssertFalse(migrated.historyPersisted)
    XCTAssertFalse(migrated.transcriptionTaskPersisted)
    XCTAssertFalse(migrated.canDeleteInternalVideo)

    object["finalAudioValidated"] = true
    object["finalAudioValidatedAt"] = ISO8601DateFormatter().string(from: Date())
    object["historyPersisted"] = true
    object["historyPersistedAt"] = ISO8601DateFormatter().string(from: Date())
    object["historyRecordReference"] = UUID().uuidString
    object["transcriptionTaskPersisted"] = true
    object["transcriptionTaskPersistedAt"] = ISO8601DateFormatter().string(from: Date())
    object["transcriptionTaskReference"] = UUID().uuidString
    object["stage"] = AudioAdapterSessionStage.completed.rawValue
    object["schemaVersion"] = 1
    let injectedV1 = try JSONSerialization.data(withJSONObject: object)
    let migratedInjected = try decoder.decode(AudioAdapterSessionManifest.self, from: injectedV1)
    XCTAssertEqual(migratedInjected.stage, .failed)
    XCTAssertFalse(migratedInjected.finalAudioValidated)
    XCTAssertFalse(migratedInjected.historyPersisted)
    XCTAssertFalse(migratedInjected.transcriptionTaskPersisted)
    XCTAssertNil(migratedInjected.historyRecordReference)
    XCTAssertNil(migratedInjected.transcriptionTaskReference)

    object["schemaVersion"] = AudioAdapterSessionManifest.currentSchemaVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(try decoder.decode(AudioAdapterSessionManifest.self, from: futureData))
  }

  func testRecoveryMarksCorruptCaptureTerminalAtRetryCapAndKeepsMOV() async throws {
    let session = try store.createSession(selectedAudioSources: .system)
    let captureURL = try session.url(for: "capture.mov")
    try Data("not a movie".utf8).write(to: captureURL)
    _ = try store.transition(sessionID: session.sessionID, to: .preparing)
    _ = try store.transition(sessionID: session.sessionID, to: .recording)
    _ = try store.transition(sessionID: session.sessionID, to: .stopping)
    _ = try store.recordTrackIDs(
      sessionID: session.sessionID,
      segmentID: session.manifest.segments[0].id,
      trackIDsByRole: [.system: 1]
    )

    let service = AudioRecordingRecoveryService(store: store, maximumRetries: 1)
    let report = await service.recover()
    guard case .damagedSession(_, _, let retryCount) = report.actions[0] else {
      return XCTFail("Expected corrupt capture to remain a damaged session")
    }
    XCTAssertEqual(retryCount, 1)
    let recovered = try store.load(sessionID: session.sessionID)
    XCTAssertTrue(recovered.manifest.recoveryTerminal)
    XCTAssertEqual(recovered.manifest.stage, .failed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))
    XCTAssertTrue(AudioRecordingRecoveryService(store: store).scanUnfinishedSessions().isEmpty)
  }

  func testOrdinaryMutationCannotRewriteSchemaRetryTerminalOrSegmentIdentity() throws {
    let session = try store.createSession(selectedAudioSources: .system)

    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.schemaVersion = 1
    })
    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.retryCount = 9
    })
    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.recoveryTerminal = true
    })
    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.selectedAudioSources = .microphone
    })
    XCTAssertThrowsError(try store.update(sessionID: session.sessionID) { manifest in
      manifest.segments[0].id = UUID()
    })
    var saveBypass = try store.load(sessionID: session.sessionID)
    saveBypass.manifest.retryCount = 4
    XCTAssertThrowsError(try store.save(saveBypass))
  }

  func testRoleMetadataContractRejectsMissingDuplicateUnknownAndHandlesReversedTracks() {
    let expected: [AudioAdapterTrackRole] = [.system, .microphone]
    let reversed = [
      AudioAdapterTrackDescriptor(
        trackID: 20,
        metadata: [AudioAdapterTrackMetadata(
          identifier: AudioAdapterTrackRoleMetadataContract.identifier,
          value: "microphone"
        )]
      ),
      AudioAdapterTrackDescriptor(
        trackID: 10,
        metadata: [AudioAdapterTrackMetadata(
          identifier: AudioAdapterTrackRoleMetadataContract.identifier,
          value: "system"
        )]
      ),
    ]
    XCTAssertEqual(
      AudioAdapterTrackRoleMetadataContract.mapping(for: reversed, expectedRoles: expected),
      [.system: 10, .microphone: 20]
    )

    var missing = reversed
    missing[0] = AudioAdapterTrackDescriptor(trackID: 20, metadata: [])
    XCTAssertNil(AudioAdapterTrackRoleMetadataContract.mapping(for: missing, expectedRoles: expected))

    var duplicate = reversed
    duplicate[1] = AudioAdapterTrackDescriptor(
      trackID: 10,
      metadata: [AudioAdapterTrackMetadata(
        identifier: AudioAdapterTrackRoleMetadataContract.identifier,
        value: "microphone"
      )]
    )
    XCTAssertNil(AudioAdapterTrackRoleMetadataContract.mapping(for: duplicate, expectedRoles: expected))

    var unknown = reversed
    unknown[0] = AudioAdapterTrackDescriptor(
      trackID: 20,
      metadata: [AudioAdapterTrackMetadata(
        identifier: AudioAdapterTrackRoleMetadataContract.identifier,
        value: "line-in"
      )]
    )
    XCTAssertNil(AudioAdapterTrackRoleMetadataContract.mapping(for: unknown, expectedRoles: expected))

    XCTAssertEqual(
      AudioAdapterTrackRoleMetadataContract.mapping(
        for: [reversed[1]],
        expectedRoles: expected
      ),
      [.system: 10]
    )
    XCTAssertNil(
      AudioAdapterTrackRoleMetadataContract.mapping(for: [], expectedRoles: expected)
    )
  }

  func testMissingSegmentDurationBlocksRecoveryOutputValidation() async throws {
    let session = try store.createSession(selectedAudioSources: .system)
    _ = try store.recordTrackIDs(
      sessionID: session.sessionID,
      segmentID: session.manifest.segments[0].id,
      trackIDsByRole: [.system: 1]
    )
    _ = try store.update(sessionID: session.sessionID) { manifest in
      manifest.finalPaths.mixed = "mixed.m4a"
      manifest.internalPaths.mixed = "mixed.m4a"
    }
    try Data("capture".utf8).write(to: try session.url(for: "capture.mov"))
    try Data("m4a".utf8).write(to: try session.url(for: "mixed.m4a"))
    let service = AudioRecordingRecoveryService(store: store)
    await XCTAssertThrowsErrorAsync {
      _ = try await service.validateFinalOutputs(for: try self.store.load(sessionID: session.sessionID))
    }
  }

  func testDirectRecoveryOfCompletedOrCancelledIsIgnored() async throws {
    let cancelled = try store.createSession(selectedAudioSources: .system)
    _ = try store.transition(sessionID: cancelled.sessionID, to: .cancelled)
    if case .ignoredSession(let id, _) = await AudioRecordingRecoveryService(store: store)
      .recover(sessionID: cancelled.sessionID) {
      XCTAssertEqual(id, cancelled.sessionID)
    } else {
      XCTFail("Cancelled sessions must not become damaged recovery actions")
    }

    let completed = try store.createSession(selectedAudioSources: .system)
    var manifest = completed.manifest
    manifest.stage = .completed
    manifest.finalAudioValidated = true
    manifest.finalAudioValidatedAt = Date()
    manifest.historyPersisted = true
    manifest.historyPersistedAt = Date()
    manifest.historyRecordReference = UUID()
    manifest.transcriptionTaskPersisted = true
    manifest.transcriptionTaskPersistedAt = Date()
    manifest.transcriptionTaskReference = UUID()
    manifest.finalPaths.mixed = "mixed.m4a"
    manifest.internalPaths.mixed = "mixed.m4a"
    manifest.segments[0].trackIDsByRole = [.system: 1]
    manifest.segments[0].durationSeconds = 2
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: completed.manifestURL)
    if case .ignoredSession(let id, _) = await AudioRecordingRecoveryService(store: store)
      .recover(sessionID: completed.sessionID) {
      XCTAssertEqual(id, completed.sessionID)
    } else {
      XCTFail("Completed sessions must not become damaged recovery actions")
    }
  }

  func testFinalCapturePathIsNeverAValidFinalOutput() {
    let manifest = AudioAdapterSessionManifest(
      selectedAudioSources: .system,
      finalPaths: AudioAdapterSessionPaths(
        capture: "capture.m4a",
        mixed: "mixed.m4a",
        system: nil,
        microphone: nil
      ),
      segments: [AudioAdapterCaptureSegment(
        sequence: 0,
        capturePath: "capture.mov",
        trackRoles: [.system],
        trackIDsByRole: [.system: 1]
      )]
    )
    XCTAssertFalse(manifest.hasValidSemanticInvariants)
  }

  func testAncestorSymlinkCannotBecomeSessionsRoot() throws {
    let root = temporaryDirectory.appendingPathComponent("physical-root", isDirectory: true)
    let real = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let sessions = alias.appendingPathComponent("AudioAdapter/Sessions", isDirectory: true)
    let confined = AudioAdapterSessionStore(
      sessionsDirectory: sessions,
      allowedRoot: root
    )
    XCTAssertThrowsError(try confined.createSession(selectedAudioSources: .system))
  }
}

private extension XCTestCase {
  func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await expression()
      XCTFail("Expected an async throwing expression", file: file, line: line)
    } catch {
      // Expected.
    }
  }
}
