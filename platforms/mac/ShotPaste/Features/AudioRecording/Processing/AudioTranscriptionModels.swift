//
//  AudioTranscriptionModels.swift
//  ShotPaste
//
//  Durable, metadata-only models shared by local transcription and local
//  language-model processing.  None of these values contain an audio/video
//  URL; media paths are kept in the task store as session-relative paths.
//

import CryptoKit
import Foundation

/// Languages exposed by the audio transcription feature.  `auto` delegates
/// the locale choice to the current macOS locale.  Speech.framework does not
/// expose a local language-detection API, so automatic mode intentionally
/// means "use the current recognizer locale" rather than guessing online.
nonisolated enum AudioRecordingLanguage: String, CaseIterable, Codable, Sendable {
  case auto
  case en
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case ja
  case ko
  case de
  case es
  case fr
  case ru
  case vi

  // Source-compatible spellings for callers that mirror locale identifiers.
  static let zh_Hans = Self.zhHans
  static let zh_Hant = Self.zhHant

  /// The explicit locale for this language.  Automatic mode has no persisted
  /// locale and is resolved only at recognition time.
  var locale: Locale? {
    guard self != .auto else { return nil }
    return Locale(identifier: rawValue)
  }

  var localeIdentifier: String? { locale?.identifier }

  var recognizerLocale: Locale { locale ?? Locale.current }

  init(locale: Locale) {
    let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
    let lowercased = identifier.lowercased()
    if lowercased.hasPrefix("zh-hant") {
      self = .zhHant
    } else if lowercased.hasPrefix("zh") {
      self = .zhHans
    } else if let language = Self.allCases.first(where: {
      $0 != .auto && lowercased == $0.rawValue.lowercased()
    }) {
      self = language
    } else {
      self = .auto
    }
  }
}

nonisolated enum AudioOrganizationTemplate: String, CaseIterable, Codable, Sendable {
  case interviewQA
  case generalNotes
  case transcriptOnly
}

nonisolated enum AudioProcessingTaskStage: String, CaseIterable, Codable, Sendable {
  case saving
  case transcribing
  case polishing
  case organizing
  case completed
  case failed
  case waitingForModel
  case cancelled

  var isTerminal: Bool {
    self == .completed || self == .cancelled
  }

  /// A failed task remains in the scan set.  It contains only a short error
  /// code/message and can be restarted without touching the original media.
  var isRecoverable: Bool {
    !isTerminal
  }
}

typealias AudioProcessingStage = AudioProcessingTaskStage

/// The user-facing speaker role is deliberately separate from the physical
/// track.  A mixed track cannot prove who spoke, so it always maps to unknown.
nonisolated enum AudioTranscriptSpeakerRole: String, CaseIterable, Codable, Sendable {
  case me
  case other
  case unknown

  static let interviewer = Self.me
  static let candidate = Self.other

  var defaultLabel: String {
    switch self {
    case .me: "me/interviewer"
    case .other: "other/candidate"
    case .unknown: "unknown"
    }
  }
}

typealias AudioRecordingSpeakerRole = AudioTranscriptSpeakerRole

nonisolated enum AudioRecordingSource: String, CaseIterable, Codable, Sendable {
  case microphone
  case system
  case mixed

  var speakerRole: AudioTranscriptSpeakerRole {
    switch self {
    case .microphone: .me
    case .system: .other
    case .mixed: .unknown
    }
  }

  /// Ties in the merged timeline use a fixed source order.  This avoids
  /// depending on dictionary or filesystem enumeration order.
  var mergeOrder: Int {
    switch self {
    case .microphone: 0
    case .system: 1
    case .mixed: 2
    }
  }
}

typealias AudioRecordingSourceRole = AudioRecordingSource

nonisolated enum AudioTranscriptTimelineMerger {
  static func merge(_ segments: [AudioTranscriptSegment]) -> [AudioTranscriptSegment] {
    segments.sorted { lhs, rhs in
      if abs(lhs.startTime - rhs.startTime) > 0.000001 {
        return lhs.startTime < rhs.startTime
      }
      if lhs.source.mergeOrder != rhs.source.mergeOrder {
        return lhs.source.mergeOrder < rhs.source.mergeOrder
      }
      return lhs.id < rhs.id
    }
  }
}

typealias AudioTranscriptMerger = AudioTranscriptTimelineMerger

/// A timestamp computed from locally persisted segment IDs.  LLM output is
/// never trusted to supply a timestamp.
nonisolated struct AudioTranscriptTimeRange: Codable, Equatable, Sendable {
  let startTime: TimeInterval
  let endTime: TimeInterval

  init(startTime: TimeInterval, endTime: TimeInterval) {
    self.startTime = startTime
    self.endTime = max(startTime, endTime)
  }
}

