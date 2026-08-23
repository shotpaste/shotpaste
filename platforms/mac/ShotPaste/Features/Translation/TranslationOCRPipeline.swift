//
//  TranslationOCRPipeline.swift
//  ShotPaste
//
//  Local Vision OCR orchestration. The caller supplies an already frozen image
//  and an absolute deadline; this pipeline never captures, encodes, or sends a
//  screen image to a provider.
//

import CoreGraphics
import Foundation
import Vision

/// The production Vision executor. It returns only OCR observations; no
/// provider protocol or network client is referenced here.
nonisolated struct VisionTranslationOCRExecutor: TranslationOCRExecutor, Sendable {
  init() {}

  func recognize(
    tile: LocalOCRTile,
    sourceLanguageIdentifier: String?,
    deadline: Date
  ) async throws -> [TranslationOCRObservation] {
    try TranslationOCRDeadline.check(deadline)

    // Query Vision's installed locale list before creating the request. An
    // unsupported manual app language intentionally produces no recognition
    // hint, which enables Vision's automatic detection instead of passing a
    // bare/invalid language code.
    let hints = try Self.recognitionLanguageHints(
      for: sourceLanguageIdentifier,
      deadline: deadline
    )

    let state = VisionOCRRequestState<[TranslationOCRObservation]>()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranslationOCRObservation], Error>) in
        state.setContinuation(continuation)

        let request = VNRecognizeTextRequest { request, error in
          if let error {
            if Task.isCancelled {
              state.cancel(CancellationError())
            } else if Date() >= deadline {
              state.cancel(TranslationFailure.timedOut)
            } else if (error as NSError).domain == VNErrorDomain,
                      (error as NSError).code == VNErrorCode.requestCancelled.rawValue {
              state.cancel(TranslationFailure.cancelled)
            } else {
              state.cancel(TranslationFailure.unavailable)
            }
            return
          }

          guard let observations = request.results as? [VNRecognizedTextObservation] else {
            state.finish(with: .success([]))
            return
          }
          var result: [TranslationOCRObservation] = []
          result.reserveCapacity(observations.count)
          for observation in observations {
            guard Date() < deadline, !Task.isCancelled else {
              state.cancel(Task.isCancelled ? CancellationError() : TranslationFailure.timedOut)
              return
            }
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence.isFinite,
                  (0 ... 1).contains(candidate.confidence)
            else { continue }
            result.append(TranslationOCRObservation(
              text: text,
              confidence: candidate.confidence,
              visionBounds: observation.boundingBox,
              recognitionLanguageHints: hints
            ))
          }
          guard Date() < deadline, !Task.isCancelled else {
            state.cancel(Task.isCancelled ? CancellationError() : TranslationFailure.timedOut)
            return
          }
          state.finish(with: .success(result))
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.preferBackgroundProcessing = true
        request.minimumTextHeight = 0
        if !hints.isEmpty {
          request.recognitionLanguages = hints
        }
        if #available(macOS 13.0, *) {
          request.automaticallyDetectsLanguage = hints.isEmpty
        }
        state.setRequest(request)

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
          state.cancel(TranslationFailure.timedOut)
          return
        }
        let deadlineWorkItem = DispatchWorkItem {
          state.cancel(TranslationFailure.timedOut)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + remaining,
          execute: deadlineWorkItem
        )

        do {
          if Task.isCancelled || state.isTerminated {
            state.cancel(CancellationError())
            deadlineWorkItem.cancel()
            return
          }
          let handler = VNImageRequestHandler(cgImage: tile.image, options: [:])
          try handler.perform([request])
          deadlineWorkItem.cancel()
          // Vision normally invokes the completion synchronously. Complete
          // defensively if a future revision returns without a callback; a
          // later callback is treated as a late completion and discarded.
          if Date() >= deadline {
            state.cancel(TranslationFailure.timedOut)
          } else {
            state.finish(with: .success([]))
          }
        } catch {
          deadlineWorkItem.cancel()
          if Task.isCancelled {
            state.cancel(CancellationError())
          } else if Date() >= deadline {
            state.cancel(TranslationFailure.timedOut)
          } else if (error as NSError).domain == VNErrorDomain,
                    (error as NSError).code == VNErrorCode.requestCancelled.rawValue {
            state.cancel(TranslationFailure.cancelled)
          } else {
            state.cancel(TranslationFailure.unavailable)
          }
        }
      }
    }, onCancel: {
      state.cancel(CancellationError())
    })
  }

  private static func recognitionLanguageHints(
    for identifier: String?,
    deadline: Date
  ) throws -> [String] {
    try TranslationOCRDeadline.check(deadline)
    guard let identifier = TranslationLanguageDetector.visionRecognitionIdentifier(for: identifier) else {
      return []
    }
    try TranslationOCRDeadline.check(deadline)
    return [identifier]
  }
}

