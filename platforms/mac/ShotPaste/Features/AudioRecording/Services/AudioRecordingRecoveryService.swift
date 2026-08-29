//
//  AudioRecordingRecoveryService.swift
//  ShotPaste
//
//  Crash/relaunch recovery for private audio-adapter sessions. Recovery emits
//  metadata-only actions; history and transcription remain Coordinator work.
//

import Foundation

nonisolated enum AudioRecordingRecoveryAction: Equatable, Sendable {
  case retryExtraction(sessionID: UUID, attempt: Int)
  case readyForHistory(sessionID: UUID, outputPaths: [String])
  case readyForTranscription(sessionID: UUID, outputPaths: [String])
  case damagedSession(sessionID: UUID, diagnosticCode: String, retryCount: Int)
  case damagedDirectory(identifier: String, diagnosticCode: String)
  case ignoredSession(sessionID: UUID, reason: String)
}

nonisolated struct AudioRecordingRecoveryReport: Equatable, Sendable {
  let actions: [AudioRecordingRecoveryAction]

  var retryCount: Int {
    actions.reduce(into: 0) { count, action in
      if case .retryExtraction = action { count += 1 }
    }
  }

  var readyForHistoryCount: Int {
    actions.reduce(into: 0) { count, action in
      if case .readyForHistory = action { count += 1 }
    }
  }

  var readyForTranscriptionCount: Int {
    actions.reduce(into: 0) { count, action in
      if case .readyForTranscription = action { count += 1 }
    }
  }
}

nonisolated enum AudioRecordingRecoveryError: LocalizedError, Equatable {
  case unsafeOutputPath
  case outputValidationFailed
  case deletionNotPermitted

  var errorDescription: String? {
    switch self {
    case .unsafeOutputPath:
      "The audio adapter output path is unsafe."
    case .outputValidationFailed:
      "The audio adapter final output failed validation."
    case .deletionNotPermitted:
      "The audio adapter internal video deletion gate is not satisfied."
    }
  }
}

