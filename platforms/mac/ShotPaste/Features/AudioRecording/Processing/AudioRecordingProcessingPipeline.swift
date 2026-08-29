//
//  AudioRecordingProcessingPipeline.swift
//  ShotPaste
//
//  Durable task-driven orchestration for raw transcription and local-derived
//  processing.  Source media remains untouched on every failure/cancellation.
//

import Foundation

nonisolated struct AudioProcessingOptions: Codable, Equatable, Sendable {
  let language: AudioRecordingLanguage
  let template: AudioOrganizationTemplate
  let autoTranscribe: Bool
  let autoAI: Bool

  init(
    language: AudioRecordingLanguage = .auto,
    template: AudioOrganizationTemplate = .transcriptOnly,
    autoTranscribe: Bool = true,
    autoAI: Bool = false
  ) {
    self.language = language
    self.template = template
    self.autoTranscribe = autoTranscribe
    self.autoAI = autoAI
  }
}

nonisolated struct AudioProcessingPipelineResult: Sendable {
  let task: AudioProcessingTask
  let rawTranscript: AudioRawTranscript?
  let polishedTranscript: AudioPolishedTranscript?
  let structuredContent: AudioStructuredContent?
}

nonisolated enum AudioRecordingProcessingPipelineError: LocalizedError, Equatable, Sendable {
  case noAudioSource
  case unsafeSourcePath
  case taskNotFound
  case cancelled
  case invalidRawTranscript

  var errorDescription: String? {
    switch self {
    case .noAudioSource: "No extracted local audio source is available."
    case .unsafeSourcePath: "An extracted audio source path is unsafe."
    case .taskNotFound: "The audio processing task was not found."
    case .cancelled: "Audio processing was cancelled."
    case .invalidRawTranscript: "The raw transcript failed local validation."
    }
  }
}

nonisolated protocol AudioTranscribing: Sendable {
  func transcribe(
    sources: [AudioTranscriptionSourceInput],
    language: AudioRecordingLanguage,
    processingDirectory: URL?,
    sessionID: UUID?
  ) async throws -> AudioRawTranscript
}

nonisolated protocol AudioLLMProcessing: Sendable {
  func process(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage?
  ) async throws -> AudioLLMProcessingResult

  func process(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage?,
    existingPolished: AudioPolishedTranscript?
  ) async throws -> AudioLLMProcessingResult
}

extension AudioLLMProcessing {
  /// Implementations that support durable polished checkpoints can override
  /// this overload to organize only.  A legacy provider may still use the
  /// three-argument entry point for a fresh run, but it must not silently
  /// polish a transcript again when recovery supplies a checkpoint.
  func process(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage?,
    existingPolished: AudioPolishedTranscript?
  ) async throws -> AudioLLMProcessingResult {
    guard existingPolished == nil else {
      throw AudioLocalLLMError.invalidOutput
    }
    return try await process(raw: raw, template: template, language: language)
  }
}

extension LocalAudioTranscriber: AudioTranscribing {}
extension LocalAudioLLMProcessor: AudioLLMProcessing {}

actor AudioProcessingTaskSingleFlight {
  private struct Waiter {
    let token: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var activeSessions = Set<UUID>()
  private var waiters: [UUID: [UUID: Waiter]] = [:]

  /// Test-only observability for deterministic single-flight boundary tests.
  /// The value is actor-isolated, so seeing a waiter means the caller has
  /// crossed the exclusive boundary and cannot run cleanup yet.
  func waiterCount(for sessionID: UUID) -> Int {
    waiters[sessionID]?.count ?? 0
  }

  func withExclusive<T: Sendable>(
    sessionID: UUID,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try Task.checkCancellation()
    while activeSessions.contains(sessionID) {
      let token = UUID()
      try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiters[sessionID, default: [:]][token] = Waiter(
              token: token,
              continuation: continuation
            )
          }
        }
      }, onCancel: {
        Task { await self.cancelWaiter(sessionID: sessionID, token: token) }
      })
    }
    try Task.checkCancellation()
    activeSessions.insert(sessionID)
    defer { release(sessionID: sessionID) }
    return try await operation()
  }

  private func cancelWaiter(sessionID: UUID, token: UUID) {
    guard var sessionWaiters = waiters[sessionID],
          let waiter = sessionWaiters.removeValue(forKey: token) else {
      return
    }
    if sessionWaiters.isEmpty {
      waiters.removeValue(forKey: sessionID)
    } else {
      waiters[sessionID] = sessionWaiters
    }
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func release(sessionID: UUID) {
    activeSessions.remove(sessionID)
    let pending: [Waiter]
    if let sessionWaiters = waiters.removeValue(forKey: sessionID) {
      pending = Array(sessionWaiters.values)
    } else {
      pending = []
    }
    pending.forEach { $0.continuation.resume() }
  }
}

