//
//  LocalAudioTranscriber.swift
//  ShotPaste
//
//  Bounded, sequential Speech.framework transcription for extracted local
//  audio tracks.
//

import AVFoundation
import Foundation
import Speech

nonisolated struct AudioTranscriptionChunk: Equatable, Sendable {
  let index: Int
  let startTime: TimeInterval
  let duration: TimeInterval

  var endTime: TimeInterval { startTime + duration }
}

nonisolated enum AudioTranscriptionChunkPlannerError: LocalizedError, Equatable, Sendable {
  case invalidDuration
  case invalidChunkDuration

  var errorDescription: String? {
    switch self {
    case .invalidDuration: "The audio duration is invalid."
    case .invalidChunkDuration: "The transcription chunk duration is invalid."
    }
  }
}

nonisolated enum AudioTranscriptionChunkPlanner {
  static let defaultChunkDurationSeconds: TimeInterval = 10 * 60

  static func plan(
    durationSeconds: TimeInterval,
    chunkDurationSeconds: TimeInterval = defaultChunkDurationSeconds
  ) throws -> [AudioTranscriptionChunk] {
    guard durationSeconds.isFinite, durationSeconds >= 0 else {
      throw AudioTranscriptionChunkPlannerError.invalidDuration
    }
    guard chunkDurationSeconds.isFinite, chunkDurationSeconds > 0 else {
      throw AudioTranscriptionChunkPlannerError.invalidChunkDuration
    }
    guard durationSeconds > 0 else { return [] }

    var result: [AudioTranscriptionChunk] = []
    var start = 0.0
    var index = 0
    while start < durationSeconds {
      let duration = min(chunkDurationSeconds, durationSeconds - start)
      guard duration > 0 else { break }
      result.append(AudioTranscriptionChunk(index: index, startTime: start, duration: duration))
      start += duration
      index += 1
    }
    return result
  }
}

typealias AudioChunkPlanner = AudioTranscriptionChunkPlanner

nonisolated struct AudioTranscriptionSourceInput: Sendable {
  let source: AudioRecordingSource
  let url: URL
  let durationSeconds: TimeInterval?

  init(source: AudioRecordingSource, url: URL, durationSeconds: TimeInterval? = nil) {
    self.source = source
    self.url = url
    self.durationSeconds = durationSeconds
  }
}

nonisolated struct AudioSpeechChunkResult: Sendable {
  let segments: [AudioTranscriptSegment]

  init(segments: [AudioTranscriptSegment] = []) {
    self.segments = segments
  }
}

nonisolated enum AudioTranscriberError: LocalizedError, Equatable, Sendable {
  case noAudioSource
  case authorizationDenied
  case authorizationRestricted
  case speechUnavailable
  case onDeviceModelUnavailable
  case recognizerUnavailable
  case sourceNotReadable
  case sourceDurationUnavailable
  case exportFailed
  case authorizationTimedOut
  case emptyRecognitionResult
  case recognitionFailed
  case recognitionTimedOut
  case cancelled

  var errorDescription: String? {
    switch self {
    case .noAudioSource: "No local audio source was supplied."
    case .authorizationDenied: "Speech recognition permission was denied."
    case .authorizationRestricted: "Speech recognition is restricted on this Mac."
    case .speechUnavailable: "Speech recognition is temporarily unavailable."
    case .onDeviceModelUnavailable: "The on-device speech model is unavailable."
    case .recognizerUnavailable: "The requested speech recognizer is unavailable."
    case .sourceNotReadable: "The local audio source could not be read."
    case .sourceDurationUnavailable: "The local audio duration could not be read."
    case .exportFailed: "A local transcription chunk could not be prepared."
    case .authorizationTimedOut: "Speech recognition permission timed out."
    case .emptyRecognitionResult: "Speech recognition returned no transcript."
    case .recognitionFailed: "A local speech-recognition chunk failed."
    case .recognitionTimedOut: "A local speech-recognition chunk timed out."
    case .cancelled: "Local speech recognition was cancelled."
    }
  }
}

