//
//  TranslationSessionCoordinator.swift
//  ShotPaste
//
//  Local OCR -> local language/paragraph result -> text-only provider -> local
//  layout. The coordinator owns the session deadline and generation fence; it
//  never gives a provider a frozen image or OCR geometry.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
final class TranslationSessionCoordinator: ObservableObject {
  @Published private(set) var phase: TranslationSessionPhase = .ready
  @Published private(set) var progress: TranslationProgress?
  @Published private(set) var renderBlocks: [TranslationRenderBlock] = []
  @Published private(set) var detectedSourceLanguage: String?
  @Published private(set) var lowConfidenceLineCount = 0
  @Published private(set) var resolvedTargetLanguage: TranslationResolvedLanguage?
  @Published private(set) var resultInput: TranslationInput?
  @Published var sourceLanguage: TranslationSourceLanguage = .automatic
  @Published var targetLanguage: TranslationTargetLanguage = .currentLanguage

  /// The inline selection host owns desktop teardown. Timeout and provider
  /// configuration failures ask it to close only after this task is cancelled.
  var onTerminalExit: ((TranslationFailure) -> Void)?

  private let provider: any TranslationTextProvider
  private let credentialStore: any AgentCredentialProviding
  private let preferences: () -> TranslationPreferences
  private let providerConfiguration: () -> AgentProviderConfiguration
  private let ocrPipeline: TranslationOCRPipeline
  private let layoutResolver: TranslationLayoutResolver
  private let migrationDefaults: UserDefaults
  private let sendRecognizedText: @Sendable () -> Bool
  /// Test-only synchronization seam. Production construction leaves this
  /// nil; the seam lets tests close the privacy gate or invalidate a clock
  /// after local layout has completed but before the MainActor commit fence.
  private let beforeCommit: (@Sendable () async -> Void)?
  private let now: () -> Date
  private var requestTask: Task<Void, Never>?
  private var activeGeneration: UUID?

  init() {
    let defaults = UserDefaults.standard
    let defaultsBox = TranslationUserDefaultsBox(defaults)
    provider = TranslationConfigurableTextProvider()
    credentialStore = AgentCredentialStore.shared
    preferences = { TranslationPreferences.current(defaults: defaults) }
    providerConfiguration = { AgentProviderConfiguration.current(defaults: defaults) }
    ocrPipeline = TranslationOCRPipeline()
    layoutResolver = TranslationLayoutResolver()
    migrationDefaults = defaultsBox.defaults
    sendRecognizedText = {
      TranslationSettingsMigration.sendRecognizedText(defaults: defaultsBox.defaults)
    }
    beforeCommit = nil
    now = { Date() }
  }

  init(
    provider: any TranslationTextProvider,
    credentialStore: any AgentCredentialProviding,
    preferences: @escaping () -> TranslationPreferences,
    providerConfiguration: @escaping () -> AgentProviderConfiguration,
    ocrPipeline: TranslationOCRPipeline = TranslationOCRPipeline(),
    layoutResolver: TranslationLayoutResolver = TranslationLayoutResolver(),
    defaults: UserDefaults = .standard,
    sendRecognizedText: (@Sendable () -> Bool)? = nil,
    beforeCommit: (@Sendable () async -> Void)? = nil,
    now: @escaping () -> Date = { Date() }
  ) {
    let defaultsBox = TranslationUserDefaultsBox(defaults)
    self.provider = provider
    self.credentialStore = credentialStore
    self.preferences = preferences
    self.providerConfiguration = providerConfiguration
    self.ocrPipeline = ocrPipeline
    self.layoutResolver = layoutResolver
    migrationDefaults = defaultsBox.defaults
    self.sendRecognizedText = sendRecognizedText ?? {
      TranslationSettingsMigration.sendRecognizedText(defaults: defaultsBox.defaults)
    }
    self.beforeCommit = beforeCommit
    self.now = now
  }

  deinit {
    requestTask?.cancel()
  }

  func availability() -> TranslationAvailability {
    prepareTranslationSettings()
    let apiKey = try? credentialStore.resolvedAPIKey()
    return TranslationAvailability.evaluate(
      configuration: providerConfiguration(),
      apiKey: apiKey ?? nil,
      sendRecognizedText: sendRecognizedText()
    )
  }

  func requestDeadline(startedAt: Date = Date()) -> Date {
    startedAt.addingTimeInterval(TimeInterval(preferences().timeoutSeconds))
  }

