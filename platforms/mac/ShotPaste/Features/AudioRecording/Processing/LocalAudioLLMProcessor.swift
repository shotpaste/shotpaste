//
//  LocalAudioLLMProcessor.swift
//  ShotPaste
//
//  Local-only input construction and FoundationModels adapter.  The adapter
//  receives stable segment IDs and text only; URLs, media objects and prompt
//  bodies never enter the task/history models or diagnostic output.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated enum AudioLocalModelAvailability: Equatable, Sendable {
  case available
  case unavailable(String)
}

nonisolated enum AudioLocalLLMError: LocalizedError, Equatable, Sendable {
  case modelUnavailable(String)
  case invalidOutput
  case failed
  case cancelled

  var errorDescription: String? {
    switch self {
    case .modelUnavailable:
      "The on-device language model is not available yet."
    case .invalidOutput:
      "The on-device language model returned an invalid structured result."
    case .failed:
      "The on-device language-model operation failed."
    case .cancelled:
      "The on-device language-model operation was cancelled."
    }
  }
}

/// The only payload accepted by a local language model provider.  It has no
/// URL/path/media fields by construction.
nonisolated struct AudioLLMInputSegment: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let speaker: AudioTranscriptSpeakerRole
}

nonisolated struct AudioLLMInput: Codable, Equatable, Sendable {
  let template: AudioOrganizationTemplate
  let language: AudioRecordingLanguage
  let segments: [AudioLLMInputSegment]

  var segmentIDs: [String] { segments.map(\.id) }

  /// A bounded, ID-labelled representation used to construct a prompt.  A
  /// provider can choose another encoding, but it still receives this same
  /// metadata-only input value.
  var renderedText: String {
    segments.map { segment in
      "[\(segment.id)] [speaker:\(segment.speaker.rawValue)] \(segment.text)"
    }.joined(separator: "\n")
  }
}

nonisolated struct AudioLLMBatch: Equatable, Sendable {
  let index: Int
  let input: AudioLLMInput
}

