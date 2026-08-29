//
//  AudioTranscriptionProcessingTests.swift
//  ShotPasteTests
//

import Foundation
import Speech
@testable import ShotPaste
import XCTest

final class AudioTranscriptionProcessingTests: XCTestCase {
  private var root: URL!
  private var store: AudioProcessingTaskStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "shotpaste-audio-processing-tests-\(UUID().uuidString)",
        isDirectory: true
      )
    store = AudioProcessingTaskStore(sessionsDirectory: root)
  }

  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
    store = nil
    root = nil
    try super.tearDownWithError()
  }

  func testStableWordAndSegmentIDsAreDeterministic() {
    let first = AudioTranscriptWord(
      text: "hello",
      startTime: 1.25,
      duration: 0.4,
      source: .microphone,
      chunkIndex: 3,
      ordinal: 8
    )
    let second = AudioTranscriptWord(
      text: "hello",
      startTime: 1.25,
      duration: 0.4,
      source: .microphone,
      chunkIndex: 3,
      ordinal: 8
    )
    XCTAssertEqual(first.id, second.id)
    XCTAssertTrue(first.id.hasPrefix("word-"))

    let firstSegment = AudioTranscriptSegment(
      text: "hello",
      startTime: 1.25,
      duration: 0.4,
      source: .microphone,
      words: [first],
      chunkIndex: 3,
      ordinal: 2
    )
    let secondSegment = AudioTranscriptSegment(
      text: "hello",
      startTime: 1.25,
      duration: 0.4,
      source: .microphone,
      words: [second],
      chunkIndex: 3,
      ordinal: 2
    )
    XCTAssertEqual(firstSegment.id, secondSegment.id)
    XCTAssertTrue(firstSegment.id.hasPrefix("segment-"))
  }

  func testSourceRolesAndStableTimelineTieBreaks() {
    XCTAssertEqual(AudioRecordingSource.microphone.speakerRole, .me)
    XCTAssertEqual(AudioRecordingSource.system.speakerRole, .other)
    XCTAssertEqual(AudioRecordingSource.mixed.speakerRole, .unknown)

    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "candidate", startTime: 2, duration: 1, source: .system),
      AudioTranscriptSegment(text: "interviewer", startTime: 2, duration: 1, source: .microphone)
    ])
    let input = AudioLLMInputBuilder.makeInput(
      raw: raw,
      template: .transcriptOnly
    )
    XCTAssertEqual(input.segments.map(\.speaker), [.me, .other])
    XCTAssertEqual(input.segments.map(\.text), ["interviewer", "candidate"])
  }

  func testCitationsResolveToLocalTimestampRanges() {
    let first = AudioTranscriptSegment(text: "question", startTime: 4, duration: 2, source: .microphone)
    let second = AudioTranscriptSegment(text: "answer", startTime: 8, duration: 3, source: .system)
    let raw = AudioRawTranscript(segments: [first, second])
    let content = AudioStructuredContent(
      template: .interviewQA,
      interviewQA: [AudioInterviewQAItem(
        question: "question",
        answer: "answer",
        segmentIDs: [first.id, second.id]
      )]
    )
    XCTAssertTrue(content.hasValidReferences(in: raw))
    let range = content.timeRange(forQAAt: 0, in: raw)
    XCTAssertEqual(range?.startTime, 4)
    XCTAssertEqual(range?.endTime, 11)
  }

  func testRawTranscriptIsImmutableAndDerivedArtifactsAreIndependent() throws {
    let sessionID = UUID()
    let task = AudioProcessingTask(
      sessionID: sessionID,
      sourcePaths: [.mixed: "mixed.m4a"]
    )
    XCTAssertEqual(try store.persistTask(task), task.id)
    let raw = AudioRawTranscript(sessionID: sessionID, segments: [
      AudioTranscriptSegment(text: "raw", startTime: 0, duration: 1, source: .mixed)
    ])
    try store.persistRawTranscript(raw, sessionID: sessionID)
    XCTAssertThrowsError(try store.persistRawTranscript(raw, sessionID: sessionID)) { error in
      XCTAssertEqual(error as? AudioProcessingTaskStoreError, .rawTranscriptAlreadyPersisted)
    }

    try store.persistPolishedTranscript(
      AudioPolishedTranscript(text: "polished", sourceSegmentIDs: [raw.segments[0].id]),
      sessionID: sessionID
    )
    XCTAssertEqual(try store.loadRawTranscript(sessionID: sessionID).text, "raw")
    XCTAssertEqual(try store.loadPolishedTranscript(sessionID: sessionID).text, "polished")
  }

  func testTaskRecoveryScansUnfinishedTaskAndSidecarIsMetadataOnly() throws {
    let sessionID = UUID()
    let task = AudioProcessingTask(sessionID: sessionID, sourcePaths: [.mixed: "mixed.m4a"])
    _ = try store.persistTask(task)
    let unfinished = store.scanUnfinishedTasks()
    XCTAssertEqual(unfinished.map(\.id), [task.id])
    let history = try store.loadHistory(sessionID: sessionID)
    XCTAssertEqual(history.stage, .saving)
    XCTAssertFalse(history.rawTranscriptAvailable)
    XCTAssertFalse(history.polishedTranscriptAvailable)
    XCTAssertFalse(history.structuredContentAvailable)
  }

  func testLLMInputContainsNoMediaPath() {
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "keep this text", startTime: 0, duration: 1, source: .mixed)
    ])
    let input = AudioLLMInputBuilder.makeInput(raw: raw, template: .generalNotes)
    XCTAssertNil(Mirror(reflecting: input).children.first { $0.value is URL })
    XCTAssertFalse(input.renderedText.contains(".m4a"))
    XCTAssertFalse(input.renderedText.contains("/tmp"))
    XCTAssertTrue(input.renderedText.contains(raw.segments[0].id))
    XCTAssertTrue(input.renderedText.contains("keep this text"))
  }

  func testStructuredResponseRejectsFreeText() {
    XCTAssertThrowsError(
      try SystemAudioLanguageModelProvider.decodeStructuredResponse("not JSON")
    )
  }

  func testLLMRejectsUnknownCitation() async throws {
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "known", startTime: 0, duration: 1, source: .mixed)
    ])
    let processor = LocalAudioLLMProcessor(provider: UnknownCitationProvider())
    do {
      _ = try await processor.process(raw: raw, template: .generalNotes)
      XCTFail("unknown citation must be rejected")
    } catch let error as AudioLocalLLMError {
      XCTAssertEqual(error, .invalidOutput)
    }
  }

  func testLLMRejectsWhitespaceOnlyPolish() async throws {
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "known", startTime: 0, duration: 1, source: .mixed)
    ])
    let processor = LocalAudioLLMProcessor(provider: WhitespacePolishProvider())
    do {
      _ = try await processor.process(raw: raw, template: .transcriptOnly)
      XCTFail("whitespace-only polish must be rejected")
    } catch let error as AudioLocalLLMError {
      XCTAssertEqual(error, .invalidOutput)
    }
  }

  func testLLMRejectsEmptyStructuredOutputForInterviewAndNotes() async throws {
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "known", startTime: 0, duration: 1, source: .mixed)
    ])
    for template in [AudioOrganizationTemplate.interviewQA, .generalNotes] {
      let processor = LocalAudioLLMProcessor(provider: EmptyStructuredProvider())
      do {
        _ = try await processor.process(raw: raw, template: template)
        XCTFail("empty structured output must be rejected for \(template)")
      } catch let error as AudioLocalLLMError {
        XCTAssertEqual(error, .invalidOutput)
      }
    }
  }

  func testTranscriptOnlyDoesNotCallOrganize() async throws {
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "known", startTime: 0, duration: 1, source: .mixed)
    ])
    let provider = OrganizeCallCounterProvider()
    let result = try await LocalAudioLLMProcessor(provider: provider)
      .process(raw: raw, template: .transcriptOnly)
    XCTAssertEqual(result.polished.text, "polished")
    XCTAssertEqual(provider.organizeCount, 0)
  }

  func testLongRecordingChunkPlanIsBounded() throws {
    let chunks = try AudioTranscriptionChunkPlanner.plan(
      durationSeconds: 3_901,
      chunkDurationSeconds: 600
    )
    XCTAssertEqual(chunks.count, 7)
    XCTAssertTrue(chunks.allSatisfy { $0.duration <= 600 && $0.duration > 0 })
    XCTAssertEqual(chunks.first?.startTime, 0)
    XCTAssertEqual(try XCTUnwrap(chunks.last).endTime, 3_901, accuracy: 0.0001)

    let raw = AudioRawTranscript(segments: (0..<241).map { index in
      AudioTranscriptSegment(
        text: "segment-\(index)",
        startTime: Double(index),
        duration: 0.5,
        source: .mixed
      )
    })
    let batches = AudioLLMInputBuilder.makeBatches(
      raw: raw,
      template: .transcriptOnly,
      maximumSegments: 40,
      maximumCharacters: 600
    )
    XCTAssertGreaterThan(batches.count, 1)
    XCTAssertTrue(batches.allSatisfy { $0.input.segments.count <= 40 })
    XCTAssertEqual(batches.flatMap { $0.input.segmentIDs }, raw.segments.map(\.id))
  }

  func testPipelinePersistsRawThenCompletesWithoutAI() async throws {
    let sessionID = UUID()
    let transcriber = FakeTranscriber(raw: AudioRawTranscript(
      sessionID: sessionID,
      segments: [AudioTranscriptSegment(text: "hello", startTime: 0, duration: 1, source: .mixed)]
    ))
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: transcriber,
      llmProcessor: UnavailableLLM()
    )
    let result = try await pipeline.process(
      sessionID: sessionID,
      sourceInputs: [AudioTranscriptionSourceInput(
        source: .mixed,
        url: try makeSourceFile(sessionID: sessionID),
        durationSeconds: 1
      )],
      options: AudioProcessingOptions(autoAI: false)
    )
    XCTAssertEqual(result.task.stage, .completed)
    XCTAssertEqual(result.rawTranscript?.text, "hello")
    XCTAssertEqual(try store.loadRawTranscript(sessionID: sessionID).text, "hello")
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(sessionID.uuidString).path))
  }

  func testSourcePathConfinementRejectsOutsideAndSymlink() throws {
    let sessionID = UUID()
    let source = try makeSourceFile(sessionID: sessionID)
    XCTAssertEqual(try store.confinedSourcePath(for: source, sessionID: sessionID), "mixed.m4a")

    let reservedDirectory = try store.chunksDirectoryURL(for: sessionID)
    let reserved = reservedDirectory.appendingPathComponent("reserved-source.m4a")
    try Data([1, 2, 3]).write(to: reserved)
    XCTAssertThrowsError(try store.confinedSourcePath(for: reserved, sessionID: sessionID))
    XCTAssertThrowsError(try store.persistTask(AudioProcessingTask(
      sessionID: sessionID,
      sourcePaths: [.mixed: "Processing/Chunks/reserved-source.m4a"]
    )))
    XCTAssertTrue(FileManager.default.fileExists(atPath: reserved.path))

    let outside = root
      .deletingLastPathComponent()
      .appendingPathComponent("shotpaste-outside-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data([1]).write(to: outside)
    XCTAssertThrowsError(try store.confinedSourcePath(for: outside, sessionID: sessionID))

    let symlink = source.deletingLastPathComponent().appendingPathComponent("link.m4a")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    XCTAssertThrowsError(try store.confinedSourcePath(for: symlink, sessionID: sessionID))
  }

  func testRawWinnerIsStableAcrossStoreInstances() throws {
    let sessionID = UUID()
    let task = AudioProcessingTask(sessionID: sessionID, sourcePaths: [.mixed: "mixed.m4a"])
    _ = try store.persistTask(task)
    let primaryStore = store!
    let secondStore = AudioProcessingTaskStore(sessionsDirectory: root)
    let raw = AudioRawTranscript(sessionID: sessionID, segments: [
      AudioTranscriptSegment(text: "winner", startTime: 0, duration: 1, source: .mixed)
    ])
    let raceResult = RawRaceResult()
    DispatchQueue.concurrentPerform(iterations: 2) { index in
      do {
        try (index == 0 ? primaryStore : secondStore).persistRawTranscript(raw, sessionID: sessionID)
        raceResult.recordSuccess()
      } catch let error as AudioProcessingTaskStoreError {
        raceResult.record(error: error)
      } catch {
        XCTFail("unexpected persistence error: \(error)")
      }
    }
    XCTAssertEqual(raceResult.successCount, 1)
    XCTAssertTrue(raceResult.errors.contains(.rawTranscriptAlreadyPersisted))
    XCTAssertEqual(try store.loadRawTranscript(sessionID: sessionID).text, "winner")
  }

  func testCancellationPersistsAndRestartIsAllowed() throws {
    let sessionID = UUID()
    let task = AudioProcessingTask(sessionID: sessionID, sourcePaths: [.mixed: "mixed.m4a"])
    _ = try store.persistTask(task)
    _ = try store.requestCancellation(sessionID: sessionID)
    let cancelled = try store.loadTask(sessionID: sessionID)
    XCTAssertEqual(cancelled.stage, .cancelled)
    XCTAssertTrue(cancelled.cancellationRequested)

    let restarted = try store.updateTask(sessionID: sessionID) { task in
      task.stage = .saving
      task.cancellationRequested = false
    }
    XCTAssertEqual(restarted.stage, .saving)
    XCTAssertFalse(restarted.cancellationRequested)
  }

  func testPipelineRejectsEmptySpeechAndDoesNotComplete() async throws {
    let sessionID = UUID()
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: FakeTranscriber(raw: AudioRawTranscript(sessionID: sessionID, segments: [])),
      llmProcessor: UnavailableLLM()
    )
    do {
      _ = try await pipeline.process(
        sessionID: sessionID,
        sourceInputs: [AudioTranscriptionSourceInput(
          source: .mixed,
          url: try makeSourceFile(sessionID: sessionID),
          durationSeconds: 1
        )]
      )
      XCTFail("empty raw transcript must fail")
    } catch let error as AudioRecordingProcessingPipelineError {
      XCTAssertEqual(error, .invalidRawTranscript)
    }
    XCTAssertEqual(try store.loadTask(sessionID: sessionID).stage, .failed)
  }

  func testPipelineRejectsZeroDurationBeforeTranscription() async throws {
    let sessionID = UUID()
    let counter = CallCounter()
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: FakeTranscriber(raw: AudioRawTranscript(sessionID: sessionID, segments: [
        AudioTranscriptSegment(text: "should not run", startTime: 0, duration: 1, source: .mixed)
      ])),
      llmProcessor: CountingLLM(counter: counter)
    )
    do {
      _ = try await pipeline.process(
        sessionID: sessionID,
        sourceInputs: [AudioTranscriptionSourceInput(
          source: .mixed,
          url: try makeSourceFile(sessionID: sessionID),
          durationSeconds: 0
        )]
      )
      XCTFail("zero duration must be rejected")
    } catch let error as AudioRecordingProcessingPipelineError {
      XCTAssertEqual(error, .noAudioSource)
    }
    XCTAssertEqual(counter.value, 0)
  }

  func testPipelineResumeUsesPersistedDerivedCheckpoint() async throws {
    let sessionID = UUID()
    let raw = AudioRawTranscript(sessionID: sessionID, segments: [
      AudioTranscriptSegment(text: "checkpoint", startTime: 0, duration: 1, source: .mixed)
    ])
    let counter = CallCounter()
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: FakeTranscriber(raw: raw),
      llmProcessor: CountingLLM(counter: counter)
    )
    let source = try makeSourceFile(sessionID: sessionID)
    let input = AudioTranscriptionSourceInput(source: .mixed, url: source, durationSeconds: 1)
    _ = try await pipeline.process(
      sessionID: sessionID,
      sourceInputs: [input],
      options: AudioProcessingOptions(autoAI: true)
    )
    XCTAssertEqual(counter.value, 1)
    _ = try await pipeline.resume(sessionID: sessionID, sourceInputs: [input])
    XCTAssertEqual(counter.value, 1)
  }

  func testSpeechContinuationTimeoutAndCancellationResumeExactlyOnce() async {
    let timeoutState = SpeechRecognitionContinuationState<Int>(timeoutSeconds: 0.01)
    let timeoutWaiter = Task.detached { () -> Result<Int, Error> in
      do {
        let value = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Int, Error>) in
          XCTAssertTrue(timeoutState.installContinuation(continuation))
          timeoutState.startTimeout()
        }
        return .success(value)
      } catch {
        return .failure(error)
      }
    }
    let timeoutResult = await timeoutWaiter.value
    if case let .failure(error) = timeoutResult {
      XCTAssertEqual(error as? AudioTranscriberError, .recognitionTimedOut)
    } else {
      XCTFail("timeout must resume with an error")
    }

    let cancelState = SpeechRecognitionContinuationState<Int>(timeoutSeconds: 1)
    // Exercise the cancellation-before-continuation-install race explicitly.
    cancelState.cancel()
    let cancelWaiter = Task.detached { () -> Result<Int, Error> in
      do {
        let value = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Int, Error>) in
          _ = cancelState.installContinuation(continuation)
        }
        return .success(value)
      } catch {
        return .failure(error)
      }
    }
    cancelState.finish(returning: 42)
    let cancelResult = await cancelWaiter.value
    if case let .failure(error) = cancelResult {
      XCTAssertEqual(error as? AudioTranscriberError, .cancelled)
    } else {
      XCTFail("cancel must win exactly once")
    }
  }

  func testSpeechAuthorizationBridgeTimeoutAndLateCallbackAreExactlyOnce() async {
    let requester = AuthorizationRequesterSpy()
    let bridge = SpeechAuthorizationBridge(requester: requester, timeoutSeconds: 0.01)
    let waiter = Task { () -> Result<SFSpeechRecognizerAuthorizationStatus, Error> in
      do {
        return .success(try await bridge.requestAuthorization())
      } catch {
        return .failure(error)
      }
    }
    let result = await waiter.value
    if case let .failure(error) = result {
      XCTAssertEqual(error as? AudioTranscriberError, .authorizationTimedOut)
    } else {
      XCTFail("authorization timeout must resume with an error")
    }

    requester.respond(.authorized)
    XCTAssertEqual(requester.responseCount, 1)
  }

  func testSpeechAuthorizationBridgeCancellationResumesBeforeLateCallback() async {
    let requester = AuthorizationRequesterSpy()
    let bridge = SpeechAuthorizationBridge(requester: requester, timeoutSeconds: 10)
    let waiter = Task { () -> Result<SFSpeechRecognizerAuthorizationStatus, Error> in
      do {
        return .success(try await bridge.requestAuthorization())
      } catch {
        return .failure(error)
      }
    }

    for _ in 0..<100 where !requester.hasHandler {
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    waiter.cancel()
    let result = await waiter.value
    if case let .failure(error) = result {
      XCTAssertEqual(error as? AudioTranscriberError, .cancelled)
    } else {
      XCTFail("authorization cancellation must resume immediately")
    }

    requester.respond(.authorized)
    XCTAssertEqual(requester.responseCount, 1)
  }

  func testSpeechAuthorizationPolicyDistinguishesNotDeterminedAndRestricted() {
    XCTAssertEqual(
      AudioSpeechAuthorizationPolicy.error(for: .notDetermined),
      .authorizationDenied
    )
    XCTAssertEqual(
      AudioSpeechAuthorizationPolicy.error(for: .restricted),
      .authorizationRestricted
    )
    XCTAssertNil(AudioSpeechAuthorizationPolicy.error(for: .authorized))
  }

  func testRawWordIDsMustBeUnique() {
    let first = AudioTranscriptWord(id: "duplicate", text: "one", startTime: 0, duration: 1, source: .mixed)
    let second = AudioTranscriptWord(id: "duplicate", text: "two", startTime: 1, duration: 1, source: .mixed)
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "one", startTime: 0, duration: 1, source: .mixed, words: [first]),
      AudioTranscriptSegment(text: "two", startTime: 1, duration: 1, source: .mixed, words: [second])
    ])
    XCTAssertFalse(raw.hasValidStructure)
  }

  func testPipelinePrunesStaleChunksAtEveryRunBoundaryWithoutDeletingMedia() async throws {
    let sessionID = UUID()
    let source = try makeSourceFile(sessionID: sessionID)
    let input = AudioTranscriptionSourceInput(source: .mixed, url: source, durationSeconds: 1)
    let transcriber = FakeTranscriber(raw: AudioRawTranscript(
      sessionID: sessionID,
      segments: [AudioTranscriptSegment(text: "hello", startTime: 0, duration: 1, source: .mixed)]
    ))
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: transcriber,
      llmProcessor: UnavailableLLM()
    )
    _ = try await pipeline.process(
      sessionID: sessionID,
      sourceInputs: [input],
      options: AudioProcessingOptions(autoAI: false)
    )

    for boundary in 0..<2 {
      let chunks = try store.chunksDirectoryURL(for: sessionID)
      let staleRoot = chunks.appendingPathComponent("run-stale-\(boundary)", isDirectory: true)
      try FileManager.default.createDirectory(at: staleRoot, withIntermediateDirectories: true)
      try Data([1, 2, 3]).write(to: staleRoot.appendingPathComponent("chunk.m4a"))
      if boundary == 0 {
        _ = try await pipeline.resume(sessionID: sessionID, sourceInputs: [input])
      } else {
        _ = try await pipeline.restart(sessionID: sessionID, sourceInputs: [input])
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: staleRoot.path))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  func testPartialPolishedCheckpointSkipsPolishOnResume() async throws {
    let sessionID = UUID()
    let source = try makeSourceFile(sessionID: sessionID)
    let raw = AudioRawTranscript(sessionID: sessionID, segments: [
      AudioTranscriptSegment(text: "checkpoint", startTime: 0, duration: 1, source: .mixed)
    ])
    let task = AudioProcessingTask(
      sessionID: sessionID,
      template: .generalNotes,
      autoAI: true,
      sourcePaths: [.mixed: "mixed.m4a"]
    )
    _ = try store.persistTask(task)
    try store.persistRawTranscript(raw, sessionID: sessionID)
    try store.persistPolishedTranscript(
      AudioPolishedTranscript(text: "already polished", sourceSegmentIDs: raw.segments.map(\.id)),
      sessionID: sessionID
    )
    let provider = CheckpointProvider()
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: FakeTranscriber(raw: raw),
      llmProcessor: LocalAudioLLMProcessor(provider: provider)
    )

    let result = try await pipeline.resume(
      sessionID: sessionID,
      sourceInputs: [AudioTranscriptionSourceInput(
        source: .mixed,
        url: source,
        durationSeconds: 1
      )]
    )
    XCTAssertEqual(result.task.stage, .completed)
    XCTAssertEqual(provider.polishCount, 0)
    XCTAssertEqual(provider.organizeCount, 1)
    XCTAssertNotNil(try store.loadStructuredContent(sessionID: sessionID))
    let persistedRaw = try store.loadRawTranscript(sessionID: sessionID)
    XCTAssertEqual(persistedRaw.text, raw.text)
    XCTAssertEqual(persistedRaw.segments, raw.segments)
  }

  func testSingleFlightCancelledWaiterReturnsWithoutWaitingForActiveOperation() async {
    let flight = AudioProcessingTaskSingleFlight()
    let sessionID = UUID()
    let activeStarted = XCTestExpectation(description: "active operation started")
    let active = Task { () -> Result<Int, Error> in
      do {
        let value = try await flight.withExclusive(sessionID: sessionID) {
          activeStarted.fulfill()
          try await Task.sleep(nanoseconds: 60_000_000_000)
          return 1
        }
        return .success(value)
      } catch {
        return .failure(error)
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let waiter = Task { () -> Result<Int, Error> in
      do {
        return .success(try await flight.withExclusive(sessionID: sessionID) { 2 })
      } catch {
        return .failure(error)
      }
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
    let cancelStart = Date()
    waiter.cancel()
    let waiterResult = await waiter.value
    XCTAssertLessThan(Date().timeIntervalSince(cancelStart), 1)
    if case let .failure(error) = waiterResult {
      XCTAssertTrue(error is CancellationError)
    } else {
      XCTFail("cancelled waiter must not acquire the active session")
    }

    active.cancel()
    _ = await active.value
  }

  func testSecondResumeWaiterCannotCleanupActiveRunChunks() async throws {
    let sessionID = UUID()
    let source = try makeSourceFile(sessionID: sessionID)
    let input = AudioTranscriptionSourceInput(source: .mixed, url: source, durationSeconds: 1)
    let raw = AudioRawTranscript(sessionID: sessionID, segments: [
      AudioTranscriptSegment(text: "blocked", startTime: 0, duration: 1, source: .mixed)
    ])
    let transcriber = BlockingTranscriber(raw: raw)
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: transcriber,
      llmProcessor: UnavailableLLM()
    )

    let active = Task {
      try await pipeline.process(
        sessionID: sessionID,
        sourceInputs: [input],
        options: AudioProcessingOptions(autoAI: false)
      )
    }
    await transcriber.started.wait()

    let activeRun = try store.chunksDirectoryURL(for: sessionID)
      .appendingPathComponent("run-active", isDirectory: true)
    try FileManager.default.createDirectory(at: activeRun, withIntermediateDirectories: true)
    let activeChunk = activeRun.appendingPathComponent("chunk.m4a")
    try Data([4, 5, 6]).write(to: activeChunk)

    let second = Task {
      try await pipeline.resume(sessionID: sessionID, sourceInputs: [input])
    }
    var sawWaiter = false
    for _ in 0..<1_000 {
      if await AudioRecordingProcessingPipeline.singleFlight.waiterCount(for: sessionID) == 1 {
        sawWaiter = true
        break
      }
      await Task.yield()
    }
    XCTAssertTrue(sawWaiter, "second run must queue before it can clean chunks")
    XCTAssertTrue(FileManager.default.fileExists(atPath: activeChunk.path))

    await transcriber.release.signal()
    _ = try await active.value
    _ = try await second.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: activeRun.path))
  }

  func testReservedSourceIsRejectedAndRemainsOnDiskAcrossPipelineBoundary() async throws {
    let sessionID = UUID()
    let reservedDirectory = try store.chunksDirectoryURL(for: sessionID)
    let reserved = reservedDirectory.appendingPathComponent("reserved-source.m4a")
    try Data([7, 8, 9]).write(to: reserved)
    let pipeline = AudioRecordingProcessingPipeline(
      taskStore: store,
      transcriber: FakeTranscriber(raw: AudioRawTranscript(sessionID: sessionID, segments: [])),
      llmProcessor: UnavailableLLM()
    )

    do {
      _ = try await pipeline.process(
        sessionID: sessionID,
        sourceInputs: [AudioTranscriptionSourceInput(
          source: .mixed,
          url: reserved,
          durationSeconds: 1
        )]
      )
      XCTFail("Processing/Chunks source must be rejected")
    } catch let error as AudioRecordingProcessingPipelineError {
      XCTAssertEqual(error, .unsafeSourcePath)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: reserved.path))
  }

  func testDefaultExistingPolishedOverloadRejectsCheckpoint() async throws {
    let raw = AudioRawTranscript(segments: [
      AudioTranscriptSegment(text: "checkpoint", startTime: 0, duration: 1, source: .mixed)
    ])
    let checkpoint = AudioPolishedTranscript(
      text: "already polished",
      sourceSegmentIDs: raw.segments.map(\.id)
    )
    let provider: any AudioLLMProcessing = LegacyLLM()
    do {
      _ = try await provider.process(
        raw: raw,
        template: .generalNotes,
        language: nil,
        existingPolished: checkpoint
      )
      XCTFail("legacy providers must not silently re-polish a checkpoint")
    } catch let error as AudioLocalLLMError {
      XCTAssertEqual(error, .invalidOutput)
    }
  }

  private func makeSourceFile(sessionID: UUID, name: String = "mixed.m4a") throws -> URL {
    let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name, isDirectory: false)
    if !FileManager.default.fileExists(atPath: url.path) {
      try Data([0, 1, 2]).write(to: url)
    }
    return url
  }

  private struct FakeTranscriber: AudioTranscribing {
    let raw: AudioRawTranscript

    func transcribe(
      sources: [AudioTranscriptionSourceInput],
      language: AudioRecordingLanguage,
      processingDirectory: URL?,
      sessionID: UUID?
    ) async throws -> AudioRawTranscript {
      raw
    }
  }

  private final class BlockingTranscriber: @unchecked Sendable, AudioTranscribing {
    let raw: AudioRawTranscript
    let started = AsyncLatch()
    let release = AsyncLatch()

    init(raw: AudioRawTranscript) {
      self.raw = raw
    }

    func transcribe(
      sources: [AudioTranscriptionSourceInput],
      language: AudioRecordingLanguage,
      processingDirectory: URL?,
      sessionID: UUID?
    ) async throws -> AudioRawTranscript {
      await started.signal()
      await release.wait()
      return raw
    }
  }

  private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    func signal() {
      isOpen = true
      let pending = waiters
      waiters.removeAll(keepingCapacity: false)
      pending.forEach { $0.resume() }
    }
  }

  private struct UnavailableLLM: AudioLLMProcessing {
    func process(
      raw: AudioRawTranscript,
      template: AudioOrganizationTemplate,
      language: AudioRecordingLanguage?
    ) async throws -> AudioLLMProcessingResult {
      throw AudioLocalLLMError.modelUnavailable("test")
    }

    func process(
      raw: AudioRawTranscript,
      template: AudioOrganizationTemplate,
      language: AudioRecordingLanguage?,
      existingPolished: AudioPolishedTranscript?
    ) async throws -> AudioLLMProcessingResult {
      throw AudioLocalLLMError.modelUnavailable("test")
    }
  }

  private struct LegacyLLM: AudioLLMProcessing {
    func process(
      raw: AudioRawTranscript,
      template: AudioOrganizationTemplate,
      language: AudioRecordingLanguage?
    ) async throws -> AudioLLMProcessingResult {
      let ids = raw.segments.map(\.id)
      return AudioLLMProcessingResult(
        polished: AudioPolishedTranscript(text: "polished", sourceSegmentIDs: ids),
        structured: AudioStructuredContent(template: template, transcriptSegmentIDs: ids)
      )
    }
  }

  private struct UnknownCitationProvider: LocalAudioLanguageModelProvider {
    var availability: AudioLocalModelAvailability { .available }

    func polish(input: AudioLLMInput) async throws -> String { "polished" }

    func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch {
      AudioLLMStructuredBatch(notes: [AudioGeneralNote(text: "bad", segmentIDs: ["unknown"])])
    }
  }

  private struct WhitespacePolishProvider: LocalAudioLanguageModelProvider {
    var availability: AudioLocalModelAvailability { .available }

    func polish(input: AudioLLMInput) async throws -> String { " \n\t" }

    func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch {
      AudioLLMStructuredBatch()
    }
  }

  private struct EmptyStructuredProvider: LocalAudioLanguageModelProvider {
    var availability: AudioLocalModelAvailability { .available }

    func polish(input: AudioLLMInput) async throws -> String { "polished" }

    func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch {
      AudioLLMStructuredBatch()
    }
  }

  private final class OrganizeCallCounterProvider: @unchecked Sendable,
    LocalAudioLanguageModelProvider {
    private let lock = NSLock()
    private var storedOrganizeCount = 0

    var availability: AudioLocalModelAvailability { .available }

    var organizeCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return storedOrganizeCount
    }

    func polish(input: AudioLLMInput) async throws -> String { "polished" }

    func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch {
      incrementOrganizeCount()
      return AudioLLMStructuredBatch()
    }

    private func incrementOrganizeCount() {
      lock.lock()
      storedOrganizeCount += 1
      lock.unlock()
    }
  }

  private final class AuthorizationRequesterSpy: @unchecked Sendable,
    SpeechAuthorizationRequester {
    private let lock = NSLock()
    private var handler: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
    private var storedResponseCount = 0

    var hasHandler: Bool {
      lock.lock()
      defer { lock.unlock() }
      return handler != nil
    }

    var responseCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return storedResponseCount
    }

    func requestAuthorization(
      _ handler: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
      lock.lock()
      self.handler = handler
      lock.unlock()
    }

    func respond(_ status: SFSpeechRecognizerAuthorizationStatus) {
      lock.lock()
      let callback = handler
      storedResponseCount += 1
      lock.unlock()
      callback?(status)
    }
  }

  private final class CheckpointProvider: @unchecked Sendable,
    LocalAudioLanguageModelProvider {
    private let lock = NSLock()
    private var storedPolishCount = 0
    private var storedOrganizeCount = 0

    var availability: AudioLocalModelAvailability { .available }

    var polishCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return storedPolishCount
    }

    var organizeCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return storedOrganizeCount
    }

    func polish(input: AudioLLMInput) async throws -> String {
      incrementPolishCount()
      return "unexpected polish"
    }

    func organize(input: AudioLLMInput) async throws -> AudioLLMStructuredBatch {
      incrementOrganizeCount()
      return AudioLLMStructuredBatch(notes: [AudioGeneralNote(
        text: "note",
        segmentIDs: [input.segments[0].id]
      )])
    }

    private func incrementPolishCount() {
      lock.lock()
      storedPolishCount += 1
      lock.unlock()
    }

    private func incrementOrganizeCount() {
      lock.lock()
      storedOrganizeCount += 1
      lock.unlock()
    }
  }

  private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func increment() {
      lock.lock()
      storage += 1
      lock.unlock()
    }
  }

  private final nonisolated class RawRaceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var recordedErrors: [AudioProcessingTaskStoreError] = []

    var successCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return successes
    }

    var errors: [AudioProcessingTaskStoreError] {
      lock.lock()
      defer { lock.unlock() }
      return recordedErrors
    }

    func recordSuccess() {
      lock.lock()
      successes += 1
      lock.unlock()
    }

    func record(error: AudioProcessingTaskStoreError) {
      lock.lock()
      recordedErrors.append(error)
      lock.unlock()
    }
  }

  private struct CountingLLM: AudioLLMProcessing {
    let counter: CallCounter

    func process(
      raw: AudioRawTranscript,
      template: AudioOrganizationTemplate,
      language: AudioRecordingLanguage?
    ) async throws -> AudioLLMProcessingResult {
      counter.increment()
      let ids = raw.segments.map(\.id)
      return AudioLLMProcessingResult(
        polished: AudioPolishedTranscript(text: "polished", sourceSegmentIDs: ids),
        structured: AudioStructuredContent(
          template: template,
          transcriptSegmentIDs: ids
        )
      )
    }

    func process(
      raw: AudioRawTranscript,
      template: AudioOrganizationTemplate,
      language: AudioRecordingLanguage?,
      existingPolished: AudioPolishedTranscript?
    ) async throws -> AudioLLMProcessingResult {
      guard existingPolished == nil else {
        throw AudioLocalLLMError.invalidOutput
      }
      return try await process(raw: raw, template: template, language: language)
    }
  }
}
