//
//  AudioAdapterSession.swift
//  ShotPaste
//
//  Durable, metadata-only state for the audio-adapter recording pipeline.
//

import Foundation

/// The two independent inputs accepted by the audio adapter.
nonisolated enum AudioAdapterAudioSourceSelection: String, CaseIterable, Codable, Sendable {
  case none
  case system
  case microphone
  case systemAndMicrophone

  var capturesSystemAudio: Bool {
    self == .system || self == .systemAndMicrophone
  }

  var capturesMicrophone: Bool {
    self == .microphone || self == .systemAndMicrophone
  }

  var expectedTrackCount: Int {
    (capturesSystemAudio ? 1 : 0) + (capturesMicrophone ? 1 : 0)
  }
}

/// Roles are persisted independently from the AVAsset track array order.
/// The recorder's writer contract is used only to create the role -> stable
/// track-ID mapping at stop time; extraction then looks tracks up by ID.
nonisolated enum AudioAdapterTrackRole: String, CaseIterable, Codable, Sendable {
  case system
  case microphone
  case mixed

  static func roles(for selection: AudioAdapterAudioSourceSelection) -> [AudioAdapterTrackRole] {
    var result: [AudioAdapterTrackRole] = []
    if selection.capturesSystemAudio { result.append(.system) }
    if selection.capturesMicrophone { result.append(.microphone) }
    return result
  }
}

/// A small state machine is persisted after every externally visible step.
nonisolated enum AudioAdapterSessionStage: String, CaseIterable, Codable, Sendable {
  case created
  case preparing
  case recording
  case paused
  case stopping
  case extracting
  case awaitingHistory
  case awaitingTranscription
  case completed
  case failed
  case cancelled

  var isTerminal: Bool {
    switch self {
    case .completed, .cancelled:
      true
    default:
      false
    }
  }

  /// This is intentionally broad.  The recovery service additionally checks
  /// the manifest's terminal-damage bit before returning an item.
  var isRecoveryCandidate: Bool {
    switch self {
    case .created, .preparing, .recording, .paused, .stopping, .extracting,
         .awaitingHistory, .awaitingTranscription, .failed:
      true
    case .completed, .cancelled:
      false
    }
  }

  var requiresTrackIDMapping: Bool {
    switch self {
    case .extracting, .awaitingHistory, .awaitingTranscription, .completed:
      true
    default:
      false
    }
  }
}

/// The path fields are deliberately relative to the UUID session directory.
/// They are not URL strings, which makes it harder to accidentally persist a
/// path outside the private working area.
nonisolated struct AudioAdapterSessionPaths: Codable, Equatable, Sendable {
  var capture: String?
  var mixed: String?
  var system: String?
  var microphone: String?

  init(
    capture: String? = "capture.mov",
    mixed: String? = "mixed.m4a",
    system: String? = "system.m4a",
    microphone: String? = "microphone.m4a"
  ) {
    self.capture = capture
    self.mixed = mixed
    self.system = system
    self.microphone = microphone
  }

  static let empty = AudioAdapterSessionPaths(
    capture: nil,
    mixed: nil,
    system: nil,
    microphone: nil
  )

  var allValues: [String] {
    [capture, mixed, system, microphone].compactMap { $0 }
  }

  private enum CodingKeys: String, CodingKey {
    case capture
    case mixed
    case system
    case microphone
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    capture = try container.decodeIfPresent(String.self, forKey: .capture)
    mixed = try container.decodeIfPresent(String.self, forKey: .mixed)
    system = try container.decodeIfPresent(String.self, forKey: .system)
    microphone = try container.decodeIfPresent(String.self, forKey: .microphone)
  }
}

