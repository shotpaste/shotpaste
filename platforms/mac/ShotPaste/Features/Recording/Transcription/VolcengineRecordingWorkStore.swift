import Foundation

/// Parent recording receipt keeps long-file continuation independent of any window.
/// Paths refer only to already saved local media; no keys or signed URLs are stored.
nonisolated struct VolcengineRecordingWork: Codable, Identifiable, Sendable {
  enum State: String, Codable, Sendable { case running, failed, cancelled, completed }
  enum Kind: String, Codable, Sendable { case video, audioTrack, verification }
  let id: String
  var kind: Kind?
  var audioSessionIDs: Set<UUID>?
  let recordingURL: URL
  let configuration: RecordingTranscriptionConfiguration
  let sourceChecksum: String
  var state: State = .running
  var transcript: RecordingTranscript?
  var createdAt: Date? = Date()
  var automaticAI: Bool?
  var polished: AudioPolishedTranscript?
  var structured: AudioStructuredContent?
  enum AIState: String, Codable, Sendable { case processing, completed, failed }
  var aiState: AIState?
}

actor VolcengineRecordingWorkStore {
  static let shared = VolcengineRecordingWorkStore()
  private let root: URL
  init(root: URL? = nil) {
    self.root = root ?? (AppDataLocations.applicationSupportRoot ?? AppDataLocations.fallbackCaptureDirectory)
      .appendingPathComponent("RecordingTranscriptionSessions", isDirectory: true)
  }
  private var active: Set<String> = []
  private var activeAI: Set<String> = []
  private var cache: [String: VolcengineRecordingWork]?

  private func load() -> [String: VolcengineRecordingWork] {
    if let cache { return cache }
    var loaded: [String: VolcengineRecordingWork] = [:]
    for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
      if let data = try? Data(contentsOf: file), var work = try? JSONDecoder().decode(VolcengineRecordingWork.self, from: data) {
        // Read older local receipts without changing their request or account identity.
        if work.kind == nil {
          work.kind = ["mov", "mp4", "m4v"].contains(work.recordingURL.pathExtension.lowercased())
            ? .video : .audioTrack
        }
        if work.createdAt == nil {
          work.createdAt = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        }
        loaded[work.id] = work
      }
    }
    cache = loaded; return loaded
  }
  private func save(_ work: VolcengineRecordingWork) throws {
    _ = load()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = root.appendingPathComponent(work.id + ".json")
    try JSONEncoder().encode(work).write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    cache?[work.id] = work
  }
  func begin(url: URL, configuration: RecordingTranscriptionConfiguration, checksum: String,
             automaticAI: Bool = false, kind: VolcengineRecordingWork.Kind = .video,
             audioSessionID: UUID? = nil) async throws -> VolcengineRecordingWork {
    let id = VolcengineTOSSigner.sha256(Data("\(configuration.account.id)|\(configuration.sourceLanguage.rawValue)|\(checksum)".utf8))
    while active.contains(id) { try await Task.sleep(for: .milliseconds(200)) }
    var work = load()[id] ?? VolcengineRecordingWork(id: id, recordingURL: url, configuration: configuration, sourceChecksum: checksum)
    if work.kind == nil { work.kind = kind }
    if let audioSessionID {
      work.kind = .audioTrack
      work.audioSessionIDs = (work.audioSessionIDs ?? []).union([audioSessionID])
    }
    if work.automaticAI == nil { work.automaticAI = automaticAI }
    try save(work)
    if work.transcript != nil { return work }
    if work.state == .cancelled { throw CancellationError() }
    work.state = .running; try save(work); active.insert(id)
    return work
  }
  func finish(_ id: String, transcript: RecordingTranscript?, cancelled: Bool = false) throws {
    defer { active.remove(id) }
    guard var work = load()[id] else { return }
    work.transcript = transcript
    work.state = transcript != nil ? .completed : cancelled ? .cancelled : .failed
    try save(work)
  }
  func works() -> [VolcengineRecordingWork] { Array(load().values).sorted { $0.id < $1.id } }
  /// One-time relationship repair for receipts written before explicit audio parents.
  /// This only writes local metadata; it never submits or queries a cloud job.
  func associateLegacyAudioTasks(_ sources: [UUID: Set<URL>]) throws {
    for var work in load().values where work.kind == .audioTrack && work.audioSessionIDs == nil {
      let owners = Set(sources.filter { $0.value.contains(work.recordingURL) }.map(\.key))
      if !owners.isEmpty { work.audioSessionIDs = owners; try save(work) }
    }
  }
  func work(_ id: String) -> VolcengineRecordingWork? { load()[id] }

  /// The complete derived result belongs to the durable task, never to a window.
  func processAI(_ id: String, processor: any AudioLLMProcessing = LocalAudioLLMProcessor()) async throws {
    guard var work = load()[id], let transcript = work.transcript,
          !activeAI.contains(id) else { return }
    activeAI.insert(id)
    defer { activeAI.remove(id) }
    work.aiState = .processing
    try save(work)
    do {
      let raw = transcript.audioRawTranscript(language: work.configuration.sourceLanguage)
      let result = try await processor.process(raw: raw, template: .generalNotes,
        language: work.configuration.sourceLanguage, existingPolished: work.polished)
      try Task.checkCancellation()
      guard result.structured.hasValidReferences(in: raw),
            Set(result.polished.sourceSegmentIDs) == raw.segmentIDs else {
        throw AudioLocalLLMError.invalidOutput
      }
      work.polished = result.polished
      work.structured = result.structured
      work.aiState = .completed
      try save(work)
    } catch {
      work.aiState = .failed
      try save(work)
      throw error
    }
  }
  func profilesToRetain() -> Set<UUID> {
    Set(load().values.filter { $0.state == .running || $0.state == .failed }.map { $0.configuration.account.id })
  }
  func checkCancellation(_ id: String) throws {
    if load()[id]?.state == .cancelled { throw CancellationError() }
  }
  func cancel(_ id: String) async {
    guard var work = load()[id], work.state != .completed else { return }
    work.state = .cancelled; try? save(work)
    for job in await VolcengineCloudJobs.shared.jobs() where job.parentWorkID == id && job.transcript == nil {
      await VolcengineCloudJobs.shared.cancel(job.id)
    }
  }
  func retry(_ id: String) async {
    guard var work = load()[id], !active.contains(id), work.state == .failed else { return }
    work.state = .running; try? save(work)
    await recover()
  }
  func recover() async {
    for var work in load().values where work.state == .running && !active.contains(work.id) {
      guard (try? VolcengineAudioPreparation.checksum(work.recordingURL)) == work.sourceChecksum else {
        work.state = .failed; try? save(work); continue
      }
      do {
        _ = try await VolcengineRecordingTranscriptionService().transcribe(recordingURL: work.recordingURL,
          configuration: work.configuration, sourceKind: work.kind ?? .video,
          audioSessionID: work.audioSessionIDs?.first)
      } catch { /* Service persists failure or cancellation; original media remains intact. */ }
    }
    for work in load().values where work.transcript != nil
      && (work.aiState == .processing || (work.automaticAI == true && work.aiState == nil))
      && !activeAI.contains(work.id) {
      try? await processAI(work.id)
    }
  }
}
