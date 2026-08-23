//
//  TranslationSessionCoordinatorTests.swift
//  ShotPasteTests
//

import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class TranslationSessionCoordinatorTests: XCTestCase {
  func testFirstGateRejectsTextSharingDisabledWithoutOCROrProvider() async throws {
    let providerState = ProviderState()
    let provider = StubTextProvider(state: providerState)
    let ocrState = OCRExecutorState()
    let coordinator = makeCoordinator(
      provider: provider,
      ocrState: ocrState,
      sendRecognizedText: { false }
    )

    coordinator.begin(input: try input())
    XCTAssertEqual(coordinator.phase, .failed(.recognizedTextSharingDisabled))
    XCTAssertEqual(ocrState.calls, 0)
    XCTAssertEqual(providerState.calls, 0)
  }

  func testAgentImageFlagDoesNotAffectAvailability() async {
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: ProviderState()),
      ocrState: OCRExecutorState(),
      sendsImages: false
    )
    XCTAssertEqual(coordinator.availability(), .available)
  }

  func testProgressTargetFreezeAndLocalOCRBoundsReachShowingResult() async throws {
    let providerState = ProviderState()
    let ocrState = OCRExecutorState(observations: [observation(text: "Welcome")])
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: providerState),
      ocrState: ocrState
    )
    coordinator.targetLanguage = .language("zh-Hans")
    let imageInput = try input()

    coordinator.begin(input: imageInput, deadline: Date().addingTimeInterval(3))
    XCTAssertEqual(coordinator.phase, .translating)
    XCTAssertEqual(coordinator.progress, .recognizingText)
    // A setting changed after click must not change this request's target.
    coordinator.targetLanguage = .language("ja")

    try await waitUntil { coordinator.phase == .showingResult }
    XCTAssertEqual(coordinator.phase, .showingResult)
    XCTAssertEqual(coordinator.resolvedTargetLanguage?.identifier, "zh-Hans")
    XCTAssertEqual(providerState.targetLanguages, ["zh-Hans"])
    XCTAssertEqual(coordinator.renderBlocks.count, 1)
    XCTAssertEqual(coordinator.renderBlocks.first?.translatedText, "翻译-Welcome")
    XCTAssertEqual(coordinator.renderBlocks.first?.screenBounds, CGRect(x: 10, y: 60, width: 60, height: 20))
    XCTAssertGreaterThanOrEqual(coordinator.renderBlocks.first?.confidence ?? 0, 0.9)
  }

  func testExplicitlyResolvedTargetSurvivesSelectionChangeBeforeBegin() async throws {
    let providerState = ProviderState()
    let ocrState = OCRExecutorState(observations: [observation(text: "Welcome")])
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: providerState),
      ocrState: ocrState
    )
    coordinator.targetLanguage = .currentLanguage
    let clickedTarget = TranslationSessionCoordinator.resolveTargetLanguage(
      selection: coordinator.targetLanguage,
      currentLanguageIdentifier: "zh-Hans"
    )

    // Simulate the selector/app language changing while the frozen crop is
    // being prepared. The request must continue using the click-time value.
    coordinator.targetLanguage = .language("ja")
    coordinator.begin(
      input: try input(),
      deadline: Date().addingTimeInterval(3),
      targetLanguage: clickedTarget
    )

    try await waitUntil { coordinator.phase == .showingResult }
    XCTAssertEqual(providerState.targetLanguages, ["zh-Hans"])
    XCTAssertEqual(coordinator.resolvedTargetLanguage?.identifier, "zh-Hans")
  }

  func testExplicitlyFrozenSourceSurvivesSelectionChangeBeforeBegin() async throws {
    let providerState = ProviderState()
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: providerState),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome")])
    )
    let clickedSource = TranslationSourceLanguage.language("en")
    coordinator.sourceLanguage = .language("ja")
    coordinator.begin(
      input: try input(),
      deadline: Date().addingTimeInterval(3),
      sourceLanguage: clickedSource
    )

    try await waitUntil { coordinator.phase == .showingResult }
    XCTAssertEqual(providerState.sourceLanguages, ["en"])
  }

  func testLowConfidenceOCRStillRendersAndRecordsCount() async throws {
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: ProviderState()),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome", confidence: 0.4)])
    )

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    try await waitUntil { coordinator.phase == .showingResult }

    XCTAssertEqual(coordinator.lowConfidenceLineCount, 1)
    XCTAssertEqual(coordinator.renderBlocks.count, 1)
  }

  func testPrivacyGateClosedAtCommitFenceNeverRenders() async throws {
    let gate = PrivacyGate(allowed: true)
    let commitReached = TranslationTestLatch()
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: ProviderState()),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome")]),
      sendRecognizedText: { gate.isAllowed },
      beforeCommit: {
        // This runs after local layout has completed and immediately before
        // the MainActor output commit fence.
        gate.isAllowed = false
        await commitReached.signal()
      }
    )
    var terminalFailure: TranslationFailure?
    coordinator.onTerminalExit = { terminalFailure = $0 }

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    await commitReached.wait()
    try await waitUntil { coordinator.phase == .terminating }
    XCTAssertEqual(terminalFailure, .recognizedTextSharingDisabled)
    XCTAssertTrue(coordinator.renderBlocks.isEmpty)
    XCTAssertNil(coordinator.resultInput)
  }

  func testDeadlineExpiredAtCommitFenceNeverRenders() async throws {
    let deadline = Date().addingTimeInterval(5)
    let clock = TranslationTestClock(now: Date())
    let commitReached = TranslationTestLatch()
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: ProviderState()),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome")]),
      beforeCommit: {
        clock.now = deadline.addingTimeInterval(1)
        await commitReached.signal()
      },
      now: { clock.now }
    )

    coordinator.begin(input: try input(), deadline: deadline)
    await commitReached.wait()
    try await waitUntil { coordinator.phase == .terminating }
    XCTAssertTrue(coordinator.renderBlocks.isEmpty)
    XCTAssertNil(coordinator.resultInput)
  }

  func testProviderAuthenticationFailureMapsToSettingsTerminal() async throws {
    let coordinator = makeCoordinator(
      provider: StatusTextProvider(status: 401),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome")])
    )
    var terminalFailure: TranslationFailure?
    coordinator.onTerminalExit = { terminalFailure = $0 }

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    try await waitUntil { coordinator.phase == .terminating }

    XCTAssertEqual(terminalFailure, .providerStatus(401))
    XCTAssertTrue(coordinator.renderBlocks.isEmpty)
  }

  func testSecondGateStopsProviderAfterBeginWithoutPartialRender() async throws {
    let gate = PrivacyGate(allowed: true)
    let providerState = ProviderState()
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: providerState),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome")]),
      sendRecognizedText: { gate.isAllowed }
    )
    var terminalFailure: TranslationFailure?
    coordinator.onTerminalExit = { terminalFailure = $0 }

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    gate.isAllowed = false
    try await waitUntil { coordinator.phase == .terminating }

    XCTAssertEqual(terminalFailure, .recognizedTextSharingDisabled)
    XCTAssertEqual(providerState.calls, 0)
    XCTAssertTrue(coordinator.renderBlocks.isEmpty)
  }

  func testCancelInvalidatesGenerationAndDiscardsLateProviderResult() async throws {
    let providerState = ProviderState(delay: 0.15)
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: providerState),
      ocrState: OCRExecutorState(observations: [observation(text: "Welcome")])
    )

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    try await waitUntil { providerState.calls > 0 }
    coordinator.cancel()
    try await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(coordinator.phase, .terminating)
    XCTAssertTrue(coordinator.renderBlocks.isEmpty)
    XCTAssertNil(coordinator.resultInput)
  }

  func testPreserveOriginalBlockNeverReachesProvider() async throws {
    let providerState = ProviderState()
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: providerState),
      ocrState: OCRExecutorState(observations: [observation(text: "https://example.com")])
    )

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    try await waitUntil { coordinator.phase == .showingResult }

    XCTAssertEqual(providerState.calls, 0)
    XCTAssertEqual(coordinator.renderBlocks.first?.sourceText, "https://example.com")
    XCTAssertEqual(coordinator.renderBlocks.first?.translatedText, "https://example.com")
  }

  func testNoOCRTextFailsWithoutRendering() async throws {
    let coordinator = makeCoordinator(
      provider: StubTextProvider(state: ProviderState()),
      ocrState: OCRExecutorState(observations: [])
    )

    coordinator.begin(input: try input(), deadline: Date().addingTimeInterval(3))
    try await waitUntil { if case .failed(.noText) = coordinator.phase { return true }; return false }
    XCTAssertTrue(coordinator.renderBlocks.isEmpty)
  }

  func testBatchExecutorLimitsConcurrencyAndRejectsMissingID() async throws {
    let providerState = ProviderState(delay: 0.03)
    let provider = StubTextProvider(state: providerState)
    let request = TranslationTextRequest(
      generationID: "generation-batch",
      sourceLanguage: "auto",
      targetLanguage: "zh-Hans",
      blocks: (0 ..< 205).map {
        TranslationTextRequestBlock(id: String(format: "block-%04d", $0), text: "Text \($0)")
      }
    )
    let batches = try TranslationTextBatcher.makeBatches(from: request)
    let result = try await TranslationBatchExecutor.execute(
      batches: batches,
      provider: provider,
      configuration: configuration(),
      apiKey: "test-key-not-secret",
      deadline: Date().addingTimeInterval(3),
      sendRecognizedText: { true }
    )
    XCTAssertEqual(result.translations.count, 205)
    XCTAssertEqual(providerState.calls, 3)
    XCTAssertLessThanOrEqual(providerState.maxInFlight, 2)

    let incomplete = IncompleteTextProvider()
    do {
      _ = try await TranslationBatchExecutor.execute(
        batches: [TranslationTextRequest(
          generationID: "generation-batch",
          sourceLanguage: "auto",
          targetLanguage: "zh-Hans",
          blocks: [TranslationTextRequestBlock(id: "block-0000", text: "Text")]
        )],
        provider: incomplete,
        configuration: configuration(),
        apiKey: "test-key-not-secret",
        deadline: Date().addingTimeInterval(3),
        sendRecognizedText: { true }
      )
      XCTFail("missing ids must reject the whole batch")
    } catch let error as TranslationTextProviderError {
      XCTAssertEqual(error, .invalidResponse)
    }
  }

  func testBatchExecutorDoesNotStartWhenDeadlineBudgetIsInsufficient() async throws {
    let state = ProviderState()
    let request = TranslationTextRequest(
      generationID: "generation-deadline",
      sourceLanguage: "auto",
      targetLanguage: "en",
      blocks: [TranslationTextRequestBlock(id: "block-0001", text: "Text")]
    )
    do {
      _ = try await TranslationBatchExecutor.execute(
        batches: [request],
        provider: StubTextProvider(state: state),
        configuration: configuration(),
        apiKey: "test-key-not-secret",
        deadline: Date().addingTimeInterval(0.000_1),
        sendRecognizedText: { true }
      )
      XCTFail("expired start budget must fail")
    } catch let error as TranslationTextProviderError {
      XCTAssertEqual(error, .timedOut)
    }
    XCTAssertEqual(state.calls, 0)
  }

  func testBatchExecutorPrivacyMonitorReturnsPromptlyAndDropsLateBatches() async throws {
    let gate = PrivacyGate(allowed: true)
    let state = NonCooperativeBatchProviderState(delay: 0.30)
    let request = batchRequest(blockCount: 205)
    let batches = try TranslationTextBatcher.makeBatches(from: request)
    let task = Task {
      () -> Result<TranslationBatchExecutor.Result, Error> in
      do {
        return .success(try await TranslationBatchExecutor.execute(
          batches: batches,
          provider: NonCooperativeBatchProvider(state: state),
          configuration: configuration(),
          apiKey: "test-key-not-secret",
          deadline: Date().addingTimeInterval(5),
          sendRecognizedText: { gate.isAllowed }
        ))
      } catch {
        return .failure(error)
      }
    }

    try await waitUntil { state.calls >= 2 }
    let gateClosedAt = Date()
    gate.isAllowed = false
    let outcome = await task.value
    XCTAssertLessThan(Date().timeIntervalSince(gateClosedAt), 0.20)
    if case .success = outcome {
      XCTFail("privacy failure must not return a partial result")
    } else if case .failure(let error) = outcome {
      XCTAssertEqual(error as? TranslationFailure, .recognizedTextSharingDisabled)
    }

    // Cancellation is best effort for Thread.sleep, but no third batch may
    // start and no late worker may turn its response into a result.
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(state.calls, 2)
    XCTAssertLessThanOrEqual(state.maxInFlight, 2)
    XCTAssertGreaterThanOrEqual(state.cancellationCount, 1)
  }

  func testBatchExecutorCallerCancelReturnsPromptlyWithNonCooperativeProvider() async throws {
    let state = NonCooperativeBatchProviderState(delay: 0.30)
    let batches = try TranslationTextBatcher.makeBatches(from: batchRequest(blockCount: 205))
    let task = Task {
      () -> Result<TranslationBatchExecutor.Result, Error> in
      do {
        return .success(try await TranslationBatchExecutor.execute(
          batches: batches,
          provider: NonCooperativeBatchProvider(state: state),
          configuration: configuration(),
          apiKey: "test-key-not-secret",
          deadline: Date().addingTimeInterval(5),
          sendRecognizedText: { true }
        ))
      } catch {
        return .failure(error)
      }
    }

    try await waitUntil { state.calls >= 2 }
    let cancelledAt = Date()
    task.cancel()
    let outcome = await task.value
    XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.20)
    if case .success = outcome {
      XCTFail("caller cancellation must fail the request")
    }
  }

  func testBatchExecutorDeadlineReturnsPromptlyWithNonCooperativeProvider() async throws {
    let state = NonCooperativeBatchProviderState(delay: 0.30)
    let batches = try TranslationTextBatcher.makeBatches(from: batchRequest(blockCount: 205))
    let deadline = Date().addingTimeInterval(0.08)
    let task = Task {
      () -> Result<TranslationBatchExecutor.Result, Error> in
      do {
        return .success(try await TranslationBatchExecutor.execute(
          batches: batches,
          provider: NonCooperativeBatchProvider(state: state),
          configuration: configuration(),
          apiKey: "test-key-not-secret",
          deadline: deadline,
          sendRecognizedText: { true }
        ))
      } catch {
        return .failure(error)
      }
    }

    try await waitUntil { state.calls >= 2 }
    let outcome = await task.value
    if case .success = outcome {
      XCTFail("deadline must fail the request")
    } else if case .failure(let error) = outcome {
      XCTAssertEqual(error as? TranslationTextProviderError, .timedOut)
    }
  }

  func testBatchExecutorWaveBarrierSuccessFastFailureSlowDoesNotStartThirdBatch() async throws {
    let state = NonCooperativeBatchProviderState(
      delay: 0,
      failingID: "block-0100",
      failureDelay: 0.12,
      waitForSuccessfulBatchBeforeFailure: true
    )
    let request = batchRequest(blockCount: 205)
    let batches = try TranslationTextBatcher.makeBatches(from: request)
    let task = Task {
      () -> Result<TranslationBatchExecutor.Result, Error> in
      do {
        return .success(try await TranslationBatchExecutor.execute(
          batches: batches,
          provider: NonCooperativeBatchProvider(state: state),
          configuration: configuration(),
          apiKey: "test-key-not-secret",
          deadline: Date().addingTimeInterval(5),
          sendRecognizedText: { true }
        ))
      } catch {
        return .failure(error)
      }
    }

    await state.waitForFailureStart()
    let outcome = await task.value
    if case .success = outcome {
      XCTFail("one failed batch must reject the complete request")
    } else if case .failure(let error) = outcome {
      XCTAssertEqual(error as? TranslationTextProviderError, .providerStatus(500))
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(state.calls, 2)
    XCTAssertLessThanOrEqual(state.maxInFlight, 2)
  }

  func testBatchExecutorWaveBarrierFailureFastSuccessSlowDoesNotStartThirdBatch() async throws {
    let state = NonCooperativeBatchProviderState(
      delay: 0.30,
      failingID: "block-0000",
      failureDelay: 0,
      waitForSiblingBeforeFailure: true
    )
    let request = batchRequest(blockCount: 205)
    let batches = try TranslationTextBatcher.makeBatches(from: request)
    let task = Task {
      () -> Result<TranslationBatchExecutor.Result, Error> in
      do {
        return .success(try await TranslationBatchExecutor.execute(
          batches: batches,
          provider: NonCooperativeBatchProvider(state: state),
          configuration: configuration(),
          apiKey: "test-key-not-secret",
          deadline: Date().addingTimeInterval(5),
          sendRecognizedText: { true }
        ))
      } catch {
        return .failure(error)
      }
    }

    await state.waitForFailureStart()
    let failedAt = state.failureStartedAt ?? Date()
    let outcome = await task.value
    XCTAssertLessThan(Date().timeIntervalSince(failedAt), 0.20)
    if case .success = outcome {
      XCTFail("one failed batch must reject the complete request")
    } else if case .failure(let error) = outcome {
      XCTAssertEqual(error as? TranslationTextProviderError, .providerStatus(500))
    }
    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertEqual(state.calls, 2)
    XCTAssertLessThanOrEqual(state.maxInFlight, 2)
  }

  private func batchRequest(blockCount: Int) -> TranslationTextRequest {
    TranslationTextRequest(
      generationID: "generation-race",
      sourceLanguage: "auto",
      targetLanguage: "zh-Hans",
      blocks: (0 ..< blockCount).map {
        TranslationTextRequestBlock(id: String(format: "block-%04d", $0), text: "Text \($0)")
      }
    )
  }

  private func makeCoordinator(
    provider: any TranslationTextProvider,
    ocrState: OCRExecutorState,
    sendsImages: Bool = true,
    sendRecognizedText: @escaping @Sendable () -> Bool = { true },
    beforeCommit: (@Sendable () async -> Void)? = nil,
    now: @escaping () -> Date = { Date() }
  ) -> TranslationSessionCoordinator {
    TranslationSessionCoordinator(
      provider: provider,
      credentialStore: TranslationTestCredentials(apiKey: "test-key-not-secret"),
      preferences: {
        TranslationPreferences(
          timeoutSeconds: 5,
          promptMode: .builtin,
          prompt: "",
          sendRecognizedText: true
        )
      },
      providerConfiguration: { self.configuration(sendsImages: sendsImages) },
      ocrPipeline: TranslationOCRPipeline(executor: StubOCRExecutor(state: ocrState)),
      defaults: UserDefaults(suiteName: "TranslationSessionCoordinatorTests.\(UUID().uuidString)")!,
      sendRecognizedText: sendRecognizedText,
      beforeCommit: beforeCommit,
      now: now
    )
  }

  private func input() throws -> TranslationInput {
    TranslationInput(
      image: try XCTUnwrap(TestImageFactory.solidColor(width: 100, height: 100)),
      screenRect: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
  }

  private func configuration(sendsImages: Bool = true) -> AgentProviderConfiguration {
    AgentProviderConfiguration(
      endpoint: "https://example.com/v1/chat/completions",
      model: "text-model",
      thinkingEnabled: false,
      sendsImages: sendsImages,
      maxActions: 10
    )
  }

  private func observation(text: String, confidence: Float = 0.95) -> TranslationOCRObservation {
    TranslationOCRObservation(
      text: text,
      confidence: confidence,
      visionBounds: CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.2)
    )
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    for _ in 0 ..< 200 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition did not become true")
  }
}