/// The state object lets Esc and the absolute deadline cancel a VNRequest even
/// while `VNImageRequestHandler.perform` is synchronously processing it.
/// It is internal (rather than private) so deterministic tests can exercise
/// cancellation-before-continuation and late-callback races without invoking
/// a real Vision request.
final nonisolated class VisionOCRRequestState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var request: VNRequest?
  private var continuation: CheckedContinuation<Value, Error>?
  /// The first terminal event wins. This is deliberately separate from
  /// `continuationResumed`: a terminal result may arrive before the
  /// continuation is installed and must then be replayed exactly once.
  private var terminalResult: Result<Value, Error>?
  private var continuationResumed = false

  func setRequest(_ request: VNRequest) {
    lock.lock()
    let shouldCancel = terminalResult != nil || continuationResumed
    if !shouldCancel { self.request = request }
    lock.unlock()
    if shouldCancel { request.cancel() }
  }

  func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let terminalResult, !continuationResumed {
      continuationResumed = true
      lock.unlock()
      continuation.resume(with: terminalResult)
      return
    }
    if continuationResumed {
      lock.unlock()
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func finish(with result: Result<Value, Error>) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let continuation: CheckedContinuation<Value, Error>?
    if let installed = self.continuation {
      continuationResumed = true
      continuation = installed
      self.continuation = nil
    } else {
      continuation = nil
    }
    request = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  func cancel(_ error: Error) {
    lock.lock()
    let request = self.request
    self.request = nil
    guard terminalResult == nil else {
      lock.unlock()
      request?.cancel()
      return
    }
    terminalResult = .failure(error)
    let continuation: CheckedContinuation<Value, Error>?
    if let installed = self.continuation {
      continuationResumed = true
      continuation = installed
      self.continuation = nil
    } else {
      continuation = nil
    }
    lock.unlock()

    request?.cancel()
    continuation?.resume(throwing: error)
  }

  var isTerminated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminalResult != nil
  }
}

/// Races an arbitrary injected OCR executor against the same absolute
/// deadline used by the session. The executor task is intentionally
/// unstructured: a non-cooperative implementation may continue in the
/// background after cancellation, but it can never keep the caller waiting
/// past the deadline and its late value is discarded by this first-wins state.
private final nonisolated class TranslationOCRExecutorRaceState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var terminalResult: Result<Value, Error>?
  private var worker: Task<Void, Never>?
  private var deadlineWorkItem: DispatchWorkItem?

  func setContinuation(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let terminalResult {
      lock.unlock()
      continuation.resume(with: terminalResult)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func setWorker(_ worker: Task<Void, Never>) {
    lock.lock()
    let shouldCancel = terminalResult != nil
    if !shouldCancel { self.worker = worker }
    lock.unlock()
    if shouldCancel { worker.cancel() }
  }

  @discardableResult
  func setDeadlineWorkItem(_ workItem: DispatchWorkItem) -> Bool {
    lock.lock()
    let shouldSchedule = terminalResult == nil
    if shouldSchedule { deadlineWorkItem = workItem }
    lock.unlock()
    if !shouldSchedule { workItem.cancel() }
    return shouldSchedule
  }

  func finish(with result: Result<Value, Error>) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let continuation = self.continuation
    self.continuation = nil
    let worker = self.worker
    self.worker = nil
    let deadlineWorkItem = self.deadlineWorkItem
    self.deadlineWorkItem = nil
    lock.unlock()

    worker?.cancel()
    deadlineWorkItem?.cancel()
    continuation?.resume(with: result)
  }

  func cancel(_ error: Error) {
    finish(with: .failure(error))
  }

  var isTerminated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminalResult != nil
  }
}

private actor TranslationOCRLineBudget {
  private var reserved = 0

  func reserve(_ count: Int) throws {
    guard count >= 0,
          count <= TranslationOCRLimits.maximumOCRLines - reserved else {
      throw TranslationFailure.inputTooLarge
    }
    reserved += count
  }
}

private actor TranslationOCRTileIndexSource {
  private let count: Int
  private var next = 0

  init(count: Int) {
    self.count = count
  }

  func take() -> Int? {
    guard next < count else { return nil }
    defer { next += 1 }
    return next
  }
}

