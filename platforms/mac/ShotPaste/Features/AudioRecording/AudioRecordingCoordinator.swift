//
//  AudioRecordingCoordinator.swift
//  ShotPaste
//
//  Product-level owner for audio recording. This lifecycle is intentionally
//  independent from OneShotCoordinator and RecordingCoordinator: the tiny
//  screen stream is only an internal audio clock/carrier and never becomes a
//  user-facing video selection or recording session.
//

import AppKit
import Combine
import Foundation

nonisolated enum AudioRecordingCoordinatorState: String, CaseIterable, Equatable, Sendable {
  case idle
  case presenting
  case preparing
  case recording
  case paused
  case saving
  case transcribing
  case polishing
  case organizing
  case completed
  case recoverable
  case failed

  var isCaptureActive: Bool {
    switch self {
    case .presenting, .preparing, .recording, .paused, .saving:
      true
    default:
      false
    }
  }

  var isProcessing: Bool {
    switch self {
    case .transcribing, .polishing, .organizing:
      true
    default:
      false
    }
  }
}

typealias AudioRecordingState = AudioRecordingCoordinatorState

nonisolated enum AudioRecordingTransactionStep: Equatable, Sendable {
  case extract
  case history
  case transcriptionTask
  case deleteInternalVideo
  case complete
}

/// Pure transaction policy used by the Coordinator and focused tests. A
/// missing earlier gate can never be skipped by a later side effect.
nonisolated enum AudioRecordingTransactionGatePolicy {
  static func nextStep(
    finalAudioValidated: Bool,
    historyPersisted: Bool,
    transcriptionTaskPersisted: Bool
  ) -> AudioRecordingTransactionStep {
    if !finalAudioValidated { return .extract }
    if !historyPersisted { return .history }
    if !transcriptionTaskPersisted { return .transcriptionTask }
    return .deleteInternalVideo
  }

  static func canDelete(
    finalAudioValidated: Bool,
    historyPersisted: Bool,
    transcriptionTaskPersisted: Bool
  ) -> Bool {
    finalAudioValidated && historyPersisted && transcriptionTaskPersisted
  }
}

nonisolated enum AudioRecordingSaveToastNotice: Equatable, Sendable {
  case saved
  case endedEarlySaved
  case savedWithoutMicrophone
  case savedWithoutSystemAudio
}

/// Computes the success notice from actual captured roles, never from the
/// requested toggle state alone.  An effective empty set is not a successful
/// save and is therefore represented by the normal fallback only for callers
/// that have already passed extraction's non-empty-role gate.
nonisolated enum AudioRecordingSaveToastPolicy {
  static func notice(
    requestedRoles: [AudioAdapterTrackRole],
    effectiveRoles: [AudioAdapterTrackRole],
    endedEarly: Bool
  ) -> AudioRecordingSaveToastNotice {
    let missing = Set(requestedRoles).subtracting(Set(effectiveRoles))
    if missing.contains(.microphone) {
      return .savedWithoutMicrophone
    }
    if missing.contains(.system) {
      return .savedWithoutSystemAudio
    }
    return endedEarly ? .endedEarlySaved : .saved
  }
}

/// Automatic display recovery is deliberately bounded. A second display
/// churn event stops and preserves the current session instead of repeatedly
/// cycling ScreenCaptureKit streams in the background.
nonisolated enum AudioRecordingDisplayRecoveryPolicy {
  static let maximumAutomaticRecoveries = 1
  static let timeout: TimeInterval = 3

  static func shouldAttempt(recoveryCount: Int) -> Bool {
    recoveryCount < maximumAutomaticRecoveries
  }
}

nonisolated enum AudioRecordingStreamFailurePolicy {
  static func shouldDeferUntilStartReturns(
    state: AudioRecordingCoordinatorState,
    event: RecordingStreamFailureEvent
  ) -> Bool {
    state == .preparing
      && event.purpose == .audioAdapter
      && event.wasAdapterStartClaimed
  }

  static func shouldQueueStop(
    state: AudioRecordingCoordinatorState,
    event: RecordingStreamFailureEvent
  ) -> Bool {
    (state == .recording || state == .paused)
      && event.purpose == .audioAdapter
      && event.wasAdapterStartClaimed
  }
}

private final class AudioDisplayRecoveryGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<AudioAdapterSession, Error>?
  private var pendingError: Error?
  private var finished = false

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  func install(_ continuation: CheckedContinuation<AudioAdapterSession, Error>) {
    lock.lock()
    if finished {
      let error = pendingError ?? CancellationError()
      lock.unlock()
      continuation.resume(throwing: error)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func succeed(_ value: AudioAdapterSession) {
    finish { continuation in
      continuation.resume(returning: value)
    }
  }

  func fail(_ error: Error) {
    lock.lock()
    pendingError = error
    lock.unlock()
    finish { continuation in
      continuation.resume(throwing: error)
    }
  }

  private func finish(_ resume: (CheckedContinuation<AudioAdapterSession, Error>) -> Void) {
    lock.lock()
    guard !finished else { lock.unlock(); return }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    if let continuation { resume(continuation) }
  }
}

@MainActor
protocol AudioRecordingPostCaptureHandling: AnyObject {
  func handleAudioCapture(
    url: URL,
    skipQuickAccess: Bool
  ) async
    -> AudioCapturePostProcessingResult
}

@MainActor
private protocol AudioRecordingPreferredPostCaptureHandling: AnyObject {
  func handleAudioCapture(
    url: URL,
    skipQuickAccess: Bool,
    preferredHistoryID: UUID?
  ) async -> AudioCapturePostProcessingResult
}

extension AudioRecordingPostCaptureHandling {
  func handleAudioCapture(
    url: URL,
    skipQuickAccess: Bool,
    preferredHistoryID: UUID? = nil
  ) async -> AudioCapturePostProcessingResult {
    if let preferred = self as? any AudioRecordingPreferredPostCaptureHandling {
      return await preferred.handleAudioCapture(
        url: url,
        skipQuickAccess: skipQuickAccess,
        preferredHistoryID: preferredHistoryID
      )
    }
    return await handleAudioCapture(url: url, skipQuickAccess: skipQuickAccess)
  }
}

@MainActor
extension PostCaptureActionHandler: AudioRecordingPostCaptureHandling {}

@MainActor
extension PostCaptureActionHandler: AudioRecordingPreferredPostCaptureHandling {}

nonisolated enum AudioRecordingCoordinatorError: LocalizedError, Equatable, Sendable {
  case noSession
  case noCaptureOutput
  case historyNotPersisted
  case transcriptionTaskNotPersisted
  case deletionGateClosed
  case displayRecoveryTimedOut
  case processingFailed

  var errorDescription: String? {
    switch self {
    case .noSession: "Audio recording session is unavailable."
    case .noCaptureOutput: "Audio recording did not produce a capture output."
    case .historyNotPersisted: "Audio history was not persisted."
    case .transcriptionTaskNotPersisted: "Audio processing task was not persisted."
    case .deletionGateClosed: "Audio internal-video deletion gate is closed."
    case .displayRecoveryTimedOut: "Audio display recovery timed out."
    case .processingFailed: "Audio processing failed."
    }
  }
}

@MainActor
final class AudioRecordingCoordinator: ObservableObject {
  static let shared = AudioRecordingCoordinator()

  @Published private(set) var state: AudioRecordingCoordinatorState = .idle
  @Published private(set) var elapsedSeconds = 0
  @Published private(set) var configuration: AudioRecordingConfiguration
  @Published private(set) var sessionID: UUID?
  @Published private(set) var lastError: String?
  @Published private(set) var isWaitingForModel = false

  private let adapter: TinyRegionRecordingAdapter
  private let sessionStore: AudioAdapterSessionStore
  private let extractionPipeline: AudioExtractionPipeline
  private let postCapture: any AudioRecordingPostCaptureHandling
  private let processingStore: AudioProcessingTaskStore
  private let processingPipeline: AudioRecordingProcessingPipeline
  private let recoveryService: AudioRecordingRecoveryService
  private let historyProcessingStatusStore: AudioHistoryProcessingStatusStore
  private let recorder: ScreenRecordingManager
  private var cancellables = Set<AnyCancellable>()
  private var preparationPanel: AudioRecordingPreparationPanel?
  private var controlBar: AudioRecordingControlBarWindow?
  private var preparationTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var processingTask: Task<Void, Never>?
  private var displayRecoveryTask: Task<Void, Never>?
  private var displayRecoveryCount = 0
  private var endedEarly = false
  private var pendingStreamFailure = false
  private var streamFailureStopScheduled = false
  private var recoveryInFlight = false
  private var processingGeneration = UUID()
  private var sessionOperationGeneration: UInt64 = 0
  private var sessionOperation: SessionOperation = .idle

  private enum SessionOperation: Equatable {
    case idle
    case displayRecovery(UInt64)
    case stopping(UInt64)
  }

  init(
    adapter: TinyRegionRecordingAdapter? = nil,
    sessionStore: AudioAdapterSessionStore = AudioAdapterSessionStore(),
    extractionPipeline: AudioExtractionPipeline? = nil,
    postCapture: any AudioRecordingPostCaptureHandling = PostCaptureActionHandler.shared,
    processingStore: AudioProcessingTaskStore? = nil,
    processingPipeline: AudioRecordingProcessingPipeline? = nil,
    recoveryService: AudioRecordingRecoveryService? = nil,
    historyProcessingStatusStore: AudioHistoryProcessingStatusStore = .shared,
    transcriber: LocalAudioTranscriber = LocalAudioTranscriber(),
    llmProcessor: LocalAudioLLMProcessor = LocalAudioLLMProcessor(),
    recorder: ScreenRecordingManager = .shared
  ) {
    self.sessionStore = sessionStore
    let resolvedPipeline = extractionPipeline
      ?? AudioExtractionPipeline(store: sessionStore)
    self.extractionPipeline = resolvedPipeline
    self.adapter = adapter ?? TinyRegionRecordingAdapter(store: sessionStore)
    self.postCapture = postCapture
    let resolvedProcessingStore = processingStore
      ?? AudioProcessingTaskStore(
        sessionsDirectory: sessionStore.sessionsDirectory,
        allowedRoot: sessionStore.allowedRoot
      )
    self.processingStore = resolvedProcessingStore
    self.historyProcessingStatusStore = historyProcessingStatusStore
    self.processingPipeline = processingPipeline
      ?? AudioRecordingProcessingPipeline(
        taskStore: resolvedProcessingStore,
        transcriber: transcriber,
        llmProcessor: llmProcessor,
        adapterStore: sessionStore
      )
    self.recoveryService = recoveryService
      ?? AudioRecordingRecoveryService(
        store: sessionStore,
        pipeline: resolvedPipeline
      )
    self.recorder = recorder
    self.configuration = AudioRecordingPreferences.configuration()

    recorder.$elapsedSeconds
      .receive(on: RunLoop.main)
      .sink { [weak self] seconds in
        guard let self, self.state.isCaptureActive else { return }
        self.elapsedSeconds = seconds
      }
      .store(in: &cancellables)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(streamDidFail(_:)),
      name: .recordingStreamDidFail,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenParametersDidChange(_:)),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  var isActive: Bool { state != .idle }

  var isBlockingOtherCapture: Bool {
    state.isCaptureActive || state.isProcessing
  }

  var isRecording: Bool {
    state == .recording || state == .paused
  }

  var hasProcessingStatus: Bool {
    isWaitingForModel || state == .saving || state.isProcessing || sessionID != nil && lastError != nil
  }

  var canRetryProcessing: Bool {
    guard let sessionID, !isRecording, processingTask == nil else { return false }
    guard let task = try? processingStore.loadTask(sessionID: sessionID) else { return false }
    return task.stage.isRecoverable
  }

  var canRetrySave: Bool {
    guard state == .recoverable, let sessionID else { return false }
    guard let session = try? sessionStore.load(sessionID: sessionID) else { return false }
    return !session.manifest.canDeleteInternalVideo
      && (session.manifest.stage.isRecoveryCandidate || session.manifest.stage == .completed)
  }

  var processingStatusLabel: String {
    if isWaitingForModel { return L10n.AudioRecording.modelUnavailable }
    if lastError != nil { return L10n.AudioRecording.failedTitle }
    switch state {
    case .saving: return L10n.AudioRecording.saving
    case .transcribing: return L10n.AudioRecording.transcribing
    case .polishing: return L10n.AudioRecording.polishing
    case .organizing: return L10n.AudioRecording.organizingInterviewQA
    case .recoverable, .failed: return L10n.AudioRecording.failedTitle
    default: return L10n.AudioRecording.recording
    }
  }

  var formattedElapsed: String {
    let mins = elapsedSeconds / 60
    let secs = elapsedSeconds % 60
    return String(format: "%02d:%02d", mins, secs)
  }

  /// Opens the only audio preparation entry point. It does not activate the
  /// app, hide windows, freeze a screen, or create an area selection.
  func showPreparation() {
    guard canBeginCapture else {
      DiagnosticLogger.shared.log(
        .debug,
        .recording,
        "Audio preparation ignored because another capture is active"
      )
      return
    }

    configuration = AudioRecordingPreferences.configuration()
    state = .presenting
    let panel = preparationPanel ?? AudioRecordingPreparationPanel(configuration: configuration)
    preparationPanel = panel
    panel.onStart = { [weak self] configuration in
      self?.begin(configuration: configuration)
    }
    panel.onCancel = { [weak self] in
      self?.cancelPreparation()
    }
    panel.setConfiguration(configuration)
    panel.showWithoutActivating()
  }

  func begin(configuration: AudioRecordingConfiguration) {
    let normalized = configuration.normalized
    guard state == .presenting || state == .idle, canStartConfiguredCapture else { return }
    guard normalized.hasAudioSource else {
      lastError = L10n.AudioRecording.unableToStart
      state = .failed
      return
    }
    AudioRecordingPreferences.save(normalized)
    self.configuration = normalized
    preparationPanel?.showPreparingWithoutActivating()
    state = .preparing
    lastError = nil
    isWaitingForModel = false
    endedEarly = false
    pendingStreamFailure = false
    streamFailureStopScheduled = false
    displayRecoveryCount = 0
    preparationTask?.cancel()
    preparationTask = Task { @MainActor [weak self] in
      await self?.prepareAndStart(configuration: normalized)
    }
  }

  func cancelPreparation() {
    guard state == .presenting || state == .preparing else { return }
    let wasPreparing = state == .preparing
    preparationTask?.cancel()
    preparationTask = nil
    preparationPanel?.orderOut(nil)
    if wasPreparing {
      Task { @MainActor [weak self] in
        guard let self else { return }
        try? await self.adapter.cancel()
        self.state = .idle
      }
    } else {
      state = .idle
    }
  }

  func pauseOrResume() {
    guard state == .recording || state == .paused else { return }
    do {
      if state == .recording {
        try adapter.pause()
        state = .paused
      } else {
        try adapter.resume()
        state = .recording
      }
    } catch {
      failCapture(error)
    }
  }

  func stop() {
    guard state.isCaptureActive, state != .presenting, state != .preparing else {
      cancelPreparation()
      return
    }
    guard stopTask == nil else { return }
    sessionOperationGeneration &+= 1
    let generation = sessionOperationGeneration
    sessionOperation = .stopping(generation)
    state = .saving
    stopTask = Task { @MainActor [weak self] in
      await self?.stopAndPersist()
    }
  }

  func restart() {
    guard isRecording else { return }
    guard confirm(
      title: L10n.AudioRecording.restartConfirmTitle,
      message: L10n.AudioRecording.restartConfirmMessage,
      action: L10n.AudioRecording.restart
    ) else { return }
    endedEarly = false
    stopTask?.cancel()
    stopTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await self.adapter.cancel()
      self.controlBar?.orderOut(nil)
      self.state = .idle
      self.showPreparation()
    }
  }

  func delete() {
    guard state.isCaptureActive else { return }
    guard confirm(
      title: L10n.AudioRecording.deleteConfirmTitle,
      message: L10n.AudioRecording.deleteConfirmMessage,
      action: L10n.AudioRecording.delete
    ) else { return }
    stopTask?.cancel()
    stopTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await self.adapter.cancel()
      self.closeCaptureUI()
      self.state = .idle
    }
  }

  /// Retry is intentionally separate from ordinary Start so recovery can
  /// preserve the failed session's manifest and never expose its MOV path.
  func retrySave() {
    guard state == .recoverable, let sessionID else { return }
    state = .saving
    stopTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let current = try self.sessionStore.load(sessionID: sessionID)
        if current.manifest.finalAudioValidated,
           current.manifest.historyPersisted,
           current.manifest.transcriptionTaskPersisted {
          try await self.sessionStore.deleteInternalVideo(sessionID: sessionID)
          if let task = try? self.processingStore.loadTask(sessionID: sessionID) {
            self.historyProcessingStatusStore.update(
              sessionID: sessionID,
              taskID: task.id,
              stage: AudioProcessingTaskStage.completed.rawValue
            )
          }
          self.state = .completed
        } else {
          let action = await self.recoveryService.recover(sessionID: sessionID)
          await self.handleRecoveryAction(action)
          let updated = try self.sessionStore.load(sessionID: sessionID)
          self.state = updated.manifest.historyPersisted
            && updated.manifest.transcriptionTaskPersisted ? .completed : .recoverable
        }
      } catch {
        self.lastError = error.localizedDescription
        self.state = .recoverable
      }
      self.stopTask = nil
    }
  }

  /// Called once during launch. Recovery actions intentionally do not surface
  /// an internal MOV; only valid final audio is handed into post-capture.
  func recoverOnLaunch() async {
    guard !recoveryInFlight else { return }
    recoveryInFlight = true
    defer { recoveryInFlight = false }
    let report = await recoveryService.recover()
    for action in report.actions {
      await handleRecoveryAction(action)
    }
    await resumeUnfinishedProcessingTasks()
  }

  // MARK: - Preparation and transaction

  private var canBeginCapture: Bool {
    state == .idle && canStartConfiguredCapture
  }

  private var canStartConfiguredCapture: Bool {
    !RecordingCoordinator.shared.isActive
      && !OneShotCoordinator.shared.isActive
      && !ScrollingCaptureCoordinator.shared.isActive
      && !InlineAreaAnnotateCoordinator.shared.isActive
      && !recorder.isActive
  }

  private func prepareAndStart(configuration: AudioRecordingConfiguration) async {
    do {
      let prepared = try await adapter.prepare(configuration: configuration.adapterConfiguration)
      let normalizedConfiguration = configuration.normalized
      _ = try sessionStore.update(sessionID: prepared.sessionID) { manifest in
        manifest.processingLanguage = normalizedConfiguration.primaryLanguage
        manifest.processingTemplate = normalizedConfiguration.template
        manifest.processingAutoTranscribe = normalizedConfiguration.automaticTranscription
        manifest.processingAutoAI = normalizedConfiguration.automaticAI
      }
      try await adapter.start()
      guard recorder.state == .recording else {
        throw AudioRecordingCoordinatorError.noCaptureOutput
      }
      preparationPanel?.orderOut(nil)
      state = .recording
      elapsedSeconds = recorder.elapsedSeconds
      showControlBar()
      if pendingStreamFailure {
        pendingStreamFailure = false
        endedEarly = true
        streamFailureStopScheduled = true
        stop()
        return
      }
      // Audio semantics begin only after Tiny adapter.start returned from its
      // first-frame handshake.
      SoundManager.play("Purr")
      DiagnosticLogger.shared.log(.info, .recording, "Audio recording started")
    } catch is CancellationError {
      try? await adapter.cancel()
      state = .idle
    } catch {
      lastError = error.localizedDescription
      state = adapter.session == nil ? .failed : .recoverable
      closeCaptureUI()
      await showFailureToast(L10n.AudioRecording.unableToStart)
      pendingStreamFailure = false
    }
    preparationTask = nil
  }

  private func stopAndPersist() async {
    defer {
      stopTask = nil
      streamFailureStopScheduled = false
      if case .stopping = sessionOperation { sessionOperation = .idle }
    }
    guard let activeSessionID = adapter.session?.sessionID ?? self.sessionID else {
      state = .failed
      lastError = AudioRecordingCoordinatorError.noSession.localizedDescription
      closeCaptureUI()
      return
    }
    let sessionID = activeSessionID
    self.sessionID = activeSessionID

    do {
      await cancelDisplayRecoveryForStop()
      if let current = try? sessionStore.load(sessionID: sessionID),
         current.manifest.stage != .recording,
         current.manifest.stage != .paused {
        try await stopAndPersistExistingSegments(sessionID: sessionID)
        return
      }
      guard let captureURL = try await adapter.stop(),
            FileManager.default.fileExists(atPath: captureURL.path) else {
        throw AudioRecordingCoordinatorError.noCaptureOutput
      }
      let extraction = try await extractionPipeline.extract(sessionID: sessionID)
      let inputBundle = try transcriptionInputBundle(
        for: sessionID,
        extraction: extraction
      )
      let postCaptureResult = await postCapture.handleAudioCapture(
        url: extraction.mixed.url,
        skipQuickAccess: false,
        preferredHistoryID: sessionID
      )
      guard postCaptureResult.historyPersisted,
            let historyRecordID = postCaptureResult.historyRecordID else {
        throw AudioRecordingCoordinatorError.historyNotPersisted
      }

      _ = try sessionStore.markHistoryPersisted(
        sessionID: sessionID,
        reference: historyRecordID
      )

      let normalizedConfiguration = configuration.normalized
      let task = AudioProcessingTask(
        sessionID: sessionID,
        language: normalizedConfiguration.primaryLanguage,
        template: normalizedConfiguration.template,
        autoTranscribe: normalizedConfiguration.automaticTranscription,
        autoAI: normalizedConfiguration.automaticAI,
        sourcePaths: inputBundle.sourcePaths
      )
      let taskID = try processingStore.persistTask(sessionID: sessionID, task: task)
      _ = try sessionStore.markTranscriptionTaskPersisted(
        sessionID: sessionID,
        reference: taskID
      )
      historyProcessingStatusStore.associate(
        historyRecordID: historyRecordID,
        sessionID: sessionID,
        taskID: taskID,
        stage: task.stage.rawValue
      )

      guard AudioRecordingTransactionGatePolicy.canDelete(
        finalAudioValidated: true,
        historyPersisted: true,
        transcriptionTaskPersisted: true
      ) else {
        throw AudioRecordingCoordinatorError.deletionGateClosed
      }
      try await sessionStore.deleteInternalVideo(sessionID: sessionID)
      closeCaptureUI()
      SoundManager.play("Glass")
      await showSuccessToast(successToastMessage(for: sessionID, endedEarly: endedEarly))

      if normalizedConfiguration.automaticTranscription {
        state = .transcribing
        startProcessing(
          taskID: taskID,
          sessionID: sessionID,
          sourceInputs: inputBundle.inputs
        )
      } else {
        historyProcessingStatusStore.update(
          sessionID: sessionID,
          taskID: taskID,
          stage: AudioProcessingTaskStage.completed.rawValue
        )
        state = .completed
        scheduleReturnToIdle()
      }
    } catch {
      lastError = error.localizedDescription
      state = .recoverable
      closeCaptureUI()
      await showFailureToast(L10n.AudioRecording.extractionRecoverable)
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Audio recording transaction retained recoverable session"
      )
    }
  }

  /// A timeout/cancel can leave the adapter at a failed extraction boundary
  /// after rolling back its newest unresolved placeholder. Save the completed
  /// prefix directly instead of calling Tiny.stop on an invalid stage.
  private func stopAndPersistExistingSegments(sessionID: UUID) async throws {
    let extraction = try await extractionPipeline.extract(sessionID: sessionID)
    let inputBundle = try transcriptionInputBundle(for: sessionID, extraction: extraction)
    let postCaptureResult = await postCapture.handleAudioCapture(
      url: extraction.mixed.url,
      skipQuickAccess: false,
      preferredHistoryID: sessionID
    )
    guard postCaptureResult.historyPersisted,
          let historyRecordID = postCaptureResult.historyRecordID else {
      throw AudioRecordingCoordinatorError.historyNotPersisted
    }
    _ = try sessionStore.markHistoryPersisted(sessionID: sessionID, reference: historyRecordID)
    let normalizedConfiguration = configuration.normalized
    let task = AudioProcessingTask(
      sessionID: sessionID,
      language: normalizedConfiguration.primaryLanguage,
      template: normalizedConfiguration.template,
      autoTranscribe: normalizedConfiguration.automaticTranscription,
      autoAI: normalizedConfiguration.automaticAI,
      sourcePaths: inputBundle.sourcePaths
    )
    let taskID = try processingStore.persistTask(sessionID: sessionID, task: task)
    _ = try sessionStore.markTranscriptionTaskPersisted(sessionID: sessionID, reference: taskID)
    historyProcessingStatusStore.associate(
      historyRecordID: historyRecordID,
      sessionID: sessionID,
      taskID: taskID,
      stage: task.stage.rawValue
    )
    try await sessionStore.deleteInternalVideo(sessionID: sessionID)
    closeCaptureUI()
    await showSuccessToast(successToastMessage(for: sessionID, endedEarly: endedEarly))
    state = normalizedConfiguration.automaticTranscription ? .transcribing : .completed
    if normalizedConfiguration.automaticTranscription {
      startProcessing(taskID: taskID, sessionID: sessionID, sourceInputs: inputBundle.inputs)
    } else {
      historyProcessingStatusStore.update(
        sessionID: sessionID,
        taskID: taskID,
        stage: AudioProcessingTaskStage.completed.rawValue
      )
      scheduleReturnToIdle()
    }
  }

  private func cancelDisplayRecoveryForStop() async {
    guard let recoveryTask = displayRecoveryTask else { return }
    recoveryTask.cancel()
    await adapter.abortDisplayRecovery()
    _ = await recoveryTask.value
    displayRecoveryTask = nil
    sessionOperation = .stopping(sessionOperationGeneration)
  }

  private struct TranscriptionInputBundle {
    let inputs: [AudioTranscriptionSourceInput]
    let sourcePaths: [AudioRecordingSource: String]
  }

  /// Builds the Pipeline inputs and persisted source map together. The two
  /// values intentionally cannot drift: dual-track extraction exposes only
  /// system+microphone, while every other shape uses the mixed output.
  private func transcriptionInputBundle(
    for sessionID: UUID,
    extraction: AudioAdapterExtractionResult
  ) throws -> TranscriptionInputBundle {
    let session = try sessionStore.load(sessionID: sessionID)
    if let system = extraction.system, let microphone = extraction.microphone {
      let inputs = [
        AudioTranscriptionSourceInput(
          source: .system,
          url: try session.url(for: system.relativePath),
          durationSeconds: system.durationSeconds
        ),
        AudioTranscriptionSourceInput(
          source: .microphone,
          url: try session.url(for: microphone.relativePath),
          durationSeconds: microphone.durationSeconds
        ),
      ]
      return TranscriptionInputBundle(
        inputs: inputs,
        sourcePaths: [.system: system.relativePath, .microphone: microphone.relativePath]
      )
    }
    return TranscriptionInputBundle(
      inputs: [AudioTranscriptionSourceInput(
        source: .mixed,
        url: try session.url(for: extraction.mixed.relativePath),
        durationSeconds: extraction.mixed.durationSeconds
      )],
      sourcePaths: [.mixed: extraction.mixed.relativePath]
    )
  }

  private func startProcessing(
    taskID: UUID,
    sessionID: UUID,
    sourceInputs: [AudioTranscriptionSourceInput]
  ) {
    let generation = UUID()
    processingGeneration = generation
    processingTask?.cancel()
    processingTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let monitor = Task { @MainActor [weak self] in
        await self?.observeProcessingState(sessionID: sessionID, generation: generation)
      }
      do {
        // The task was persisted and its session gate opened by the stop
        // transaction. Resume is therefore the correct pipeline entry: it
        // never creates a second task or rewrites an immutable raw transcript.
        let task = try self.processingStore.loadTask(sessionID: sessionID)
        let result: AudioProcessingPipelineResult
        if task.stage == .failed {
          result = try await self.processingPipeline.restart(
            sessionID: sessionID,
            sourceInputs: sourceInputs
          )
        } else {
          result = try await self.processingPipeline.resume(
            sessionID: sessionID,
            sourceInputs: sourceInputs
          )
        }
        monitor.cancel()
        guard self.processingGeneration == generation else { return }
        self.applyProcessingResult(result, generation: generation)
      } catch is CancellationError {
        monitor.cancel()
        return
      } catch AudioRecordingProcessingPipelineError.cancelled {
        monitor.cancel()
        return
      } catch {
        monitor.cancel()
        guard self.processingGeneration == generation else { return }
        self.lastError = error.localizedDescription
        self.state = .idle
        self.historyProcessingStatusStore.update(
          sessionID: sessionID,
          taskID: taskID,
          stage: AudioProcessingTaskStage.failed.rawValue
        )
      }
      if self.processingGeneration == generation { self.processingTask = nil }
    }
  }

  /// Reads only task stage/sidecar metadata. Transcript text and model input
  /// stay inside the processing pipeline; the Coordinator maps the durable
  /// stage to the small user-facing state machine.
  private func observeProcessingState(sessionID: UUID, generation: UUID) async {
    while !Task.isCancelled {
      guard processingGeneration == generation else { return }
      if let task = try? processingStore.loadTask(sessionID: sessionID) {
        guard processingGeneration == generation else { return }
        applyProcessingStage(task.stage)
        historyProcessingStatusStore.update(
          sessionID: sessionID,
          taskID: task.id,
          stage: task.stage.rawValue
        )
      }
      // Sidecar availability is intentionally read as metadata only; the
      // pipeline owns transcript/content decoding and persistence semantics.
      _ = try? processingStore.loadHistory(sessionID: sessionID)
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func applyProcessingStage(_ stage: AudioProcessingTaskStage) {
    switch stage {
    case .saving:
      state = .saving
    case .transcribing:
      isWaitingForModel = false
      state = .transcribing
    case .polishing:
      isWaitingForModel = false
      state = .polishing
    case .organizing:
      isWaitingForModel = false
      state = .organizing
    case .waitingForModel:
      isWaitingForModel = true
      // Waiting for a device model is a recoverable background condition, not
      // an active capture/processing lock. Keep the session/task identity for
      // retry, but allow a new capture immediately.
      state = .idle
    case .completed:
      isWaitingForModel = false
      state = .completed
    case .failed, .cancelled:
      isWaitingForModel = false
      state = .idle
    }
  }

  private func applyProcessingResult(
    _ result: AudioProcessingPipelineResult,
    generation: UUID? = nil
  ) {
    if let generation, processingGeneration != generation { return }
    applyProcessingStage(result.task.stage)
    historyProcessingStatusStore.update(
      sessionID: result.task.sessionID,
      taskID: result.task.id,
      stage: result.task.stage.rawValue
    )
    switch result.task.stage {
    case .completed:
      scheduleReturnToIdle()
    case .waitingForModel:
      Task { await showFailureToast(L10n.AudioRecording.modelUnavailable) }
    case .failed:
      lastError = AudioRecordingCoordinatorError.processingFailed.localizedDescription
    case .cancelled:
      // User cancellation is not a processing failure and must not overwrite
      // a newer run's state or surface a generic error.
      break
    default:
      break
    }
  }

  /// Persists cancellation in the task store and lets the pipeline observe it
  /// between bounded export/recognition operations. It never deletes source
  /// audio or the recoverable session manifest.
  func cancelProcessing() {
    guard let sessionID, state.isProcessing else { return }
    processingGeneration = UUID()
    try? processingPipeline.cancel(sessionID: sessionID)
    processingTask?.cancel()
    processingTask = nil
  }

  // MARK: - Recovery

  private func handleRecoveryAction(_ action: AudioRecordingRecoveryAction) async {
    switch action {
    case let .readyForHistory(sessionID, _):
      await completeRecoveryHistory(sessionID: sessionID)
    case let .readyForTranscription(sessionID, _):
      await completeRecoveryTranscription(sessionID: sessionID)
    case .retryExtraction, .damagedSession, .damagedDirectory, .ignoredSession:
      break
    }
  }

  /// Processing artifacts have their own recovery boundary. The adapter
  /// manifest may already be terminal because the task UUID gate is intended
  /// to protect MOV deletion, so launch recovery must scan Processing rather
  /// than rely only on the manifest stage.
  private func resumeUnfinishedProcessingTasks() async {
    for task in processingStore.scanUnfinishedTasks() {
      guard let session = try? sessionStore.load(sessionID: task.sessionID) else {
        _ = try? processingStore.markFailed(
          sessionID: task.sessionID,
          code: "session_unavailable",
          message: "audio processing session metadata is unavailable"
        )
        historyProcessingStatusStore.update(
          sessionID: task.sessionID,
          taskID: task.id,
          stage: AudioProcessingTaskStage.failed.rawValue
        )
        continue
      }
      guard let sources = try? transcriptionSources(for: session) else {
        _ = try? processingStore.markFailed(
          sessionID: task.sessionID,
          code: "invalid_source_metadata",
          message: "audio processing source metadata is invalid"
        )
        historyProcessingStatusStore.update(
          sessionID: task.sessionID,
          taskID: task.id,
          stage: AudioProcessingTaskStage.failed.rawValue
        )
        continue
      }
      let generation = UUID()
      processingGeneration = generation
      sessionID = task.sessionID
      if let historyID = session.manifest.historyRecordReference {
        historyProcessingStatusStore.associate(
          historyRecordID: historyID,
          sessionID: task.sessionID,
          taskID: task.id,
          stage: task.stage.rawValue
        )
      }
      state = .transcribing
      do {
        let result: AudioProcessingPipelineResult
        if task.stage == .failed {
          result = try await processingPipeline.restart(
            sessionID: task.sessionID,
            sourceInputs: sources
          )
        } else {
          result = try await processingPipeline.resume(
            sessionID: task.sessionID,
            sourceInputs: sources
          )
        }
        guard processingGeneration == generation else { continue }
        applyProcessingResult(result, generation: generation)
      } catch AudioRecordingProcessingPipelineError.cancelled {
        continue
      } catch {
        guard processingGeneration == generation else { continue }
        lastError = error.localizedDescription
        state = .idle
        historyProcessingStatusStore.update(
          sessionID: task.sessionID,
          taskID: task.id,
          stage: AudioProcessingTaskStage.failed.rawValue
        )
      }
    }
  }

  /// Retry a failed or model-waiting task without reopening the private MOV.
  func retryProcessing() {
    guard canRetryProcessing,
          let sessionID,
          let task = try? processingStore.loadTask(sessionID: sessionID),
          let session = try? sessionStore.load(sessionID: sessionID),
          let sources = try? transcriptionSources(for: session) else { return }
    isWaitingForModel = false
    lastError = nil
    state = .transcribing
    startProcessing(taskID: task.id, sessionID: sessionID, sourceInputs: sources)
  }

  private func transcriptionSources(
    for session: AudioAdapterSession
  ) throws -> [AudioTranscriptionSourceInput] {
    let paths = session.manifest.finalPaths
    if let system = paths.system, let microphone = paths.microphone {
      guard AudioAdapterSessionManifest.isFinalRelativePath(system),
            AudioAdapterSessionManifest.isFinalRelativePath(microphone) else {
        throw AudioRecordingProcessingPipelineError.unsafeSourcePath
      }
      return [
        AudioTranscriptionSourceInput(source: .system, url: try session.url(for: system)),
        AudioTranscriptionSourceInput(source: .microphone, url: try session.url(for: microphone)),
      ]
    }
    guard let mixed = paths.mixed,
          AudioAdapterSessionManifest.isFinalRelativePath(mixed) else {
      throw AudioRecordingProcessingPipelineError.noAudioSource
    }
    return [AudioTranscriptionSourceInput(source: .mixed, url: try session.url(for: mixed))]
  }

  private func completeRecoveryHistory(sessionID: UUID) async {
    do {
      let session = try sessionStore.load(sessionID: sessionID)
      guard let mixedPath = session.manifest.finalPaths.mixed else { return }
      let result = await postCapture.handleAudioCapture(
        url: try session.url(for: mixedPath),
        skipQuickAccess: false,
        preferredHistoryID: sessionID
      )
      guard let historyRecordID = result.historyRecordID else { return }
      _ = try sessionStore.markHistoryPersisted(
        sessionID: sessionID,
        reference: historyRecordID
      )
      await completeRecoveryTranscription(sessionID: sessionID)
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Audio history recovery deferred")
    }
  }

  private func completeRecoveryTranscription(sessionID: UUID) async {
    do {
      let session = try sessionStore.load(sessionID: sessionID)
      let taskID: UUID
      let task: AudioProcessingTask
      if let existing = try? processingStore.loadTask(sessionID: sessionID) {
        taskID = existing.id
        task = existing
      } else {
        let hasPersistedOptions = session.manifest.processingLanguage != nil
          && session.manifest.processingTemplate != nil
          && session.manifest.processingAutoTranscribe != nil
          && session.manifest.processingAutoAI != nil
        if !hasPersistedOptions {
          lastError = "Audio processing options were unavailable; recovery used defaults."
        }
        task = AudioProcessingTask(
          sessionID: sessionID,
          language: session.manifest.processingLanguage ?? .auto,
          template: session.manifest.processingTemplate ?? .transcriptOnly,
          autoTranscribe: session.manifest.processingAutoTranscribe ?? true,
          autoAI: (session.manifest.processingAutoAI ?? false)
            && (session.manifest.processingAutoTranscribe ?? true),
          sourcePaths: finalSourcePaths(from: session.manifest)
        )
        taskID = try processingStore.persistTask(sessionID: sessionID, task: task)
      }
      if !session.manifest.transcriptionTaskPersisted {
        _ = try sessionStore.markTranscriptionTaskPersisted(
          sessionID: sessionID,
          reference: taskID
        )
      }
      if let historyID = session.manifest.historyRecordReference {
        historyProcessingStatusStore.associate(
          historyRecordID: historyID,
          sessionID: sessionID,
          taskID: taskID,
          stage: task.stage.rawValue
        )
        if session.manifest.processingLanguage == nil
          || session.manifest.processingTemplate == nil
          || session.manifest.processingAutoTranscribe == nil
          || session.manifest.processingAutoAI == nil {
          historyProcessingStatusStore.update(
            sessionID: sessionID,
            taskID: taskID,
            stage: AudioProcessingTaskStage.failed.rawValue
          )
        }
      }
      try await sessionStore.deleteInternalVideo(sessionID: sessionID)
      _ = task
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Audio transcription recovery deferred")
    }
  }

  private func finalSourcePaths(
    from manifest: AudioAdapterSessionManifest
  ) -> [AudioRecordingSource: String] {
    if let system = manifest.finalPaths.system,
       let microphone = manifest.finalPaths.microphone {
      return [.system: system, .microphone: microphone]
    }
    guard let mixed = manifest.finalPaths.mixed else { return [:] }
    return [.mixed: mixed]
  }

  // MARK: - Display / stream recovery

  @objc private func streamDidFail(_ notification: Notification) {
    guard let event = notification.userInfo?[RecordingStreamFailureEvent.userInfoKey]
      as? RecordingStreamFailureEvent,
      event.purpose == .audioAdapter,
      event.wasAdapterStartClaimed else { return }
    guard !streamFailureStopScheduled else { return }
    endedEarly = true
    if state == .preparing {
      // The manager can publish the failure after its atomic start claim but
      // before adapter.start() returns. Queue the save; prepareAndStart will
      // enter recording state only long enough to run the normal stop gate.
      pendingStreamFailure = true
      return
    }
    guard isRecording else { return }
    streamFailureStopScheduled = true
    stop()
  }

  @objc private func screenParametersDidChange(_: Notification) {
    guard isRecording else { return }
    guard stopTask == nil, case .idle = sessionOperation else { return }
    guard AudioRecordingDisplayRecoveryPolicy.shouldAttempt(
      recoveryCount: displayRecoveryCount
    ) else {
      endedEarly = true
      stop()
      return
    }
    displayRecoveryCount += 1
    displayRecoveryTask?.cancel()
    sessionOperationGeneration &+= 1
    let generation = sessionOperationGeneration
    sessionOperation = .displayRecovery(generation)
    displayRecoveryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.beginNextSegmentWithTimeout()
      } catch {
        self.endedEarly = true
        // The adapter has already rolled back its newest unresolved segment;
        // stop will extract the completed prefix without calling Tiny.stop on
        // its failed recovery stage.
        self.lastError = error.localizedDescription
        self.displayRecoveryTask = nil
        self.stop()
      }
      self.displayRecoveryTask = nil
      if self.sessionOperation == .displayRecovery(generation) {
        self.sessionOperation = .idle
      }
    }
  }

  private func beginNextSegmentWithTimeout() async throws {
    let gate = AudioDisplayRecoveryGate()
    let operation = Task { @MainActor [adapter] in
      try await adapter.beginNextSegment()
    }

    Task { @MainActor in
      do {
        gate.succeed(try await operation.value)
      } catch {
        gate.fail(error)
      }
    }
    Task { @MainActor [weak self] in
      do {
        try await Task.sleep(
          nanoseconds: UInt64(AudioRecordingDisplayRecoveryPolicy.timeout * 1_000_000_000)
        )
        guard !gate.isFinished else { return }
        operation.cancel()
        await self?.adapter.abortDisplayRecovery()
        gate.fail(AudioRecordingCoordinatorError.displayRecoveryTimedOut)
      } catch {
        // The operation won or the timeout task was cancelled.
      }
    }

    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
      }
    }, onCancel: { [weak self] in
      operation.cancel()
      gate.fail(CancellationError())
      Task { @MainActor [weak self] in
        await self?.adapter.abortDisplayRecovery()
      }
    })
  }

  // MARK: - UI helpers

  private func showControlBar() {
    let bar = controlBar ?? AudioRecordingControlBarWindow(coordinator: self)
    controlBar = bar
    bar.onPauseResume = { [weak self] in self?.pauseOrResume() }
    bar.onRestart = { [weak self] in self?.restart() }
    bar.onDelete = { [weak self] in self?.delete() }
    bar.onStop = { [weak self] in self?.stop() }
    bar.showWithoutActivating()
  }

  private func closeCaptureUI() {
    preparationPanel?.orderOut(nil)
    controlBar?.orderOut(nil)
  }

  private func confirm(title: String, message: String, action: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: L10n.Common.cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func failCapture(_ error: Error) {
    lastError = error.localizedDescription
    state = adapter.session == nil ? .failed : .recoverable
    Task { await showFailureToast(L10n.AudioRecording.failedTitle) }
  }

  private func showSuccessToast(_ message: String) async {
    await MainActor.run {
      AppToastManager.shared.show(message: message, style: .success, position: .bottomCenter)
    }
  }

  private func successToastMessage(for sessionID: UUID, endedEarly: Bool) -> String {
    let notice: AudioRecordingSaveToastNotice
    if let session = try? sessionStore.load(sessionID: sessionID) {
      notice = AudioRecordingSaveToastPolicy.notice(
        requestedRoles: session.manifest.trackRoles,
        effectiveRoles: session.manifest.effectiveCapturedTrackRoles,
        endedEarly: endedEarly
      )
    } else {
      notice = endedEarly ? .endedEarlySaved : .saved
    }
    switch notice {
    case .saved:
      return L10n.AudioRecording.saved
    case .endedEarlySaved:
      return L10n.AudioRecording.endedEarlySaved
    case .savedWithoutMicrophone:
      return L10n.AudioRecording.savedWithoutMicrophone
    case .savedWithoutSystemAudio:
      return L10n.AudioRecording.savedWithoutSystemAudio
    }
  }

  private func showFailureToast(_ message: String) async {
    await MainActor.run {
      AppToastManager.shared.show(message: message, style: .warning, position: .bottomCenter)
    }
  }

  private func scheduleReturnToIdle() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      guard let self, self.state == .completed else { return }
      self.state = .idle
      self.sessionID = nil
      self.isWaitingForModel = false
    }
  }
}