/// A capture segment allows display changes or recorder restarts to be
/// represented without changing the session identity.  `timelineStartSeconds`
/// is on one shared session timeline, so recovery gaps are retained and
/// overlaps are rejected rather than silently compressed.
nonisolated struct AudioAdapterCaptureSegment: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var sequence: Int
  var capturePath: String
  var timelineStartSeconds: Double
  var durationSeconds: Double?
  var trackRoles: [AudioAdapterTrackRole]
  var trackIDsByRole: [AudioAdapterTrackRole: Int32]
  var checksum: String?

  /// Compatibility spelling for callers that use the role-oriented name.
  var roleTrackIDs: [AudioAdapterTrackRole: Int32] {
    get { trackIDsByRole }
    set { trackIDsByRole = newValue }
  }

  init(
    id: UUID = UUID(),
    sequence: Int,
    capturePath: String,
    timelineStartSeconds: Double = 0,
    durationSeconds: Double? = nil,
    trackRoles: [AudioAdapterTrackRole],
    trackIDsByRole: [AudioAdapterTrackRole: Int32] = [:],
    checksum: String? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.capturePath = capturePath
    self.timelineStartSeconds = timelineStartSeconds
    self.durationSeconds = durationSeconds
    self.trackRoles = trackRoles
    self.trackIDsByRole = trackIDsByRole
    self.checksum = checksum
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case sequence
    case capturePath
    case timelineStartSeconds
    case durationSeconds
    case trackRoles
    case trackIDsByRole
    case roleTrackIDs
    case checksum
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    sequence = try container.decode(Int.self, forKey: .sequence)
    capturePath = try container.decode(String.self, forKey: .capturePath)
    timelineStartSeconds = try container.decodeIfPresent(
      Double.self,
      forKey: .timelineStartSeconds
    ) ?? 0
    durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
    trackRoles = try container.decodeIfPresent(
      [AudioAdapterTrackRole].self,
      forKey: .trackRoles
    ) ?? []
    trackIDsByRole = try container.decodeIfPresent(
      [AudioAdapterTrackRole: Int32].self,
      forKey: .trackIDsByRole
    ) ?? (try container.decodeIfPresent(
      [AudioAdapterTrackRole: Int32].self,
      forKey: .roleTrackIDs
    ) ?? [:])
    checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(sequence, forKey: .sequence)
    try container.encode(capturePath, forKey: .capturePath)
    try container.encode(timelineStartSeconds, forKey: .timelineStartSeconds)
    try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    try container.encode(trackRoles, forKey: .trackRoles)
    try container.encode(trackIDsByRole, forKey: .trackIDsByRole)
    try container.encodeIfPresent(checksum, forKey: .checksum)
  }
}

nonisolated struct AudioAdapterRecoverableError: Codable, Equatable, Sendable {
  var code: String
  var message: String
  var isRecoverable: Bool
  var recordedAt: Date

  init(
    code: String,
    message: String,
    isRecoverable: Bool = true,
    recordedAt: Date = Date()
  ) {
    self.code = code
    self.message = message
    self.isRecoverable = isRecoverable
    self.recordedAt = recordedAt
  }
}