nonisolated enum AudioTranscriptStableID {
  static func wordID(
    source: AudioRecordingSource,
    chunkIndex: Int,
    ordinal: Int,
    startTime: TimeInterval,
    duration: TimeInterval,
    text: String
  ) -> String {
    digest(
      kind: "word",
      source: source,
      chunkIndex: chunkIndex,
      ordinal: ordinal,
      startTime: startTime,
      duration: duration,
      text: text
    )
  }

  static func segmentID(
    source: AudioRecordingSource,
    chunkIndex: Int,
    ordinal: Int,
    startTime: TimeInterval,
    duration: TimeInterval,
    text: String
  ) -> String {
    digest(
      kind: "segment",
      source: source,
      chunkIndex: chunkIndex,
      ordinal: ordinal,
      startTime: startTime,
      duration: duration,
      text: text
    )
  }

  private static func digest(
    kind: String,
    source: AudioRecordingSource,
    chunkIndex: Int,
    ordinal: Int,
    startTime: TimeInterval,
    duration: TimeInterval,
    text: String
  ) -> String {
    // bitPattern makes the canonical representation independent of the
    // process locale and of floating-point formatting choices.
    let canonical = [
      kind,
      source.rawValue,
      String(chunkIndex),
      String(ordinal),
      String(startTime.bitPattern, radix: 16),
      String(duration.bitPattern, radix: 16),
      text
    ].joined(separator: "|")
    let hash = SHA256.hash(data: Data(canonical.utf8))
    return "\(kind)-" + hash.map { String(format: "%02x", $0) }.joined()
  }
}

nonisolated struct AudioTranscriptWord: Codable, Equatable, Hashable, Sendable, Identifiable {
  let id: String
  let text: String
  let startTime: TimeInterval
  let duration: TimeInterval
  let source: AudioRecordingSource
  let speaker: AudioTranscriptSpeakerRole

  init(
    id: String? = nil,
    text: String,
    startTime: TimeInterval,
    duration: TimeInterval,
    source: AudioRecordingSource,
    speaker: AudioTranscriptSpeakerRole? = nil,
    chunkIndex: Int = 0,
    ordinal: Int = 0
  ) {
    let safeStart = startTime.isFinite ? max(0, startTime) : 0
    let safeDuration = duration.isFinite ? max(0, duration) : 0
    self.id = id ?? AudioTranscriptStableID.wordID(
      source: source,
      chunkIndex: chunkIndex,
      ordinal: ordinal,
      startTime: safeStart,
      duration: safeDuration,
      text: text
    )
    self.text = text
    self.startTime = safeStart
    self.duration = safeDuration
    self.source = source
    self.speaker = speaker ?? source.speakerRole
  }

  var endTime: TimeInterval { startTime + duration }
  var timestamp: TimeInterval { startTime }
  var startTimeSeconds: TimeInterval { startTime }
  var durationSeconds: TimeInterval { duration }

  static func stableID(
    source: AudioRecordingSource,
    chunkIndex: Int,
    ordinal: Int,
    startTime: TimeInterval,
    duration: TimeInterval,
    text: String
  ) -> String {
    AudioTranscriptStableID.wordID(
      source: source,
      chunkIndex: chunkIndex,
      ordinal: ordinal,
      startTime: startTime,
      duration: duration,
      text: text
    )
  }
}

nonisolated struct AudioTranscriptSegment: Codable, Equatable, Hashable, Sendable, Identifiable {
  let id: String
  let text: String
  let startTime: TimeInterval
  let duration: TimeInterval
  let source: AudioRecordingSource
  let speaker: AudioTranscriptSpeakerRole
  let words: [AudioTranscriptWord]

  init(
    id: String? = nil,
    text: String,
    startTime: TimeInterval,
    duration: TimeInterval,
    source: AudioRecordingSource,
    speaker: AudioTranscriptSpeakerRole? = nil,
    words: [AudioTranscriptWord] = [],
    chunkIndex: Int = 0,
    ordinal: Int = 0
  ) {
    let safeStart = startTime.isFinite ? max(0, startTime) : 0
    let safeDuration = duration.isFinite ? max(0, duration) : 0
    self.id = id ?? AudioTranscriptStableID.segmentID(
      source: source,
      chunkIndex: chunkIndex,
      ordinal: ordinal,
      startTime: safeStart,
      duration: safeDuration,
      text: text
    )
    self.text = text
    self.startTime = safeStart
    self.duration = safeDuration
    self.source = source
    self.speaker = speaker ?? source.speakerRole
    self.words = words
  }

  var endTime: TimeInterval { startTime + duration }
  var timestamp: TimeInterval { startTime }
  var startTimeSeconds: TimeInterval { startTime }
  var durationSeconds: TimeInterval { duration }
  var speakerRole: AudioTranscriptSpeakerRole { speaker }

  static func stableID(
    source: AudioRecordingSource,
    chunkIndex: Int,
    ordinal: Int,
    startTime: TimeInterval,
    duration: TimeInterval,
    text: String
  ) -> String {
    AudioTranscriptStableID.segmentID(
      source: source,
      chunkIndex: chunkIndex,
      ordinal: ordinal,
      startTime: startTime,
      duration: duration,
      text: text
    )
  }
}