  /// Resolves the target selection at the call site that owns a translation
  /// button event. In particular, `.currentLanguage` is converted to a
  /// concrete identifier while the selection UI is still live; callers can
  /// carry this value across frozen-image preparation without observing a
  /// later app-language change.
  func resolveTargetLanguage() -> TranslationResolvedLanguage {
    TranslationLanguageCatalog.resolvedTarget(
      targetLanguage,
      currentLanguageIdentifier: AppLanguageManager.shared.activeEffectiveLanguageIdentifier
    )
  }

  /// Pure form used by request setup/tests that already captured the active
  /// app-language identifier. It intentionally does not mutate the selection
  /// published to the UI.
  nonisolated static func resolveTargetLanguage(
    selection: TranslationTargetLanguage,
    currentLanguageIdentifier: String
  ) -> TranslationResolvedLanguage {
    TranslationLanguageCatalog.resolvedTarget(
      selection,
      currentLanguageIdentifier: currentLanguageIdentifier
    )
  }

  func begin(
    input: TranslationInput,
    deadline requestedDeadline: Date? = nil,
    startedAt: Date = Date(),
    sourceLanguage requestedSourceLanguage: TranslationSourceLanguage? = nil,
    targetLanguage requestedTargetLanguage: TranslationResolvedLanguage? = nil
  ) {
    guard phase != .translating, phase != .terminating else { return }

    // First hard gate. This also performs the one-time legacy migration even
    // when the Preferences screen has never been opened.
    prepareTranslationSettings()
    let configuration = providerConfiguration()
    let apiKey = try? credentialStore.resolvedAPIKey()
    switch TranslationAvailability.evaluate(
      configuration: configuration,
      apiKey: apiKey ?? nil,
      sendRecognizedText: sendRecognizedText()
    ) {
    case .available:
      break
    case .unavailable(let failure):
      phase = .failed(failure)
      progress = nil
      return
    }

    requestTask?.cancel()
    let generation = UUID()
    activeGeneration = generation
    let frozenPreferences = preferences()
    let frozenSourceLanguage = requestedSourceLanguage ?? sourceLanguage
    let frozenTargetLanguage = requestedTargetLanguage ?? resolveTargetLanguage()
    let deadline = requestedDeadline
      ?? startedAt.addingTimeInterval(TimeInterval(frozenPreferences.timeoutSeconds))

    renderBlocks.removeAll()
    detectedSourceLanguage = nil
    lowConfidenceLineCount = 0
    resultInput = nil
    resolvedTargetLanguage = frozenTargetLanguage
    phase = .translating
    progress = .recognizingText

    requestTask = Task { [weak self] in
      guard let self else { return }
      do {
        let output = try await Self.runWithHardDeadline(
          generationID: generation.uuidString,
          input: input,
          sourceLanguage: frozenSourceLanguage,
          targetLanguage: frozenTargetLanguage,
          preferences: frozenPreferences,
          configuration: configuration,
          apiKey: apiKey ?? nil,
          provider: provider,
          ocrPipeline: ocrPipeline,
          layoutResolver: layoutResolver,
          deadline: deadline,
          sendRecognizedText: sendRecognizedText,
          isActiveGeneration: { @MainActor [weak self] in
            self?.activeGeneration == generation
          },
          onProgress: { [weak self] nextProgress in
            guard let self else { return }
            await self.updateProgress(nextProgress, generation: generation)
          }
        )
        guard !Task.isCancelled, activeGeneration == generation else { return }
        if let beforeCommit { await beforeCommit() }
        // This is deliberately a second, MainActor-local fence. The output
        // may have finished local layout just before an Esc/cancel, a retry
        // generation, a privacy preference change, or the absolute deadline.
        guard !Task.isCancelled, activeGeneration == generation else { return }
        guard now() < deadline else {
          requestTask = nil
          progress = nil
          handle(failure: .timedOut)
          return
        }
        guard sendRecognizedText() else {
          requestTask = nil
          progress = nil
          handle(failure: .recognizedTextSharingDisabled)
          return
        }
        renderBlocks = output.blocks
        detectedSourceLanguage = output.detectedSourceLanguage
        lowConfidenceLineCount = output.lowConfidenceLineCount
        resultInput = input
        progress = nil
        phase = .showingResult
        requestTask = nil
        log(
          status: "success",
          input: input,
          blockCount: output.blocks.count,
          duration: Date().timeIntervalSince(startedAt)
        )
      } catch is CancellationError {
        // Esc/teardown increments the generation and intentionally does not
        // surface a result or error after the frozen selection disappears.
      } catch let failure as TranslationFailure {
        guard !Task.isCancelled, activeGeneration == generation else { return }
        requestTask = nil
        progress = nil
        log(
          status: failure.diagnosticLabel,
          input: input,
          blockCount: 0,
          duration: Date().timeIntervalSince(startedAt)
        )
        handle(failure: failure)
      } catch let providerError as TranslationTextProviderError {
        guard !Task.isCancelled, activeGeneration == generation else { return }
        requestTask = nil
        progress = nil
        let failure = TranslationFailure(providerError: providerError)
        log(
          status: failure.diagnosticLabel,
          input: input,
          blockCount: 0,
          duration: Date().timeIntervalSince(startedAt)
        )
        handle(failure: failure)
      } catch {
        guard !Task.isCancelled, activeGeneration == generation else { return }
        requestTask = nil
        progress = nil
        log(
          status: "unavailable",
          input: input,
          blockCount: 0,
          duration: Date().timeIntervalSince(startedAt)
        )
        handle(failure: .unavailable)
      }
    }
  }