/// JSON representation stored as `<session>/manifest.json`.
nonisolated struct AudioAdapterSessionManifest: Codable, Equatable, Sendable {
  /// Schema 1 manifests are explicitly migrated by the decoder.  Future
  /// versions are rejected so an older binary can never overwrite unknown
  /// state.
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var sessionID: UUID
  var stage: AudioAdapterSessionStage
  var startedAt: Date
  var updatedAt: Date
  var selectedAudioSources: AudioAdapterAudioSourceSelection
  var trackRoles: [AudioAdapterTrackRole]
  var internalPaths: AudioAdapterSessionPaths
  var finalPaths: AudioAdapterSessionPaths
  var checksums: [String: String]

  /// These are independent durable facts.  Extraction may only set the first
  /// one.  Store checked APIs set the latter two after the corresponding
  /// record/task has actually been persisted.
  var finalAudioValidated: Bool
  var finalAudioValidatedAt: Date?
  var historyPersisted: Bool
  var historyPersistedAt: Date?
  /// A reference is an opaque durable object identity, not a caller supplied
  /// label.  Keeping it typed prevents values such as "history:1" from being
  /// mistaken for a persisted history row.
  var historyRecordReference: UUID?
  var transcriptionTaskPersisted: Bool
  var transcriptionTaskPersistedAt: Date?
  var transcriptionTaskReference: UUID?

  /// Protected processing choices are written before stop so a crash after
  /// extraction can recover the user's language/template/AI selection even if
  /// the processing task file itself was not created yet.
  var processingLanguage: AudioRecordingLanguage?
  var processingTemplate: AudioOrganizationTemplate?
  var processingAutoTranscribe: Bool?
  var processingAutoAI: Bool?

  /// Kept as a durable compatibility/read-model bit.  It is only allowed to
  /// be true once all three gates are true and the stage is completed; Store
  /// never accepts a caller-provided value that violates that invariant.
  var canDeleteInternalVideo: Bool
  var retryCount: Int
  var recoverableError: AudioAdapterRecoverableError?
  var recoveryTerminal: Bool
  var segments: [AudioAdapterCaptureSegment]

  /// Roles that were actually delivered by every completed capture segment.
  /// Requested roles remain in `trackRoles`; this intersection is the only
  /// role set extraction and downstream persistence may trust.
  var completedSegments: [AudioAdapterCaptureSegment] {
    segments
      .filter { segment in
        guard let duration = segment.durationSeconds else { return false }
        return duration.isFinite && duration > 0
      }
      .sorted { $0.sequence < $1.sequence }
  }

  var effectiveCapturedTrackRoles: [AudioAdapterTrackRole] {
    let completed = completedSegments
    guard let first = completed.first else { return [] }
    let intersection = completed.dropFirst().reduce(Set(first.trackRoles)) {
      $0.intersection(Set($1.trackRoles))
    }
    return trackRoles.filter { intersection.contains($0) }
  }

  var missingRequestedTrackRoles: [AudioAdapterTrackRole] {
    let effective = Set(effectiveCapturedTrackRoles)
    return trackRoles.filter { !effective.contains($0) }
  }

  init(
    sessionID: UUID = UUID(),
    stage: AudioAdapterSessionStage = .created,
    startedAt: Date = Date(),
    selectedAudioSources: AudioAdapterAudioSourceSelection = .none,
    trackRoles: [AudioAdapterTrackRole]? = nil,
    internalPaths: AudioAdapterSessionPaths = AudioAdapterSessionPaths(),
    finalPaths: AudioAdapterSessionPaths = .empty,
    checksums: [String: String] = [:],
    finalAudioValidated: Bool = false,
    finalAudioValidatedAt: Date? = nil,
    historyPersisted: Bool = false,
    historyPersistedAt: Date? = nil,
    historyRecordReference: UUID? = nil,
    transcriptionTaskPersisted: Bool = false,
    transcriptionTaskPersistedAt: Date? = nil,
    transcriptionTaskReference: UUID? = nil,
    processingLanguage: AudioRecordingLanguage? = nil,
    processingTemplate: AudioOrganizationTemplate? = nil,
    processingAutoTranscribe: Bool? = nil,
    processingAutoAI: Bool? = nil,
    canDeleteInternalVideo: Bool = false,
    retryCount: Int = 0,
    recoverableError: AudioAdapterRecoverableError? = nil,
    recoveryTerminal: Bool = false,
    segments: [AudioAdapterCaptureSegment]? = nil
  ) {
    let roles = trackRoles ?? AudioAdapterTrackRole.roles(for: selectedAudioSources)
    let defaultSegment = AudioAdapterCaptureSegment(
      sequence: 0,
      capturePath: internalPaths.capture ?? "capture.mov",
      trackRoles: roles
    )

    self.schemaVersion = Self.currentSchemaVersion
    self.sessionID = sessionID
    self.stage = stage
    self.startedAt = startedAt
    self.updatedAt = startedAt
    self.selectedAudioSources = selectedAudioSources
    self.trackRoles = roles
    self.internalPaths = Self.normalizedInternalPaths(
      internalPaths,
      selectedAudioSources: selectedAudioSources
    )
    self.finalPaths = finalPaths
    self.checksums = checksums
    self.finalAudioValidated = finalAudioValidated
    self.finalAudioValidatedAt = finalAudioValidatedAt
    self.historyPersisted = historyPersisted
    self.historyPersistedAt = historyPersistedAt
    self.historyRecordReference = historyRecordReference
    self.transcriptionTaskPersisted = transcriptionTaskPersisted
    self.transcriptionTaskPersistedAt = transcriptionTaskPersistedAt
    self.transcriptionTaskReference = transcriptionTaskReference
    self.processingLanguage = processingLanguage
    self.processingTemplate = processingTemplate
    self.processingAutoTranscribe = processingAutoTranscribe
    self.processingAutoAI = processingAutoAI
    self.canDeleteInternalVideo = canDeleteInternalVideo
    self.retryCount = max(0, retryCount)
    self.recoverableError = recoverableError
    self.recoveryTerminal = recoveryTerminal
    self.segments = segments ?? [defaultSegment]
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sessionID
    case stage
    case startedAt
    case updatedAt
    case selectedAudioSources
    case trackRoles
    case internalPaths
    case finalPaths
    case checksums
    case finalAudioValidated
    case finalAudioValidatedAt
    case historyPersisted
    case historyPersistedAt
    case historyRecordReference
    case transcriptionTaskPersisted
    case transcriptionTaskPersistedAt
    case transcriptionTaskReference
    case processingLanguage
    case processingTemplate
    case processingAutoTranscribe
    case processingAutoAI
    case canDeleteInternalVideo
    case retryCount
    case recoverableError
    case recoveryTerminal
    case segments
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard version >= 1, version <= Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported future audio adapter schema \(version)."
      )
    }

    let decodedSessionID = try container.decode(UUID.self, forKey: .sessionID)
    let decodedStage = try container.decodeIfPresent(
      AudioAdapterSessionStage.self,
      forKey: .stage
    ) ?? .created
    let decodedStartedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
    let selected = try container.decodeIfPresent(
      AudioAdapterAudioSourceSelection.self,
      forKey: .selectedAudioSources
    ) ?? .none
    let roles = try container.decodeIfPresent(
      [AudioAdapterTrackRole].self,
      forKey: .trackRoles
    ) ?? AudioAdapterTrackRole.roles(for: selected)
    let paths = try container.decodeIfPresent(
      AudioAdapterSessionPaths.self,
      forKey: .internalPaths
    ) ?? AudioAdapterSessionPaths()
    let decodedFinalPaths = try container.decodeIfPresent(
      AudioAdapterSessionPaths.self,
      forKey: .finalPaths
    ) ?? .empty
    let decodedSegments = try container.decodeIfPresent(
      [AudioAdapterCaptureSegment].self,
      forKey: .segments
    ) ?? [AudioAdapterCaptureSegment(
      sequence: 0,
      capturePath: paths.capture ?? "capture.mov",
      trackRoles: roles
    )]

    schemaVersion = Self.currentSchemaVersion
    sessionID = decodedSessionID
    stage = decodedStage
    startedAt = decodedStartedAt
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? decodedStartedAt
    selectedAudioSources = selected
    trackRoles = roles
    internalPaths = Self.normalizedInternalPaths(paths, selectedAudioSources: selected)
    finalPaths = decodedFinalPaths
    checksums = try container.decodeIfPresent([String: String].self, forKey: .checksums) ?? [:]

    // v1 had one unsafe deletion bit but no proof for either downstream
    // persistence step.  Never promote that bit while migrating.
    finalAudioValidated = try container.decodeIfPresent(
      Bool.self,
      forKey: .finalAudioValidated
    ) ?? false
    finalAudioValidatedAt = try container.decodeIfPresent(
      Date.self,
      forKey: .finalAudioValidatedAt
    )
    historyPersisted = try container.decodeIfPresent(Bool.self, forKey: .historyPersisted) ?? false
    historyPersistedAt = try container.decodeIfPresent(Date.self, forKey: .historyPersistedAt)
    historyRecordReference = version >= Self.currentSchemaVersion
      ? try container.decodeIfPresent(UUID.self, forKey: .historyRecordReference)
      : try? container.decode(UUID.self, forKey: .historyRecordReference)
    transcriptionTaskPersisted = try container.decodeIfPresent(
      Bool.self,
      forKey: .transcriptionTaskPersisted
    ) ?? false
    transcriptionTaskPersistedAt = try container.decodeIfPresent(
      Date.self,
      forKey: .transcriptionTaskPersistedAt
    )
    transcriptionTaskReference = version >= Self.currentSchemaVersion
      ? try container.decodeIfPresent(UUID.self, forKey: .transcriptionTaskReference)
      : try? container.decode(UUID.self, forKey: .transcriptionTaskReference)
    processingLanguage = try container.decodeIfPresent(
      AudioRecordingLanguage.self,
      forKey: .processingLanguage
    )
    processingTemplate = try container.decodeIfPresent(
      AudioOrganizationTemplate.self,
      forKey: .processingTemplate
    )
    processingAutoTranscribe = try container.decodeIfPresent(
      Bool.self,
      forKey: .processingAutoTranscribe
    )
    processingAutoAI = try container.decodeIfPresent(
      Bool.self,
      forKey: .processingAutoAI
    )
    canDeleteInternalVideo = try container.decodeIfPresent(
      Bool.self,
      forKey: .canDeleteInternalVideo
    ) ?? false
    retryCount = max(0, try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0)
    recoverableError = try container.decodeIfPresent(
      AudioAdapterRecoverableError.self,
      forKey: .recoverableError
    )
    recoveryTerminal = try container.decodeIfPresent(Bool.self, forKey: .recoveryTerminal) ?? false
    segments = decodedSegments

    // A v1 manifest predates the three-gate protocol.  Even if an old JSON
    // file has been maliciously augmented with v2-looking fields, none of
    // those fields are evidence that the corresponding side effect happened.
    // Re-enter through the recoverable failure state so recovery can inspect
    // the MOV without ever opening a deletion gate.
    if version < Self.currentSchemaVersion {
      finalAudioValidated = false
      finalAudioValidatedAt = nil
      historyPersisted = false
      historyPersistedAt = nil
      historyRecordReference = nil
      transcriptionTaskPersisted = false
      transcriptionTaskPersistedAt = nil
      transcriptionTaskReference = nil
      canDeleteInternalVideo = false
      stage = .failed
      recoveryTerminal = false
      recoverableError = AudioAdapterRecoverableError(
        code: "schema_v1_migrated",
        message: "v1 audio adapter metadata requires recovery before outputs can be trusted",
        isRecoverable: true
      )
      updatedAt = max(updatedAt, Date())
    }
  }

  mutating func setStage(_ stage: AudioAdapterSessionStage, at date: Date = Date()) {
    self.stage = stage
    updatedAt = date
  }

  mutating func recordError(
    _ error: AudioAdapterRecoverableError,
    terminal: Bool = false,
    at date: Date = Date()
  ) {
    recoverableError = error
    recoveryTerminal = terminal
    updatedAt = date
    stage = .failed
    canDeleteInternalVideo = false
  }

  mutating func clearError(at date: Date = Date()) {
    recoverableError = nil
    recoveryTerminal = false
    updatedAt = date
  }

  mutating func incrementRetry(at date: Date = Date()) {
    retryCount += 1
    updatedAt = date
  }

  mutating func updateChecksum(_ checksum: String, for relativePath: String, at date: Date = Date()) {
    checksums[relativePath] = checksum
    updatedAt = date
  }

  mutating func updateSegment(_ segment: AudioAdapterCaptureSegment, at date: Date = Date()) {
    if let index = segments.firstIndex(where: { $0.id == segment.id }) {
      segments[index] = segment
    } else {
      segments.append(segment)
    }
    segments.sort { $0.sequence < $1.sequence }
    updatedAt = date
  }

  /// The persisted manifest must only carry paths that can be resolved within
  /// this session.  Store calls this before every write and on load.  File
  /// type/symlink checks that need a filesystem are performed by Store too.
  var hasSafeRelativePaths: Bool {
    guard hasValidSemanticInvariants else { return false }
    let values = internalPaths.allValues + finalPaths.allValues + segments.map(\.capturePath)
    return values.allSatisfy(Self.isSafeRelativePath)
      && checksums.keys.allSatisfy(Self.isSafeRelativePath)
  }

  var hasValidSemanticInvariants: Bool {
    guard schemaVersion == Self.currentSchemaVersion,
          retryCount >= 0,
          trackRoles == AudioAdapterTrackRole.roles(for: selectedAudioSources),
          !segments.isEmpty,
          !recoveryTerminal || stage == .failed else {
      return false
    }

    let capturePaths = segments.map(\.capturePath) + [internalPaths.capture].compactMap { $0 }
    guard capturePaths.allSatisfy(Self.isCaptureRelativePath) else { return false }
    let requestedRoleSet = Set(trackRoles)
    guard segments.allSatisfy({ segment in
      let actualRoleSet = Set(segment.trackRoles)
      let mappedRoleSet = Set(segment.trackIDsByRole.keys)
      let isCompleted = segment.durationSeconds != nil
      let hasValidDuration = segment.durationSeconds.map {
        $0.isFinite && $0 > 0
      } ?? true
      let unresolvedRolesAreValid = mappedRoleSet.isEmpty
        ? (segment.trackRoles.isEmpty || segment.trackRoles == trackRoles)
        : (!actualRoleSet.isEmpty
          && actualRoleSet.isSubset(of: requestedRoleSet)
          && mappedRoleSet == actualRoleSet)
      let completedRolesAreValid = !actualRoleSet.isEmpty
        && actualRoleSet.isSubset(of: requestedRoleSet)
        && mappedRoleSet == actualRoleSet
      return segment.sequence >= 0
        && Set(segment.trackRoles).count == segment.trackRoles.count
        && segment.timelineStartSeconds.isFinite
        && segment.timelineStartSeconds >= 0
        && hasValidDuration
        && Self.hasUniqueTrackIDs(segment.trackIDsByRole)
        && (isCompleted ? completedRolesAreValid : unresolvedRolesAreValid)
    }) else {
      return false
    }
    let sequences = segments.map(\.sequence)
    guard Set(sequences).count == sequences.count else { return false }
    let unresolved = segments.filter { $0.durationSeconds == nil }
    guard unresolved.count <= 1,
          unresolved.isEmpty || unresolved[0].sequence == sequences.max() else {
      return false
    }
    guard hasNonOverlappingTimeline else { return false }

    // A capture is private source media, never a final output.  It must not be
    // persisted in the output namespace where recovery/deletion could confuse
    // the two kinds of file.
    guard finalPaths.capture == nil else { return false }

    let declaredFinalValues = self.finalPaths.allValues
    let internalOutputValues = [
      internalPaths.mixed,
      internalPaths.system,
      internalPaths.microphone,
    ].compactMap { $0 }
    guard declaredFinalValues.allSatisfy(Self.isFinalRelativePath),
          Set(declaredFinalValues).count == declaredFinalValues.count,
          internalOutputValues.allSatisfy(Self.isFinalRelativePath),
          (declaredFinalValues.isEmpty
            || Set(internalOutputValues).isSubset(of: Set(declaredFinalValues))) else {
      return false
    }
    let requestedRoles = Set(trackRoles)
    let declaredRolePaths = [
      (AudioAdapterTrackRole.system, finalPaths.system),
      (AudioAdapterTrackRole.microphone, finalPaths.microphone),
      (AudioAdapterTrackRole.system, internalPaths.system),
      (AudioAdapterTrackRole.microphone, internalPaths.microphone),
    ]
    guard declaredRolePaths.allSatisfy({ entry in
      entry.1 == nil || requestedRoles.contains(entry.0)
    }) else { return false }
    if selectedAudioSources != .systemAndMicrophone {
      guard finalPaths.system == nil, finalPaths.microphone == nil,
            internalPaths.system == nil, internalPaths.microphone == nil else {
        return false
      }
    }
    let allFinalPathValues = Array(Set(declaredFinalValues + internalOutputValues))
    guard Set(capturePaths).isDisjoint(with: Set(allFinalPathValues)) else { return false }
    guard checksums.keys.allSatisfy(Self.isSafeRelativePath) else { return false }

    let sourceRoles = Set(trackRoles)
    for segment in segments {
      let mappedRoles = Set(segment.trackIDsByRole.keys)
      guard mappedRoles.isSubset(of: sourceRoles),
            Self.hasUniqueTrackIDs(segment.trackIDsByRole) else {
        return false
      }
      if segment.durationSeconds != nil,
         (mappedRoles.isEmpty || mappedRoles != Set(segment.trackRoles)) {
        return false
      }
    }
    if stage.requiresTrackIDMapping {
      // A failed/recovery boundary may still carry the newest unresolved
      // placeholder. Extraction remains authoritative and will reject it;
      // keeping the manifest loadable lets existing recovery diagnostics mark
      // the session without deleting the source MOV.
      guard !effectiveCapturedTrackRoles.isEmpty
        || (unresolved.count == 1 && !unresolved[0].trackRoles.isEmpty) else {
        return false
      }
    }

    if finalAudioValidated {
      guard finalAudioValidatedAt != nil,
            finalPaths.mixed != nil,
            !effectiveCapturedTrackRoles.isEmpty else {
        return false
      }
      if effectiveCapturedTrackRoles.count == 2 {
        guard finalPaths.system != nil, finalPaths.microphone != nil else {
          return false
        }
      } else {
        guard finalPaths.system == nil, finalPaths.microphone == nil else {
          return false
        }
      }
    }
    if historyPersisted {
      guard finalAudioValidated,
            historyPersistedAt != nil,
            historyRecordReference != nil else { return false }
    }
    if transcriptionTaskPersisted {
      guard historyPersisted,
            transcriptionTaskPersistedAt != nil,
            transcriptionTaskReference != nil else { return false }
    }

    switch stage {
    case .awaitingHistory:
      guard finalAudioValidated, !historyPersisted else { return false }
    case .awaitingTranscription:
      guard finalAudioValidated, historyPersisted, !transcriptionTaskPersisted else {
        return false
      }
    case .completed:
      guard finalAudioValidated, historyPersisted, transcriptionTaskPersisted else {
        return false
      }
    default:
      break
    }

    if canDeleteInternalVideo {
      guard finalAudioValidated, historyPersisted, transcriptionTaskPersisted,
            stage == .completed else { return false }
    }
    return true
  }

  /// Uses persisted durations when available. A segment without a duration is
  /// still allowed during recording, but once both sides are known an overlap
  /// is a manifest error rather than something extraction may silently flatten.
  var hasNonOverlappingTimeline: Bool {
    var previousEnd = 0.0
    var previousStart = 0.0
    for segment in segments.sorted(by: { $0.sequence < $1.sequence }) {
      if segment.timelineStartSeconds < previousStart - 0.001
        || segment.timelineStartSeconds < previousEnd - 0.001 {
        return false
      }
      previousStart = segment.timelineStartSeconds
      if let duration = segment.durationSeconds {
        previousEnd = max(previousEnd, segment.timelineStartSeconds + duration)
      }
    }
    return true
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
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty }) else { return false }
    return components.allSatisfy { component in
      component != "." && component != ".."
    }
  }

  static func isCaptureRelativePath(_ path: String) -> Bool {
    isSafeRelativePath(path) && pathExtension(of: path) == "mov"
  }

  static func isFinalRelativePath(_ path: String) -> Bool {
    isSafeRelativePath(path) && pathExtension(of: path) == "m4a"
  }

  static func pathExtension(of path: String) -> String {
    URL(fileURLWithPath: path).pathExtension.lowercased()
  }

  static func hasUniqueTrackIDs(_ mapping: [AudioAdapterTrackRole: Int32]) -> Bool {
    let values = Array(mapping.values)
    return Set(values).count == values.count && values.allSatisfy { $0 > 0 }
  }

  static func orderedRequestedRoles(
    _ roles: Set<AudioAdapterTrackRole>,
    for selection: AudioAdapterAudioSourceSelection
  ) -> [AudioAdapterTrackRole] {
    AudioAdapterTrackRole.roles(for: selection).filter { roles.contains($0) }
  }

  private static func normalizedInternalPaths(
    _ paths: AudioAdapterSessionPaths,
    selectedAudioSources: AudioAdapterAudioSourceSelection
  ) -> AudioAdapterSessionPaths {
    var normalized = paths
    if selectedAudioSources != .systemAndMicrophone {
      normalized.system = nil
      normalized.microphone = nil
    }
    if selectedAudioSources == .none { normalized.mixed = nil }
    return normalized
  }
}

