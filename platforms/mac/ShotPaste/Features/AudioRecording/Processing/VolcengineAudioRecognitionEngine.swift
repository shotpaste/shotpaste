import Foundation

nonisolated struct VolcengineAudioRecognitionEngine {
  var recognize: @Sendable (URL, AudioRecordingLanguage, UUID?) async throws -> AudioSpeechChunkResult = Self.recognizeFile

  func recognizeChunk(at url: URL, language: AudioRecordingLanguage, sessionID: UUID? = nil) async throws -> AudioSpeechChunkResult {
    try await recognize(url, language, sessionID)
  }

  static func configured(_ configuration: RecordingTranscriptionConfiguration) -> Self {
    Self(recognize: { url, _, sessionID in
      try await recognizeFile(at: url, configuration: configuration, sessionID: sessionID)
    })
  }

  private static func recognizeFile(at url: URL, language: AudioRecordingLanguage, sessionID: UUID? = nil) async throws -> AudioSpeechChunkResult {
    guard let stored = await RecordingTranscriptionConfiguration.current() else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    return try await recognizeFile(at: url,
      configuration: .init(account: stored.account, sourceLanguage: language), sessionID: sessionID)
  }

  private static func recognizeFile(at url: URL, configuration: RecordingTranscriptionConfiguration, sessionID: UUID?) async throws -> AudioSpeechChunkResult {
    let result = try await VolcengineRecordingTranscriptionService().transcribe(recordingURL: url,
      configuration: configuration, sourceKind: .audioTrack, audioSessionID: sessionID)
    return AudioSpeechChunkResult(segments: result.segments.enumerated().map { index, segment in
      AudioTranscriptSegment(text: segment.text, startTime: segment.startTime,
        duration: segment.duration, source: .system, ordinal: index, recognitionSpeaker: segment.speaker,
        cloudRequestID: segment.cloudRequestID, providerVersion: VolcengineFileASRProtocol.resourceID)
    })
  }
}