/// Scans only the variant-scoped private session directory. It never emits a
/// MOV as an ordinary capture; callers receive actions for later history or
/// transcription work instead.
nonisolated final class AudioRecordingRecoveryService: @unchecked Sendable {
  typealias ActionHandler = @Sendable (AudioRecordingRecoveryAction) async -> Void

  private let store: AudioAdapterSessionStore
  private let pipeline: AudioExtractionPipeline
  private let fileManager: FileManager
  private let maximumRetries: Int
  private let actionHandler: ActionHandler?

  init(
    store: AudioAdapterSessionStore = AudioAdapterSessionStore(),
    pipeline: AudioExtractionPipeline? = nil,
    maximumRetries: Int = 3,
    fileManager: FileManager = .default,
    actionHandler: ActionHandler? = nil
  ) {
    self.store = store
    self.pipeline = pipeline ?? AudioExtractionPipeline(store: store, fileManager: fileManager)
    self.maximumRetries = max(0, maximumRetries)
    self.fileManager = fileManager
    self.actionHandler = actionHandler
  }

  func scanUnfinishedSessions() -> [AudioAdapterSession] {
    store.scanSessions().filter {
      $0.manifest.stage.isRecoveryCandidate && !$0.manifest.recoveryTerminal
    }
  }

  func recover() async -> AudioRecordingRecoveryReport {
    var actions: [AudioRecordingRecoveryAction] = []
    for record in store.scanSessionRecords() {
      let action: AudioRecordingRecoveryAction
      if let session = record.session {
        // A crash can happen after all three gates and before MOV unlink. A
        // completed manifest is still a cleanup candidate until the deletion
        // bit is committed; retrying this is safe when unlink was partial.
        if session.manifest.stage == .completed,
           session.manifest.finalAudioValidated,
           session.manifest.historyPersisted,
           session.manifest.transcriptionTaskPersisted,
           !session.manifest.canDeleteInternalVideo {
          try? await store.deleteInternalVideo(sessionID: session.sessionID)
          continue
        }
        if session.manifest.recoveryTerminal || !session.manifest.stage.isRecoveryCandidate {
          continue
        }
        action = await recover(session: session)
      } else if let sessionID = record.sessionID {
        action = .damagedSession(
          sessionID: sessionID,
          diagnosticCode: record.diagnosticCode ?? "manifest_unreadable",
          retryCount: 0
        )
      } else {
        action = .damagedDirectory(
          identifier: record.identifier,
          diagnosticCode: record.diagnosticCode ?? "manifest_unreadable"
        )
      }
      actions.append(action)
      await actionHandler?(action)
    }
    return AudioRecordingRecoveryReport(actions: actions)
  }

  func recover(sessionID: UUID) async -> AudioRecordingRecoveryAction {
    guard let session = try? store.load(sessionID: sessionID) else {
      return .damagedSession(sessionID: sessionID, diagnosticCode: "manifest_unreadable", retryCount: 0)
    }
    guard !session.manifest.recoveryTerminal else {
      return .ignoredSession(sessionID: sessionID, reason: "terminal_damage")
    }
    guard session.manifest.stage.isRecoveryCandidate else {
      return .ignoredSession(sessionID: sessionID, reason: "terminal_stage")
    }
    return await recover(session: session)
  }

  /// Deletes private capture MOV segments only after a fresh load, fresh M4A
  /// validation, and all three durable persistence gates. There is no caller
  /// success boolean that can accidentally authorize one missing task.
  func deleteInternalVideo(sessionID: UUID) async throws {
    let session = try store.load(sessionID: sessionID)
    guard try await validateFinalOutputs(for: session),
          try await store.canDeleteInternalVideo(sessionID: sessionID) else {
      throw AudioRecordingRecoveryError.deletionNotPermitted
    }
    try await store.deleteInternalVideo(sessionID: sessionID)
  }

  func validateFinalOutputs(for session: AudioAdapterSession) async throws -> Bool {
    let roles = session.manifest.effectiveCapturedTrackRoles
    guard !roles.isEmpty else {
      throw AudioRecordingRecoveryError.outputValidationFailed
    }
    guard session.manifest.finalPaths.capture == nil else {
      throw AudioRecordingRecoveryError.unsafeOutputPath
    }
    guard let mixedPath = session.manifest.finalPaths.mixed,
          AudioAdapterSessionManifest.isFinalRelativePath(mixedPath) else {
      throw AudioRecordingRecoveryError.unsafeOutputPath
    }

    var outputPaths = [mixedPath]
    if roles.count == 2 {
      guard let path = session.manifest.finalPaths.system,
            AudioAdapterSessionManifest.isFinalRelativePath(path) else {
        throw AudioRecordingRecoveryError.unsafeOutputPath
      }
      outputPaths.append(path)
      guard let path = session.manifest.finalPaths.microphone,
            AudioAdapterSessionManifest.isFinalRelativePath(path) else {
        throw AudioRecordingRecoveryError.unsafeOutputPath
      }
      outputPaths.append(path)
    } else {
      guard session.manifest.finalPaths.system == nil,
            session.manifest.finalPaths.microphone == nil else {
        throw AudioRecordingRecoveryError.unsafeOutputPath
      }
    }

    let captureURLs = try session.manifest.segments.map {
      guard AudioAdapterSessionManifest.isCaptureRelativePath($0.capturePath) else {
        throw AudioRecordingRecoveryError.unsafeOutputPath
      }
      return try session.url(for: $0.capturePath)
    }
    let captureKeys = Set(captureURLs.map(fileIdentity))
    var outputKeys = Set<String>()
    var finalDuration: Double?
    guard session.manifest.segments.allSatisfy({
      guard let duration = $0.durationSeconds else { return false }
      return duration.isFinite && duration > 0
    }) else {
      throw AudioRecordingRecoveryError.outputValidationFailed
    }
    for path in outputPaths {
      let url = try session.url(for: path)
      guard !AudioAdapterSessionStorePathChecks.hasSymlinkComponent(
        root: session.directoryURL.standardizedFileURL,
        relativePath: path,
        fileManager: fileManager
      ),
        AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: fileManager) else {
        throw AudioRecordingRecoveryError.outputValidationFailed
      }
      let key = fileIdentity(url)
      guard outputKeys.insert(key).inserted, !captureKeys.contains(key) else {
        throw AudioRecordingRecoveryError.unsafeOutputPath
      }
      let validation = await AudioAssetValidator.validate(url: url)
      guard validation.isValid,
            validation.videoTrackCount == 0,
            validation.audioTrackCount >= 1,
            let duration = validation.duration,
            duration.isFinite,
            duration > 0 else {
        throw AudioRecordingRecoveryError.outputValidationFailed
      }
      if finalDuration == nil { finalDuration = duration }
      if let finalDuration,
         abs(duration - finalDuration)
           > AudioAdapterSessionDurationPolicy.tolerance(for: finalDuration) {
        throw AudioRecordingRecoveryError.outputValidationFailed
      }
    }

    guard let expectedDuration = expectedTimelineDuration(for: session),
          let finalDuration,
          abs(finalDuration - expectedDuration)
            <= AudioAdapterSessionDurationPolicy.tolerance(for: expectedDuration) else {
      throw AudioRecordingRecoveryError.outputValidationFailed
    }
    return true
  }

  // MARK: - Recovery decisions

  private func recover(session: AudioAdapterSession) async -> AudioRecordingRecoveryAction {
    guard session.manifest.stage.isRecoveryCandidate else {
      return .ignoredSession(sessionID: session.sessionID, reason: "terminal_stage")
    }
    if let validOutputAction = await existingOutputAction(for: session) {
      return validOutputAction
    }

    guard session.manifest.stage == .stopping
      || session.manifest.stage == .extracting
      || session.manifest.stage == .failed else {
      return await markDamaged(
        session: session,
        code: "capture_incomplete",
        recoverable: false
      )
    }

    let hasCapture = session.manifest.segments.contains { segment in
      guard AudioAdapterSessionManifest.isCaptureRelativePath(segment.capturePath),
            let url = try? session.url(for: segment.capturePath) else { return false }
      return AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: fileManager)
    }
    guard hasCapture else {
      return await markDamaged(session: session, code: "capture_missing", recoverable: false)
    }
    guard session.manifest.retryCount < maximumRetries else {
      return await markDamaged(session: session, code: "retry_limit_reached", recoverable: false)
    }

    let attempt: Int
    do {
      var current = try store.load(sessionID: session.sessionID)
      if current.manifest.stage != .failed {
        _ = try store.transition(sessionID: current.sessionID, to: .failed)
        current = try store.load(sessionID: current.sessionID)
      }
      let updated = try store.beginRecoveryRetry(sessionID: current.sessionID)
      attempt = updated.manifest.retryCount
      _ = try store.transition(sessionID: current.sessionID, to: .extracting)
    } catch {
      return await markDamaged(session: session, code: "manifest_update_failed", recoverable: true)
    }

    do {
      let result = try await pipeline.extract(sessionID: session.sessionID)
      return .readyForHistory(
        sessionID: session.sessionID,
        outputPaths: result.outputs.map(\.relativePath)
      )
    } catch {
      return await markDamaged(
        session: (try? store.load(sessionID: session.sessionID)) ?? session,
        code: diagnosticCode(for: error),
        recoverable: attempt < maximumRetries
      )
    }
  }

  private func existingOutputAction(
    for session: AudioAdapterSession
  ) async -> AudioRecordingRecoveryAction? {
    guard let mixedPath = session.manifest.finalPaths.mixed,
          AudioAdapterSessionManifest.isFinalRelativePath(mixedPath),
          let mixedURL = try? session.url(for: mixedPath),
          AudioAdapterSessionStorePathChecks.isRegularFile(at: mixedURL, fileManager: fileManager) else {
      return nil
    }

    do {
      _ = try await validateFinalOutputs(for: session)
      var updated = try store.load(sessionID: session.sessionID)
      if !updated.manifest.finalAudioValidated {
        guard updated.manifest.stage == .extracting || updated.manifest.stage == .failed else {
          return nil
        }
        if updated.manifest.stage == .failed {
          updated = try store.transition(sessionID: updated.sessionID, to: .extracting)
        }
        updated = try await store.markFinalAudioValidated(sessionID: updated.sessionID)
        updated = try store.transition(sessionID: updated.sessionID, to: .awaitingHistory)
      }
      let paths = finalOutputPaths(from: updated.manifest)
      switch updated.manifest.stage {
      case .awaitingHistory:
        return .readyForHistory(sessionID: updated.sessionID, outputPaths: paths)
      case .awaitingTranscription:
        guard updated.manifest.historyPersisted else { return nil }
        return .readyForTranscription(sessionID: updated.sessionID, outputPaths: paths)
      case .completed:
        return nil
      default:
        return nil
      }
    } catch {
      return nil
    }
  }

  private func markDamaged(
    session: AudioAdapterSession,
    code: String,
    recoverable: Bool
  ) async -> AudioRecordingRecoveryAction {
    let updated: AudioAdapterSession
    do {
      updated = try store.recordRecoveryError(
        sessionID: session.sessionID,
        code: code,
        message: "audio adapter recovery requires attention",
        recoverable: recoverable,
        terminal: !recoverable
      )
    } catch {
      // Keep the diagnostic metadata-only even if the damaged marker could
      // not be written; the action is not allowed to surface a media path.
      updated = session
    }
    return .damagedSession(
      sessionID: updated.sessionID,
      diagnosticCode: code,
      retryCount: updated.manifest.retryCount
    )
  }

  private func expectedTimelineDuration(for session: AudioAdapterSession) -> Double? {
    guard session.manifest.segments.allSatisfy({
      guard let duration = $0.durationSeconds else { return false }
      return duration.isFinite && duration > 0
    }) else { return nil }
    return session.manifest.segments.map {
      $0.timelineStartSeconds + ($0.durationSeconds ?? 0)
    }.max()
  }

  private func finalOutputPaths(from manifest: AudioAdapterSessionManifest) -> [String] {
    [manifest.finalPaths.mixed, manifest.finalPaths.system, manifest.finalPaths.microphone]
      .compactMap { $0 }
      .filter { AudioAdapterSessionManifest.isFinalRelativePath($0) }
  }

  private func fileIdentity(_ url: URL) -> String {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      return "missing:\(url.standardizedFileURL.path)"
    }
    let device = attributes[.systemNumber] as? NSNumber
    let inode = attributes[.systemFileNumber] as? NSNumber
    if let device, let inode { return "inode:\(device)-\(inode)" }
    return "path:\(url.standardizedFileURL.path)"
  }

  private func diagnosticCode(for error: Error) -> String {
    guard let error = error as? AudioExtractionPipelineError else {
      return "recovery_extraction_failed"
    }
    switch error {
    case .missingCaptureFile:
      return "missing_capture"
    case .invalidTrackCount:
      return "invalid_track_count"
    case .trackRoleMismatch:
      return "track_role_mismatch"
    case .invalidDuration, .finalDurationMismatch:
      return "invalid_duration"
    case .segmentOverlap:
      return "segment_overlap"
    case .duplicateSequence:
      return "duplicate_sequence"
    case .unsafeCapturePath, .unsafeOutputPath:
      return "path_invariant"
    case .extractionTimedOut:
      return "extraction_timeout"
    case .extractionCancelled:
      return "extraction_cancelled"
    case .outputValidationFailed:
      return "output_validation"
    default:
      return "recovery_extraction_failed"
    }
  }
}