  func cancel() {
    // Invalidate before cancellation so a non-cooperative OCR/provider/layout
    // task can never commit a late overlay.
    activeGeneration = UUID()
    requestTask?.cancel()
    requestTask = nil
    renderBlocks.removeAll()
    detectedSourceLanguage = nil
    lowConfidenceLineCount = 0
    resolvedTargetLanguage = nil
    resultInput = nil
    progress = nil
    phase = .terminating
  }

  func resetForRetry() {
    guard phase != .translating, phase != .terminating else { return }
    renderBlocks.removeAll()
    detectedSourceLanguage = nil
    lowConfidenceLineCount = 0
    resultInput = nil
    progress = nil
    phase = .ready
  }

  func fail(_ failure: TranslationFailure) {
    guard phase != .translating, phase != .terminating else { return }
    resultInput = nil
    renderBlocks.removeAll()
    progress = nil
    phase = .failed(failure)
  }

  /// Clipboard/history writes remain an explicit user action only.
  func copyRenderedResult() -> Bool {
    guard phase == .showingResult,
          let resultInput,
          let image = TranslationResultRenderer.render(input: resultInput, blocks: renderBlocks)
    else { return false }
    ClipboardHelper.copyImage(image, recordInHistory: true)
    return true
  }

  private func prepareTranslationSettings() {
    TranslationSettingsMigration.applyIfNeeded(defaults: migrationDefaults)
  }

  private func updateProgress(_ nextProgress: TranslationProgress, generation: UUID) {
    guard activeGeneration == generation, phase == .translating else { return }
    progress = nextProgress
  }

  private func handle(failure: TranslationFailure) {
    if failure == .timedOut || failure.requiresProviderSettings {
      phase = .terminating
      onTerminalExit?(failure)
      return
    }
    // 429/5xx stays failed while the frozen selection remains available for a
    // user retry. No partial batch is ever committed.
    phase = .failed(failure)
  }

