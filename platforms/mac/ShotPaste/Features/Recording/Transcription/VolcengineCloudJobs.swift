import Foundation

nonisolated struct VolcengineCloudJob: Codable, Sendable, Identifiable {
  enum Stage: String, Codable, Sendable {
    case preparing, uploading, uploaded, submitting, submitted, polling, transcriptReady, failed, cancelled
  }
  enum Cleanup: String, Codable, Sendable { case notUploaded, pending, cleaned }
  let id: UUID
  let account: VolcengineCloudAccount
  let sourceChecksum: String
  let language: String?
  let requestID: UUID
  var parentWorkID: String?
  var providerTaskID: UUID?
  var stage: Stage = .preparing
  var cleanup: Cleanup = .notUploaded
  var pollAttempts = 0
  var submittedAt: Date?
  var transcript: VolcengineFileTranscript?
  var uploadedBytes: Int64?
  var totalBytes: Int64?
  var archived: Bool?
  var lastError: String?
  var retryAfter: Date?
  var objectKey: String { account.prefix + id.uuidString.lowercased() + "/part.m4a" }
}

/// Durable private audio parts and receipts. Only this actor mutates the store.
/// Old credential profiles own their jobs even after a settings account switch.
actor VolcengineCloudJobs {
  static let shared = VolcengineCloudJobs()
  private let root: URL
  private var active: Set<String> = []
  private var cachedRecords: [String: VolcengineCloudJob]?
  private var cancelled: Set<UUID> = []
  private let http: any VolcengineCloudTransport
  private let wait: @Sendable (Double) async throws -> Void

  init(root: URL? = nil, http: any VolcengineCloudTransport = VolcengineCloudHTTP(),
       wait: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    self.http = http; self.wait = wait
    self.root = root ?? (AppDataLocations.applicationSupportRoot ?? AppDataLocations.fallbackCaptureDirectory)
      .appendingPathComponent("CloudTranscription", isDirectory: true)
  }

  private func reference(source: String, account: VolcengineCloudAccount, language: String?) -> String {
    VolcengineTOSSigner.sha256(Data("\(account.id)|\(source)|\(language ?? "auto")".utf8))
  }
  private func record(_ ref: String) -> URL { root.appendingPathComponent(ref + ".json") }
  private func audioURL(_ ref: String) -> URL { root.appendingPathComponent(ref + ".m4a") }
  private func save(_ job: VolcengineCloudJob, _ ref: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(job).write(to: record(ref), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record(ref).path)
    cachedRecords?[ref] = job
  }
  private func records() -> [(String, VolcengineCloudJob)] {
    if let cachedRecords { return cachedRecords.map { ($0.key, $0.value) } }
    let records: [(String, VolcengineCloudJob)] = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "json" }.compactMap { file in
        guard let data = try? Data(contentsOf: file),
              let job = try? JSONDecoder().decode(VolcengineCloudJob.self, from: data) else { return nil }
        return (file.deletingPathExtension().lastPathComponent, job)
      }
    cachedRecords = Dictionary(uniqueKeysWithValues: records)
    return records
  }
  func jobs() -> [VolcengineCloudJob] { records().map(\.1).filter { $0.archived != true }.sorted { $0.id.uuidString < $1.id.uuidString } }

  func transcribe(audio: Data, account: VolcengineCloudAccount,
                  credentials: VolcengineCloudCredentials, language: String?, sourceID: String? = nil, parentWorkID: String? = nil,
                  progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> VolcengineFileTranscript {
    guard !audio.isEmpty, audio.count <= VolcengineAudioPreparation.maximumBytes else {
      throw RecordingTranscriptionError.invalidRecording
    }
    let checksum = VolcengineTOSSigner.sha256(audio)
    let ref = reference(source: sourceID ?? checksum, account: account, language: language)
    while active.contains(ref) || active.count >= 2 {
      try await Task.sleep(for: .milliseconds(200))
    }
    var job: VolcengineCloudJob
    if FileManager.default.fileExists(atPath: record(ref).path) {
      job = try JSONDecoder().decode(VolcengineCloudJob.self, from: Data(contentsOf: record(ref)))
      guard job.account.id == account.id, job.language == language else { throw RecordingTranscriptionError.invalidRecording }
      if let transcript = job.transcript { return transcript }
      if job.stage == .preparing, !FileManager.default.fileExists(atPath: audioURL(ref).path), job.sourceChecksum == checksum {
        try audio.write(to: audioURL(ref), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL(ref).path)
      }
      guard job.stage != .failed, job.stage != .cancelled else {
        throw VolcengineCloudFailure(http: 404, code: job.lastError ?? "ReviewTask")
      }
    } else {
      job = VolcengineCloudJob(id: UUID(), account: account, sourceChecksum: checksum,
        language: language, requestID: UUID())
      job.parentWorkID = parentWorkID
      try save(job, ref)
      try audio.write(to: audioURL(ref), options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL(ref).path)
    }
    return try await execute(job, ref: ref, credentials: credentials, progress: progress)
  }

  private func execute(_ initial: VolcengineCloudJob, ref: String, credentials: VolcengineCloudCredentials,
                       progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> VolcengineFileTranscript {
    guard !active.contains(ref), active.count < 2 else { throw RecordingTranscriptionError.connectionFailed }
    active.insert(ref)
    defer { active.remove(ref); cancelled.remove(initial.id) }
    var job = initial
    let tos = VolcengineTOSClient(signer: try credentials.signer, http: http)
    do {
      try checkCancellation(job.id)
      if let parent = job.parentWorkID { try await VolcengineRecordingWorkStore.shared.checkCancellation(parent) }
      if [.preparing, .uploading].contains(job.stage) {
        progress(L10n.CloudTranscription.uploading)
        guard FileManager.default.fileExists(atPath: audioURL(ref).path) else {
          job.stage = .failed; job.lastError = "LocalPartUnavailable"
          throw RecordingTranscriptionError.invalidRecording
        }
        let audio = try Data(contentsOf: audioURL(ref), options: .mappedIfSafe)
        guard VolcengineTOSSigner.sha256(audio) == job.sourceChecksum else { throw RecordingTranscriptionError.invalidRecording }
        job.stage = .uploading; job.cleanup = .pending
        try save(job, ref)
        let head = try credentials.signer.request(method: "HEAD", bucket: job.account.bucket, key: job.objectKey)
        let (_, response) = try await http.send(head)
        if response.statusCode == 404 {
          try await tos.upload(audio, account: job.account, key: job.objectKey) { sent, total in
            progress("\(L10n.CloudTranscription.uploading) \(sent)/\(total) B")
            Task { await self.updateUpload(ref: ref, sent: sent, total: total) }
          }
        } else if response.statusCode != 200 {
          throw VolcengineCloudFailure(http: response.statusCode)
        } else if response.value(forHTTPHeaderField: "x-tos-meta-sha256") != job.sourceChecksum {
          throw RecordingTranscriptionError.invalidResponse
        }
        job.stage = .uploaded; try save(job, ref)
      }
      try checkCancellation(job.id)
      if job.stage == .uploaded {
        progress(L10n.CloudTranscription.submitting)
        job.stage = .submitting; job.submittedAt = Date(); try save(job, ref)
        let signed = try credentials.signer.signedGET(bucket: job.account.bucket, key: job.objectKey)
        let request = try VolcengineFileASRProtocol.request(apiKey: credentials.speechKey,
          requestID: job.requestID, audioURL: signed, language: job.language)
        // A lost submit response remains ambiguous: persist before sending, never repeat it.
        do {
          let (data, response) = try await http.send(request)
          job.providerTaskID = try VolcengineFileASRProtocol.submittedTaskID(data, response: response)
          job.stage = .submitted; try save(job, ref)
        } catch let error as VolcengineCloudFailure where !error.retryable {
          job.stage = .failed; throw error
        } catch is CancellationError { throw CancellationError() }
        catch { /* Query the original ID after an ambiguous transport response. */ }
      }
      progress(L10n.CloudTranscription.recognizing)
      job.stage = .polling; try save(job, ref)
      var transientFailures = 0
      for attempt in 0..<120 {
        if job.pollAttempts >= 120 {
          job.stage = .failed; job.lastError = "QueryLimit"
          throw RecordingTranscriptionError.timeout
        }
        try checkCancellation(job.id)
        let normalDelay = Double(min(5 + attempt, 30)) + Double.random(in: 0...1)
        let delay = max(normalDelay, job.retryAfter?.timeIntervalSinceNow ?? 0)
        // Long Retry-After is persisted; a later maintenance run honors it.
        guard delay <= 60 else { throw RecordingTranscriptionError.timeout }
        try await wait(delay)
        try checkCancellation(job.id)
        do {
          let request = try VolcengineFileASRProtocol.request(apiKey: credentials.speechKey,
            requestID: job.providerTaskID ?? job.requestID)
          job.pollAttempts += 1
          try save(job, ref)
          let (data, response) = try await http.send(request)
          job.retryAfter = Self.retryDate(response)
          try save(job, ref)
          switch try VolcengineFileASRProtocol.queryResult(data, response: response) {
          case .pending: transientFailures = 0; continue
          case var .completed(transcript):
            transcript.requestID = job.requestID
            transcript.providerVersion = VolcengineFileASRProtocol.resourceID
            job.transcript = transcript; job.stage = .transcriptReady; job.lastError = nil
            try save(job, ref) // Raw result survives deletion or later AI failure.
            progress(L10n.CloudTranscription.cleaning)
            await cleanup(&job, ref: ref, tos: tos)
            return transcript
          }
        } catch let error as VolcengineCloudFailure where error.retryable {
          transientFailures += 1
          if transientFailures >= 3 { throw error }
        } catch RecordingTranscriptionError.connectionFailed {
          transientFailures += 1
          if transientFailures >= 3 { throw RecordingTranscriptionError.connectionFailed }
        }
      }
      throw RecordingTranscriptionError.timeout
    } catch {
      if Task.isCancelled || cancelled.contains(job.id) || error is CancellationError {
        job.stage = .cancelled
      } else if let failure = error as? VolcengineCloudFailure, !failure.retryable {
        job.stage = .failed; job.lastError = failure.code
      } else if error as? RecordingTranscriptionError == .emptyTranscript || error as? RecordingTranscriptionError == .invalidResponse {
        job.stage = .failed; job.lastError = "InvalidResult"
      }
      try save(job, ref)
      if [.failed, .cancelled].contains(job.stage) { await cleanup(&job, ref: ref, tos: tos) }
      if job.stage == .cancelled { throw CancellationError() }
      throw error
    }
  }

  private func updateUpload(ref: String, sent: Int64, total: Int64) {
    _ = records()
    guard cachedRecords?[ref]?.stage == .uploading else { return }
    cachedRecords?[ref]?.uploadedBytes = sent
    cachedRecords?[ref]?.totalBytes = total
  }

  static func retryDate(_ response: HTTPURLResponse, now: Date = Date()) -> Date? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }
  private func checkCancellation(_ id: UUID) throws {
    try Task.checkCancellation()
    if cancelled.contains(id) { throw CancellationError() }
  }
  private func cleanup(_ job: inout VolcengineCloudJob, ref: String, tos: VolcengineTOSClient) async {
    if job.cleanup == .pending {
      let account = job.account, key = job.objectKey
      let cleaned = await Task.detached {
        do { try await tos.delete(account: account, key: key); return true } catch { return false }
      }.value
      if cleaned { job.cleanup = .cleaned; try? save(job, ref) }
    }
    if job.stage == .transcriptReady || job.stage == .cancelled {
      try? FileManager.default.removeItem(at: audioURL(ref))
    }
  }
  func cancel(_ id: UUID) async {
    guard let (ref, initial) = records().first(where: { $0.1.id == id }) else { return }
    if active.contains(ref) { cancelled.insert(id); return }
    var job = initial; job.stage = .cancelled; try? save(job, ref)
    await retryCleanup()
  }
  func retryCleanup() async {
    for (ref, initial) in records() where !active.contains(ref) {
      guard [.transcriptReady, .failed, .cancelled].contains(initial.stage),
            initial.cleanup == .pending || (initial.stage != .failed && FileManager.default.fileExists(atPath: audioURL(ref).path)),
            let credentials = try? await VolcengineCloudAccounts.credentials(for: initial.account.id) else { continue }
      active.insert(ref)
      var job = initial
      if let signer = try? credentials.signer { await cleanup(&job, ref: ref, tos: .init(signer: signer, http: http)) }
      active.remove(ref)
    }
  }
  /// Background recovery never creates a new request ID. Fatal errors require explicit user action.
  func recover() async {
    await retryCleanup()
    let retained = Set(records().filter {
      $0.1.cleanup == .pending || ($0.1.archived != true && ![.transcriptReady, .cancelled].contains($0.1.stage))
    }.map { $0.1.account.id })
    let parentProfiles = await VolcengineRecordingWorkStore.shared.profilesToRetain()
    let audioProfiles = AudioProcessingTaskStore().cloudProfilesToRetain()
    await VolcengineCloudAccounts.pruneRetired(excluding: retained.union(parentProfiles).union(audioProfiles))
    for (ref, job) in records() where !active.contains(ref) && active.count < 2 {
      guard ![.failed, .cancelled, .transcriptReady].contains(job.stage),
            (job.retryAfter ?? .distantPast) <= Date(),
            let credentials = try? await VolcengineCloudAccounts.credentials(for: job.account.id) else { continue }
      _ = try? await execute(job, ref: ref, credentials: credentials)
    }
  }
  /// Called only after explicit duplicate-charge confirmation in Results.
  func resubmit(_ id: UUID) async throws {
    while active.count >= 2 { try await Task.sleep(for: .milliseconds(200)) }
    guard let (ref, old) = records().first(where: { $0.1.id == id }), !active.contains(ref),
          old.stage == .failed, old.cleanup != .pending else { throw RecordingTranscriptionError.invalidConfiguration }
    let audio = try Data(contentsOf: audioURL(ref))
    let credentials = try await VolcengineCloudAccounts.credentials(for: old.account.id)
    // Archive the old receipt so its provider request is never silently overwritten.
    var archived = old; archived.archived = true
    try save(archived, UUID().uuidString)
    var fresh = VolcengineCloudJob(id: UUID(), account: old.account,
      sourceChecksum: VolcengineTOSSigner.sha256(audio), language: old.language, requestID: UUID())
    fresh.parentWorkID = old.parentWorkID
    try save(fresh, ref)
    _ = try await execute(fresh, ref: ref, credentials: credentials)
  }
}