nonisolated struct AudioRawTranscript: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let sessionID: UUID?
  let language: AudioRecordingLanguage
  let segments: [AudioTranscriptSegment]
  let text: String
  let createdAt: Date

  init(
    sessionID: UUID? = nil,
    language: AudioRecordingLanguage = .auto,
    segments: [AudioTranscriptSegment],
    text: String? = nil,
    createdAt: Date = Date()
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.sessionID = sessionID
    self.language = language
    self.segments = segments
    self.text = text ?? segments.map(\.text).joined(separator: " ")
    self.createdAt = createdAt
  }

  var duration: TimeInterval {
    segments.map(\.endTime).max() ?? 0
  }

  var segmentIDs: Set<String> { Set(segments.map(\.id)) }
  var wordIDs: Set<String> { Set(segments.flatMap { $0.words.map(\.id) }) }
  var rawText: String { text }

  /// Raw data is the immutable boundary used by all downstream stages.  A
  /// malformed or empty transcript must never be promoted to a completed
  /// processing task, and word IDs must be unique just like segment IDs.
  var hasValidStructure: Bool {
    guard schemaVersion == Self.currentSchemaVersion,
          !segments.isEmpty,
          segmentIDs.count == segments.count else {
      return false
    }
    let words = segments.flatMap(\.words)
    guard wordIDs.count == words.count else { return false }
    return segments.allSatisfy { segment in
      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && segment.startTime.isFinite
        && segment.startTime >= 0
        && segment.duration.isFinite
        && segment.duration >= 0
        && segment.words.allSatisfy { word in
          word.startTime.isFinite
            && word.startTime >= 0
            && word.duration.isFinite
            && word.duration >= 0
            && !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
  }

  func timeRange(for segmentIDs: [String]) -> AudioTranscriptTimeRange? {
    let requested = Set(segmentIDs)
    guard !requested.isEmpty else { return nil }
    let matches = segments.filter { requested.contains($0.id) }
    guard matches.count == requested.count, let first = matches.map(\.startTime).min(),
          let last = matches.map(\.endTime).max() else {
      return nil
    }
    return AudioTranscriptTimeRange(startTime: first, endTime: last)
  }
}

nonisolated struct AudioPolishedTranscript: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let text: String
  let sourceSegmentIDs: [String]
  let createdAt: Date

  init(
    text: String,
    sourceSegmentIDs: [String],
    createdAt: Date = Date()
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.text = text
    self.sourceSegmentIDs = sourceSegmentIDs
    self.createdAt = createdAt
  }
}

nonisolated struct AudioInterviewQAItem: Codable, Equatable, Sendable {
  let question: String
  let answer: String
  let segmentIDs: [String]
}

nonisolated struct AudioGeneralNote: Codable, Equatable, Sendable {
  let text: String
  let segmentIDs: [String]
}