nonisolated enum AudioSpeechAuthorizationPolicy {
  static func error(
    for status: SFSpeechRecognizerAuthorizationStatus
  ) -> AudioTranscriberError? {
    switch status {
    case .authorized:
      return nil
    case .denied:
      return .authorizationDenied
    case .restricted:
      return .authorizationRestricted
    case .notDetermined:
      return .authorizationDenied
    @unknown default:
      return .authorizationDenied
    }
  }
}

nonisolated protocol LocalAudioRecognitionEngine: Sendable {
  func recognizeChunk(
    at url: URL,
    language: AudioRecordingLanguage
  ) async throws -> AudioSpeechChunkResult
}

/// The system permission API has no async cancellation or timeout contract.
/// Keep it behind a tiny injectable requester so the bridge can own the
/// continuation exactly-once state and tests can exercise every callback race
/// without presenting a real permission sheet.
nonisolated protocol SpeechAuthorizationRequester: Sendable {
  func requestAuthorization(
    _ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
  )
}

nonisolated struct SystemSpeechAuthorizationRequester: SpeechAuthorizationRequester {
  func requestAuthorization(
    _ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
  ) {
    SFSpeechRecognizer.requestAuthorization(handler)
  }
}

nonisolated final class SpeechAuthorizationContinuationState: @unchecked Sendable {
  private let lock = NSLock()
  private var didFinish = false
  private var continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Error>?
  private var timeoutTask: Task<Void, Never>?
  let timeoutSeconds: TimeInterval

  init(timeoutSeconds: TimeInterval) {
    self.timeoutSeconds = timeoutSeconds.isFinite
      ? min(3_600, max(0.001, timeoutSeconds))
      : 120
  }

  func installContinuation(
    _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Error>
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !didFinish else { return false }
    self.continuation = continuation
    return true
  }

  func installTimeoutTask(_ timeoutTask: Task<Void, Never>) {
    lock.lock()
    let shouldCancel = didFinish
    if !shouldCancel { self.timeoutTask = timeoutTask }
    lock.unlock()
    if shouldCancel { timeoutTask.cancel() }
  }

  func startTimeout() {
    let timeoutTask = Task { [state = self] in
      let nanoseconds = UInt64(state.timeoutSeconds * 1_000_000_000)
      do {
        try await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled else { return }
        state.finish(throwing: AudioTranscriberError.authorizationTimedOut)
      } catch {
        // Cancellation of the timeout task is the normal callback/cancel path.
      }
    }
    installTimeoutTask(timeoutTask)
  }

  func finish(returning status: SFSpeechRecognizerAuthorizationStatus) {
    finish { continuation in
      continuation.resume(returning: status)
    }
  }

  func finish(throwing error: Error) {
    finish { continuation in
      continuation.resume(throwing: error)
    }
  }

  func cancel() {
    finish(throwing: AudioTranscriberError.cancelled)
  }

  private func finish(
    _ resume: (CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Error>) -> Void
  ) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    let continuation = self.continuation
    self.continuation = nil
    let timeoutTask = self.timeoutTask
    self.timeoutTask = nil
    lock.unlock()
    timeoutTask?.cancel()
    if let continuation { resume(continuation) }
  }
}

/// Cancellation-aware async facade for SFSpeechRecognizer.requestAuthorization.
/// A late system callback is harmless after cancellation or timeout.
nonisolated final class SpeechAuthorizationBridge: @unchecked Sendable {
  private let requester: any SpeechAuthorizationRequester
  private let timeoutSeconds: TimeInterval

  init(
    requester: any SpeechAuthorizationRequester = SystemSpeechAuthorizationRequester(),
    timeoutSeconds: TimeInterval = 120
  ) {
    self.requester = requester
    self.timeoutSeconds = timeoutSeconds.isFinite
      ? min(3_600, max(0.001, timeoutSeconds))
      : 120
  }

  func requestAuthorization() async throws -> SFSpeechRecognizerAuthorizationStatus {
    let state = SpeechAuthorizationContinuationState(timeoutSeconds: timeoutSeconds)
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        guard state.installContinuation(continuation) else {
          continuation.resume(throwing: AudioTranscriberError.cancelled)
          return
        }
        if Task.isCancelled {
          state.cancel()
          return
        }
        state.startTimeout()
        requester.requestAuthorization { status in
          state.finish(returning: status)
        }
      }
    }, onCancel: {
      state.cancel()
    })
  }
}