nonisolated private struct TranslationTestCredentials: AgentCredentialProviding {
  let apiKey: String?

  func resolvedAPIKey() throws -> String? { apiKey }
}

nonisolated private final class PrivacyGate: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  var isAllowed: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }

  init(allowed: Bool) { value = allowed }
}

nonisolated private final class TranslationTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  var now: Date {
    get {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
    set {
      lock.lock()
      value = newValue
      lock.unlock()
    }
  }

  init(now: Date) { value = now }
}

private actor TranslationTestLatch {
  private var signaled = false
  private var waiter: CheckedContinuation<Void, Never>?

  func signal() {
    if let waiter {
      self.waiter = nil
      waiter.resume()
    } else {
      signaled = true
    }
  }

  func wait() async {
    if signaled {
      signaled = false
      return
    }
    await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }
}

nonisolated private final class OCRExecutorState: @unchecked Sendable {
  private let lock = NSLock()
  private var observationsStorage: [TranslationOCRObservation]
  private var callCount = 0

  var observations: [TranslationOCRObservation] {
    lock.lock()
    defer { lock.unlock() }
    return observationsStorage
  }

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  init(observations: [TranslationOCRObservation] = []) {
    observationsStorage = observations
  }

  func snapshotObservations() -> [TranslationOCRObservation] {
    lock.lock()
    defer { lock.unlock() }
    callCount += 1
    return observationsStorage
  }
}

