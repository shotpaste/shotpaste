import Foundation

nonisolated struct VolcengineAudioRecognitionEngine: LocalAudioRecognitionEngine {
  var recognize: @Sendable (URL, AudioRecordingLanguage) async throws -> AudioSpeechChunkResult = Self.recognizeFile

  func recognizeChunk(at url: URL, language: AudioRecordingLanguage) async throws -> AudioSpeechChunkResult {
    try await recognize(url, language)
  }

  static func configured(_ configuration: RecordingTranscriptionConfiguration) -> Self {
    Self(recognize: { url, _ in
      try await recognizeFile(at: url, configuration: configuration)
    })
  }

  private static func recognizeFile(at url: URL, language: AudioRecordingLanguage) async throws -> AudioSpeechChunkResult {
    guard let stored = await RecordingTranscriptionConfiguration.current() else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    return try await recognizeFile(at: url,
      configuration: .init(account: stored.account, sourceLanguage: language))
  }

  private static func recognizeFile(at url: URL, configuration: RecordingTranscriptionConfiguration) async throws -> AudioSpeechChunkResult {
    let result = try await VolcengineRecordingTranscriptionService().transcribe(recordingURL: url,
      configuration: configuration)
    return AudioSpeechChunkResult(segments: result.segments.enumerated().map { index, segment in
      AudioTranscriptSegment(text: segment.text, startTime: segment.startTime,
        duration: segment.duration, source: .system, ordinal: index, recognitionSpeaker: segment.speaker,
        cloudRequestID: segment.cloudRequestID, providerVersion: VolcengineFileASRProtocol.resourceID)
    })
  }
}
