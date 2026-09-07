import AVFoundation
import Foundation

nonisolated struct RecordingTranscriptionConfiguration: Codable, Sendable, Equatable {
  let account: VolcengineCloudAccount
  let sourceLanguage: AudioRecordingLanguage

  @MainActor
  static func current(defaults: UserDefaults = .standard) -> Self? {
    guard let account = VolcengineCloudAccounts.current(defaults: defaults),
          account.initialized, account.verified,
          (try? VolcengineCloudAccounts.credentials(for: account.id, defaults: defaults)) != nil else { return nil }
    let raw = defaults.string(forKey: PreferencesKeys.recordingTranscriptionSourceLanguage) ?? "auto"
    return Self(account: account, sourceLanguage: AudioRecordingLanguage(rawValue: raw) ?? .auto)
  }

  @MainActor
  static func current(for options: OneShotRecordingOptions, defaults: UserDefaults = .standard) -> Self? {
    guard options.shouldTranscribe, let configured = current(defaults: defaults) else { return nil }
    return Self(account: configured.account, sourceLanguage: options.transcriptionLanguage)
  }
}

nonisolated struct RecordingTranscript: Codable, Sendable, Equatable {
  let text: String
  var segments: [Segment] = []
  nonisolated struct Segment: Codable, Sendable, Equatable {
    let text: String
    let startTime: TimeInterval
    let duration: TimeInterval
    var speaker: String? = nil
    var cloudRequestID: UUID? = nil
  }
  var timedText: String {
    guard !segments.isEmpty else { return text }
    return segments.map { segment in
      func stamp(_ seconds: Double) -> String {
        let value = Int(seconds * 1000)
        return String(format: "%02d:%02d:%02d.%03d", value / 3600000,
                      value / 60000 % 60, value / 1000 % 60, value % 1000)
      }
      return "[\(stamp(segment.startTime)) → \(stamp(segment.startTime + segment.duration))] \(segment.text)"
    }.joined(separator: "\n")
  }

  func audioRawTranscript(language: AudioRecordingLanguage) -> AudioRawTranscript {
    AudioRawTranscript(language: language, segments: segments.enumerated().map { index, segment in
      AudioTranscriptSegment(text: segment.text, startTime: segment.startTime,
        duration: segment.duration, source: .mixed, ordinal: index)
    })
  }
}

nonisolated enum RecordingTranscriptionError: LocalizedError, Equatable {
  case invalidConfiguration
  case invalidRecording
  case noAudioTrack
  case audioTooLong
  case audioDecodeFailed
  case connectionFailed
  case service(code: String, message: String)
  case invalidResponse
  case responseTooLarge
  case emptyTranscript
  case timeout

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      L10n.CloudTranscription.invalidConfiguration
    case .invalidRecording:
      L10n.RecordingTranscription.invalidRecording
    case .noAudioTrack:
      L10n.RecordingTranscription.noAudioTrack
    case .audioTooLong:
      L10n.RecordingTranscription.audioTooLong
    case .audioDecodeFailed:
      L10n.RecordingTranscription.audioDecodeFailed
    case .connectionFailed:
      L10n.RecordingTranscription.connectionFailed
    case let .service(code, message):
      L10n.RecordingTranscription.serviceError(code, message)
    case .invalidResponse:
      L10n.RecordingTranscription.invalidResponse
    case .responseTooLarge:
      L10n.RecordingTranscription.responseTooLarge
    case .emptyTranscript:
      L10n.RecordingTranscription.emptyTranscript
    case .timeout:
      L10n.RecordingTranscription.timeout
    }
  }
}


nonisolated extension AudioRecordingLanguage {
  var fileASRLanguage: String? {
    switch self {
    case .auto: nil
    case .en: "en-US"
    case .zhHans, .zhHant: "zh-CN"
    case .ja: "ja-JP"
    case .ko: "ko-KR"
    case .de: "de-DE"
    case .es: "es-MX"
    case .fr: "fr-FR"
    case .ru: "ru-RU"
    case .vi: "vi-VN"
    }
  }
}

nonisolated struct VolcengineRecordingTranscriptionService: Sendable {
  func transcribe(recordingURL: URL, configuration: RecordingTranscriptionConfiguration,
                  automaticAI: Bool = false,
                  progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RecordingTranscript {
    let sourceID = try VolcengineAudioPreparation.checksum(recordingURL)
    let work = try await VolcengineRecordingWorkStore.shared.begin(url: recordingURL, configuration: configuration,
      checksum: sourceID, automaticAI: automaticAI)
    let historyID = await MainActor.run {
      CaptureHistoryStore.shared.record(forFilePath: recordingURL.path)?.id
    }
    if let historyID { await TranscriptionResultsRepository.shared.linkHistoryRecord(historyID, sourceURL: recordingURL) }
    if let transcript = work.transcript { return transcript }
    do {
    let credentials = try await VolcengineCloudAccounts.acquire(configuration.account.id)
    defer { Task { @MainActor in VolcengineCloudAccounts.release(configuration.account.id) } }
    let duration = try await VolcengineAudioPreparation.duration(recordingURL)
    var start = 0.0
    var segments: [RecordingTranscript.Segment] = []
    var texts: [String] = []
    while start < duration - 0.001 {
      try Task.checkCancellation()
      try await VolcengineRecordingWorkStore.shared.checkCancellation(work.id)
      progress(L10n.CloudTranscription.preparing)
      let part = try await VolcengineAudioPreparation.prepare(recordingURL, start: start, totalDuration: duration)
      defer { if part.temporary { try? FileManager.default.removeItem(at: part.url) } }
      let data = try Data(contentsOf: part.url, options: .mappedIfSafe)
      let stableID = sourceID + "|" + String(format: "%.3f", start)
      let result: VolcengineFileTranscript
      do {
      result = try await VolcengineCloudJobs.shared.transcribe(audio: data,
        account: configuration.account, credentials: credentials,
        language: configuration.sourceLanguage.fileASRLanguage, sourceID: stableID, parentWorkID: work.id, progress: progress)
      } catch let failure as VolcengineCloudFailure where failure.code == "20000003" {
        // A silent part is a terminal no-speech result, including a retained
        // receipt from an earlier run. Continue without uploading it again.
        start += part.duration
        continue
      }
      texts.append(result.text)
      segments += result.utterances.map { .init(text: $0.text,
        startTime: start + Double($0.startMilliseconds) / 1000,
        duration: Double($0.endMilliseconds - $0.startMilliseconds) / 1000,
        speaker: $0.speaker.map { stableID + ":" + $0 }, cloudRequestID: result.requestID) }
      start += part.duration
    }
    try await VolcengineRecordingWorkStore.shared.checkCancellation(work.id)
    let transcript = RecordingTranscript(text: texts.joined(separator: "\n"), segments: segments)
    try await VolcengineRecordingWorkStore.shared.finish(work.id, transcript: transcript)
    if work.automaticAI == true { try? await VolcengineRecordingWorkStore.shared.processAI(work.id) }
    return transcript
    } catch {
      try? await VolcengineRecordingWorkStore.shared.finish(work.id, transcript: nil,
        cancelled: error is CancellationError || Task.isCancelled)
      throw error
    }
  }
}
