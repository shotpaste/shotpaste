//
//  AudioAdapterSessionStore.swift
//  ShotPaste
//
//  Atomic persistence and path confinement for audio-adapter sessions.
//

import AVFoundation
import Foundation

nonisolated struct AudioAdapterSessionScanRecord: Equatable, Sendable {
  let identifier: String
  let sessionID: UUID?
  let session: AudioAdapterSession?
  let diagnosticCode: String?

  var isValid: Bool { session != nil }

  static func valid(_ session: AudioAdapterSession) -> AudioAdapterSessionScanRecord {
    AudioAdapterSessionScanRecord(
      identifier: session.sessionID.uuidString,
      sessionID: session.sessionID,
      session: session,
      diagnosticCode: nil
    )
  }

  static func damaged(
    identifier: String,
    sessionID: UUID?,
    diagnosticCode: String
  ) -> AudioAdapterSessionScanRecord {
    AudioAdapterSessionScanRecord(
      identifier: identifier,
      sessionID: sessionID,
      session: nil,
      diagnosticCode: diagnosticCode
    )
  }
}

nonisolated final class AudioAdapterSessionStore: @unchecked Sendable {
  static let manifestFileName = "manifest.json"

  let sessionsDirectory: URL
  /// The physical root which owns the sessions directory.  Production uses
  /// the variant-specific Application Support root; tests may inject a
  /// temporary root.  Every component between this root and Sessions is
  /// checked with lstat before it is traversed.
  let allowedRoot: URL
  private let fileManager: FileManager
  private let outputValidator: @Sendable (URL) async -> AudioAssetValidationResult
  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    sessionsDirectory: URL? = AppDataLocations.audioAdapterSessionsDirectory,
    allowedRoot: URL? = nil,
    fileManager: FileManager = .default,
    outputValidator: @escaping @Sendable (URL) async -> AudioAssetValidationResult = {
      await AudioAssetValidator.validate(url: $0)
    }
  ) {
    let fallbackName = "ShotPaste-AudioAdapter-Sessions-\(AppVariant.current.rawValue)"
    let resolvedSessionsDirectory = (sessionsDirectory ?? fileManager.temporaryDirectory
      .appendingPathComponent(fallbackName, isDirectory: true))
      .standardizedFileURL
    self.sessionsDirectory = resolvedSessionsDirectory
    let defaultAllowedRoot: URL
    if sessionsDirectory == nil, let applicationSupportRoot = AppDataLocations.applicationSupportRoot {
      defaultAllowedRoot = applicationSupportRoot
    } else {
      defaultAllowedRoot = resolvedSessionsDirectory.deletingLastPathComponent()
    }
    self.allowedRoot = (allowedRoot ?? defaultAllowedRoot).standardizedFileURL
    self.fileManager = fileManager
    self.outputValidator = outputValidator

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  @discardableResult
  func createSession(
    sessionID: UUID = UUID(),
    selectedAudioSources: AudioAdapterAudioSourceSelection = .none,
    startedAt: Date = Date()
  ) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }

    try ensureSessionsDirectoryUnlocked()
    let directory = directoryURL(for: sessionID)
    if fileManager.fileExists(atPath: directory.path)
      || AudioAdapterSessionStorePathChecks.isSymbolicLink(at: directory, fileManager: fileManager) {
      throw AudioAdapterSessionStoreError.sessionAlreadyExists(sessionID)
    }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    } catch {
      throw AudioAdapterSessionStoreError.cannotCreateDirectory(directory.lastPathComponent)
    }

    let manifest = AudioAdapterSessionManifest(
      sessionID: sessionID,
      startedAt: startedAt,
      selectedAudioSources: selectedAudioSources
    )
    let session = AudioAdapterSession(manifest: manifest, directoryURL: directory)
    do {
      try persistUnlocked(session)
    } catch {
      // A failed first write must not leave a directory which a later call
      // could accidentally treat as an existing valid session.
      try? fileManager.removeItem(at: directory)
      throw error
    }
    return session
  }

  func load(sessionID: UUID) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }
    return try loadUnlocked(sessionID: sessionID)
  }

  /// Returns valid manifests.  Callers that need diagnostics should use
  /// `scanSessionRecords`, which deliberately retains corrupt UUID folders.
  func scanSessions() -> [AudioAdapterSession] {
    scanSessionRecords().compactMap(\.session).sorted {
      $0.manifest.startedAt < $1.manifest.startedAt
    }
  }

  /// Scans only real directories and keeps metadata-only records for corrupt
  /// manifests instead of silently dropping them.
  func scanSessionRecords() -> [AudioAdapterSessionScanRecord] {
    lock.lock()
    defer { lock.unlock() }

    guard AudioAdapterSessionStorePathChecks.isDirectory(
      at: sessionsDirectory,
      fileManager: fileManager
    ) else {
      return []
    }
    guard let entries = try? fileManager.contentsOfDirectory(
      at: sessionsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    return entries.compactMap { entry in
      let identifier = entry.lastPathComponent
      guard let id = UUID(uuidString: identifier) else {
        return .damaged(
          identifier: identifier,
          sessionID: nil,
          diagnosticCode: "invalid_session_directory_name"
        )
      }
      guard AudioAdapterSessionStorePathChecks.isDirectory(
        at: entry,
        fileManager: fileManager
      ) else {
        return .damaged(
          identifier: identifier,
          sessionID: id,
          diagnosticCode: "session_directory_not_real"
        )
      }
      do {
        return .valid(try loadUnlocked(sessionID: id))
      } catch let error as AudioAdapterSessionStoreError {
        let code: String
        switch error {
        case .unsupportedFutureSchema:
          code = "future_schema"
        case .unsafePath, .invalidCapturePath, .invalidOutputPath:
          code = "manifest_path_invariant"
        default:
          code = "manifest_unreadable"
        }
        return .damaged(identifier: identifier, sessionID: id, diagnosticCode: code)
      } catch {
        return .damaged(
          identifier: identifier,
          sessionID: id,
          diagnosticCode: "manifest_unreadable"
        )
      }
    }
  }

  func save(_ session: AudioAdapterSession) throws {
    lock.lock()
    defer { lock.unlock() }
    try validateStageMutationOnSaveUnlocked(session)
    try persistUnlocked(session)
  }

  /// `update` is deliberately non-stage.  Stage changes must go through the
  /// checked transition API, preventing an arbitrary closure from skipping
  /// awaitingHistory/awaitingTranscription.
  func update(
    sessionID: UUID,
    _ mutation: (inout AudioAdapterSessionManifest) throws -> Void
  ) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }

    var session = try loadUnlocked(sessionID: sessionID)
    let originalStage = session.manifest.stage
    let originalGateState = GateState(manifest: session.manifest)
    let originalMutationIdentity = MutationIdentity(manifest: session.manifest)
    try mutation(&session.manifest)
    guard session.manifest.schemaVersion == AudioAdapterSessionManifest.currentSchemaVersion,
          MutationIdentity(manifest: session.manifest) == originalMutationIdentity else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    guard session.manifest.stage == originalStage else {
      throw AudioAdapterSessionStoreError.invalidStateTransition(
        originalStage,
        session.manifest.stage
      )
    }
    guard GateState(manifest: session.manifest) == originalGateState else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    session.manifest.updatedAt = Date()
    try persistUnlocked(session)
    return session
  }

  @discardableResult
  func transition(
    sessionID: UUID,
    to stage: AudioAdapterSessionStage,
    at date: Date = Date()
  ) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }

    var session = try loadUnlocked(sessionID: sessionID)
    guard Self.isAllowedTransition(from: session.manifest.stage, to: stage) else {
      throw AudioAdapterSessionStoreError.invalidStateTransition(session.manifest.stage, stage)
    }
    session.manifest.setStage(stage, at: date)
    try persistUnlocked(session)
    return session
  }

  func appendSegment(
    sessionID: UUID,
    capturePath: String,
    sequence: Int? = nil,
    timelineStartSeconds: Double? = nil,
    durationSeconds: Double? = nil,
    trackRoles: [AudioAdapterTrackRole],
    trackIDsByRole: [AudioAdapterTrackRole: Int32] = [:]
  ) throws -> AudioAdapterSession {
    guard AudioAdapterSessionManifest.isCaptureRelativePath(capturePath) else {
      throw AudioAdapterSessionStoreError.invalidCapturePath(capturePath)
    }
    guard AudioAdapterSessionManifest.hasUniqueTrackIDs(trackIDsByRole) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    lock.lock()
    defer { lock.unlock() }
    var session = try loadUnlocked(sessionID: sessionID)
    let nextSequence = sequence ?? ((session.manifest.segments.map(\.sequence).max() ?? -1) + 1)
    let requestedRoles = Set(session.manifest.trackRoles)
    let actualRoles = Set(trackRoles)
    guard !session.manifest.segments.contains(where: { $0.sequence == nextSequence }),
          actualRoles.isSubset(of: requestedRoles),
          trackRoles.count == actualRoles.count,
          (durationSeconds == nil
            ? (trackIDsByRole.isEmpty
              ? (trackRoles.isEmpty || trackRoles == session.manifest.trackRoles)
              : Set(trackIDsByRole.keys) == actualRoles)
            : (!actualRoles.isEmpty && Set(trackIDsByRole.keys) == actualRoles)) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    let derivedStart = timelineStartSeconds ?? session.manifest.segments.map {
      ($0.timelineStartSeconds + ($0.durationSeconds ?? 0))
    }.max() ?? 0
    let segment = AudioAdapterCaptureSegment(
      sequence: nextSequence,
      capturePath: capturePath,
      timelineStartSeconds: derivedStart,
      durationSeconds: durationSeconds,
      trackRoles: trackRoles,
      trackIDsByRole: trackIDsByRole
    )
    session.manifest.segments.append(segment)
    session.manifest.segments.sort { $0.sequence < $1.sequence }
    session.manifest.updatedAt = Date()
    try persistUnlocked(session)
    return session
  }

  /// Persists the role -> actual AVAsset track-ID contract after stop.
  @discardableResult
  func recordTrackIDs(
    sessionID: UUID,
    segmentID: UUID,
    trackIDsByRole: [AudioAdapterTrackRole: Int32]
  ) throws -> AudioAdapterSession {
    guard !trackIDsByRole.isEmpty,
          AudioAdapterSessionManifest.hasUniqueTrackIDs(trackIDsByRole) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    lock.lock()
    defer { lock.unlock() }
    var session = try loadUnlocked(sessionID: sessionID)
    guard let index = session.manifest.segments.firstIndex(where: { $0.id == segmentID }),
          session.manifest.segments[index].durationSeconds == nil,
          Set(trackIDsByRole.keys).isSubset(of: Set(session.manifest.trackRoles)) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    let newestUnresolved = session.manifest.segments
      .filter { $0.durationSeconds == nil }
      .max { $0.sequence < $1.sequence }
    guard newestUnresolved?.id == session.manifest.segments[index].id else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    let actualRoles = AudioAdapterSessionManifest.orderedRequestedRoles(
      Set(trackIDsByRole.keys),
      for: session.manifest.selectedAudioSources
    )
    guard !actualRoles.isEmpty else { throw AudioAdapterSessionStoreError.invalidManifest }
    session.manifest.segments[index].trackRoles = actualRoles
    session.manifest.segments[index].trackIDsByRole = trackIDsByRole
    session.manifest.updatedAt = Date()
    try persistUnlocked(session)
    return session
  }

  /// Controlled stop transition.  Capture path and duration are identity
  /// fields, so Tiny stop must use this API rather than the general mutation
  /// closure.
  @discardableResult
  func recordCaptureOutput(
    sessionID: UUID,
    relativePath: String,
    durationSeconds: Double,
    trackIDsByRole: [AudioAdapterTrackRole: Int32],
    segmentID: UUID? = nil
  ) throws -> AudioAdapterSession {
    guard AudioAdapterSessionManifest.isCaptureRelativePath(relativePath),
          durationSeconds.isFinite,
          durationSeconds > 0,
          !trackIDsByRole.isEmpty,
          AudioAdapterSessionManifest.hasUniqueTrackIDs(trackIDsByRole) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    lock.lock()
    defer { lock.unlock() }
    var session = try loadUnlocked(sessionID: sessionID)
    guard session.manifest.stage == .stopping else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    let index = segmentID.flatMap { id in
      session.manifest.segments.firstIndex(where: { $0.id == id })
    }
    guard let index else { throw AudioAdapterSessionStoreError.invalidManifest }
    let newestUnresolved = session.manifest.segments
      .filter { $0.durationSeconds == nil }
      .max { $0.sequence < $1.sequence }
    guard let newestUnresolved,
          newestUnresolved.id == session.manifest.segments[index].id,
          session.manifest.segments[index].durationSeconds == nil else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    let actualRoles = AudioAdapterSessionManifest.orderedRequestedRoles(
      Set(trackIDsByRole.keys),
      for: session.manifest.selectedAudioSources
    )
    guard !actualRoles.isEmpty,
          Set(trackIDsByRole.keys).isSubset(of: Set(session.manifest.trackRoles)) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    guard Set(actualRoles) == Set(trackIDsByRole.keys) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    session.manifest.segments[index].trackRoles = actualRoles
    session.manifest.internalPaths.capture = relativePath
    session.manifest.segments[index].capturePath = relativePath
    session.manifest.segments[index].durationSeconds = durationSeconds
    session.manifest.segments[index].trackIDsByRole = trackIDsByRole
    session.manifest.updatedAt = Date()
    try persistUnlocked(session)
    return session
  }

  /// Atomically drops only the newest unresolved display-recovery placeholder
  /// and moves the session to a recoverable extraction boundary. Completed
  /// segments stay in manifest order and remain extractable by recovery.
  @discardableResult
  func abortDisplayRecovery(sessionID: UUID) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }
    var session = try loadUnlocked(sessionID: sessionID)
    guard session.manifest.stage == .stopping
      || session.manifest.stage == .preparing
      || session.manifest.stage == .failed else {
      return session
    }
    if let index = session.manifest.segments.lastIndex(where: { $0.durationSeconds == nil }) {
      let path = session.manifest.segments[index].capturePath
      if AudioAdapterSessionManifest.isCaptureRelativePath(path),
         let url = try? session.url(for: path),
         fileManager.fileExists(atPath: url.path),
         AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: fileManager) {
        try? fileManager.removeItem(at: url)
      }
      session.manifest.segments.remove(at: index)
    }
    session.manifest.internalPaths.capture = session.manifest.segments.last?.capturePath
    session.manifest.stage = .failed
    session.manifest.canDeleteInternalVideo = false
    session.manifest.updatedAt = Date()
    try persistUnlocked(session)
    return session
  }

  /// Starts one recovery retry and clears only a non-terminal recoverable
  /// error.  Retry count cannot be reset through `save`/`update`.
  @discardableResult
  func beginRecoveryRetry(sessionID: UUID) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }
    var session = try loadUnlocked(sessionID: sessionID)
    guard session.manifest.stage == .failed,
          !session.manifest.recoveryTerminal else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    session.manifest.incrementRetry()
    session.manifest.clearError()
    try persistUnlocked(session)
    return session
  }

  /// Records recovery failure through a monotonic, field-level API.  A
  /// terminal marker cannot be cleared by a broad manifest mutation.
  @discardableResult
  func recordRecoveryError(
    sessionID: UUID,
    code: String,
    message: String,
    recoverable: Bool,
    terminal: Bool
  ) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }
    var session = try loadUnlocked(sessionID: sessionID)
    guard !session.manifest.stage.isTerminal,
          !session.manifest.recoveryTerminal || terminal else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    session.manifest.recordError(
      AudioAdapterRecoverableError(code: code, message: message, isRecoverable: recoverable),
      terminal: terminal
    )
    try persistUnlocked(session)
    return session
  }

  func directoryURL(for sessionID: UUID) -> URL {
    sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
  }

  func url(for relativePath: String, sessionID: UUID) throws -> URL {
    let session = try load(sessionID: sessionID)
    return try session.url(for: relativePath)
  }

  /// Records that final outputs were validated.  Validation is performed here
  /// immediately before the durable mark, so a caller cannot turn a stale
  /// in-memory result into a deletion proof.
  @discardableResult
  func markFinalAudioValidated(
    sessionID: UUID,
    at date: Date = Date()
  ) async throws -> AudioAdapterSession {
    let session = try withStoreLock { try loadUnlocked(sessionID: sessionID) }
    guard session.manifest.stage == .extracting,
          !session.manifest.historyPersisted,
          !session.manifest.transcriptionTaskPersisted else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }

    try await validateFinalOutputs(for: session)

    return try withStoreLock {
      // Re-read in the same critical section as the commit. The identity
      // check prevents an earlier AV validation from opening a stale gate.
      let latest = try loadUnlocked(sessionID: sessionID)
      guard Self.matchesSnapshot(session, current: latest),
            latest.manifest.stage == .extracting,
            !latest.manifest.historyPersisted,
            !latest.manifest.transcriptionTaskPersisted else {
        throw AudioAdapterSessionStoreError.invalidManifest
      }
      var committed = latest
      committed.manifest.finalAudioValidated = true
      committed.manifest.finalAudioValidatedAt = date
      committed.manifest.canDeleteInternalVideo = false
      try persistUnlocked(committed)
      return committed
    }
  }

  /// Checked history persistence gate.  This atomically advances the stage
  /// and cannot be called out of order or with a caller-supplied boolean.
  @discardableResult
  func markHistoryPersisted(
    sessionID: UUID,
    reference: UUID,
    at date: Date = Date()
  ) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }

    var session = try loadUnlocked(sessionID: sessionID)
    guard Self.isUsableReference(reference),
          session.manifest.stage == .awaitingHistory,
          session.manifest.finalAudioValidated,
          !session.manifest.historyPersisted else {
      throw AudioAdapterSessionStoreError.invalidStateTransition(
        session.manifest.stage,
        .awaitingTranscription
      )
    }
    session.manifest.historyPersisted = true
    session.manifest.historyPersistedAt = date
    session.manifest.historyRecordReference = reference
    session.manifest.canDeleteInternalVideo = false
    session.manifest.setStage(.awaitingTranscription, at: date)
    try persistUnlocked(session)
    return session
  }

  /// Checked transcription persistence gate.  It is the only operation that
  /// may reach `completed`; the final deletion check still reloads and
  /// validates all M4A files before removing any MOV.
  @discardableResult
  func markTranscriptionTaskPersisted(
    sessionID: UUID,
    reference: UUID,
    at date: Date = Date()
  ) throws -> AudioAdapterSession {
    lock.lock()
    defer { lock.unlock() }

    var session = try loadUnlocked(sessionID: sessionID)
    guard Self.isUsableReference(reference),
          session.manifest.stage == .awaitingTranscription,
          session.manifest.finalAudioValidated,
          session.manifest.historyPersisted,
          !session.manifest.transcriptionTaskPersisted else {
      throw AudioAdapterSessionStoreError.invalidStateTransition(
        session.manifest.stage,
        .completed
      )
    }
    session.manifest.transcriptionTaskPersisted = true
    session.manifest.transcriptionTaskPersistedAt = date
    session.manifest.transcriptionTaskReference = reference
    session.manifest.canDeleteInternalVideo = false
    session.manifest.setStage(.completed, at: date)
    try persistUnlocked(session)
    return session
  }

  /// Reloads the manifest and verifies all durable gates plus every output
  /// path/content.  There is intentionally no caller-provided success bit.
  func canDeleteInternalVideo(sessionID: UUID) async throws -> Bool {
    let session = try withStoreLock { try loadUnlocked(sessionID: sessionID) }
    guard session.manifest.finalAudioValidated,
          session.manifest.historyPersisted,
          session.manifest.transcriptionTaskPersisted,
          session.manifest.stage == .completed else {
      return false
    }
    try await validateFinalOutputs(for: session)
    return true
  }

  /// Reloads and validates before deleting.  Only explicitly registered,
  /// regular `.mov` capture entries are unlinked; final `.m4a` files are never
  /// part of this operation.
  func deleteInternalVideo(sessionID: UUID) async throws {
    let snapshot = try withStoreLock { try loadUnlocked(sessionID: sessionID) }
    guard snapshot.manifest.finalAudioValidated,
          snapshot.manifest.historyPersisted,
          snapshot.manifest.transcriptionTaskPersisted,
          snapshot.manifest.stage == .completed else {
      throw AudioAdapterSessionStoreError.cannotPersistManifest("internal video deletion gate")
    }

    try await validateFinalOutputs(for: snapshot)

    try withStoreLock {
      var session = try loadUnlocked(sessionID: sessionID)
      guard Self.matchesSnapshot(snapshot, current: session),
            session.manifest.finalAudioValidated,
            session.manifest.historyPersisted,
            session.manifest.transcriptionTaskPersisted,
            session.manifest.stage == .completed else {
        throw AudioAdapterSessionStoreError.cannotPersistManifest("stale internal video deletion snapshot")
      }

    let paths = session.manifest.segments.map(\.capturePath)
      + [session.manifest.internalPaths.capture].compactMap { $0 }
    guard AudioAdapterSessionStorePathChecks.isPhysicallyConfined(
      session.directoryURL,
      under: allowedRoot,
      fileManager: fileManager
    ),
      session.directoryURL.deletingLastPathComponent().standardizedFileURL.path
        == sessionsDirectory.standardizedFileURL.path,
      !AudioAdapterSessionStorePathChecks.isSymbolicLink(
        at: session.directoryURL,
        fileManager: fileManager
      ) else {
      throw AudioAdapterSessionStoreError.unsafePath(session.directoryURL.path)
    }
    var removed = Set<String>()
    for relativePath in paths where removed.insert(relativePath).inserted {
      guard AudioAdapterSessionManifest.isCaptureRelativePath(relativePath) else {
        throw AudioAdapterSessionStoreError.invalidCapturePath(relativePath)
      }
      let url = try session.url(for: relativePath)
      if fileManager.fileExists(atPath: url.path) {
        guard AudioAdapterSessionStorePathChecks.isRegularFile(
          at: url,
          fileManager: fileManager
        ) else {
          throw AudioAdapterSessionStoreError.invalidCapturePath(relativePath)
        }
        try fileManager.removeItem(at: url)
      }
    }
    session.manifest.canDeleteInternalVideo = true
    session.manifest.updatedAt = Date()
    try persistUnlocked(session)
    }
  }

  /// Convenience spelling for code that already holds a session.  It still
  /// reloads by UUID, so a stale in-memory manifest cannot authorize cleanup.
  func deleteInternalVideo(for session: AudioAdapterSession) async throws {
    try await deleteInternalVideo(sessionID: session.sessionID)
  }

  // MARK: - Private

  /// Keeps synchronous NSLock operations inside a synchronous closure so
  /// Swift 6 does not treat them as actor-unsafe calls from async methods.
  private func withStoreLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func ensureSessionsDirectoryUnlocked() throws {
    guard AudioAdapterSessionStorePathChecks.isPhysicallyConfined(
      sessionsDirectory,
      under: allowedRoot,
      fileManager: fileManager
    ) else {
      throw AudioAdapterSessionStoreError.cannotCreateDirectory(sessionsDirectory.path)
    }
    if fileManager.fileExists(atPath: sessionsDirectory.path) {
      guard AudioAdapterSessionStorePathChecks.isDirectory(
        at: sessionsDirectory,
        fileManager: fileManager
      ) else {
        throw AudioAdapterSessionStoreError.cannotCreateDirectory(sessionsDirectory.path)
      }
      return
    }
    do {
      try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    } catch {
      throw AudioAdapterSessionStoreError.cannotCreateDirectory(sessionsDirectory.path)
    }
  }

  private func loadUnlocked(sessionID: UUID) throws -> AudioAdapterSession {
    guard AudioAdapterSessionStorePathChecks.isPhysicallyConfined(
      sessionsDirectory,
      under: allowedRoot,
      fileManager: fileManager
    ) else {
      throw AudioAdapterSessionStoreError.sessionNotFound(sessionID)
    }
    guard AudioAdapterSessionStorePathChecks.isDirectory(
      at: sessionsDirectory,
      fileManager: fileManager
    ) else {
      throw AudioAdapterSessionStoreError.sessionNotFound(sessionID)
    }
    let directory = directoryURL(for: sessionID)
    guard AudioAdapterSessionStorePathChecks.isPhysicallyConfined(
      directory,
      under: allowedRoot,
      fileManager: fileManager
    ) else {
      throw AudioAdapterSessionStoreError.sessionNotFound(sessionID)
    }
    guard AudioAdapterSessionStorePathChecks.isDirectory(
      at: directory,
      fileManager: fileManager
    ) else {
      throw AudioAdapterSessionStoreError.sessionNotFound(sessionID)
    }
    let manifestURL = directory.appendingPathComponent(Self.manifestFileName, isDirectory: false)
    guard AudioAdapterSessionStorePathChecks.isRegularFile(
      at: manifestURL,
      fileManager: fileManager
    ), let data = try? Data(contentsOf: manifestURL) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }

    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let version = object["schemaVersion"] as? Int,
       version > AudioAdapterSessionManifest.currentSchemaVersion {
      throw AudioAdapterSessionStoreError.unsupportedFutureSchema(version)
    }

    let manifest: AudioAdapterSessionManifest
    do {
      manifest = try decoder.decode(AudioAdapterSessionManifest.self, from: data)
    } catch {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    guard manifest.sessionID == sessionID,
          manifest.hasSafeRelativePaths else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    let session = AudioAdapterSession(manifest: manifest, directoryURL: directory)
    try validateRuntimePathsUnlocked(session)
    return session
  }

  private func persistUnlocked(_ session: AudioAdapterSession) throws {
    guard let directoryID = UUID(uuidString: session.directoryURL.lastPathComponent),
          session.manifest.sessionID == directoryID,
          session.directoryURL.deletingLastPathComponent().standardizedFileURL.path
            == sessionsDirectory.standardizedFileURL.path,
          AudioAdapterSessionStorePathChecks.isPhysicallyConfined(
            session.directoryURL,
            under: allowedRoot,
            fileManager: fileManager
          ) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }

    do {
      if fileManager.fileExists(atPath: session.directoryURL.path) {
        guard AudioAdapterSessionStorePathChecks.isDirectory(
          at: session.directoryURL,
          fileManager: fileManager
        ) else {
          throw AudioAdapterSessionStoreError.cannotCreateDirectory(
            session.directoryURL.lastPathComponent
          )
        }
      } else {
        try fileManager.createDirectory(
          at: session.directoryURL,
          withIntermediateDirectories: false
        )
      }

      try validateRuntimePathsUnlocked(session)
      guard session.manifest.hasSafeRelativePaths else {
        throw AudioAdapterSessionStoreError.invalidManifest
      }

      let data = try encoder.encode(session.manifest)
      let manifestURL = session.manifestURL
      if fileManager.fileExists(atPath: manifestURL.path) {
        guard AudioAdapterSessionStorePathChecks.isRegularFile(
          at: manifestURL,
          fileManager: fileManager
        ) else {
          throw AudioAdapterSessionStoreError.invalidManifest
        }
      }
      let temporaryURL = session.directoryURL.appendingPathComponent(
        ".manifest-" + UUID().uuidString + ".tmp",
        isDirectory: false
      )
      defer { try? fileManager.removeItem(at: temporaryURL) }
      try data.write(to: temporaryURL, options: .atomic)

      if fileManager.fileExists(atPath: manifestURL.path) {
        _ = try fileManager.replaceItemAt(
          manifestURL,
          withItemAt: temporaryURL,
          backupItemName: nil,
          options: []
        )
      } else {
        try fileManager.moveItem(at: temporaryURL, to: manifestURL)
      }
    } catch let error as AudioAdapterSessionStoreError {
      throw error
    } catch {
      throw AudioAdapterSessionStoreError.cannotPersistManifest(error.localizedDescription)
    }
  }

  private func validateStageMutationOnSaveUnlocked(_ session: AudioAdapterSession) throws {
    guard fileManager.fileExists(atPath: session.manifestURL.path) else { return }
    let current = try loadUnlocked(sessionID: session.sessionID)
    guard session.manifest.schemaVersion == AudioAdapterSessionManifest.currentSchemaVersion,
          MutationIdentity(manifest: session.manifest)
            == MutationIdentity(manifest: current.manifest) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
    guard current.manifest.stage == session.manifest.stage else {
      throw AudioAdapterSessionStoreError.invalidStateTransition(
        current.manifest.stage,
        session.manifest.stage
      )
    }
    guard GateState(manifest: session.manifest) == GateState(manifest: current.manifest) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
  }

  private struct GateState: Equatable {
    let finalAudioValidated: Bool
    let finalAudioValidatedAt: Date?
    let historyPersisted: Bool
    let historyPersistedAt: Date?
    let historyRecordReference: UUID?
    let transcriptionTaskPersisted: Bool
    let transcriptionTaskPersistedAt: Date?
    let transcriptionTaskReference: UUID?
    let canDeleteInternalVideo: Bool

    init(manifest: AudioAdapterSessionManifest) {
      finalAudioValidated = manifest.finalAudioValidated
      finalAudioValidatedAt = manifest.finalAudioValidatedAt
      historyPersisted = manifest.historyPersisted
      historyPersistedAt = manifest.historyPersistedAt
      historyRecordReference = manifest.historyRecordReference
      transcriptionTaskPersisted = manifest.transcriptionTaskPersisted
      transcriptionTaskPersistedAt = manifest.transcriptionTaskPersistedAt
      transcriptionTaskReference = manifest.transcriptionTaskReference
      canDeleteInternalVideo = manifest.canDeleteInternalVideo
    }
  }

  /// A validation result was computed without holding the Store lock. Before
  /// committing a gate or deleting MOVs, require the manifest identity and
  /// gate inputs to be unchanged by another actor/task.
  private static func matchesSnapshot(
    _ snapshot: AudioAdapterSession,
    current: AudioAdapterSession
  ) -> Bool {
    snapshot.sessionID == current.sessionID
      && snapshot.manifest.schemaVersion == current.manifest.schemaVersion
      && snapshot.manifest.stage == current.manifest.stage
      && snapshot.manifest.updatedAt == current.manifest.updatedAt
      && snapshot.manifest.selectedAudioSources == current.manifest.selectedAudioSources
      && snapshot.manifest.trackRoles == current.manifest.trackRoles
      && snapshot.manifest.segments == current.manifest.segments
      && snapshot.manifest.internalPaths == current.manifest.internalPaths
      && snapshot.manifest.finalPaths == current.manifest.finalPaths
      && snapshot.manifest.checksums == current.manifest.checksums
      && GateState(manifest: snapshot.manifest) == GateState(manifest: current.manifest)
  }

  /// Fields which ordinary closures are never allowed to rewrite.  Workflow
  /// operations below expose narrow, named transitions for retry, terminal
  /// diagnostics, and capture identity updates instead.
  private struct MutationIdentity: Equatable {
    let schemaVersion: Int
    let sessionID: UUID
    let stage: AudioAdapterSessionStage
    let selectedAudioSources: AudioAdapterAudioSourceSelection
    let trackRoles: [AudioAdapterTrackRole]
    let retryCount: Int
    let recoveryTerminal: Bool
    let segments: [AudioAdapterCaptureSegment]

    init(manifest: AudioAdapterSessionManifest) {
      schemaVersion = manifest.schemaVersion
      sessionID = manifest.sessionID
      stage = manifest.stage
      selectedAudioSources = manifest.selectedAudioSources
      trackRoles = manifest.trackRoles
      retryCount = manifest.retryCount
      recoveryTerminal = manifest.recoveryTerminal
      segments = manifest.segments
        .sorted { $0.sequence < $1.sequence }
    }
  }

  private func validateRuntimePathsUnlocked(_ session: AudioAdapterSession) throws {
    let capturePaths = session.manifest.segments.map(\.capturePath)
      + [session.manifest.internalPaths.capture].compactMap { $0 }
    let outputPaths = session.manifest.finalPaths.allValues
      + [
        session.manifest.internalPaths.mixed,
        session.manifest.internalPaths.system,
        session.manifest.internalPaths.microphone,
      ].compactMap { $0 }

    var captureURLs: [URL] = []
    for path in capturePaths {
      guard AudioAdapterSessionManifest.isCaptureRelativePath(path) else {
        throw AudioAdapterSessionStoreError.invalidCapturePath(path)
      }
      let url = try session.url(for: path)
      captureURLs.append(url)
      if fileManager.fileExists(atPath: url.path),
         !AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: fileManager) {
        throw AudioAdapterSessionStoreError.invalidCapturePath(path)
      }
    }

    var outputURLs: [URL] = []
    for path in outputPaths {
      guard AudioAdapterSessionManifest.isFinalRelativePath(path) else {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
      let url = try session.url(for: path)
      outputURLs.append(url)
      if fileManager.fileExists(atPath: url.path),
         !AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: fileManager) {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
    }

    let captureKeys = Set(captureURLs.map { Self.fileIdentity($0, fileManager: fileManager) })
    let outputKeys = Set(outputURLs.map { Self.fileIdentity($0, fileManager: fileManager) })
    guard captureKeys.isDisjoint(with: outputKeys) else {
      throw AudioAdapterSessionStoreError.invalidManifest
    }
  }

  private func validateFinalOutputs(for session: AudioAdapterSession) async throws {
    let roles = session.manifest.effectiveCapturedTrackRoles
    guard !roles.isEmpty else {
      throw AudioAdapterSessionStoreError.invalidOutputPath("effective_roles")
    }
    var required: [String] = []
    guard session.manifest.finalPaths.capture == nil else {
      throw AudioAdapterSessionStoreError.invalidOutputPath("capture")
    }
    guard let mixed = session.manifest.finalPaths.mixed else {
      throw AudioAdapterSessionStoreError.invalidOutputPath("mixed")
    }
    required.append(mixed)
    if roles.count == 2 {
      guard let path = session.manifest.finalPaths.system else {
        throw AudioAdapterSessionStoreError.invalidOutputPath("system")
      }
      required.append(path)
      guard let path = session.manifest.finalPaths.microphone else {
        throw AudioAdapterSessionStoreError.invalidOutputPath("microphone")
      }
      required.append(path)
    } else {
      guard session.manifest.finalPaths.system == nil,
            session.manifest.finalPaths.microphone == nil else {
        throw AudioAdapterSessionStoreError.invalidOutputPath("unexpected_role_output")
      }
    }

    let captureURLs = try session.manifest.segments.map { segment -> URL in
      guard AudioAdapterSessionManifest.isCaptureRelativePath(segment.capturePath),
            segment.durationSeconds?.isFinite == true,
            segment.durationSeconds ?? 0 > 0 else {
        throw AudioAdapterSessionStoreError.invalidCapturePath(segment.capturePath)
      }
      let url = try session.url(for: segment.capturePath)
      guard !AudioAdapterSessionStorePathChecks.hasSymlinkComponent(
        root: session.directoryURL.standardizedFileURL,
        relativePath: segment.capturePath,
        fileManager: fileManager
      ) else {
        throw AudioAdapterSessionStoreError.invalidCapturePath(segment.capturePath)
      }
      return url
    }
    let captureKeys = Set(captureURLs.map { Self.fileIdentity($0, fileManager: fileManager) })
    var outputKeys = Set<String>()
    var finalDuration: Double?
    for path in required {
      guard AudioAdapterSessionManifest.isFinalRelativePath(path) else {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
      let url = try session.url(for: path)
      guard !AudioAdapterSessionStorePathChecks.hasSymlinkComponent(
        root: session.directoryURL.standardizedFileURL,
        relativePath: path,
        fileManager: fileManager
      ),
        AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: fileManager) else {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
      let identity = Self.fileIdentity(url, fileManager: fileManager)
      guard outputKeys.insert(identity).inserted, !captureKeys.contains(identity) else {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
      let validation = await outputValidator(url)
      guard validation.isValid,
            validation.audioTrackCount >= 1,
            validation.videoTrackCount == 0,
            let duration = validation.duration,
            duration.isFinite,
            duration > 0 else {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
      if let finalDuration,
         abs(duration - finalDuration) > AudioAdapterSessionDurationPolicy.tolerance(for: finalDuration) {
        throw AudioAdapterSessionStoreError.invalidOutputPath(path)
      }
      if finalDuration == nil { finalDuration = duration }
    }

    guard let expectedDuration = expectedTimelineDuration(for: session),
          let finalDuration,
          abs(finalDuration - expectedDuration)
            <= AudioAdapterSessionDurationPolicy.tolerance(for: expectedDuration) else {
      throw AudioAdapterSessionStoreError.invalidOutputPath("duration")
    }
  }

  private func expectedTimelineDuration(for session: AudioAdapterSession) -> Double? {
    guard !session.manifest.segments.isEmpty,
          session.manifest.segments.allSatisfy({
            guard let duration = $0.durationSeconds else { return false }
            return duration.isFinite && duration > 0
          }) else { return nil }
    return session.manifest.segments.map {
      $0.timelineStartSeconds + ($0.durationSeconds ?? 0)
    }.max()
  }

  private static func isUsableReference(_ reference: UUID) -> Bool {
    reference != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
  }

  private static func fileIdentity(
    _ url: URL,
    fileManager: FileManager = .default
  ) -> String {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      return "missing:\(url.standardizedFileURL.path)"
    }
    let device = attributes[.systemNumber] as? NSNumber
    let inode = attributes[.systemFileNumber] as? NSNumber
    if let device, let inode {
      return "inode:\(device)-\(inode)"
    }
    return "path:\(url.standardizedFileURL.path)"
  }

  private static func isAllowedTransition(
    from: AudioAdapterSessionStage,
    to: AudioAdapterSessionStage
  ) -> Bool {
    if from == to { return true }
    switch (from, to) {
    case (.created, .preparing), (.created, .cancelled), (.created, .failed),
         (.preparing, .recording), (.preparing, .cancelled), (.preparing, .failed),
         (.recording, .paused), (.recording, .stopping), (.recording, .cancelled), (.recording, .failed),
         (.paused, .recording), (.paused, .stopping), (.paused, .cancelled), (.paused, .failed),
         (.stopping, .extracting), (.stopping, .failed), (.stopping, .cancelled),
         (.extracting, .awaitingHistory), (.extracting, .failed),
         (.awaitingHistory, .awaitingTranscription), (.awaitingHistory, .failed),
         (.awaitingTranscription, .completed), (.awaitingTranscription, .failed),
         (.failed, .preparing), (.failed, .extracting), (.failed, .cancelled):
      return true
    default:
      return false
    }
  }
}