/// The pipeline persists a task before doing recognition.  Recovery can scan
/// the task file and resume from the durable raw/derived artifact boundaries.
nonisolated final class AudioRecordingProcessingPipeline: @unchecked Sendable {
  static let singleFlight = AudioProcessingTaskSingleFlight()
  private let taskStore: AudioProcessingTaskStore
  private let transcriber: any AudioTranscribing
  private let llmProcessor: any AudioLLMProcessing
  private let adapterStore: AudioAdapterSessionStore?

  init(
    taskStore: AudioProcessingTaskStore = AudioProcessingTaskStore(),
    transcriber: any AudioTranscribing = LocalAudioTranscriber(),
    llmProcessor: any AudioLLMProcessing = LocalAudioLLMProcessor(),
    adapterStore: AudioAdapterSessionStore? = nil
  ) {
    self.taskStore = taskStore
    self.transcriber = transcriber
    self.llmProcessor = llmProcessor
    self.adapterStore = adapterStore
  }

  /// Creates the durable task and returns its real UUID reference.  The
  /// optional session gate is explicit because an adapter session must already
  /// be in `awaitingTranscription` before its third gate can open.
  @discardableResult
  func persistTask(
    sessionID: UUID,
    sourcePaths: [AudioRecordingSource: String],
    options: AudioProcessingOptions,
    markSessionTranscriptionGate: Bool = false
  ) throws -> UUID {
    let task = AudioProcessingTask(
      sessionID: sessionID,
      language: options.language,
      template: options.template,
      autoTranscribe: options.autoTranscribe,
      autoAI: options.autoAI,
      sourcePaths: sourcePaths
    )
    let reference = try taskStore.persistTask(task)
    if markSessionTranscriptionGate, let adapterStore {
      _ = try adapterStore.markTranscriptionTaskPersisted(
        sessionID: sessionID,
        reference: reference
      )
    }
    return reference
  }

  /// Starts a new processing task from an existing adapter session.  Source
  /// paths are copied as relative metadata; the media itself is only opened by
  /// the transcriber after path resolution and confinement checks.
  func process(
    session: AudioAdapterSession,
    options: AudioProcessingOptions = AudioProcessingOptions()
  ) async throws -> AudioProcessingPipelineResult {
    let inputs = try sourceInputs(for: session)
    let allowedSourcePaths = Set(session.manifest.finalPaths.allValues)
    let sourcePaths = try validatedSourcePaths(
      sessionID: session.sessionID,
      inputs: inputs,
      allowedSourcePaths: allowedSourcePaths
    )
    let task = AudioProcessingTask(
      sessionID: session.sessionID,
      language: options.language,
      template: options.template,
      autoTranscribe: options.autoTranscribe,
      autoAI: options.autoAI,
      sourcePaths: sourcePaths
    )
    _ = try taskStore.persistTask(task)
    return try await run(
      task: task,
      inputs: inputs,
      allowedSourcePaths: allowedSourcePaths
    )
  }

  /// A lower-level entry point used by recovery and tests that already have
  /// confined source URLs.
  func process(
    sessionID: UUID,
    sourceInputs: [AudioTranscriptionSourceInput],
    options: AudioProcessingOptions = AudioProcessingOptions()
  ) async throws -> AudioProcessingPipelineResult {
    guard !sourceInputs.isEmpty else {
      throw AudioRecordingProcessingPipelineError.noAudioSource
    }
    let sourcePaths = try validatedSourcePaths(sessionID: sessionID, inputs: sourceInputs)
    let task = AudioProcessingTask(
      sessionID: sessionID,
      language: options.language,
      template: options.template,
      autoTranscribe: options.autoTranscribe,
      autoAI: options.autoAI,
      sourcePaths: sourcePaths
    )
    _ = try taskStore.persistTask(task)
    return try await run(task: task, inputs: sourceInputs)
  }

  /// Resumes an existing task after relaunch.  Existing raw/derived artifacts
  /// are reused, so an immutable raw transcript is never re-written.
  func resume(
    sessionID: UUID,
    sourceInputs: [AudioTranscriptionSourceInput]
  ) async throws -> AudioProcessingPipelineResult {
    let task = try taskStore.loadTask(sessionID: sessionID)
    return try await run(
      task: task,
      inputs: sourceInputs,
      allowedSourcePaths: Set(task.sourcePaths.values)
    )
  }

  /// Resets only task metadata and resumes.  Source M4A/MOV files are never
  /// removed, even when the prior task failed.
  func restart(
    sessionID: UUID,
    sourceInputs: [AudioTranscriptionSourceInput]
  ) async throws -> AudioProcessingPipelineResult {
    let reset = try taskStore.updateTask(sessionID: sessionID) { task in
      task.stage = .saving
      task.cancellationRequested = false
      task.errorCode = nil
      task.errorMessage = nil
      task.progress = AudioProcessingTaskProgress()
    }
    return try await run(
      task: reset,
      inputs: sourceInputs,
      allowedSourcePaths: Set(reset.sourcePaths.values)
    )
  }

  /// Cancellation is persisted and observed between bounded export/recognition
  /// operations.  It does not delete any source or derived artifact.
  func cancel(sessionID: UUID) throws {
    _ = try taskStore.requestCancellation(sessionID: sessionID)
  }

  func recoverableTasks() -> [AudioProcessingTask] {
    taskStore.scanUnfinishedTasks()
  }

  // MARK: - Pipeline state machine

  private func run(
    task initialTask: AudioProcessingTask,
    inputs: [AudioTranscriptionSourceInput],
    allowedSourcePaths: Set<String>? = nil
  ) async throws -> AudioProcessingPipelineResult {
    try await Self.singleFlight.withExclusive(sessionID: initialTask.sessionID) {
      // Cleanup belongs to the owner operation.  The source paths are passed
      // through as protected paths so a malformed/reserved input can never be
      // deleted before runExclusive rejects it.
      try self.taskStore.removeTemporaryChunks(
        sessionID: initialTask.sessionID,
        preservingSourceURLs: inputs.map(\.url)
      )
      return try await self.runExclusive(
        task: initialTask,
        inputs: inputs,
        allowedSourcePaths: allowedSourcePaths
      )
    }
  }

  private func runExclusive(
    task initialTask: AudioProcessingTask,
    inputs: [AudioTranscriptionSourceInput],
    allowedSourcePaths: Set<String>? = nil
  ) async throws -> AudioProcessingPipelineResult {
    var task = initialTask
    do {
      if task.stage == .cancelled {
        throw AudioRecordingProcessingPipelineError.cancelled
      }
      try checkCancellation(task)
      guard task.hasSafeSourcePaths else {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }
      guard !inputs.isEmpty else {
        throw AudioRecordingProcessingPipelineError.noAudioSource
      }
      guard inputs.allSatisfy({
        guard let duration = $0.durationSeconds else { return true }
        return duration.isFinite && duration > 0
      }) else {
        throw AudioRecordingProcessingPipelineError.noAudioSource
      }
      let inputPaths = try validatedSourcePaths(
        sessionID: task.sessionID,
        inputs: inputs,
        allowedSourcePaths: allowedSourcePaths
      )
      guard inputPaths == task.sourcePaths else {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }

      if task.stage == .completed {
        let completedRaw = try? taskStore.loadRawTranscript(sessionID: task.sessionID)
        let completedPolished = try? taskStore.loadPolishedTranscript(sessionID: task.sessionID)
        let completedStructured = try? taskStore.loadStructuredContent(sessionID: task.sessionID)
        if let completedRaw,
           completedRaw.hasValidStructure,
           !task.autoAI || hasCompleteDerived(
             polished: completedPolished,
             structured: completedStructured,
             template: task.template,
             raw: completedRaw
           ) {
          return AudioProcessingPipelineResult(
            task: task,
            rawTranscript: completedRaw,
            polishedTranscript: completedPolished,
            structuredContent: completedStructured
          )
        }
        if !task.autoTranscribe && !task.autoAI && completedRaw == nil {
          return AudioProcessingPipelineResult(
            task: task,
            rawTranscript: nil,
            polishedTranscript: completedPolished,
            structuredContent: completedStructured
          )
        }
        task = try taskStore.transition(sessionID: task.sessionID, to: .saving)
      }
      if task.stage == .failed {
        task = try taskStore.transition(sessionID: task.sessionID, to: .saving)
      }

      var raw: AudioRawTranscript?
      if let persisted = try? taskStore.loadRawTranscript(sessionID: task.sessionID) {
        guard persisted.hasValidStructure else {
          throw AudioRecordingProcessingPipelineError.invalidRawTranscript
        }
        raw = persisted
      }

      if task.autoTranscribe, raw == nil {
        if task.stage != .saving && task.stage != .transcribing {
          task = try taskStore.transition(sessionID: task.sessionID, to: .saving)
        }
        if task.stage == .saving || task.stage == .waitingForModel {
          task = try taskStore.transition(sessionID: task.sessionID, to: .transcribing)
        }
        try checkCancellation(task)
        let processingDirectory = try taskStore.processingDirectoryURL(for: task.sessionID)
        let transcript = try await transcriber.transcribe(
          sources: inputs,
          language: task.language,
          processingDirectory: processingDirectory,
          sessionID: task.sessionID
        )
        guard transcript.hasValidStructure else {
          throw AudioRecordingProcessingPipelineError.invalidRawTranscript
        }
        do {
          try taskStore.persistRawTranscript(transcript, sessionID: task.sessionID)
        } catch AudioProcessingTaskStoreError.rawTranscriptAlreadyPersisted {
          // A concurrent/recovery writer won the immutable raw boundary.  The
          // next load is the only value used downstream.
        }
        raw = try taskStore.loadRawTranscript(sessionID: task.sessionID)
      }

      guard let raw else {
        guard !task.autoTranscribe && !task.autoAI else {
          throw AudioRecordingProcessingPipelineError.noAudioSource
        }
        task = try taskStore.transition(sessionID: task.sessionID, to: .completed)
        return AudioProcessingPipelineResult(task: task, rawTranscript: nil, polishedTranscript: nil, structuredContent: nil)
      }

      try checkCancellation(task)
      guard task.autoAI else {
        if task.stage != .completed {
          task = try taskStore.transition(sessionID: task.sessionID, to: .completed)
        }
        return AudioProcessingPipelineResult(
          task: task,
          rawTranscript: raw,
          polishedTranscript: try? taskStore.loadPolishedTranscript(sessionID: task.sessionID),
          structuredContent: try? taskStore.loadStructuredContent(sessionID: task.sessionID)
        )
      }

      let persistedPolished = try? taskStore.loadPolishedTranscript(sessionID: task.sessionID)
      let persistedStructured = try? taskStore.loadStructuredContent(sessionID: task.sessionID)
      if hasCompleteDerived(
        polished: persistedPolished,
        structured: persistedStructured,
        template: task.template,
        raw: raw
      ) {
        if task.stage != .completed {
          task = try taskStore.transition(sessionID: task.sessionID, to: .completed)
        }
        return AudioProcessingPipelineResult(
          task: task,
          rawTranscript: raw,
          polishedTranscript: persistedPolished,
          structuredContent: persistedStructured
        )
      }

      // A crash can leave raw and polished artifacts while the task metadata
      // is still at its initial saving stage.  Walk through the persisted
      // state machine before organizing so the partial checkpoint is a valid
      // recovery path rather than an invalid saving -> polishing transition.
      if task.stage == .saving {
        task = try taskStore.transition(sessionID: task.sessionID, to: .transcribing)
      }
      if task.stage == .transcribing
        || task.stage == .waitingForModel || task.stage == .organizing {
        task = try taskStore.transition(sessionID: task.sessionID, to: .polishing)
      }
      try checkCancellation(task)

      let derived: AudioLLMProcessingResult
      do {
        derived = try await llmProcessor.process(
          raw: raw,
          template: task.template,
          language: task.language,
          existingPolished: persistedPolished
        )
      } catch let error as AudioLocalLLMError {
        if case .modelUnavailable = error {
          task = try taskStore.transition(sessionID: task.sessionID, to: .waitingForModel)
          return AudioProcessingPipelineResult(
            task: task,
            rawTranscript: raw,
            polishedTranscript: try? taskStore.loadPolishedTranscript(sessionID: task.sessionID),
            structuredContent: try? taskStore.loadStructuredContent(sessionID: task.sessionID)
          )
        }
        throw error
      }

      try checkCancellation(task)
      task = try taskStore.transition(sessionID: task.sessionID, to: .organizing)
      guard derived.structured.hasValidReferences(in: raw) else {
        throw AudioRecordingProcessingPipelineError.invalidRawTranscript
      }
      try taskStore.persistPolishedTranscript(derived.polished, sessionID: task.sessionID)
      try taskStore.persistStructuredContent(derived.structured, sessionID: task.sessionID)
      task = try taskStore.transition(sessionID: task.sessionID, to: .completed)
      return AudioProcessingPipelineResult(
        task: task,
        rawTranscript: raw,
        polishedTranscript: derived.polished,
        structuredContent: derived.structured
      )
    } catch is CancellationError {
      return try await failOrCancel(task: task, code: "cancelled", message: "cancelled", cancelled: true)
    } catch let error as AudioTranscriberError where error == .cancelled {
      return try await failOrCancel(task: task, code: "cancelled", message: "cancelled", cancelled: true)
    } catch let error as AudioLocalLLMError where error == .cancelled {
      return try await failOrCancel(task: task, code: "cancelled", message: "cancelled", cancelled: true)
    } catch let error as AudioRecordingProcessingPipelineError where error == .cancelled {
      return try await failOrCancel(task: task, code: "cancelled", message: "cancelled", cancelled: true)
    } catch {
      _ = try? taskStore.markFailed(
        sessionID: task.sessionID,
        code: errorCode(for: error),
        message: errorMessage(for: error)
      )
      throw error
    }
  }

  private func failOrCancel(
    task: AudioProcessingTask,
    code: String,
    message: String,
    cancelled: Bool
  ) async throws -> AudioProcessingPipelineResult {
    var current = task
    if cancelled {
      current = (try? taskStore.transition(sessionID: task.sessionID, to: .cancelled)) ?? task
    } else {
      current = (try? taskStore.markFailed(sessionID: task.sessionID, code: code, message: message)) ?? task
    }
    return AudioProcessingPipelineResult(
      task: current,
      rawTranscript: try? taskStore.loadRawTranscript(sessionID: task.sessionID),
      polishedTranscript: try? taskStore.loadPolishedTranscript(sessionID: task.sessionID),
      structuredContent: try? taskStore.loadStructuredContent(sessionID: task.sessionID)
    )
  }

  private func checkCancellation(_ task: AudioProcessingTask) throws {
    if Task.isCancelled || (try? taskStore.loadTask(sessionID: task.sessionID).cancellationRequested) == true {
      throw AudioRecordingProcessingPipelineError.cancelled
    }
  }

  private func validatedSourcePaths(
    sessionID: UUID,
    inputs: [AudioTranscriptionSourceInput],
    allowedSourcePaths: Set<String>? = nil
  ) throws -> [AudioRecordingSource: String] {
    guard !inputs.isEmpty,
          Set(inputs.map(\.source)).count == inputs.count else {
      throw AudioRecordingProcessingPipelineError.noAudioSource
    }
    var paths: [AudioRecordingSource: String] = [:]
    for input in inputs {
      do {
        paths[input.source] = try taskStore.confinedSourcePath(
          for: input.url,
          sessionID: sessionID,
          allowedRelativePaths: allowedSourcePaths
        )
      } catch {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }
    }
    return paths
  }

  private func hasCompleteDerived(
    polished: AudioPolishedTranscript?,
    structured: AudioStructuredContent?,
    template: AudioOrganizationTemplate,
    raw: AudioRawTranscript
  ) -> Bool {
    guard let polished,
          !polished.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !polished.sourceSegmentIDs.isEmpty,
          Set(polished.sourceSegmentIDs).count == polished.sourceSegmentIDs.count,
          Set(polished.sourceSegmentIDs) == raw.segmentIDs else {
      return false
    }
    if template == .transcriptOnly {
      return true
    }
    guard let structured else { return false }
    return structured.template == template
      && structured.transcriptSegmentIDs.count == raw.segmentIDs.count
      && Set(structured.transcriptSegmentIDs) == raw.segmentIDs
      && structured.hasValidReferences(in: raw)
  }

  private func sourceInputs(for session: AudioAdapterSession) throws -> [AudioTranscriptionSourceInput] {
    var result: [AudioTranscriptionSourceInput] = []
    let finalPaths = session.manifest.finalPaths
    if let system = finalPaths.system {
      guard AudioAdapterSessionManifest.isFinalRelativePath(system) else {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }
      result.append(AudioTranscriptionSourceInput(source: .system, url: try session.url(for: system)))
    }
    if let microphone = finalPaths.microphone {
      guard AudioAdapterSessionManifest.isFinalRelativePath(microphone) else {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }
      result.append(AudioTranscriptionSourceInput(source: .microphone, url: try session.url(for: microphone)))
    }
    if result.isEmpty, let mixed = finalPaths.mixed {
      guard AudioAdapterSessionManifest.isFinalRelativePath(mixed) else {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }
      result.append(AudioTranscriptionSourceInput(source: .mixed, url: try session.url(for: mixed)))
    }
    guard !result.isEmpty else { throw AudioRecordingProcessingPipelineError.noAudioSource }
    return result
  }

  private func errorCode(for error: Error) -> String {
    switch error {
    case is AudioTranscriberError: "transcription_failed"
    case is AudioLocalLLMError: "model_processing_failed"
    case is AudioProcessingTaskStoreError: "persistence_failed"
    default: "processing_failed"
    }
  }

  private func errorMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return "processing_failed"
  }
}
