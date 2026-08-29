//
//  AudioProcessingTaskStore.swift
//  ShotPaste
//
//  Atomic, variant-scoped persistence for transcription and derived content.
//

import Foundation

nonisolated enum AudioProcessingTaskStoreError: LocalizedError, Equatable, Sendable {
  case invalidTask
  case taskAlreadyPersisted(UUID)
  case taskNotFound(UUID)
  case rawTranscriptAlreadyPersisted
  case artifactNotFound(String)
  case unsafePath(String)
  case unsafeSessionDirectory
  case cannotCreateDirectory(String)
  case cannotPersist(String)
  case invalidStateTransition(AudioProcessingTaskStage, AudioProcessingTaskStage)
  case cancellationRequested

  var errorDescription: String? {
    switch self {
    case .invalidTask:
      "The audio processing task is invalid."
    case .taskAlreadyPersisted:
      "The audio processing task has already been persisted."
    case .taskNotFound:
      "The audio processing task was not found."
    case .rawTranscriptAlreadyPersisted:
      "The raw transcript is immutable once persisted."
    case .artifactNotFound:
      "The requested audio processing artifact was not found."
    case .unsafePath, .unsafeSessionDirectory:
      "The audio processing path is outside the private session directory."
    case .cannotCreateDirectory:
      "The audio processing directory could not be created."
    case .cannotPersist:
      "The audio processing state could not be persisted."
    case .invalidStateTransition:
      "The audio processing state transition is not allowed."
    case .cancellationRequested:
      "The audio processing task was cancelled."
    }
  }
}