/// Collects bounded worker loops without attaching an arbitrary executor task
/// to a structured task group. Once the first error/deadline wins, all worker
/// tasks are cancelled and the caller continuation is resumed immediately.
private final class TranslationOCRTileWorkerState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var remainingWorkers: Int
  private var results: [Value] = []
  private var workers: [Task<Void, Never>] = []
  private var continuation: CheckedContinuation<[Value], Error>?
  private var terminalResult: Result<[Value], Error>?

  init(expectedWorkers: Int) {
    remainingWorkers = expectedWorkers
  }

  func setContinuation(_ continuation: CheckedContinuation<[Value], Error>) {
    lock.lock()
    if let terminalResult {
      lock.unlock()
      continuation.resume(with: terminalResult)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func setWorker(_ worker: Task<Void, Never>) {
    lock.lock()
    let shouldCancel = terminalResult != nil
    if !shouldCancel { workers.append(worker) }
    lock.unlock()
    if shouldCancel { worker.cancel() }
  }

  func workerFinished(_ values: [Value]) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    results.append(contentsOf: values)
    remainingWorkers -= 1
    guard remainingWorkers == 0 else {
      lock.unlock()
      return
    }
    let completedResults = results
    terminalResult = .success(completedResults)
    let continuation = self.continuation
    self.continuation = nil
    let workers = self.workers
    self.workers.removeAll()
    lock.unlock()

    for worker in workers { worker.cancel() }
    continuation?.resume(returning: completedResults)
  }

  func fail(_ error: Error) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = .failure(error)
    let continuation = self.continuation
    self.continuation = nil
    let workers = self.workers
    self.workers.removeAll()
    lock.unlock()

    for worker in workers { worker.cancel() }
    continuation?.resume(throwing: error)
  }

  var isTerminated: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminalResult != nil
  }
}