/// Converts a raw transcript to bounded model batches.  The split is based on
/// persisted segments, never on an unbounded character copy of the full
/// recording.
nonisolated enum AudioLLMInputBuilder {
  static let defaultMaximumSegments = 80
  static let defaultMaximumCharacters = 12_000

  static func makeInput(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage? = nil,
    segmentIDs: Set<String>? = nil
  ) -> AudioLLMInput {
    let segments = raw.segments
      .filter { segmentIDs?.contains($0.id) ?? true }
      .sorted(by: timelineSort)
      .map {
        AudioLLMInputSegment(
          id: $0.id,
          text: $0.text,
          speaker: $0.speaker
        )
      }
    return AudioLLMInput(
      template: template,
      language: language ?? raw.language,
      segments: segments
    )
  }

  static func makeBatches(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage? = nil,
    segmentIDs: Set<String>? = nil,
    maximumSegments: Int = defaultMaximumSegments,
    maximumCharacters: Int = defaultMaximumCharacters
  ) -> [AudioLLMBatch] {
    let safeSegmentLimit = max(1, maximumSegments)
    let safeCharacterLimit = max(256, maximumCharacters)
    var batches: [AudioLLMBatch] = []
    var current: [AudioLLMInputSegment] = []
    var currentCharacters = 0

    func flush() {
      guard !current.isEmpty else { return }
      let batchInput = AudioLLMInput(
        template: template,
        language: language ?? raw.language,
        segments: current
      )
      batches.append(AudioLLMBatch(index: batches.count, input: batchInput))
      current.removeAll(keepingCapacity: true)
      currentCharacters = 0
    }

    let orderedSegments = raw.segments
      .filter { segmentIDs?.contains($0.id) ?? true }
      .sorted(by: timelineSort)
    for segment in orderedSegments {
      let inputSegment = AudioLLMInputSegment(
        id: segment.id,
        text: segment.text,
        speaker: segment.speaker
      )
      let segmentCharacters = inputSegment.id.count
        + inputSegment.text.count
        + inputSegment.speaker.rawValue.count
        + 20
      if !current.isEmpty,
         (current.count >= safeSegmentLimit
           || currentCharacters + segmentCharacters > safeCharacterLimit) {
        flush()
      }
      current.append(inputSegment)
      currentCharacters += segmentCharacters
    }
    flush()
    return batches
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

nonisolated struct AudioLLMStructuredBatch: Codable, Equatable, Sendable {
  let qa: [AudioInterviewQAItem]
  let notes: [AudioGeneralNote]

  init(
    qa: [AudioInterviewQAItem] = [],
    notes: [AudioGeneralNote] = []
  ) {
    self.qa = qa
    self.notes = notes
  }
}

nonisolated protocol LocalAudioLanguageModelProvider: Sendable {
  var availability: AudioLocalModelAvailability { get }

  func polish(input: AudioLLMInput) async throws -> String

  func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch
}

nonisolated struct AudioLLMProcessingResult: Equatable, Sendable {
  let polished: AudioPolishedTranscript
  let structured: AudioStructuredContent
}

/// Coordinates bounded polish/organize calls and validates every citation
/// before anything derived is persisted.
nonisolated final class LocalAudioLLMProcessor: @unchecked Sendable {
  private let provider: any LocalAudioLanguageModelProvider
  private let maximumSegmentsPerBatch: Int
  private let maximumCharactersPerBatch: Int

  init(
    provider: any LocalAudioLanguageModelProvider = SystemAudioLanguageModelProvider(),
    maximumSegmentsPerBatch: Int = AudioLLMInputBuilder.defaultMaximumSegments,
    maximumCharactersPerBatch: Int = AudioLLMInputBuilder.defaultMaximumCharacters
  ) {
    self.provider = provider
    self.maximumSegmentsPerBatch = max(1, maximumSegmentsPerBatch)
    self.maximumCharactersPerBatch = max(256, maximumCharactersPerBatch)
  }

  var availability: AudioLocalModelAvailability { provider.availability }

  func process(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage? = nil
  ) async throws -> AudioLLMProcessingResult {
    try await process(
      raw: raw,
      template: template,
      language: language,
      existingPolished: nil
    )
  }

  /// Processes a raw transcript while optionally reusing a durable polished
  /// checkpoint.  A crash after the polished artifact is written must not
  /// cause the next run to ask the model to polish the same transcript again.
  /// The raw transcript remains the only source of input IDs and text.
  func process(
    raw: AudioRawTranscript,
    template: AudioOrganizationTemplate,
    language: AudioRecordingLanguage? = nil,
    existingPolished: AudioPolishedTranscript?
  ) async throws -> AudioLLMProcessingResult {
    guard raw.hasValidStructure else {
      throw AudioLocalLLMError.invalidOutput
    }
    guard case .available = provider.availability else {
      if case .unavailable(let reason) = provider.availability {
        throw AudioLocalLLMError.modelUnavailable(reason)
      }
      throw AudioLocalLLMError.modelUnavailable("unavailable")
    }

    let allIDs = raw.segments.sorted {
      if abs($0.startTime - $1.startTime) > 0.000001 {
        return $0.startTime < $1.startTime
      }
      if $0.source.mergeOrder != $1.source.mergeOrder {
        return $0.source.mergeOrder < $1.source.mergeOrder
      }
      return $0.id < $1.id
    }.map(\.id)
    guard !allIDs.isEmpty else {
      throw AudioLocalLLMError.invalidOutput
    }

    let polishedText: String
    let batches = AudioLLMInputBuilder.makeBatches(
      raw: raw,
      template: template,
      language: language,
      maximumSegments: maximumSegmentsPerBatch,
      maximumCharacters: maximumCharactersPerBatch
    )
    var polishedParts: [String] = []
    var qa: [AudioInterviewQAItem] = []
    var notes: [AudioGeneralNote] = []

    if let existingPolished {
      let trimmed = existingPolished.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard existingPolished.schemaVersion == AudioPolishedTranscript.currentSchemaVersion,
            !trimmed.isEmpty,
            !existingPolished.sourceSegmentIDs.isEmpty,
            Set(existingPolished.sourceSegmentIDs).count == existingPolished.sourceSegmentIDs.count,
            Set(existingPolished.sourceSegmentIDs) == raw.segmentIDs else {
        throw AudioLocalLLMError.invalidOutput
      }
      polishedText = trimmed
    } else {
      for batch in batches {
        try Task.checkCancellation()
        let polished = try await provider.polish(input: batch.input)
        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
          polishedParts.append(trimmed)
        }
      }
      polishedText = polishedParts
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard !polishedText.isEmpty else {
      throw AudioLocalLLMError.invalidOutput
    }

    for batch in batches {
      try Task.checkCancellation()
      if template != .transcriptOnly {
        let structured = try await provider.organize(input: batch.input)
        let validIDs = Set(batch.input.segmentIDs)
        guard structured.qa.allSatisfy({
                !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.segmentIDs.isEmpty
                  && Set($0.segmentIDs).isSubset(of: validIDs)
              }),
              structured.notes.allSatisfy({
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && !$0.segmentIDs.isEmpty
                  && Set($0.segmentIDs).isSubset(of: validIDs)
              }) else {
          throw AudioLocalLLMError.invalidOutput
        }
        qa.append(contentsOf: structured.qa)
        notes.append(contentsOf: structured.notes)
      }
    }

    let structured = AudioStructuredContent(
      template: template,
      interviewQA: template == .interviewQA ? qa : [],
      generalNotes: template == .generalNotes ? notes : [],
      transcriptSegmentIDs: allIDs
    )
    guard template != .interviewQA || !qa.isEmpty,
          template != .generalNotes || !notes.isEmpty,
          structured.hasValidReferences(in: raw) else {
      throw AudioLocalLLMError.invalidOutput
    }
    return AudioLLMProcessingResult(
      polished: AudioPolishedTranscript(text: polishedText, sourceSegmentIDs: allIDs),
      structured: structured
    )
  }
}

/// FoundationModels adapter for macOS 26 and later.  The enclosing feature
/// remains deployable to macOS 13 because every framework call is isolated by
/// both `canImport` and an availability check.
nonisolated struct SystemAudioLanguageModelProvider: LocalAudioLanguageModelProvider {
  var availability: AudioLocalModelAvailability {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return .available
      case .unavailable(let reason):
        return .unavailable(Self.reasonDescription(reason))
      }
    }
    #endif
    return .unavailable("requires macOS 26")
  }

  func polish(input: AudioLLMInput) async throws -> String {
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, *) else {
      throw AudioLocalLLMError.modelUnavailable("requires macOS 26")
    }
    guard case .available = availability else {
      if case .unavailable(let reason) = availability {
        throw AudioLocalLLMError.modelUnavailable(reason)
      }
      throw AudioLocalLLMError.modelUnavailable("unavailable")
    }
    let prompt = """
    Polish the following transcript while preserving its meaning. Return only the polished transcript text. Do not add facts or timestamps.
    Each line begins with a stable segment ID; use the lines as source text only.
    \(input.renderedText)
    """
    do {
      let response = try await LanguageModelSession().respond(to: prompt)
      return response.content
    } catch is CancellationError {
      throw AudioLocalLLMError.cancelled
    } catch {
      throw AudioLocalLLMError.failed
    }
    #else
    throw AudioLocalLLMError.modelUnavailable("FoundationModels unavailable")
    #endif
  }

  func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch {
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, *) else {
      throw AudioLocalLLMError.modelUnavailable("requires macOS 26")
    }
    guard case .available = availability else {
      if case .unavailable(let reason) = availability {
        throw AudioLocalLLMError.modelUnavailable(reason)
      }
      throw AudioLocalLLMError.modelUnavailable("unavailable")
    }
    let prompt = """
    Organize this transcript into the requested template: \(input.template.rawValue). Return JSON only with this shape: {"qa":[{"question":"","answer":"","segmentIDs":["..."]}],"notes":[{"text":"","segmentIDs":["..."]}]}. Every item must cite one or more supplied segment IDs. Never invent IDs, timestamps, paths, or media references.
    \(input.renderedText)
    """
    do {
      let response = try await LanguageModelSession().respond(to: prompt)
      return try Self.decodeStructuredResponse(response.content)
    } catch is CancellationError {
      throw AudioLocalLLMError.cancelled
    } catch let error as AudioLocalLLMError {
      throw error
    } catch {
      throw AudioLocalLLMError.invalidOutput
    }
    #else
    throw AudioLocalLLMError.modelUnavailable("FoundationModels unavailable")
    #endif
  }

  static func decodeStructuredResponse(_ value: String) throws -> AudioLLMStructuredBatch {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let body: String
    if trimmed.hasPrefix("```") {
      let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
      body = lines.count >= 3
        ? lines.dropFirst().dropLast().joined(separator: "\n")
        : trimmed
    } else {
      body = trimmed
    }
    return try JSONDecoder().decode(
      AudioLLMStructuredBatch.self,
      from: Data(body.utf8)
    )
  }

  #if canImport(FoundationModels)
  @available(macOS 26.0, *)
  private static func reasonDescription(
    _ reason: SystemLanguageModel.Availability.UnavailableReason
  ) -> String {
    switch reason {
    case .deviceNotEligible: "device_not_eligible"
    case .appleIntelligenceNotEnabled: "apple_intelligence_disabled"
    case .modelNotReady: "model_not_ready"
    @unknown default: "model_unavailable"
    }
  }

  #endif
}
