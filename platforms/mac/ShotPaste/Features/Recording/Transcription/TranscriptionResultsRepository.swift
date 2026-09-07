import Foundation

nonisolated enum TranscriptionResultID: Codable, Hashable, Sendable {
  case audio(UUID)
  case video(String)
}

nonisolated enum TranscriptionArtifactKind: String, CaseIterable, Identifiable, Sendable {
  case raw, polished, organized
  var id: Self { self }
  var title: String {
    switch self {
    case .raw: L10n.TranscriptionResults.raw
    case .polished: L10n.TranscriptionResults.polished
    case .organized: L10n.TranscriptionResults.organized
    }
  }
}

nonisolated struct TranscriptionArtifact: Equatable, Sendable, Identifiable {
  let id: TranscriptionArtifactKind
  let text: String
  let exportText: String
}

nonisolated struct TranscriptionResultSummary: Identifiable, Equatable, Sendable {
  let id: TranscriptionResultID
  let date: Date
  let mediaURLs: [URL]
  let historyRecordID: UUID?
  let stage: AudioProcessingTaskStage
  var requiresResubmission = false

  var isAudio: Bool { if case .audio = id { true } else { false } }
  var title: String {
    isAudio ? L10n.TranscriptionResults.audio : (mediaURLs.first?.lastPathComponent ?? L10n.TranscriptionResults.video)
  }
  var isRunning: Bool { [.saving, .transcribing, .polishing, .organizing].contains(stage) }
  var status: String {
    switch stage {
    case .saving: L10n.AudioRecording.saving
    case .transcribing: L10n.AudioRecording.transcribing
    case .polishing: L10n.AudioRecording.polishing
    case .organizing: L10n.AudioRecording.organizingInterviewQA
    case .waitingForModel: L10n.AudioRecording.modelUnavailable
    case .completed: L10n.AudioRecording.complete
    case .failed: L10n.TranscriptionResults.failed
    case .cancelled: L10n.TranscriptionResults.cancelled
    }
  }

  func matches(historyID: UUID, mediaURL: URL) -> Bool {
    historyRecordID == historyID || mediaURLs.contains { $0.standardizedFileURL == mediaURL.standardizedFileURL }
  }
}