nonisolated private struct StubOCRExecutor: TranslationOCRExecutor {
  let state: OCRExecutorState

  func recognize(
    tile _: LocalOCRTile,
    sourceLanguageIdentifier _: String?,
    deadline: Date
  ) async throws -> [TranslationOCRObservation] {
    try TranslationOCRDeadline.check(deadline)
    return state.snapshotObservations()
  }
}

nonisolated private final class ProviderState: @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0
  private var inFlightCount = 0
  private var maximumInFlight = 0
  private var sourceLanguageValues: [String] = []
  private var targetLanguageValues: [String] = []
  let delay: TimeInterval

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  var maxInFlight: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumInFlight
  }

  var sourceLanguages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return sourceLanguageValues
  }

  var targetLanguages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return targetLanguageValues
  }

  init(delay: TimeInterval = 0) { self.delay = delay }

  func enter(sourceLanguage: String, targetLanguage: String) {
    lock.lock()
    callCount += 1
    inFlightCount += 1
    maximumInFlight = max(maximumInFlight, inFlightCount)
    sourceLanguageValues.append(sourceLanguage)
    targetLanguageValues.append(targetLanguage)
    lock.unlock()
  }

  func leave() {
    lock.lock()
    inFlightCount -= 1
    lock.unlock()
  }

  func waitForDelay() {
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
  }
}