nonisolated struct AudioStructuredContent: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let template: AudioOrganizationTemplate
  let interviewQA: [AudioInterviewQAItem]
  let generalNotes: [AudioGeneralNote]
  let transcriptSegmentIDs: [String]
  let createdAt: Date

  init(
    template: AudioOrganizationTemplate,
    interviewQA: [AudioInterviewQAItem] = [],
    generalNotes: [AudioGeneralNote] = [],
    transcriptSegmentIDs: [String] = [],
    createdAt: Date = Date()
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.template = template
    self.interviewQA = interviewQA
    self.generalNotes = generalNotes
    self.transcriptSegmentIDs = transcriptSegmentIDs
    self.createdAt = createdAt
  }

  var referencedSegmentIDs: Set<String> {
    var result = Set(transcriptSegmentIDs)
    interviewQA.forEach { result.formUnion($0.segmentIDs) }
    generalNotes.forEach { result.formUnion($0.segmentIDs) }
    return result
  }

  func hasValidReferences(in raw: AudioRawTranscript) -> Bool {
    guard raw.hasValidStructure,
          referencedSegmentIDs.isSubset(of: raw.segmentIDs),
          interviewQA.allSatisfy({
            !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && !$0.segmentIDs.isEmpty
          }),
          generalNotes.allSatisfy({
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && !$0.segmentIDs.isEmpty
          }) else {
      return false
    }
    switch template {
    case .interviewQA:
      return !interviewQA.isEmpty
    case .generalNotes:
      return !generalNotes.isEmpty
    case .transcriptOnly:
      return interviewQA.isEmpty && generalNotes.isEmpty
    }
  }

  func timeRange(for segmentIDs: [String], in raw: AudioRawTranscript) -> AudioTranscriptTimeRange? {
    raw.timeRange(for: segmentIDs)
  }

  func timeRange(forQAAt index: Int, in raw: AudioRawTranscript) -> AudioTranscriptTimeRange? {
    guard interviewQA.indices.contains(index) else { return nil }
    return timeRange(for: interviewQA[index].segmentIDs, in: raw)
  }

  func timeRange(forNoteAt index: Int, in raw: AudioRawTranscript) -> AudioTranscriptTimeRange? {
    guard generalNotes.indices.contains(index) else { return nil }
    return timeRange(for: generalNotes[index].segmentIDs, in: raw)
  }
}

nonisolated struct AudioProcessingTaskProgress: Codable, Equatable, Sendable {
  var completedUnits: Int
  var totalUnits: Int

  init(completedUnits: Int = 0, totalUnits: Int = 0) {
    self.completedUnits = max(0, completedUnits)
    self.totalUnits = max(0, totalUnits)
  }

  var fraction: Double? {
    guard totalUnits > 0 else { return nil }
    return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
  }
}

nonisolated struct AudioProcessingTask: Codable, Equatable, Sendable, Identifiable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let id: UUID
  let sessionID: UUID
  let createdAt: Date
  var updatedAt: Date
  var stage: AudioProcessingTaskStage
  var language: AudioRecordingLanguage
  var template: AudioOrganizationTemplate
  var autoTranscribe: Bool
  var autoAI: Bool
  /// All values are relative to the session directory and are checked by the
  /// processing store before any media is opened.
  var sourcePaths: [AudioRecordingSource: String]
  var progress: AudioProcessingTaskProgress
  var cancellationRequested: Bool
  var errorCode: String?
  var errorMessage: String?

  init(
    id: UUID = UUID(),
    sessionID: UUID,
    language: AudioRecordingLanguage = .auto,
    template: AudioOrganizationTemplate = .transcriptOnly,
    autoTranscribe: Bool = true,
    autoAI: Bool = false,
    sourcePaths: [AudioRecordingSource: String] = [:],
    stage: AudioProcessingTaskStage = .saving,
    createdAt: Date = Date()
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.updatedAt = createdAt
    self.stage = stage
    self.language = language
    self.template = template
    self.autoTranscribe = autoTranscribe
    self.autoAI = autoAI
    self.sourcePaths = sourcePaths
    self.progress = AudioProcessingTaskProgress()
    self.cancellationRequested = false
    self.errorCode = nil
    self.errorMessage = nil
  }

  var reference: UUID { id }
  var isUnfinished: Bool { stage.isRecoverable }
  var sourceRelativePaths: [AudioRecordingSource: String] {
    get { sourcePaths }
    set { sourcePaths = newValue }
  }

  var hasSafeSourcePaths: Bool {
    sourcePaths.values.allSatisfy(Self.isSafeRelativePath)
  }

  static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.hasPrefix("~"),
          !path.contains("\\"),
          !path.contains("\0"),
          !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      return false
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty && components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
  }
}

nonisolated struct AudioProcessingHistoryRecord: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let taskID: UUID
  let sessionID: UUID
  let stage: AudioProcessingTaskStage
  let progress: AudioProcessingTaskProgress
  let rawTranscriptAvailable: Bool
  let polishedTranscriptAvailable: Bool
  let structuredContentAvailable: Bool
  let updatedAt: Date
  let errorCode: String?
  let errorMessage: String?

  init(
    task: AudioProcessingTask,
    rawTranscriptAvailable: Bool = false,
    polishedTranscriptAvailable: Bool = false,
    structuredContentAvailable: Bool = false,
    updatedAt: Date = Date()
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.taskID = task.id
    self.sessionID = task.sessionID
    self.stage = task.stage
    self.progress = task.progress
    self.rawTranscriptAvailable = rawTranscriptAvailable
    self.polishedTranscriptAvailable = polishedTranscriptAvailable
    self.structuredContentAvailable = structuredContentAvailable
    self.updatedAt = updatedAt
    self.errorCode = task.errorCode
    self.errorMessage = task.errorMessage
  }
}