/// The processing store deliberately owns only the `Processing` side of a
/// session.  It never deletes the source M4A/MOV and never emits prompt or
/// transcript content to a logger.
nonisolated final class AudioProcessingTaskStore: @unchecked Sendable {
  static let taskFileName = "processing-task.json"
  static let rawTranscriptFileName = "raw-transcript.json"
  static let polishedTranscriptFileName = "polished-transcript.json"
  static let structuredContentFileName = "structured-content.json"
  static let historyFileName = "history-processing.json"
  static let processingDirectoryName = "Processing"
  static let chunksDirectoryName = "Chunks"
  private static let artifactFileNames: Set<String> = [
    taskFileName,
    rawTranscriptFileName,
    polishedTranscriptFileName,
    structuredContentFileName,
    historyFileName
  ]

  let sessionsDirectory: URL
  let allowedRoot: URL

  private let fileManager: FileManager
  private let lock = NSLock()
  /// File coordination is process-wide because recovery can construct a new
  /// store instance for the same session.  UUID temporary names still protect
  /// against another process, while this lock closes the in-process window.
  private static let atomicWriteLock = NSLock()
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    sessionsDirectory: URL? = AppDataLocations.audioAdapterSessionsDirectory,
    allowedRoot: URL? = nil,
    fileManager: FileManager = .default
  ) {
    let fallback = fileManager.temporaryDirectory
      .appendingPathComponent(
        "ShotPaste-AudioProcessing-\(AppVariant.current.rawValue)",
        isDirectory: true
      )
    let resolved = (sessionsDirectory ?? fallback).standardizedFileURL
    self.sessionsDirectory = resolved
    self.allowedRoot = (allowedRoot ?? resolved.deletingLastPathComponent()).standardizedFileURL
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  // MARK: - Session and artifact URLs

  func sessionDirectoryURL(for sessionID: UUID) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    return try sessionDirectoryURLUnlocked(for: sessionID, create: false)
  }

  func artifactURL(sessionID: UUID, fileName: String) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    guard Self.artifactFileNames.contains(fileName) else {
      throw AudioProcessingTaskStoreError.unsafePath(fileName)
    }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: false)
    let url = directory.appendingPathComponent(fileName, isDirectory: false)
    guard isPhysicallyConfined(url), !hasSymlinkComponent(url) else {
      throw AudioProcessingTaskStoreError.unsafePath(fileName)
    }
    return url
  }

  /// Returns the private Processing directory and creates it when needed.
  func processingDirectoryURL(for sessionID: UUID) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    let sessionDirectory = try sessionDirectoryURLUnlocked(for: sessionID, create: true)
    let processingDirectory = sessionDirectory.appendingPathComponent(
      Self.processingDirectoryName,
      isDirectory: true
    )
    try ensureDirectoryUnlocked(processingDirectory)
    return processingDirectory
  }

  /// The temporary chunk directory is inside `<session>/Processing` and may
  /// be removed after every chunk.  The caller must never use it for a source
  /// media URL.
  func chunksDirectoryURL(for sessionID: UUID) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    let sessionDirectory = try sessionDirectoryURLUnlocked(for: sessionID, create: true)
    let processingDirectory = sessionDirectory.appendingPathComponent(
      Self.processingDirectoryName,
      isDirectory: true
    )
    let chunksDirectory = processingDirectory.appendingPathComponent(
      Self.chunksDirectoryName,
      isDirectory: true
    )
    try ensureDirectoryUnlocked(chunksDirectory)
    return chunksDirectory
  }

  /// Validates a final audio URL before any media reader/exporter opens it.
  /// The returned path is the only source path that may be persisted in a
  /// processing task.  Final outputs are intentionally restricted to regular,
  /// non-symlink `.m4a` files inside this session.
  func confinedSourcePath(
    for url: URL,
    sessionID: UUID,
    allowedRelativePaths: Set<String>? = nil
  ) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    let sessionDirectory = sessionsDirectory
      .appendingPathComponent(sessionID.uuidString, isDirectory: true)
      .standardizedFileURL
    let candidate = url.standardizedFileURL
    guard candidate.isFileURL,
          candidate.pathExtension.lowercased() == "m4a",
          candidate.path.hasPrefix(sessionDirectory.path + "/"),
          isPhysicallyConfined(sessionDirectory),
          isPhysicallyConfined(candidate),
          !hasSymlinkComponent(candidate),
          isRegularFile(at: candidate) else {
      throw AudioProcessingTaskStoreError.unsafePath(url.lastPathComponent)
    }
    let relative = String(candidate.path.dropFirst(sessionDirectory.path.count + 1))
    guard AudioProcessingTask.isSafeRelativePath(relative),
          !isReservedProcessingPath(relative),
          allowedRelativePaths.map({ $0.contains(relative) }) ?? true else {
      throw AudioProcessingTaskStoreError.unsafePath(relative)
    }
    return relative
  }

  // MARK: - Task persistence

  /// Persists a new task and returns the task's actual UUID reference.  The
  /// UUID is generated by `AudioProcessingTask` and is not a caller label;
  /// callers may pass it to the session store's three-gate API.
  @discardableResult
  func persistTask(_ task: AudioProcessingTask) throws -> UUID {
    lock.lock()
    defer { lock.unlock() }
    try validateTask(task)
    let directory = try sessionDirectoryURLUnlocked(for: task.sessionID, create: true)
    let taskURL = directory.appendingPathComponent(Self.taskFileName, isDirectory: false)
    guard !fileManager.fileExists(atPath: taskURL.path),
          !isSymbolicLink(at: taskURL) else {
      throw AudioProcessingTaskStoreError.taskAlreadyPersisted(task.id)
    }
    try atomicWriteUnlocked(
      task,
      to: taskURL,
      overwrite: false,
      existingError: .taskAlreadyPersisted(task.id)
    )
    let history = AudioProcessingHistoryRecord(task: task)
    try atomicWriteUnlocked(
      history,
      to: directory.appendingPathComponent(Self.historyFileName, isDirectory: false),
      overwrite: true
    )
    return task.id
  }

  /// Convenience overload used by session coordinators that already know the
  /// session ID.  The task/session identity is checked before writing.
  @discardableResult
  func persistTask(sessionID: UUID, task: AudioProcessingTask) throws -> UUID {
    guard task.sessionID == sessionID else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    return try persistTask(task)
  }

  func loadTask(sessionID: UUID) throws -> AudioProcessingTask {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: false)
    return try decodeUnlocked(
      AudioProcessingTask.self,
      at: directory.appendingPathComponent(Self.taskFileName, isDirectory: false),
      missing: .taskNotFound(sessionID)
    )
  }

  func updateTask(
    sessionID: UUID,
    _ mutation: (inout AudioProcessingTask) throws -> Void
  ) throws -> AudioProcessingTask {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: false)
    var task = try decodeUnlocked(
      AudioProcessingTask.self,
      at: directory.appendingPathComponent(Self.taskFileName, isDirectory: false),
      missing: .taskNotFound(sessionID)
    )
    let originalID = task.id
    let originalSessionID = task.sessionID
    let originalSchemaVersion = task.schemaVersion
    let originalStage = task.stage
    try mutation(&task)
    guard task.id == originalID,
          task.sessionID == originalSessionID,
          task.schemaVersion == originalSchemaVersion else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    guard task.stage == originalStage
      || Self.isAllowedTransition(from: originalStage, to: task.stage) else {
      throw AudioProcessingTaskStoreError.invalidStateTransition(originalStage, task.stage)
    }
    try validateTask(task)
    task.updatedAt = Date()
    let taskURL = directory.appendingPathComponent(Self.taskFileName, isDirectory: false)
    try atomicWriteUnlocked(task, to: taskURL, overwrite: true)
    try persistHistoryUnlocked(task, in: directory)
    return task
  }

  @discardableResult
  func transition(
    sessionID: UUID,
    to stage: AudioProcessingTaskStage,
    at date: Date = Date()
  ) throws -> AudioProcessingTask {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: false)
    var task = try decodeUnlocked(
      AudioProcessingTask.self,
      at: directory.appendingPathComponent(Self.taskFileName, isDirectory: false),
      missing: .taskNotFound(sessionID)
    )
    guard Self.isAllowedTransition(from: task.stage, to: stage) else {
      throw AudioProcessingTaskStoreError.invalidStateTransition(task.stage, stage)
    }
    task.stage = stage
    task.updatedAt = date
    if stage == .cancelled {
      task.cancellationRequested = true
    }
    if stage != .failed { task.errorCode = nil; task.errorMessage = nil }
    try atomicWriteUnlocked(
      task,
      to: directory.appendingPathComponent(Self.taskFileName, isDirectory: false),
      overwrite: true
    )
    try persistHistoryUnlocked(task, in: directory, updatedAt: date)
    return task
  }

  @discardableResult
  func markFailed(
    sessionID: UUID,
    code: String,
    message: String,
    at date: Date = Date()
  ) throws -> AudioProcessingTask {
    try updateTask(sessionID: sessionID) { task in
      task.stage = .failed
      task.errorCode = code
      // The message is deliberately a short, non-content diagnostic.  The
      // pipeline only passes framework error categories here.
      task.errorMessage = message
      task.updatedAt = date
    }
  }

  @discardableResult
  func requestCancellation(sessionID: UUID) throws -> AudioProcessingTask {
    try updateTask(sessionID: sessionID) { task in
      guard !task.stage.isTerminal else {
        throw AudioProcessingTaskStoreError.cancellationRequested
      }
      task.cancellationRequested = true
      task.stage = .cancelled
    }
  }

  // MARK: - Transcript and derived artifacts

  /// Writes raw transcript content exactly once.  An existing file, including
  /// a corrupt or symlinked file, is never replaced.
  func persistRawTranscript(
    _ transcript: AudioRawTranscript,
    sessionID: UUID
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: true)
    let taskURL = directory.appendingPathComponent(Self.taskFileName, isDirectory: false)
    guard let task = try? decodeUnlocked(AudioProcessingTask.self, at: taskURL, missing: nil),
          task.sessionID == sessionID,
          transcript.hasValidStructure else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    guard transcript.sessionID == nil || transcript.sessionID == sessionID else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    let target = directory.appendingPathComponent(Self.rawTranscriptFileName, isDirectory: false)
    guard !fileManager.fileExists(atPath: target.path), !isSymbolicLink(at: target) else {
      throw AudioProcessingTaskStoreError.rawTranscriptAlreadyPersisted
    }
    try atomicWriteUnlocked(
      transcript,
      to: target,
      overwrite: false,
      existingError: .rawTranscriptAlreadyPersisted
    )
    try updateHistoryArtifactsUnlocked(in: directory)
  }

  func loadRawTranscript(sessionID: UUID) throws -> AudioRawTranscript {
    try loadArtifact(AudioRawTranscript.self, fileName: Self.rawTranscriptFileName, sessionID: sessionID)
  }

  func persistPolishedTranscript(
    _ transcript: AudioPolishedTranscript,
    sessionID: UUID
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: true)
    guard let raw = try? decodeUnlocked(
      AudioRawTranscript.self,
      at: directory.appendingPathComponent(Self.rawTranscriptFileName, isDirectory: false),
      missing: nil
    ),
    !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    !transcript.sourceSegmentIDs.isEmpty,
    Set(transcript.sourceSegmentIDs).count == transcript.sourceSegmentIDs.count,
    Set(transcript.sourceSegmentIDs) == raw.segmentIDs else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    try atomicWriteUnlocked(
      transcript,
      to: directory.appendingPathComponent(Self.polishedTranscriptFileName, isDirectory: false),
      overwrite: true
    )
    try updateHistoryArtifactsUnlocked(in: directory)
  }

  func loadPolishedTranscript(sessionID: UUID) throws -> AudioPolishedTranscript {
    try loadArtifact(
      AudioPolishedTranscript.self,
      fileName: Self.polishedTranscriptFileName,
      sessionID: sessionID
    )
  }

  func persistStructuredContent(
    _ content: AudioStructuredContent,
    sessionID: UUID
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: true)
    guard let raw = try? decodeUnlocked(
      AudioRawTranscript.self,
      at: directory.appendingPathComponent(Self.rawTranscriptFileName, isDirectory: false),
      missing: nil
    ),
    content.transcriptSegmentIDs.count == raw.segmentIDs.count,
    Set(content.transcriptSegmentIDs) == raw.segmentIDs,
    content.hasValidReferences(in: raw) else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    try atomicWriteUnlocked(
      content,
      to: directory.appendingPathComponent(Self.structuredContentFileName, isDirectory: false),
      overwrite: true
    )
    try updateHistoryArtifactsUnlocked(in: directory)
  }

  func loadStructuredContent(sessionID: UUID) throws -> AudioStructuredContent {
    try loadArtifact(
      AudioStructuredContent.self,
      fileName: Self.structuredContentFileName,
      sessionID: sessionID
    )
  }

  func loadHistory(sessionID: UUID) throws -> AudioProcessingHistoryRecord {
    try loadArtifact(
      AudioProcessingHistoryRecord.self,
      fileName: Self.historyFileName,
      sessionID: sessionID
    )
  }

  /// Sidecar status is written independently from the task file, so a UI
  /// reader can observe progress without reading transcript/prompt content.
  func persistHistory(_ record: AudioProcessingHistoryRecord, sessionID: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    guard record.sessionID == sessionID else { throw AudioProcessingTaskStoreError.invalidTask }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: true)
    let taskURL = directory.appendingPathComponent(Self.taskFileName, isDirectory: false)
    guard let task = try? decodeUnlocked(AudioProcessingTask.self, at: taskURL, missing: nil),
          task.id == record.taskID else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
    try atomicWriteUnlocked(
      record,
      to: directory.appendingPathComponent(Self.historyFileName, isDirectory: false),
      overwrite: true
    )
  }

  // MARK: - Recovery and cleanup

  /// Scans only real UUID session directories and returns recoverable tasks.
  /// Corrupt task JSON is ignored rather than being surfaced as a fake task.
  func scanUnfinishedTasks() -> [AudioProcessingTask] {
    lock.lock()
    defer { lock.unlock() }
    guard isDirectory(at: sessionsDirectory) else { return [] }
    guard let entries = try? fileManager.contentsOfDirectory(
      at: sessionsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries.compactMap { entry in
      guard UUID(uuidString: entry.lastPathComponent) != nil,
            isDirectory(at: entry) else { return nil }
      let taskURL = entry.appendingPathComponent(Self.taskFileName, isDirectory: false)
      guard isRegularFile(at: taskURL),
            let task = try? decodeUnlocked(AudioProcessingTask.self, at: taskURL, missing: nil),
            task.isUnfinished,
            task.hasSafeSourcePaths else { return nil }
      return task
    }.sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Alias used by recovery coordinators.
  func recoverableTasks() -> [AudioProcessingTask] { scanUnfinishedTasks() }

  func removeTemporaryChunks(
    sessionID: UUID,
    preservingSourceURLs: [URL] = []
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    // A first process may not have created Processing/Chunks yet.  Cleanup is
    // deliberately idempotent so callers can invoke it at every run boundary
    // without turning a missing temporary directory into a task failure.
    guard let chunks = try? chunksDirectoryURLUnlocked(for: sessionID, create: false) else {
      return
    }
    guard isPhysicallyConfined(chunks), isDirectory(at: chunks) else { return }
    guard let entries = try? fileManager.contentsOfDirectory(
      at: chunks,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return }
    let preservedPaths = preservingSourceURLs.map { $0.standardizedFileURL.path }
    // Only direct regular files are removed.  A suspicious child remains for
    // inspection and cannot make cleanup escape the session directory.  A
    // source URL is protected by both exact-path and ancestor checks: this
    // keeps a malformed source under Chunks intact long enough for the source
    // confinement check to reject it.
    for entry in entries where isPhysicallyConfined(entry) && !hasSymlinkComponent(entry) {
      let entryPath = entry.standardizedFileURL.path
      guard !preservedPaths.contains(where: { path in
        path == entryPath || path.hasPrefix(entryPath + "/")
      }) else {
        continue
      }
      if isRegularFile(at: entry) || isDirectory(at: entry) {
        try? fileManager.removeItem(at: entry)
      }
    }
  }

  // MARK: - Private persistence helpers

  private func loadArtifact<T: Decodable>(
    _ type: T.Type,
    fileName: String,
    sessionID: UUID
  ) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: false)
    let url = directory.appendingPathComponent(fileName, isDirectory: false)
    return try decodeUnlocked(type, at: url, missing: .artifactNotFound(fileName))
  }

  private func sessionDirectoryURLUnlocked(for sessionID: UUID, create: Bool) throws -> URL {
    let directory = sessionsDirectory.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    guard isPhysicallyConfined(directory) else {
      throw AudioProcessingTaskStoreError.unsafeSessionDirectory
    }
    if create {
      try ensureDirectoryUnlocked(sessionsDirectory)
      try ensureDirectoryUnlocked(directory)
    } else if !isDirectory(at: directory) {
      throw AudioProcessingTaskStoreError.taskNotFound(sessionID)
    }
    return directory
  }

  private func chunksDirectoryURLUnlocked(for sessionID: UUID, create: Bool) throws -> URL {
    let directory = try sessionDirectoryURLUnlocked(for: sessionID, create: create)
    let processing = directory.appendingPathComponent(Self.processingDirectoryName, isDirectory: true)
    let chunks = processing.appendingPathComponent(Self.chunksDirectoryName, isDirectory: true)
    if create {
      try ensureDirectoryUnlocked(processing)
      try ensureDirectoryUnlocked(chunks)
    } else if !isDirectory(at: chunks) {
      throw AudioProcessingTaskStoreError.artifactNotFound(Self.chunksDirectoryName)
    }
    return chunks
  }

  private func isReservedProcessingPath(_ relative: String) -> Bool {
    guard let firstComponent = relative.split(separator: "/").first else {
      return false
    }
    return firstComponent.caseInsensitiveCompare(Self.processingDirectoryName)
      == .orderedSame
  }

  private func validateTask(_ task: AudioProcessingTask) throws {
    guard !Self.isZeroUUID(task.id),
          !Self.isZeroUUID(task.sessionID),
          task.schemaVersion == AudioProcessingTask.currentSchemaVersion,
          !task.sourcePaths.isEmpty,
          task.sourcePaths.values.allSatisfy({
            URL(fileURLWithPath: $0).pathExtension.lowercased() == "m4a"
              && !isReservedProcessingPath($0)
          }),
          task.hasSafeSourcePaths else {
      throw AudioProcessingTaskStoreError.invalidTask
    }
  }

  private static func isZeroUUID(_ value: UUID) -> Bool {
    value.uuidString == "00000000-0000-0000-0000-000000000000"
  }

  private func persistHistoryUnlocked(
    _ task: AudioProcessingTask,
    in directory: URL,
    updatedAt: Date = Date()
  ) throws {
    let record = AudioProcessingHistoryRecord(
      task: task,
      rawTranscriptAvailable: isRegularFile(
        at: directory.appendingPathComponent(Self.rawTranscriptFileName, isDirectory: false)
      ),
      polishedTranscriptAvailable: isRegularFile(
        at: directory.appendingPathComponent(Self.polishedTranscriptFileName, isDirectory: false)
      ),
      structuredContentAvailable: isRegularFile(
        at: directory.appendingPathComponent(Self.structuredContentFileName, isDirectory: false)
      ),
      updatedAt: updatedAt
    )
    try atomicWriteUnlocked(
      record,
      to: directory.appendingPathComponent(Self.historyFileName, isDirectory: false),
      overwrite: true
    )
  }

  private func updateHistoryArtifactsUnlocked(in directory: URL) throws {
    let taskURL = directory.appendingPathComponent(Self.taskFileName, isDirectory: false)
    guard let task = try? decodeUnlocked(AudioProcessingTask.self, at: taskURL, missing: nil) else {
      return
    }
    try persistHistoryUnlocked(task, in: directory)
  }

  private func atomicWriteUnlocked<T: Encodable>(
    _ value: T,
    to target: URL,
    overwrite: Bool,
    existingError: AudioProcessingTaskStoreError? = nil
  ) throws {
    Self.atomicWriteLock.lock()
    defer { Self.atomicWriteLock.unlock() }
    guard isPhysicallyConfined(target),
          !hasSymlinkComponent(target) else {
      throw AudioProcessingTaskStoreError.unsafePath(target.lastPathComponent)
    }
    let directory = target.deletingLastPathComponent()
    try ensureDirectoryUnlocked(directory)
    if !overwrite && fileManager.fileExists(atPath: target.path) {
      throw existingError ?? .rawTranscriptAlreadyPersisted
    }

    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw AudioProcessingTaskStoreError.cannotPersist(target.lastPathComponent)
    }
    let temporary = directory.appendingPathComponent(
      ".\(target.lastPathComponent).\(UUID().uuidString).tmp",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: temporary) }
    do {
      try data.write(to: temporary, options: [.withoutOverwriting])
      guard isPhysicallyConfined(temporary), !hasSymlinkComponent(temporary) else {
        throw AudioProcessingTaskStoreError.unsafePath(target.lastPathComponent)
      }
      if overwrite && fileManager.fileExists(atPath: target.path) {
        guard !isSymbolicLink(at: target) else {
          throw AudioProcessingTaskStoreError.unsafePath(target.lastPathComponent)
        }
        _ = try fileManager.replaceItemAt(
          target,
          withItemAt: temporary,
          backupItemName: nil,
          options: [.usingNewMetadataOnly]
        )
      } else {
        do {
          try fileManager.moveItem(at: temporary, to: target)
        } catch {
          if !overwrite,
             fileManager.fileExists(atPath: target.path),
             let existingError {
            throw existingError
          }
          throw error
        }
      }
    } catch let error as AudioProcessingTaskStoreError {
      throw error
    } catch {
      throw AudioProcessingTaskStoreError.cannotPersist(target.lastPathComponent)
    }
  }

  private func decodeUnlocked<T: Decodable>(
    _ type: T.Type,
    at url: URL,
    missing: AudioProcessingTaskStoreError?
  ) throws -> T {
    guard isRegularFile(at: url), !hasSymlinkComponent(url) else {
      throw missing ?? .artifactNotFound(url.lastPathComponent)
    }
    do {
      return try decoder.decode(type, from: Data(contentsOf: url))
    } catch {
      throw AudioProcessingTaskStoreError.cannotPersist(url.lastPathComponent)
    }
  }

  private func ensureDirectoryUnlocked(_ directory: URL) throws {
    guard isPhysicallyConfined(directory) else {
      throw AudioProcessingTaskStoreError.unsafePath(directory.lastPathComponent)
    }
    if fileManager.fileExists(atPath: directory.path) {
      guard isDirectory(at: directory) else {
        throw AudioProcessingTaskStoreError.cannotCreateDirectory(directory.lastPathComponent)
      }
      return
    }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw AudioProcessingTaskStoreError.cannotCreateDirectory(directory.lastPathComponent)
    }
    guard isDirectory(at: directory), isPhysicallyConfined(directory) else {
      throw AudioProcessingTaskStoreError.unsafePath(directory.lastPathComponent)
    }
  }

  private func isPhysicallyConfined(_ target: URL) -> Bool {
    let root = allowedRoot.standardizedFileURL
    let candidate = target.standardizedFileURL
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
      return false
    }
    if fileManager.fileExists(atPath: root.path), isSymbolicLink(at: root) { return false }
    guard candidate.path != root.path else { return true }
    let relative = String(candidate.path.dropFirst(root.path.count + 1))
    var cursor = root
    for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
      cursor.appendPathComponent(String(component), isDirectory: false)
      if fileManager.fileExists(atPath: cursor.path), isSymbolicLink(at: cursor) { return false }
    }
    return true
  }

  private func hasSymlinkComponent(_ target: URL) -> Bool {
    let root = allowedRoot.standardizedFileURL
    guard isPhysicallyConfined(target) else { return true }
    let relative = String(target.standardizedFileURL.path.dropFirst(root.path.count))
    var cursor = root
    for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
      cursor.appendPathComponent(String(component), isDirectory: false)
      if isSymbolicLink(at: cursor) { return true }
    }
    return false
  }

  private func isSymbolicLink(at url: URL) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else { return false }
    return type == .typeSymbolicLink
  }

  private func isRegularFile(at url: URL) -> Bool {
    guard !isSymbolicLink(at: url),
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else { return false }
    return type == .typeRegular
  }

  private func isDirectory(at url: URL) -> Bool {
    guard !isSymbolicLink(at: url),
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else { return false }
    return type == .typeDirectory
  }

  private static func isAllowedTransition(
    from: AudioProcessingTaskStage,
    to: AudioProcessingTaskStage
  ) -> Bool {
    if from == to { return true }
    switch (from, to) {
    case (.saving, .transcribing), (.saving, .completed), (.saving, .failed), (.saving, .cancelled),
         (.transcribing, .polishing), (.transcribing, .completed), (.transcribing, .failed),
         (.transcribing, .cancelled),
         (.transcribing, .saving),
         (.polishing, .organizing), (.polishing, .saving), (.polishing, .completed),
         (.polishing, .failed), (.polishing, .waitingForModel),
         (.polishing, .cancelled),
         (.organizing, .saving), (.organizing, .polishing), (.organizing, .completed),
         (.organizing, .failed),
         (.organizing, .cancelled),
         (.waitingForModel, .polishing), (.waitingForModel, .organizing),
         (.waitingForModel, .saving),
         (.waitingForModel, .completed), (.waitingForModel, .failed),
         (.waitingForModel, .cancelled),
         (.cancelled, .saving),
         (.completed, .saving),
         (.failed, .saving), (.failed, .transcribing), (.failed, .polishing),
         (.failed, .organizing), (.failed, .cancelled):
      return true
    default:
      return false
    }
  }
}