nonisolated private struct StubTextProvider: TranslationTextProvider {
  let state: ProviderState

  init(state: ProviderState) { self.state = state }

  func translate(
    request: TranslationTextRequest,
    configuration _: AgentProviderConfiguration,
    apiKey _: String?,
    deadline _: Date
  ) async throws -> TranslationTextResponse {
    state.enter(sourceLanguage: request.sourceLanguage, targetLanguage: request.targetLanguage)
    defer { state.leave() }
    state.waitForDelay()
    return TranslationTextResponse(
      generationID: request.generationID,
      translations: request.blocks.map {
        TranslationTextResultBlock(id: $0.id, translatedText: "翻译-\($0.text)")
      }
    )
  }
}

nonisolated private struct IncompleteTextProvider: TranslationTextProvider {
  func translate(
    request: TranslationTextRequest,
    configuration _: AgentProviderConfiguration,
    apiKey _: String?,
    deadline _: Date
  ) async throws -> TranslationTextResponse {
    TranslationTextResponse(
      generationID: request.generationID,
      translations: []
    )
  }
}

nonisolated private struct StatusTextProvider: TranslationTextProvider {
  let status: Int

  func translate(
    request _: TranslationTextRequest,
    configuration _: AgentProviderConfiguration,
    apiKey _: String?,
    deadline _: Date
  ) async throws -> TranslationTextResponse {
    throw TranslationTextProviderError.providerStatus(status)
  }
}