/// A non-persisted wrapper carrying the location of a manifest on disk.
nonisolated struct AudioAdapterSession: Equatable, Sendable {
  var manifest: AudioAdapterSessionManifest
  var directoryURL: URL

  var sessionID: UUID { manifest.sessionID }
  var manifestURL: URL {
    directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
  }

  init(manifest: AudioAdapterSessionManifest, directoryURL: URL) {
    self.manifest = manifest
    self.directoryURL = directoryURL
  }

  func url(for relativePath: String) throws -> URL {
    guard AudioAdapterSessionManifest.isSafeRelativePath(relativePath) else {
      throw AudioAdapterSessionStoreError.unsafePath(relativePath)
    }
    let root = directoryURL.standardizedFileURL
    let candidate = root.appendingPathComponent(relativePath, isDirectory: false)
      .standardizedFileURL
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
      throw AudioAdapterSessionStoreError.unsafePath(relativePath)
    }
    guard !AudioAdapterSessionStorePathChecks.hasSymlinkComponent(
      root: root,
      relativePath: relativePath,
      fileManager: .default
    ) else {
      throw AudioAdapterSessionStoreError.unsafePath(relativePath)
    }
    return candidate
  }
}

/// Shared filesystem checks live in the model file so Store, Recovery and the
/// extraction output planner use exactly the same no-symlink rule.
nonisolated enum AudioAdapterSessionStorePathChecks {
  static func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else {
      return false
    }
    return type == .typeSymbolicLink
  }

  static func hasSymlinkComponent(
    root: URL,
    relativePath: String,
    fileManager: FileManager
  ) -> Bool {
    if isSymbolicLink(at: root, fileManager: fileManager) { return true }
    var cursor = root
    for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
      cursor.appendPathComponent(String(component), isDirectory: false)
      if isSymbolicLink(at: cursor, fileManager: fileManager) { return true }
    }
    return false
  }

  /// Checks confinement using the physical path components that already
  /// exist on disk.  Lexical prefix checks alone are insufficient when an
  /// ancestor such as `AudioAdapter` or `Sessions` is a symlink.
  static func isPhysicallyConfined(
    _ target: URL,
    under allowedRoot: URL,
    fileManager: FileManager
  ) -> Bool {
    let root = allowedRoot.standardizedFileURL
    let candidate = target.standardizedFileURL
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
      return false
    }
    guard !isSymbolicLink(at: root, fileManager: fileManager) else { return false }
    guard candidate.path != root.path else { return true }

    let relative = String(candidate.path.dropFirst(root.path.count + 1))
    var cursor = root
    for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
      cursor.appendPathComponent(String(component), isDirectory: false)
      if isSymbolicLink(at: cursor, fileManager: fileManager) { return false }
    }
    return true
  }

  static func isRegularFile(at url: URL, fileManager: FileManager) -> Bool {
    guard !isSymbolicLink(at: url, fileManager: fileManager),
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else {
      return false
    }
    return type == .typeRegular
  }

  static func isDirectory(at url: URL, fileManager: FileManager) -> Bool {
    guard !isSymbolicLink(at: url, fileManager: fileManager),
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let type = attributes[.type] as? FileAttributeType else {
      return false
    }
    return type == .typeDirectory
  }
}

