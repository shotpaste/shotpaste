import Foundation
@testable import ShotPaste
import XCTest

final class TranscriptionResultsTests: XCTestCase {
  func testFatalCloudPartsOfferResubmissionForTheirAudioAndVideoParentsOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = AudioProcessingTaskStore(sessionsDirectory: root.appendingPathComponent("audio"))
    let video = VolcengineRecordingWorkStore(root: root.appendingPathComponent("video"))
    let cloudRoot = root.appendingPathComponent("cloud")
    try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
    let sessionID = UUID()
    try audio.persistTask(.init(sessionID: sessionID, sourcePaths: [.mixed: "mixed.m4a"], stage: .failed))
    let configuration = RecordingTranscriptionConfiguration(account: .init(), sourceLanguage: .auto)
    let track = try await video.begin(url: audio.sessionsDirectory.appendingPathComponent(sessionID.uuidString)
      .appendingPathComponent("mixed.m4a"), configuration: configuration, checksum: "track")
    let movie = try await video.begin(url: root.appendingPathComponent("meeting.mov"), configuration: configuration, checksum: "movie")
    let silent = try await video.begin(url: root.appendingPathComponent("silent.mov"), configuration: configuration, checksum: "silent")
    for work in [track, movie, silent] {
      try await video.finish(work.id, transcript: nil)
      var job = VolcengineCloudJob(id: UUID(), account: configuration.account, sourceChecksum: work.sourceChecksum,
        language: nil, requestID: UUID())
      job.parentWorkID = work.id; job.stage = .failed; job.cleanup = .cleaned
      job.lastError = work.id == silent.id ? "20000003" : "45000030"
      try JSONEncoder().encode(job).write(to: cloudRoot.appendingPathComponent(job.id.uuidString + ".json"))
    }
    let repository = TranscriptionResultsRepository(audioStore: audio, videoStore: video,
      cloudJobs: .init(root: cloudRoot))
    let results = await repository.summaries()
    XCTAssertEqual(results.first(where: { $0.id == .audio(sessionID) })?.requiresResubmission, true)
    XCTAssertEqual(results.first(where: { $0.id == .video(movie.id) })?.requiresResubmission, true)
    XCTAssertEqual(results.first(where: { $0.id == .video(silent.id) })?.requiresResubmission, false)
  }

  func testUnifiedResultsIncludeCompletedAndFailedTasksButExcludeRecordingWithoutTranscription() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = AudioProcessingTaskStore(sessionsDirectory: root.appendingPathComponent("audio"))
    let video = VolcengineRecordingWorkStore(root: root.appendingPathComponent("video"))
    let sessionID = UUID()
    try audio.persistTask(.init(sessionID: sessionID, sourcePaths: [.mixed: "mixed.m4a"],
      stage: .completed, createdAt: Date(timeIntervalSince1970: 50)))
    try audio.persistTask(.init(sessionID: UUID(), autoTranscribe: false,
      sourcePaths: [.mixed: "mixed.m4a"], stage: .completed))
    let work = try await video.begin(url: root.appendingPathComponent("meeting.mov"),
      configuration: .init(account: .init(), sourceLanguage: .auto), checksum: "test")
    try await video.finish(work.id, transcript: nil)
    let internalTrack = try await video.begin(url: root.appendingPathComponent("system.m4a"),
      configuration: .init(account: .init(), sourceLanguage: .auto), checksum: "track")
    try await video.finish(internalTrack.id, transcript: .init(text: "track", segments: []))
    let verification = try await video.begin(url: root.appendingPathComponent("verification.mp3"),
      configuration: .init(account: .init(), sourceLanguage: .auto), checksum: "sample")
    try await video.finish(verification.id, transcript: .init(text: "sample", segments: []))
    let repository = TranscriptionResultsRepository(audioStore: audio, videoStore: video)
    let results = await repository.summaries()
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.first?.id, .video(work.id))
    XCTAssertEqual(results.first?.stage, .failed)
    XCTAssertEqual(results.last?.id, .audio(sessionID))
    XCTAssertFalse(audio.scanUnfinishedTasks().contains { $0.sessionID == sessionID })
  }

  func testAudioArtifactsRemainReadableWithoutSourceMediaAndKeepDistinctExports() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let audio = AudioProcessingTaskStore(sessionsDirectory: root)
    let sessionID = UUID()
    try audio.persistTask(.init(sessionID: sessionID, sourcePaths: [.mixed: "mixed.m4a"], stage: .completed))
    let raw = AudioRawTranscript(sessionID: sessionID, segments: [
      .init(text: "original words", startTime: 2, duration: 3, source: .mixed, ordinal: 0)])
    try audio.persistRawTranscript(raw, sessionID: sessionID)
    try audio.persistPolishedTranscript(.init(text: "polished words", sourceSegmentIDs: Array(raw.segmentIDs)), sessionID: sessionID)
    try audio.persistStructuredContent(.init(template: .interviewQA,
      interviewQA: [.init(question: "Question?", answer: "Answer.", segmentIDs: Array(raw.segmentIDs))],
      transcriptSegmentIDs: Array(raw.segmentIDs)), sessionID: sessionID)
    let repository = TranscriptionResultsRepository(audioStore: .init(sessionsDirectory: root),
      videoStore: .init(root: root.appendingPathComponent("video")))
    let artifacts = await repository.artifacts(for: .audio(sessionID))
    XCTAssertEqual(artifacts.map(\.id), [.raw, .polished, .organized])
    XCTAssertEqual(artifacts[0].text, "original words")
    XCTAssertTrue(artifacts[0].exportText.contains("00:00:02.000 → 00:00:05.000"))
    XCTAssertEqual(artifacts[1].exportText, "polished words")
    XCTAssertTrue(artifacts[2].exportText.contains("Question?\nAnswer."))
  }

  func testVideoAIIsDurableAndFailurePreservesOriginalTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let video = VolcengineRecordingWorkStore(root: root)
    let work = try await video.begin(url: root.appendingPathComponent("meeting.mov"),
      configuration: .init(account: .init(), sourceLanguage: .auto), checksum: "test", automaticAI: true)
    let transcript = RecordingTranscript(text: "original words",
      segments: [.init(text: "original words", startTime: 2, duration: 3)])
    try await video.finish(work.id, transcript: transcript)
    try await video.processAI(work.id, processor: ResultsTestProcessor())
    let reopened = VolcengineRecordingWorkStore(root: root)
    let saved = await reopened.work(work.id)
    XCTAssertEqual(saved?.transcript, transcript)
    XCTAssertEqual(saved?.polished?.text, "polished words")
    XCTAssertEqual(saved?.structured?.generalNotes.first?.text, "organized notes")
    XCTAssertEqual(saved?.aiState, .completed)
    XCTAssertEqual(saved?.automaticAI, true)
    do {
      try await reopened.processAI(work.id, processor: ResultsTestProcessor(fails: true))
      XCTFail("Expected AI failure")
    } catch {}
    let failed = await reopened.work(work.id)
    XCTAssertEqual(failed?.transcript, transcript)
    XCTAssertEqual(failed?.polished?.text, "polished words")
    XCTAssertEqual(failed?.aiState, .failed)
  }

  @MainActor
  func testHistoryLinkTargetsExactTaskAndFocusClearsFilters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let video = VolcengineRecordingWorkStore(root: root.appendingPathComponent("video"))
    let url = root.appendingPathComponent("meeting.mov")
    let work = try await video.begin(url: url, configuration: .init(account: .init(), sourceLanguage: .auto), checksum: "test")
    try await video.finish(work.id, transcript: .init(text: "retained", segments: []))
    let repository = TranscriptionResultsRepository(
      audioStore: .init(sessionsDirectory: root.appendingPathComponent("audio")), videoStore: video)
    let model = TranscriptionResultsModel(repository: repository)
    await model.refresh()
    var record = CaptureHistoryRecord(id: UUID(), filePath: url.path, fileName: "meeting.mov",
      captureType: .video, fileSize: 1, capturedAt: Date(), isDeleted: false)
    XCTAssertEqual(model.resultID(for: record), .video(work.id))
    record.filePath = root.appendingPathComponent("different.mov").path
    XCTAssertNil(model.resultID(for: record))
    await repository.linkHistoryRecord(record.id, sourceURL: url)
    await model.refresh()
    XCTAssertEqual(model.resultID(for: record), .video(work.id), "Copied or moved media retains the history UUID link")
    let restarted = TranscriptionResultsRepository(
      audioStore: .init(sessionsDirectory: root.appendingPathComponent("audio")), videoStore: video)
    let links = await restarted.historyLinks()
    XCTAssertEqual(links[record.id], .video(work.id))
    model.search = "nonexistent"; model.filter = 1
    model.focus(.video(work.id))
    XCTAssertEqual(model.search, "")
    XCTAssertEqual(model.filter, 0)
    XCTAssertEqual(model.selectedID, .video(work.id))
    await model.loadSelection()
    XCTAssertEqual(model.artifact?.exportText, "retained")
    model.selectedID = .audio(UUID())
    XCTAssertNil(model.artifact, "Never export the previously selected task while loading another task")
  }
}

private nonisolated struct ResultsTestProcessor: AudioLLMProcessing {
  var fails = false
  func process(raw: AudioRawTranscript, template: AudioOrganizationTemplate,
               language: AudioRecordingLanguage?) async throws -> AudioLLMProcessingResult {
    if fails { throw AudioLocalLLMError.failed }
    return .init(polished: .init(text: "polished words", sourceSegmentIDs: Array(raw.segmentIDs)),
      structured: .init(template: .generalNotes,
        generalNotes: [.init(text: "organized notes", segmentIDs: Array(raw.segmentIDs))],
        transcriptSegmentIDs: Array(raw.segmentIDs)))
  }
}