/// Reads the existing task stores. No copied transcript database and no media reads
/// are needed to browse results, including after the original media was removed.
actor TranscriptionResultsRepository {
  static let shared = TranscriptionResultsRepository()
  let audioStore: AudioProcessingTaskStore
  let videoStore: VolcengineRecordingWorkStore
  let cloudJobs: VolcengineCloudJobs
  private let linksURL: URL

  init(audioStore: AudioProcessingTaskStore = .init(),
       videoStore: VolcengineRecordingWorkStore = .shared, linksURL: URL? = nil,
       cloudJobs: VolcengineCloudJobs = .shared) {
    self.audioStore = audioStore
    self.videoStore = videoStore
    self.cloudJobs = cloudJobs
    self.linksURL = linksURL ?? audioStore.allowedRoot.appendingPathComponent("transcription-history-links.json")
  }

  func historyLinks() -> [UUID: TranscriptionResultID] {
    guard let data = try? Data(contentsOf: linksURL) else { return [:] }
    return (try? JSONDecoder().decode([UUID: TranscriptionResultID].self, from: data)) ?? [:]
  }

  /// A history UUID survives Quick Access moves; clipboard copies get their own
  /// UUID association without putting transcript text in the history database.
  func linkHistoryRecord(_ historyID: UUID, sourceURL: URL) async {
    guard let result = await summaries().first(where: { $0.mediaURLs.contains(sourceURL) }) else { return }
    var links = historyLinks()
    links[historyID] = result.id
    do {
      try FileManager.default.createDirectory(at: linksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(links).write(to: linksURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: linksURL.path)
    } catch { /* Advisory navigation must never prevent capture or clipboard saving. */ }
  }

  func summaries() async -> [TranscriptionResultSummary] {
    let works = await videoStore.works()
    let failedParents = Set(await cloudJobs.jobs().filter {
      $0.stage == .failed && $0.lastError != "20000003"
    }.compactMap(\.parentWorkID))
    let sessions = AudioAdapterSessionStore(sessionsDirectory: audioStore.sessionsDirectory)
    var results = audioStore.allTasks().filter(\.autoTranscribe).map { task in
      let session = try? sessions.load(sessionID: task.sessionID)
      let directory = audioStore.sessionsDirectory.appendingPathComponent(task.sessionID.uuidString)
      var urls = task.sourcePaths.values.map { directory.appendingPathComponent($0) }
      if let path = session?.manifest.finalPaths.mixed, let url = try? session?.url(for: path) {
        urls.insert(url, at: 0)
      }
      var result = TranscriptionResultSummary(id: .audio(task.sessionID), date: task.createdAt,
        mediaURLs: urls, historyRecordID: session?.manifest.historyRecordReference,
        stage: task.stage)
      result.requiresResubmission = works.contains {
        failedParents.contains($0.id) && urls.contains($0.recordingURL)
      }
      return result
    }
    // Audio recognition creates per-track receipts in the same cloud store.
    // Its user-facing parent is already represented above; verification MP3s
    // and internal M4A tracks are never standalone screen recordings.
    results += works.filter {
      ["mov", "mp4", "m4v"].contains($0.recordingURL.pathExtension.lowercased())
    }.map { work in
      let stage: AudioProcessingTaskStage
      switch work.state {
      case .running: stage = .transcribing
      case .failed: stage = .failed
      case .cancelled: stage = .cancelled
      case .completed:
        switch work.aiState {
        case .processing: stage = .polishing
        case .failed: stage = .failed
        default: stage = .completed
        }
      }
      var result = TranscriptionResultSummary(id: .video(work.id),
        date: work.createdAt ?? .distantPast, mediaURLs: [work.recordingURL],
        historyRecordID: nil, stage: stage)
      result.requiresResubmission = failedParents.contains(work.id)
      return result
    }
    return results.sorted {
      if $0.date != $1.date { return $0.date > $1.date }
      return String(describing: $0.id) < String(describing: $1.id)
    }
  }

  func artifacts(for id: TranscriptionResultID) async -> [TranscriptionArtifact] {
    let raw: AudioRawTranscript?
    let polished: AudioPolishedTranscript?
    let structured: AudioStructuredContent?
    var artifacts: [TranscriptionArtifact] = []
    switch id {
    case let .audio(sessionID):
      raw = try? audioStore.loadRawTranscript(sessionID: sessionID)
      polished = try? audioStore.loadPolishedTranscript(sessionID: sessionID)
      structured = try? audioStore.loadStructuredContent(sessionID: sessionID)
      if let raw {
        let timed = raw.segments.map { segment in
          "[\(Self.timestamp(segment.startTime)) → \(Self.timestamp(segment.endTime))] \(segment.text)"
        }.joined(separator: "\n")
        artifacts.append(.init(id: .raw, text: raw.text, exportText: timed.isEmpty ? raw.text : timed))
      }
    case let .video(workID):
      let work = await videoStore.work(workID)
      raw = work?.transcript?.audioRawTranscript(language: work?.configuration.sourceLanguage ?? .auto)
      polished = work?.polished
      structured = work?.structured
      if let transcript = work?.transcript {
        artifacts.append(.init(id: .raw, text: transcript.text, exportText: transcript.timedText))
      }
    }
    if let polished {
      artifacts.append(.init(id: .polished, text: polished.text, exportText: polished.text))
    }
    if let structured, structured.template != .transcriptOnly {
      func sourceTime(_ ids: [String]) -> String {
        guard let raw, let range = raw.timeRange(for: ids) else { return "" }
        return "[\(Self.timestamp(range.startTime)) → \(Self.timestamp(range.endTime))]\n"
      }
      let text = structured.interviewQA.map {
        sourceTime($0.segmentIDs) + $0.question + "\n" + $0.answer
      }.joined(separator: "\n\n") + structured.generalNotes.map {
        sourceTime($0.segmentIDs) + $0.text
      }.joined(separator: "\n\n")
      artifacts.append(.init(id: .organized, text: text, exportText: text))
    }
    return artifacts
  }

  private static func timestamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 1000) else { return "—" }
    let value = Int(seconds * 1000)
    return String(format: "%02d:%02d:%02d.%03d", value / 3600000,
      value / 60000 % 60, value / 1000 % 60, value % 1000)
  }

  func retry(_ id: TranscriptionResultID, processAI: Bool = false) async throws {
    switch id {
    case let .video(workID):
      guard let work = await videoStore.work(workID) else { return }
      if work.transcript != nil { try await videoStore.processAI(workID) }
      else { await videoStore.retry(workID) }
    case let .audio(sessionID):
      let task = try audioStore.loadTask(sessionID: sessionID)
      guard ![.saving, .transcribing, .polishing, .organizing].contains(task.stage) else { return }
      if processAI { _ = try audioStore.updateTask(sessionID: sessionID) { $0.autoAI = true } }
      let directory = try audioStore.sessionDirectoryURL(for: sessionID)
      let inputs = task.sourcePaths.map { source, path in
        let url = directory.appendingPathComponent(path)
        // The existing pipeline owns source validation and checkpoint reuse.
        return AudioTranscriptionSourceInput(source: source, url: url)
      }
      let result = try await AudioRecordingProcessingPipeline(taskStore: audioStore).restart(
        sessionID: sessionID, sourceInputs: inputs)
      AudioHistoryProcessingStatusStore.shared.update(sessionID: sessionID,
        taskID: result.task.id, stage: result.task.stage.rawValue)
    }
  }

  func cancel(_ id: TranscriptionResultID) async throws {
    switch id {
    case let .audio(sessionID): _ = try audioStore.requestCancellation(sessionID: sessionID)
    case let .video(workID): await videoStore.cancel(workID)
    }
  }

  /// A new provider request is separate from resuming queries or retrying AI.
  /// The results window must obtain explicit duplicate-charge confirmation first.
  func resubmit(_ id: TranscriptionResultID) async throws {
    guard let summary = await summaries().first(where: { $0.id == id }),
          !summary.isRunning else { return }
    let parents: Set<String>
    switch id {
    case let .video(workID): parents = [workID]
    case .audio:
      parents = Set(await videoStore.works().filter { summary.mediaURLs.contains($0.recordingURL) }.map(\.id))
    }
    await cloudJobs.retryCleanup()
    for job in await cloudJobs.jobs() where job.stage == .failed && job.lastError != "20000003"
      && job.parentWorkID.map(parents.contains) == true {
      try await cloudJobs.resubmit(job.id)
    }
    try await retry(id)
  }
}