/// Speech.framework implementation.  This is kept behind a small protocol so
/// all ID/timestamp/merge behavior can be tested without invoking permission
/// prompts or requiring a speech model in CI.
nonisolated final class SpeechFrameworkAudioRecognitionEngine: @unchecked Sendable,
  LocalAudioRecognitionEngine {
  private let fileManager: FileManager
  private let recognitionTimeoutSeconds: TimeInterval
  private let authorizationBridge: SpeechAuthorizationBridge

  init(
    fileManager: FileManager = .default,
    recognitionTimeoutSeconds: TimeInterval = 120,
    authorizationTimeoutSeconds: TimeInterval = 120,
    authorizationRequester: any SpeechAuthorizationRequester = SystemSpeechAuthorizationRequester()
  ) {
    self.fileManager = fileManager
    self.recognitionTimeoutSeconds = recognitionTimeoutSeconds.isFinite
      ? min(3_600, max(1, recognitionTimeoutSeconds))
      : 120
    self.authorizationBridge = SpeechAuthorizationBridge(
      requester: authorizationRequester,
      timeoutSeconds: authorizationTimeoutSeconds
    )
  }

  func recognizeChunk(
    at url: URL,
    language: AudioRecordingLanguage
  ) async throws -> AudioSpeechChunkResult {
    guard fileManager.fileExists(atPath: url.path) else {
      throw AudioTranscriberError.sourceNotReadable
    }
    if Task.isCancelled { throw AudioTranscriberError.cancelled }
    let authorization: SFSpeechRecognizerAuthorizationStatus
    if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
      do {
        authorization = try await authorizationBridge.requestAuthorization()
      } catch is CancellationError {
        throw AudioTranscriberError.cancelled
      }
    } else {
      authorization = SFSpeechRecognizer.authorizationStatus()
    }
    if let authorizationError = AudioSpeechAuthorizationPolicy.error(for: authorization) {
      throw authorizationError
    }
    if Task.isCancelled { throw AudioTranscriberError.cancelled }

    guard let recognizer = SFSpeechRecognizer(locale: language.recognizerLocale) else {
      throw AudioTranscriberError.recognizerUnavailable
    }
    guard recognizer.isAvailable else {
      throw AudioTranscriberError.speechUnavailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw AudioTranscriberError.onDeviceModelUnavailable
    }

    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    if #available(macOS 13.0, *) {
      request.addsPunctuation = true
    }

    let state = SpeechRecognitionContinuationState<AudioSpeechChunkResult>(
      timeoutSeconds: recognitionTimeoutSeconds
    )
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        guard state.installContinuation(continuation) else { return }
        let task = recognizer.recognitionTask(with: request) { result, error in
          if let error {
            state.finish(throwing: Self.mapRecognitionError(error))
            return
          }
          guard let result, result.isFinal else { return }
          let transcription = result.bestTranscription
          let words = transcription.segments.enumerated().map { index, segment in
            AudioTranscriptWord(
              text: segment.substring,
              startTime: segment.timestamp,
              duration: segment.duration,
              source: .mixed,
              speaker: .unknown,
              chunkIndex: 0,
              ordinal: index
            )
          }
          let start = words.map(\.startTime).min() ?? 0
          let end = words.map(\.endTime).max() ?? start
          let segment = AudioTranscriptSegment(
            text: transcription.formattedString,
            startTime: start,
            duration: max(0, end - start),
            source: .mixed,
            speaker: .unknown,
            words: words,
            chunkIndex: 0,
            ordinal: 0
          )
          state.finish(returning: AudioSpeechChunkResult(segments: [segment]))
        }
        state.installTask(task)
        state.startTimeout()
      }
    }, onCancel: {
      state.cancel()
    })
  }

  private static func mapRecognitionError(_ error: Error) -> AudioTranscriberError {
    if error is CancellationError { return .cancelled }
    return .recognitionFailed
  }
}

