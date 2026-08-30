//
//  TranslationBatchExecutor.swift
//  ShotPaste
//
//  Bounded text-only batch scheduling. At most two provider calls are in
//  flight. The caller is released by the first terminal event even when a
//  provider ignores task cancellation; late provider results are discarded.
//

import Foundation

nonisolated struct TranslationBatchExecutor: Sendable {
  struct Result: Sendable {
    let translations: [String: String]
  }

  /// Executes at most two provider calls at once.
  ///
  /// This deliberately uses a locked continuation state and unstructured
  /// workers instead of a task group. A task-group scope waits for all of its
  /// children to leave the scope, even after `cancelAll()`. That is not a
  /// useful cancellation contract for a provider implementation which is
  /// synchronous or otherwise non-cooperative. Here the first terminal event
  /// resumes the caller immediately and cancellation of every worker is best
  /// effort; a late worker can never publish a partial result.
  static func execute(
    batches: [TranslationTextRequest],
    provider: any TranslationTextProvider,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    deadline: Date,
    sendRecognizedText: @escaping @Sendable () -> Bool
  ) async throws -> Result {
    guard !batches.isEmpty else { return Result(translations: [:]) }
    let expectedIDs = try validateBatches(batches)
    let state = TranslationBatchExecutionState(
      batches: batches,
      expectedIDs: expectedIDs,
      provider: provider,
      configuration: configuration,
      apiKey: apiKey,
      deadline: deadline,
      sendRecognizedText: sendRecognizedText
    )

    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Result, Error>) in
        // Install before starting workers. Cancellation/deadline/privacy may
        // win in the small window between these two operations.
        state.install(continuation)
        state.start()
      }
    }, onCancel: {
      state.finish(.failure(TranslationTextProviderError.cancelled))
    })
  }

  /// Fail closed when a caller bypasses TranslationTextBatcher. Every emitted
  /// batch must describe the same request, and an ID may occur only once over
  /// the complete request. This prevents a scheduler from ever accepting an
  /// ambiguous merge contract.
  private static func validateBatches(
    _ batches: [TranslationTextRequest]
  ) throws -> Set<String> {
    guard let first = batches.first,
          batches.count <= TranslationTextLimits.maximumBatches
    else {
      throw TranslationTextProviderError.invalidRequest
    }

    var ids = Set<String>()
    for batch in batches {
      guard batch.generationID == first.generationID,
            batch.sourceLanguage == first.sourceLanguage,
            batch.targetLanguage == first.targetLanguage,
            batch.stylePreferences == first.stylePreferences,
            !batch.blocks.isEmpty
      else {
        throw TranslationTextProviderError.invalidRequest
      }
      try TranslationTextRequestValidator.validate(batch)
      for block in batch.blocks {
        guard ids.insert(block.id).inserted else {
          throw TranslationTextProviderError.invalidRequest
        }
      }
    }
    guard !ids.isEmpty else { throw TranslationTextProviderError.invalidRequest }
    return ids
  }
}