  private func log(
    status: String,
    input: TranslationInput,
    blockCount: Int,
    duration: TimeInterval
  ) {
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Screen translation request completed",
      context: [
        "blocks": "\(blockCount)",
        "duration_ms": "\(Int((duration * 1_000).rounded()))",
        "height": "\(Int(input.screenRect.height.rounded()))",
        "status": status,
        "width": "\(Int(input.screenRect.width.rounded()))",
      ]
    )
  }

  private struct Output: Sendable {
    let blocks: [TranslationRenderBlock]
    let detectedSourceLanguage: String?
    let lowConfidenceLineCount: Int
  }

  private static func runWithHardDeadline(
    generationID: String,
    input: TranslationInput,
    sourceLanguage: TranslationSourceLanguage,
    targetLanguage: TranslationResolvedLanguage,
    preferences: TranslationPreferences,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    provider: any TranslationTextProvider,
    ocrPipeline: TranslationOCRPipeline,
    layoutResolver: TranslationLayoutResolver,
    deadline: Date,
    sendRecognizedText: @escaping @Sendable () -> Bool,
    isActiveGeneration: @escaping @MainActor @Sendable () async -> Bool,
    onProgress: @escaping @Sendable (TranslationProgress) async -> Void
  ) async throws -> Output {
    // Use an unstructured first-terminal race rather than a structured task
    // group. Swift task-group scope exit waits for children, so a future
    // non-cooperative local stage could otherwise make the caller outlive the
    // absolute deadline. The race cancels the worker and discards any late
    // value behind a generation fence.
    return try await TranslationHardDeadlineRace<Output>.run(deadline: deadline) {
      try await performTranslation(
        generationID: generationID,
        input: input,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        preferences: preferences,
        configuration: configuration,
        apiKey: apiKey,
        provider: provider,
        ocrPipeline: ocrPipeline,
        layoutResolver: layoutResolver,
        deadline: deadline,
        sendRecognizedText: sendRecognizedText,
        isActiveGeneration: isActiveGeneration,
        onProgress: onProgress
      )
    }
  }

  private static func performTranslation(
    generationID: String,
    input: TranslationInput,
    sourceLanguage: TranslationSourceLanguage,
    targetLanguage: TranslationResolvedLanguage,
    preferences: TranslationPreferences,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    provider: any TranslationTextProvider,
    ocrPipeline: TranslationOCRPipeline,
    layoutResolver: TranslationLayoutResolver,
    deadline: Date,
    sendRecognizedText: @escaping @Sendable () -> Bool,
    isActiveGeneration: @escaping @MainActor @Sendable () async -> Bool,
    onProgress: @escaping @Sendable (TranslationProgress) async -> Void
  ) async throws -> Output {
    try TranslationOCRDeadline.check(deadline)
    let sourceHint: String? = switch sourceLanguage {
    case .automatic: nil
    case .language(let identifier): identifier
    }
    let ocrResult = try await ocrPipeline.recognize(
      TranslationOCRRequest(
        image: input.image,
        screenRect: input.screenRect,
        sourceLanguageIdentifier: sourceHint,
        deadline: deadline
      )
    )
    try TranslationOCRDeadline.check(deadline)
    await onProgress(.detectingLanguage)

    let translatableBlocks = ocrResult.blocks.filter { !$0.preserveOriginal }
    var translations: [String: String] = [:]
    if !translatableBlocks.isEmpty {
      let sourceValue: String = switch sourceLanguage {
      case .automatic:
        ocrResult.detectedLanguage ?? "auto"
      case .language(let identifier):
        identifier
      }
      let request = TranslationTextRequest(
        generationID: generationID,
        sourceLanguage: sourceValue,
        targetLanguage: targetLanguage.identifier,
        blocks: translatableBlocks.map {
          TranslationTextRequestBlock(id: $0.id, text: $0.sourceText)
        },
        stylePreferences: preferences.stylePreferences
      )
      let batches = try TranslationTextBatcher.makeBatches(from: request)
      try TranslationTextRequestValidator.validate(request, enforceBatchCaps: false)
      await onProgress(.translatingText)
      guard sendRecognizedText() else {
        throw TranslationFailure.recognizedTextSharingDisabled
      }
      let result = try await TranslationBatchExecutor.execute(
        batches: batches,
        provider: provider,
        configuration: configuration,
        apiKey: apiKey,
        deadline: deadline,
        sendRecognizedText: sendRecognizedText
      )
      // The executor checks the gate before each response merge and monitors
      // it while providers are in flight. Recheck after the complete result
      // returns as well: this is the last fence before any local layout work
      // can observe translated text.
      guard sendRecognizedText() else {
        throw TranslationFailure.recognizedTextSharingDisabled
      }
      translations = result.translations
      let expectedIDs = Set(translatableBlocks.map(\.id))
      guard Set(translations.keys) == expectedIDs,
            translations.count == expectedIDs.count
      else {
        throw TranslationTextProviderError.invalidResponse
      }
    }

    try TranslationOCRDeadline.check(deadline)
    guard sendRecognizedText() else {
      throw TranslationFailure.recognizedTextSharingDisabled
    }
    await onProgress(.layingOut)
    var background: [String: CGFloat] = [:]
    background = try TranslationBackgroundSampler.luminanceByID(
      blocks: ocrResult.blocks,
      image: input.image,
      deadline: deadline
    )
    guard sendRecognizedText() else {
      throw TranslationFailure.recognizedTextSharingDisabled
    }
    let layoutInputs = ocrResult.blocks.map { block in
      TranslationLayoutInput(
        block: block,
        translatedText: block.preserveOriginal
          ? block.sourceText
          : (translations[block.id] ?? "")
      )
    }
    let layoutItems = try layoutResolver.resolve(
      layoutInputs,
      inside: input.screenRect,
      backgroundLuminanceByID: background,
      deadline: deadline
    )
    // Layout is local, but it still consumes the translated text. A privacy
    // transition after sampling/resolution must not commit an overlay.
    guard sendRecognizedText() else {
      throw TranslationFailure.recognizedTextSharingDisabled
    }
    let expectedLayoutIDs = Set(ocrResult.blocks.map(\.id))
    guard layoutItems.count == expectedLayoutIDs.count,
          Set(layoutItems.map(\.id)) == expectedLayoutIDs
    else {
      throw TranslationFailure.invalidResponse
    }
    let renderBlocks = layoutItems.map { item in
      // This is a field-for-field local copy. No provider geometry is accepted.
      TranslationRenderBlock(
        id: item.id,
        sourceText: item.sourceText,
        translatedText: item.translatedText,
        screenBounds: item.screenBounds,
        alignment: item.alignment,
        direction: item.direction,
        rotationDegrees: item.rotationDegrees,
        fontSize: item.fontSize,
        confidence: item.confidence,
        usesLightBackground: item.usesLightBackground
      )
    }
    // This is the final nonisolated fence after renderBlocks construction.
    // Check all request-owned gates again immediately before returning so a
    // late local result cannot cross the session boundary as usable output.
    try TranslationOCRDeadline.check(deadline)
    guard await isActiveGeneration() else { throw CancellationError() }
    guard sendRecognizedText() else {
      throw TranslationFailure.recognizedTextSharingDisabled
    }
    return Output(
      blocks: renderBlocks,
      detectedSourceLanguage: ocrResult.detectedLanguage,
      lowConfidenceLineCount: ocrResult.lowConfidenceLineCount
    )
  }

}