private final class AssetExportCancellationBox: @unchecked Sendable {
  let exporter: AVAssetExportSession

  init(exporter: AVAssetExportSession) {
    self.exporter = exporter
  }
}

nonisolated final class SpeechRecognitionContinuationState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var didFinish = false
  private var continuation: CheckedContinuation<Value, Error>?
  private var terminalResume: ((CheckedContinuation<Value, Error>) -> Void)?
  private var task: SFSpeechRecognitionTask?
  private var timeoutTask: Task<Void, Never>?
  let timeoutSeconds: TimeInterval

  init(timeoutSeconds: TimeInterval) {
    self.timeoutSeconds = timeoutSeconds.isFinite
      ? min(3_600, max(0.001, timeoutSeconds))
      : 120
  }

  func installContinuation(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
    lock.lock()
    guard !didFinish else {
      let resume = terminalResume
      lock.unlock()
      resume?(continuation)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func installTask(_ task: SFSpeechRecognitionTask) {
    lock.lock()
    let shouldCancel = didFinish
    if !shouldCancel { self.task = task }
    lock.unlock()
    if shouldCancel { task.cancel() }
  }

  func installTimeoutTask(_ timeoutTask: Task<Void, Never>) {
    lock.lock()
    let shouldCancel = didFinish
    if !shouldCancel { self.timeoutTask = timeoutTask }
    lock.unlock()
    if shouldCancel { timeoutTask.cancel() }
  }

  func startTimeout() {
    let timeoutTask = Task.detached { [state = self] in
      let nanoseconds = UInt64(state.timeoutSeconds * 1_000_000_000)
      do {
        try await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled else { return }
        state.finish(throwing: AudioTranscriberError.recognitionTimedOut)
      } catch {
        // Cancellation of the timeout task is the normal success path.
      }
    }
    installTimeoutTask(timeoutTask)
  }

  func finish(returning value: Value) {
    finish { continuation in
      continuation.resume(returning: value)
    }
  }

  func finish(throwing error: Error) {
    finish { continuation in
      continuation.resume(throwing: error)
    }
  }

  func cancel() {
    finish { continuation in
      continuation.resume(throwing: AudioTranscriberError.cancelled)
    }
  }

  private func finish(
    _ resume: @escaping (CheckedContinuation<Value, Error>) -> Void
  ) {
    lock.lock()
    guard !didFinish else { lock.unlock(); return }
    didFinish = true
    terminalResume = resume
    let continuation = self.continuation
    self.continuation = nil
    let task = self.task
    self.task = nil
    let timeoutTask = self.timeoutTask
    self.timeoutTask = nil
    lock.unlock()
    task?.cancel()
    timeoutTask?.cancel()
    if let continuation { resume(continuation) }
  }
}

/// Sequentially exports bounded media chunks, recognizes one chunk at a time,
/// deletes each temporary media file, then performs a stable timeline merge.
nonisolated final class LocalAudioTranscriber: @unchecked Sendable {
  let chunkDurationSeconds: TimeInterval

  private let engine: any LocalAudioRecognitionEngine
  private let fileManager: FileManager

  init(
    engine: any LocalAudioRecognitionEngine = SpeechFrameworkAudioRecognitionEngine(),
    chunkDurationSeconds: TimeInterval = AudioTranscriptionChunkPlanner.defaultChunkDurationSeconds,
    fileManager: FileManager = .default
  ) {
    self.engine = engine
    self.chunkDurationSeconds = chunkDurationSeconds
    self.fileManager = fileManager
  }

  func transcribe(
    sources: [AudioTranscriptionSourceInput],
    language: AudioRecordingLanguage = .auto,
    processingDirectory: URL? = nil,
    sessionID: UUID? = nil
  ) async throws -> AudioRawTranscript {
    guard !sources.isEmpty else { throw AudioTranscriberError.noAudioSource }
    guard Set(sources.map(\.source)).count == sources.count else {
      throw AudioTranscriberError.sourceNotReadable
    }
    guard chunkDurationSeconds.isFinite, chunkDurationSeconds > 0 else {
      throw AudioTranscriptionChunkPlannerError.invalidChunkDuration
    }
    let temporaryRoot = try makeTemporaryRoot(processingDirectory: processingDirectory)
    defer { try? fileManager.removeItem(at: temporaryRoot) }
    var mergedSegments: [AudioTranscriptSegment] = []

    // A fixed source order plus a final timestamp sort makes a repeated run
    // deterministic even if the caller supplied a dictionary-derived array.
    for sourceInput in sources.sorted(by: { $0.source.mergeOrder < $1.source.mergeOrder }) {
      try checkCancellation()
      let duration = try await sourceDuration(for: sourceInput)
      let chunks = try AudioTranscriptionChunkPlanner.plan(
        durationSeconds: duration,
        chunkDurationSeconds: chunkDurationSeconds
      )
      for chunk in chunks {
        try checkCancellation()
        let chunkURL = temporaryRoot.appendingPathComponent(
          "chunk-\(sourceInput.source.rawValue)-\(chunk.index).m4a",
          isDirectory: false
        )
        defer { try? fileManager.removeItem(at: chunkURL) }
        try await exportChunk(
          from: sourceInput.url,
          to: chunkURL,
          startTime: chunk.startTime,
          duration: chunk.duration
        )
        let localResult: AudioSpeechChunkResult
        do {
          localResult = try await engine.recognizeChunk(at: chunkURL, language: language)
        } catch is CancellationError {
          throw AudioTranscriberError.cancelled
        }
        let normalized = normalize(
          localResult.segments,
          source: sourceInput.source,
          chunk: chunk
        )
        mergedSegments.append(contentsOf: normalized)
      }
    }

    guard !mergedSegments.isEmpty else {
      throw AudioTranscriberError.emptyRecognitionResult
    }
    mergedSegments.sort(by: Self.timelineSort)
    return AudioRawTranscript(
      sessionID: sessionID,
      language: language,
      segments: mergedSegments
    )
  }

  private func makeTemporaryRoot(processingDirectory: URL?) throws -> URL {
    if let processingDirectory {
      let normalized = processingDirectory.standardizedFileURL
      guard processingDirectory.resolvingSymlinksInPath().standardizedFileURL == normalized else {
        throw AudioTranscriberError.exportFailed
      }
    }
    let root = (processingDirectory.map {
      $0
        .appendingPathComponent(AudioProcessingTaskStore.chunksDirectoryName, isDirectory: true)
        .appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
    } ?? fileManager.temporaryDirectory
      .appendingPathComponent("ShotPaste-Audio-Processing-\(UUID().uuidString)", isDirectory: true))
      .standardizedFileURL
    do {
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      throw AudioTranscriberError.exportFailed
    }
    return root
  }

  private func sourceDuration(for input: AudioTranscriptionSourceInput) async throws -> TimeInterval {
    if let duration = input.durationSeconds,
       duration.isFinite,
       duration > 0 {
      return duration
    }
    if input.durationSeconds != nil {
      throw AudioTranscriberError.sourceDurationUnavailable
    }
    guard fileManager.fileExists(atPath: input.url.path) else {
      throw AudioTranscriberError.sourceNotReadable
    }
    let asset = AVURLAsset(url: input.url)
    let duration: TimeInterval
    do {
      duration = try await asset.load(.duration).seconds
    } catch {
      throw AudioTranscriberError.sourceDurationUnavailable
    }
    guard duration.isFinite, duration > 0 else {
      throw AudioTranscriberError.sourceDurationUnavailable
    }
    return duration
  }

  private func exportChunk(
    from sourceURL: URL,
    to destinationURL: URL,
    startTime: TimeInterval,
    duration: TimeInterval
  ) async throws {
    guard fileManager.fileExists(atPath: sourceURL.path) else {
      throw AudioTranscriberError.sourceNotReadable
    }
    guard sourceURL.resolvingSymlinksInPath().standardizedFileURL
      == sourceURL.standardizedFileURL else {
      throw AudioTranscriberError.sourceNotReadable
    }
    let asset = AVURLAsset(url: sourceURL)
    guard let exporter = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetAppleM4A
    ) else {
      throw AudioTranscriberError.exportFailed
    }
    try? fileManager.removeItem(at: destinationURL)
    exporter.outputURL = destinationURL
    exporter.outputFileType = .m4a
    exporter.timeRange = CMTimeRange(
      start: CMTime(seconds: startTime, preferredTimescale: 600),
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
    let exportBox = AssetExportCancellationBox(exporter: exporter)

    await withTaskCancellationHandler(operation: {
      await exportBox.exporter.export()
    }, onCancel: {
      exportBox.exporter.cancelExport()
    })
    if Task.isCancelled || exporter.status == .cancelled {
      throw AudioTranscriberError.cancelled
    }
    guard exporter.status == .completed else {
      throw AudioTranscriberError.exportFailed
    }
    guard fileManager.fileExists(atPath: destinationURL.path),
          let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path),
          let size = attributes[.size] as? NSNumber,
          size.int64Value > 0 else {
      throw AudioTranscriberError.exportFailed
    }
    let exportedAsset = AVURLAsset(url: destinationURL)
    do {
      let exportedDuration = try await exportedAsset.load(.duration).seconds
      let audioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
      let videoTracks = try await exportedAsset.loadTracks(withMediaType: .video)
      guard exportedDuration.isFinite,
            exportedDuration > 0,
            !audioTracks.isEmpty,
            videoTracks.isEmpty else {
        throw AudioTranscriberError.exportFailed
      }
    } catch let error as AudioTranscriberError {
      throw error
    } catch {
      throw AudioTranscriberError.exportFailed
    }
  }

  private func normalize(
    _ segments: [AudioTranscriptSegment],
    source: AudioRecordingSource,
    chunk: AudioTranscriptionChunk
  ) -> [AudioTranscriptSegment] {
    var result: [AudioTranscriptSegment] = []
    var wordOrdinal = 0
    for (segmentIndex, segment) in segments.enumerated() {
      let sourceWords = segment.words.isEmpty
        ? [AudioTranscriptWord(
            text: segment.text,
            startTime: segment.startTime,
            duration: segment.duration,
            source: source,
            speaker: source.speakerRole,
            chunkIndex: chunk.index,
            ordinal: segmentIndex
          )]
        : segment.words
      let words = sourceWords.map { word in
        defer { wordOrdinal += 1 }
        return AudioTranscriptWord(
          text: word.text,
          startTime: chunk.startTime + max(0, word.startTime),
          duration: word.duration,
          source: source,
          speaker: source.speakerRole,
          chunkIndex: chunk.index,
          ordinal: wordOrdinal
        )
      }
      let start = chunk.startTime + max(0, segment.startTime)
      let end = max(
        start + max(0, segment.duration),
        words.map(\.endTime).max() ?? start
      )
      let text = segment.text.isEmpty ? words.map(\.text).joined(separator: " ") : segment.text
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      result.append(AudioTranscriptSegment(
        text: text,
        startTime: start,
        duration: max(0, end - start),
        source: source,
        speaker: source.speakerRole,
        words: words,
        chunkIndex: chunk.index,
        ordinal: segmentIndex
      ))
    }
    return result
  }

  private func checkCancellation() throws {
    if Task.isCancelled { throw AudioTranscriberError.cancelled }
  }

  private static func timelineSort(
    _ lhs: AudioTranscriptSegment,
    _ rhs: AudioTranscriptSegment
  ) -> Bool {
    if abs(lhs.startTime - rhs.startTime) > 0.000001 {
      return lhs.startTime < rhs.startTime
    }
    if lhs.source.mergeOrder != rhs.source.mergeOrder {
      return lhs.source.mergeOrder < rhs.source.mergeOrder
    }
    return lhs.id < rhs.id
  }
}