nonisolated enum AudioAdapterSessionStoreError: LocalizedError, Equatable {
  case invalidManifest
  case unsupportedFutureSchema(Int)
  case sessionNotFound(UUID)
  case sessionAlreadyExists(UUID)
  case unsafePath(String)
  case invalidCapturePath(String)
  case invalidOutputPath(String)
  case cannotCreateDirectory(String)
  case cannotPersistManifest(String)
  case invalidStateTransition(AudioAdapterSessionStage, AudioAdapterSessionStage)

  var errorDescription: String? {
    switch self {
    case .invalidManifest:
      "Audio adapter manifest is invalid."
    case .unsupportedFutureSchema(let version):
      "Audio adapter manifest schema \(version) is newer than this app."
    case .sessionNotFound:
      "Audio adapter session was not found."
    case .sessionAlreadyExists:
      "Audio adapter session already exists."
    case .unsafePath:
      "Audio adapter manifest contains an unsafe path."
    case .invalidCapturePath:
      "Audio adapter capture path is not a private MOV file."
    case .invalidOutputPath:
      "Audio adapter final output path is not a private M4A file."
    case .cannotCreateDirectory:
      "Audio adapter session directory could not be created."
    case .cannotPersistManifest:
      "Audio adapter manifest could not be persisted."
    case .invalidStateTransition:
      "Audio adapter session state transition is not allowed."
    }
  }
}

/// Shared source/final duration tolerance used by extraction, recovery, and
/// the deletion gate.  It scales with long recordings instead of imposing a
/// fixed timeout/validation ceiling.
nonisolated enum AudioAdapterSessionDurationPolicy {
  static func tolerance(for expectedDuration: Double) -> Double {
    max(0.25, min(2.0, expectedDuration * 0.05))
  }
}