nonisolated private final class NonCooperativeBatchProviderState: @unchecked Sendable {
  private let lock = NSLock()
  private let delay: TimeInterval
  private let failingID: String?
  private let failureDelay: TimeInterval
  private let waitForSiblingBeforeFailure: Bool
  private let waitForSuccessfulBatchBeforeFailureEnabled: Bool
  private let siblingReady = TranslationTestLatch()
  private let successfulBatchCompleted = TranslationTestLatch()
  private let failureStarted = TranslationTestLatch()
  private var callCount = 0
  private var inFlightCount = 0
  private var maximumInFlight = 0
  private var cancellations = 0
  private var failureStartedAtValue: Date?

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  var maxInFlight: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumInFlight
  }

  var cancellationCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return cancellations
  }

  var failureStartedAt: Date? {
    lock.lock()
    defer { lock.unlock() }
    return failureStartedAtValue
  }

  init(
    delay: TimeInterval,
    failingID: String? = nil,
    failureDelay: TimeInterval? = nil,
    waitForSiblingBeforeFailure: Bool = false,
    waitForSuccessfulBatchBeforeFailure: Bool = false
  ) {
    self.delay = delay
    self.failingID = failingID
    self.failureDelay = failureDelay ?? delay
    self.waitForSiblingBeforeFailure = waitForSiblingBeforeFailure
    self.waitForSuccessfulBatchBeforeFailureEnabled = waitForSuccessfulBatchBeforeFailure
  }

  func enter() async {
    let isSecondCall = recordEnter()
    if isSecondCall { await siblingReady.signal() }
  }

  private func recordEnter() -> Bool {
    lock.lock()
    callCount += 1
    inFlightCount += 1
    maximumInFlight = max(maximumInFlight, inFlightCount)
    let isSecondCall = callCount == 2
    lock.unlock()
    return isSecondCall
  }

  func leave() {
    lock.lock()
    inFlightCount -= 1
    lock.unlock()
  }

  func markCancellation() {
    lock.lock()
    cancellations += 1
    lock.unlock()
  }

  func shouldFail(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failingID == id
  }

  func waitForSiblingBeforeFailure(_ id: String) async {
    guard waitForSiblingBeforeFailure, shouldFail(id) else { return }
    await siblingReady.wait()
  }

  func waitForSuccessfulBatchBeforeFailure(_ id: String) async {
    guard waitForSuccessfulBatchBeforeFailureEnabled, shouldFail(id) else { return }
    await successfulBatchCompleted.wait()
  }

  func markSuccessfulBatchCompleted(_ id: String) async {
    guard waitForSuccessfulBatchBeforeFailureEnabled, !shouldFail(id) else { return }
    await successfulBatchCompleted.signal()
  }

  func markFailureStarted() async {
    guard recordFailureStarted() else { return }
    await failureStarted.signal()
  }

  private func recordFailureStarted() -> Bool {
    lock.lock()
    let shouldSignal = failureStartedAtValue == nil
    if shouldSignal { failureStartedAtValue = Date() }
    lock.unlock()
    return shouldSignal
  }

  func waitForFailureStart() async {
    await failureStarted.wait()
  }

  func wait(for id: String) {
    if shouldFail(id) {
      Thread.sleep(forTimeInterval: failureDelay)
    } else if delay > 0 {
      Thread.sleep(forTimeInterval: delay)
    }
  }
}

nonisolated private struct NonCooperativeBatchProvider: TranslationTextProvider {
  let state: NonCooperativeBatchProviderState

  func translate(
    request: TranslationTextRequest,
    configuration _: AgentProviderConfiguration,
    apiKey _: String?,
    deadline _: Date
  ) async throws -> TranslationTextResponse {
    await state.enter()
    defer { state.leave() }
    let firstID = request.blocks.first?.id ?? ""
    await state.waitForSiblingBeforeFailure(firstID)
    await state.waitForSuccessfulBatchBeforeFailure(firstID)
    state.wait(for: firstID)
    if Task.isCancelled {
      state.markCancellation()
    }
    if state.shouldFail(firstID) {
      await state.markFailureStarted()
      throw TranslationTextProviderError.providerStatus(500)
    }
    await state.markSuccessfulBatchCompleted(firstID)
    return TranslationTextResponse(
      generationID: request.generationID,
      translations: request.blocks.map {
        TranslationTextResultBlock(id: $0.id, translatedText: "translated")
      }
    )
  }
}