/// First-terminal race used for the whole session. It is intentionally kept
/// independent of provider response data and may outlive the caller briefly
/// after cancellation without being able to resume the coordinator twice.
private final nonisolated class TranslationHardDeadlineRace<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var pendingResult: Result<Value, Error>?
  private var worker: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private var finished = false

  static func run(
    deadline: Date,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let state = TranslationHardDeadlineRace<Value>()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        state.install(continuation)
        state.start(operation: operation, deadline: deadline)
      }
    }, onCancel: {
      state.finish(.failure(CancellationError()))
    })
  }

  private func install(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let pendingResult {
      self.pendingResult = nil
      lock.unlock()
      continuation.resume(with: pendingResult)
      return
    }
    if finished {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  private func start(
    operation: @escaping @Sendable () async throws -> Value,
    deadline: Date
  ) {
    let worker = Task.detached { [weak self] in
      do {
        let value = try await operation()
        self?.finish(.success(value))
      } catch {
        self?.finish(.failure(error))
      }
    }
    let deadlineTask = Task.detached { [weak self] in
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else {
        self?.finish(.failure(TranslationFailure.timedOut))
        return
      }
      do {
        try await Task.sleep(nanoseconds: TranslationTextDeadline.nanoseconds(for: remaining))
        self?.finish(.failure(TranslationFailure.timedOut))
      } catch {
        // Cancellation means the operation won the race.
      }
    }

    lock.lock()
    let shouldCancel = finished
    if !shouldCancel {
      self.worker = worker
      self.deadlineTask = deadlineTask
    }
    lock.unlock()
    if shouldCancel {
      worker.cancel()
      deadlineTask.cancel()
    }
  }

  private func finish(_ result: Result<Value, Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    if continuation == nil { pendingResult = result }
    let worker = self.worker
    let deadlineTask = self.deadlineTask
    self.worker = nil
    self.deadlineTask = nil
    lock.unlock()

    worker?.cancel()
    deadlineTask?.cancel()
    continuation?.resume(with: result)
  }
}

private final class TranslationUserDefaultsBox: @unchecked Sendable {
  let defaults: UserDefaults

  init(_ defaults: UserDefaults) {
    self.defaults = defaults
  }
}

private extension TranslationFailure {
  var diagnosticLabel: String {
    switch self {
    case .recognizedTextSharingDisabled: "recognized_text_sharing_disabled"
    case .missingAPIKey: "missing_key"
    case .invalidConfiguration: "invalid_configuration"
    case .timedOut: "timeout"
    case .cancelled: "cancelled"
    case .noText: "no_text"
    case .invalidResponse: "invalid_response"
    case .providerStatus(let status): "http_\(status)"
    case .inputTooLarge: "input_too_large"
    case .captureFailed: "capture_failed"
    case .unavailable: "unavailable"
    }
  }
}
