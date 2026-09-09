//
//  LocalAudioTranscriber.swift
//  ShotPaste
//
//  File-ASR transcription and source timeline normalization for saved audio.
//

import AVFoundation
import Foundation

nonisolated struct AudioTranscriptionChunk: Equatable, Sendable {
  let index: Int
  let startTime: TimeInterval
  let duration: TimeInterval

  var endTime: TimeInterval { startTime + duration }
}

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
  case sourceNotReadable
  case sourceDurationUnavailable
  case exportFailed
  case emptyRecognitionResult
  case recognitionFailed
  case cancelled

  var errorDescription: String? {
    switch self {
    case .noAudioSource: "No local audio source was supplied."
    case .sourceNotReadable: "The local audio source could not be read."
    case .sourceDurationUnavailable: "The local audio duration could not be read."
    case .exportFailed: "A local transcription chunk could not be prepared."
    case .emptyRecognitionResult: "Speech recognition returned no transcript."
    case .recognitionFailed: "A local speech-recognition chunk failed."
    case .cancelled: "Local speech recognition was cancelled."
    }
  }
}

/// Keep framework error identifiers, never descriptions, userInfo, paths, or text.
nonisolated enum AudioTranscriptionDiagnostics {
  static func errorContext(_ error: Error) -> [String: String] {
    let native = error as NSError
    var context = ["errorDomain": safeDomain(native.domain), "errorCode": String(native.code)]
    if let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError {
      context["underlyingDomain"] = safeDomain(underlying.domain)
      context["underlyingCode"] = String(underlying.code)
    }
    if let typed = error as? AudioTranscriberError {
      context["reason"] = String(describing: typed)
    }
    return context
  }

  private static func safeDomain(_ domain: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    guard domain.count <= 128, domain.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return "redacted"
    }
    return domain
  }
}

/// Recognizes saved source tracks; the file-ASR service owns bounded partitioning.
nonisolated final class LocalAudioTranscriber: @unchecked Sendable {
  private let engine: VolcengineAudioRecognitionEngine
  private let fileManager: FileManager

  init(engine: VolcengineAudioRecognitionEngine = VolcengineAudioRecognitionEngine(),
       fileManager: FileManager = .default) {
    self.engine = engine
    self.fileManager = fileManager
  }

  func transcribe(
    sources: [AudioTranscriptionSourceInput],
    language: AudioRecordingLanguage = .auto,
    processingDirectory: URL? = nil,
    sessionID: UUID? = nil,
    cloudConfiguration: RecordingTranscriptionConfiguration? = nil
  ) async throws -> AudioRawTranscript {
    let engine = cloudConfiguration.map(VolcengineAudioRecognitionEngine.configured) ?? self.engine
    guard !sources.isEmpty else { throw AudioTranscriberError.noAudioSource }
    guard Set(sources.map(\.source)).count == sources.count else {
      throw AudioTranscriberError.sourceNotReadable
    }
    if let processingDirectory,
       processingDirectory.resolvingSymlinksInPath().standardizedFileURL != processingDirectory.standardizedFileURL {
      throw AudioTranscriberError.sourceNotReadable
    }
    var mergedSegments: [AudioTranscriptSegment] = []
    for input in sources.sorted(by: { $0.source.mergeOrder < $1.source.mergeOrder }) {
      try checkCancellation()
      let duration = try await sourceDuration(for: input)
      let result = try await engine.recognizeChunk(at: input.url, language: language, sessionID: sessionID)
      try checkCancellation()
      mergedSegments += normalize(result.segments, source: input.source,
                                  chunk: .init(index: 0, startTime: 0, duration: duration))
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
        ordinal: segmentIndex, recognitionSpeaker: segment.recognitionSpeaker,
        cloudRequestID: segment.cloudRequestID, providerVersion: segment.providerVersion
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