/// Locked first-terminal state for `TranslationBatchExecutor`.
///
/// `finish` is linearized under `lock`, but task cancellation and continuation
/// resume are performed after unlocking. In particular, this handles all of
/// the awkward startup orderings: a worker can finish before its Task is
/// stored, or a monitor/deadline can finish before its Task is stored, and a
/// cancellation can arrive before the continuation is installed.
fileprivate final nonisolated class TranslationBatchExecutionState: @unchecked Sendable {
  fileprivate typealias ExecutorResult = TranslationBatchExecutor.Result

  private let lock = NSLock()
  private let batches: [TranslationTextRequest]
  private let expectedIDs: Set<String>
  private let provider: any TranslationTextProvider
  private let configuration: AgentProviderConfiguration
  private let apiKey: String?
  private let deadline: Date
  private let sendRecognizedText: @Sendable () -> Bool

  private var continuation: CheckedContinuation<ExecutorResult, Error>?
  private var pendingResult: Result<ExecutorResult, Error>?
  private var workerTasks: [Int: Task<Void, Never>] = [:]
  private var activeIndices = Set<Int>()
  private var nextIndex = 0
  private var translations: [String: String] = [:]
  private var monitorTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private var hasFinished = false

  /// Everything needed to complete a first-terminal transition is captured
  /// while the state lock is held, then cancellation/resume happen after
  /// unlocking. Keeping this as one action also lets provider failures
  /// terminalize under the same lock acquisition as worker/scheduler state.
  private struct TerminalActions {
    let result: Result<ExecutorResult, Error>
    let continuation: CheckedContinuation<ExecutorResult, Error>?
    let workerTasks: [Task<Void, Never>]
    let monitorTask: Task<Void, Never>?
    let deadlineTask: Task<Void, Never>?
  }

  init(
    batches: [TranslationTextRequest],
    expectedIDs: Set<String>,
    provider: any TranslationTextProvider,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    deadline: Date,
    sendRecognizedText: @escaping @Sendable () -> Bool
  ) {
    self.batches = batches
    self.expectedIDs = expectedIDs
    self.provider = provider
    self.configuration = configuration
    self.apiKey = apiKey
    self.deadline = deadline
    self.sendRecognizedText = sendRecognizedText
    translations.reserveCapacity(expectedIDs.count)
  }

  fileprivate func install(_ continuation: CheckedContinuation<ExecutorResult, Error>) {
    lock.lock()
    if let pendingResult {
      self.pendingResult = nil
      lock.unlock()
      continuation.resume(with: pendingResult)
      return
    }
    if hasFinished {
      lock.unlock()
      continuation.resume(throwing: TranslationTextProviderError.cancelled)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  fileprivate func start() {
    // The state is normally started immediately after `install`, but a task
    // cancellation can win that race. All start failures use finish, so the
    // caller still receives exactly one outcome.
    guard !isFinished() else { return }
    guard sendRecognizedText() else {
      finish(.failure(TranslationFailure.recognizedTextSharingDisabled))
      return
    }
    guard TranslationTextDeadline.hasMinimumStartBudget(until: deadline) else {
      finish(.failure(TranslationTextProviderError.timedOut))
      return
    }

    startDeadlineMonitor()
    startPrivacyMonitor()
    scheduleAvailableWorkers()
  }

  fileprivate func finish(_ result: Result<ExecutorResult, Error>) {
    lock.lock()
    let actions = takeTerminalActionsLocked(for: result)
    lock.unlock()
    complete(actions)
  }

  /// Caller must hold the state lock. This marks hasFinished before any
  /// sibling can remove a slot or ask the scheduler to reserve another batch.
  private func takeTerminalActionsLocked(
    for result: Result<ExecutorResult, Error>
  ) -> TerminalActions? {
    guard !hasFinished else { return nil }
    hasFinished = true
    let continuation = self.continuation
    self.continuation = nil
    if continuation == nil {
      pendingResult = result
    }
    let actions = TerminalActions(
      result: result,
      continuation: continuation,
      workerTasks: Array(workerTasks.values),
      monitorTask: monitorTask,
      deadlineTask: deadlineTask
    )
    workerTasks.removeAll()
    activeIndices.removeAll()
    monitorTask = nil
    deadlineTask = nil
    return actions
  }

  private func complete(_ actions: TerminalActions?) {
    guard let actions else { return }
    // Never cancel tasks while holding the state lock. Cancellation can run a
    // task's handler synchronously and re-enter finish.
    actions.workerTasks.forEach { $0.cancel() }
    actions.monitorTask?.cancel()
    actions.deadlineTask?.cancel()
    actions.continuation?.resume(with: actions.result)
  }

  private func isFinished() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return hasFinished
  }

  private func startDeadlineMonitor() {
    let task = Task.detached { [weak self] in
      let remaining = self?.deadline.timeIntervalSinceNow ?? 0
      guard remaining > 0 else {
        self?.finish(.failure(TranslationTextProviderError.timedOut))
        return
      }
      do {
        try await Task.sleep(nanoseconds: TranslationTextDeadline.nanoseconds(for: remaining))
      } catch {
        return
      }
      self?.finish(.failure(TranslationTextProviderError.timedOut))
    }

    lock.lock()
    let shouldCancel = hasFinished
    if !shouldCancel {
      deadlineTask = task
    }
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  /// Polling is the notification seam for the current preference API, which
  /// exposes a read-only closure rather than an async stream. The short
  /// interval keeps an in-flight batch from becoming a privacy bypass while
  /// the provider is still running. The value itself is never logged/stored.
  private func startPrivacyMonitor() {
    let task = Task.detached { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        if !self.sendRecognizedText() {
          self.finish(.failure(TranslationFailure.recognizedTextSharingDisabled))
          return
        }
        let remaining = self.deadline.timeIntervalSinceNow
        guard remaining > 0 else {
          self.finish(.failure(TranslationTextProviderError.timedOut))
          return
        }
        let interval = min(0.01, remaining)
        do {
          try await Task.sleep(nanoseconds: TranslationTextDeadline.nanoseconds(for: interval))
        } catch {
          return
        }
      }
    }

    lock.lock()
    let shouldCancel = hasFinished
    if !shouldCancel {
      monitorTask = task
    }
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  /// Reserve the next wave under the lock, then create the actual workers
  /// outside it. A wave is a barrier: no later batch is reserved while any
  /// worker from the current wave remains active. Reserving the whole wave
  /// before launching its tasks prevents two completion callbacks from
  /// starting the same next batch, and also means a provider failure in one
  /// sibling cannot race a success callback into a third provider call.
  /// If a terminal event wins before a Task is stored, `installWorker`
  /// observes `hasFinished` and cancels that late-created Task.
  private func scheduleAvailableWorkers() {
    guard sendRecognizedText() else {
      finish(.failure(TranslationFailure.recognizedTextSharingDisabled))
      return
    }
    guard TranslationTextDeadline.hasMinimumStartBudget(until: deadline) else {
      finish(.failure(TranslationTextProviderError.timedOut))
      return
    }

    var indices: [Int] = []
    lock.lock()
    if !hasFinished, activeIndices.isEmpty {
      while nextIndex < batches.count && activeIndices.count < 2 {
        activeIndices.insert(nextIndex)
        indices.append(nextIndex)
        nextIndex += 1
      }
    }
    lock.unlock()

    for index in indices {
      launchWorker(at: index)
    }
  }

  private func launchWorker(at index: Int) {
    let task = Task.detached { [weak self] in
      guard let self else { return }
      do {
        try TranslationTextDeadline.check(self.deadline)
        guard self.sendRecognizedText() else {
          self.workerFailed(at: index, error: TranslationFailure.recognizedTextSharingDisabled)
          return
        }
        guard TranslationTextDeadline.hasMinimumStartBudget(until: self.deadline) else {
          self.workerFailed(at: index, error: TranslationTextProviderError.timedOut)
          return
        }
        let batch = self.batches[index]
        let response = try await self.provider.translate(
          request: batch,
          configuration: self.configuration,
          apiKey: self.apiKey,
          deadline: self.deadline
        )
        // A non-cooperative provider can return after a deadline or after the
        // privacy monitor has won. Treat that response as late data.
        try TranslationTextDeadline.check(self.deadline)
        guard self.sendRecognizedText() else {
          self.workerFailed(at: index, error: TranslationFailure.recognizedTextSharingDisabled)
          return
        }
        guard response.generationID == batch.generationID else {
          self.workerFailed(at: index, error: TranslationTextProviderError.invalidResponse)
          return
        }
        let validated = try TranslationTextResponseValidator.validate(response, against: batch)
        self.workerSucceeded(at: index, response: validated)
      } catch {
        self.workerFailed(at: index, error: error)
      }
    }
    installWorker(task, at: index)
  }

  private func installWorker(_ task: Task<Void, Never>, at index: Int) {
    lock.lock()
    let shouldCancel = hasFinished || !activeIndices.contains(index)
    if !shouldCancel {
      workerTasks[index] = task
    }
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  private func workerSucceeded(
    at index: Int,
    response: TranslationTextResponse
  ) {
    // Check immediately before touching the shared translation map. A gate
    // transition must never turn a late response into partial output.
    guard sendRecognizedText() else {
      workerFailed(at: index, error: TranslationFailure.recognizedTextSharingDisabled)
      return
    }

    var terminalActions: TerminalActions?
    var shouldScheduleNextWave = false
    var shouldFinish = false
    lock.lock()
    guard !hasFinished, activeIndices.contains(index) else {
      lock.unlock()
      return
    }
    workerTasks[index] = nil
    if response.translations.contains(where: { translations[$0.id] != nil }) {
      // Keep the current wave active until its response has been fully
      // validated and merged. A duplicate ID is a batch failure, so
      // terminalize under this same lock acquisition before any sibling can
      // observe an empty active set and reserve the next wave.
      terminalActions = takeTerminalActionsLocked(
        for: .failure(TranslationTextProviderError.invalidResponse)
      )
    } else {
      for translation in response.translations {
        translations[translation.id] = translation.translatedText
      }
      activeIndices.remove(index)
      if activeIndices.isEmpty {
        shouldScheduleNextWave = nextIndex < batches.count
        shouldFinish = !shouldScheduleNextWave
      }
    }
    lock.unlock()

    if let terminalActions {
      complete(terminalActions)
      return
    }
    if shouldFinish {
      guard sendRecognizedText() else {
        finish(.failure(TranslationFailure.recognizedTextSharingDisabled))
        return
      }
      lock.lock()
      let result = !hasFinished
        && translations.count == expectedIDs.count
        && Set(translations.keys) == expectedIDs
        ? ExecutorResult(translations: translations)
        : nil
      lock.unlock()
      if let result {
        finish(.success(result))
      } else {
        finish(.failure(TranslationTextProviderError.invalidResponse))
      }
      return
    }

    if shouldScheduleNextWave {
      scheduleAvailableWorkers()
    }
  }

  private func workerFailed(at index: Int, error: Error) {
    let actions: TerminalActions?
    lock.lock()
    // Linearize provider failure as terminal while holding the same lock used
    // by worker success and the scheduler. This closes the exact window where
    // a sibling could otherwise remove its slot, reserve nextIndex, and start
    // a third provider call before finish acquired the lock.
    guard !hasFinished, activeIndices.contains(index) else {
      lock.unlock()
      return
    }
    actions = takeTerminalActionsLocked(for: .failure(error))
    lock.unlock()
    complete(actions)
  }
}