nonisolated struct TranslationOCRPipeline: Sendable {
  let executor: any TranslationOCRExecutor
  let blockBuilder: TranslationTextBlockBuilder
  let maximumConcurrentTiles: Int

  init(
    executor: any TranslationOCRExecutor = VisionTranslationOCRExecutor(),
    blockBuilder: TranslationTextBlockBuilder = TranslationTextBlockBuilder(),
    maximumConcurrentTiles: Int = 2
  ) {
    self.executor = executor
    self.blockBuilder = blockBuilder
    // Vision's working set is intentionally capped at two workers. The
    // initializer accepts a value for test/configuration compatibility, but a
    // caller can never raise this hard safety limit.
    self.maximumConcurrentTiles = max(1, min(maximumConcurrentTiles, 2))
  }

  func recognize(_ request: TranslationOCRRequest) async throws -> TranslationOCRResult {
    try Self.checkCancellationAndDeadline(request.deadline)
    guard request.image.width > 0, request.image.height > 0,
          request.screenRect.width > 0, request.screenRect.height > 0
    else { throw TranslationFailure.captureFailed }

    let tiles = try LocalOCRTiler.tiles(for: request.image, deadline: request.deadline)
    try Self.checkCancellationAndDeadline(request.deadline)
    let tileResults = try await recognizeTiles(tiles, request: request)

    try Self.checkCancellationAndDeadline(request.deadline)
    let orderedTileResults = tileResults.sorted { $0.index < $1.index }
    var allLines: [TranslationOCRLine] = []
    allLines.reserveCapacity(TranslationOCRLimits.maximumOCRLines)
    for tileResult in orderedTileResults {
      try Self.checkCancellationAndDeadline(request.deadline)
      for line in tileResult.lines {
        try Self.checkCancellationAndDeadline(request.deadline)
        allLines.append(line)
      }
    }
    let lines = try LocalOCRTiler.deduplicated(allLines, deadline: request.deadline)
    guard !lines.isEmpty else { throw TranslationFailure.noText }

    let blocks = try blockBuilder.buildBlocks(
      from: lines,
      imagePixelSize: CGSize(width: request.image.width, height: request.image.height),
      screenRect: request.screenRect,
      sourceLanguageHint: request.sourceLanguageIdentifier,
      deadline: request.deadline
    )
    guard !blocks.isEmpty else { throw TranslationFailure.noText }
    try Self.checkCancellationAndDeadline(request.deadline)

    var translatableTexts: [String] = []
    translatableTexts.reserveCapacity(blocks.count)
    for block in blocks {
      try Self.checkCancellationAndDeadline(request.deadline)
      if !block.preserveOriginal { translatableTexts.append(block.sourceText) }
    }
    let detectedLanguage = try blockBuilder.languageDetector.detectSessionLanguage(
      for: translatableTexts,
      sourceLanguageHint: request.sourceLanguageIdentifier,
      deadline: request.deadline
    )
    try Self.checkCancellationAndDeadline(request.deadline)
    var lowConfidenceLineCount = 0
    for line in lines {
      try Self.checkCancellationAndDeadline(request.deadline)
      if line.confidence < 0.55 { lowConfidenceLineCount += 1 }
    }
    try Self.checkCancellationAndDeadline(request.deadline)
    return TranslationOCRResult(
      lines: lines,
      blocks: blocks,
      detectedLanguage: detectedLanguage,
      imagePixelSize: CGSize(width: request.image.width, height: request.image.height),
      screenRect: request.screenRect,
      lowConfidenceLineCount: lowConfidenceLineCount
    )
  }

  /// Synonym useful to call sites that use OCR as an explicit stage.
  func run(_ request: TranslationOCRRequest) async throws -> TranslationOCRResult {
    try await recognize(request)
  }

  private struct TileResult: Sendable {
    let index: Int
    let lines: [TranslationOCRLine]
  }

  private func recognizeTiles(
    _ tiles: [LocalOCRTile],
    request: TranslationOCRRequest
  ) async throws -> [TileResult] {
    let workerCount = min(maximumConcurrentTiles, tiles.count)
    let indexSource = TranslationOCRTileIndexSource(count: tiles.count)
    let lineBudget = TranslationOCRLineBudget()
    let state = TranslationOCRTileWorkerState<TileResult>(expectedWorkers: workerCount)
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[TileResult], Error>) in
        state.setContinuation(continuation)
        guard !state.isTerminated else { return }
        for _ in 0 ..< workerCount {
          let worker = Task { [self] in
            do {
              let results = try await recognizeWorker(
                tiles: tiles,
                indexSource: indexSource,
                lineBudget: lineBudget,
                request: request
              )
              state.workerFinished(results)
            } catch {
              state.fail(error)
            }
          }
          state.setWorker(worker)
        }
      }
    }, onCancel: {
      state.fail(CancellationError())
    })
  }

  private func recognizeWorker(
    tiles: [LocalOCRTile],
    indexSource: TranslationOCRTileIndexSource,
    lineBudget: TranslationOCRLineBudget,
    request: TranslationOCRRequest
  ) async throws -> [TileResult] {
    var results: [TileResult] = []
    while let index = await indexSource.take() {
      try Self.checkCancellationAndDeadline(request.deadline)
      let tile = tiles[index]
      let observations = try await recognizeExecutorWithDeadline(
        tile: tile,
        sourceLanguageIdentifier: request.sourceLanguageIdentifier,
        executor: executor,
        deadline: request.deadline
      )
      try Self.checkCancellationAndDeadline(request.deadline)
      try await lineBudget.reserve(observations.count)
      var lines: [TranslationOCRLine] = []
      lines.reserveCapacity(observations.count)
      for observation in observations {
        try Self.checkCancellationAndDeadline(request.deadline)
        if let line = LocalOCRTiler.line(from: observation, in: tile) {
          lines.append(line)
        }
      }
      try Self.checkCancellationAndDeadline(request.deadline)
      results.append(TileResult(index: index, lines: lines))
    }
    return results
  }

  private func recognizeExecutorWithDeadline(
    tile: LocalOCRTile,
    sourceLanguageIdentifier: String?,
    executor: any TranslationOCRExecutor,
    deadline: Date
  ) async throws -> [TranslationOCRObservation] {
    try Self.checkCancellationAndDeadline(deadline)
    let state = TranslationOCRExecutorRaceState<[TranslationOCRObservation]>()

    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<[TranslationOCRObservation], Error>) in
        state.setContinuation(continuation)
        guard !state.isTerminated else { return }

        let worker = Task { [executor] in
          do {
            let observations = try await executor.recognize(
              tile: tile,
              sourceLanguageIdentifier: sourceLanguageIdentifier,
              deadline: deadline
            )
            if Task.isCancelled {
              state.cancel(CancellationError())
            } else if Date() >= deadline {
              state.cancel(TranslationFailure.timedOut)
            } else {
              state.finish(with: .success(observations))
            }
          } catch {
            if Task.isCancelled {
              state.cancel(CancellationError())
            } else if Date() >= deadline {
              state.cancel(TranslationFailure.timedOut)
            } else {
              state.finish(with: .failure(error))
            }
          }
        }
        state.setWorker(worker)
        guard !state.isTerminated else { return }

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
          state.cancel(TranslationFailure.timedOut)
          return
        }
        let deadlineWorkItem = DispatchWorkItem {
          state.cancel(TranslationFailure.timedOut)
        }
        guard state.setDeadlineWorkItem(deadlineWorkItem) else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + remaining,
          execute: deadlineWorkItem
        )
      }
    }, onCancel: {
      state.cancel(CancellationError())
    })
  }

  static func checkCancellationAndDeadline(_ deadline: Date) throws {
    try TranslationOCRDeadline.check(deadline)
  }
}
