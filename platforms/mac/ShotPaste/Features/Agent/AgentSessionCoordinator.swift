//
//  AgentSessionCoordinator.swift
//  ShotPaste
//
//  Owns the Agent Mode state machine and screenshot -> plan -> policy ->
//  action -> fresh observation loop.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class AgentSessionCoordinator: ObservableObject {
  @Published private(set) var phase: AgentSessionPhase = .idle
  @Published private(set) var statusMessage = L10n.Agent.readyStatus
  @Published private(set) var completionSummary: String?
  @Published private(set) var taskSummary: String?
  @Published private(set) var trajectoryEvents: [AgentAuditEvent] = []

  private let provider: any LLMProvider
  private let credentialProvider: any AgentCredentialProviding
  private let contextAssembler: AgentContextAssembler
  private let policyEngine: AgentPolicyEngine
  private let driver: any ComputerDriver
  private let store: AgentSessionStore
  private let approvalPresenter: any AgentApprovalPresenting
  private let questionPresenter: any AgentQuestionPresenting
  private let activityMonitor: AgentUserActivityMonitor
  private let leaseCoordinator: InteractionLeaseCoordinator

  private var lease: InteractionLeaseCoordinator.Lease?
  private var activeTask: Task<Void, Never>?
  private var executionTask: Task<AgentExecutionResult, Error>?
  private var currentSessionID: UUID?
  private var auditTrail: [AgentAuditEvent] = []
  private var approvedApplicationBundleIdentifiers: Set<String> = []
  private var isPaused = false
  private var pauseRevision = 0
  private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    provider: any LLMProvider,
    credentialProvider: any AgentCredentialProviding,
    contextAssembler: AgentContextAssembler,
    policyEngine: AgentPolicyEngine,
    driver: any ComputerDriver,
    store: AgentSessionStore,
    approvalPresenter: any AgentApprovalPresenting,
    questionPresenter: any AgentQuestionPresenting,
    activityMonitor: AgentUserActivityMonitor,
    leaseCoordinator: InteractionLeaseCoordinator
  ) {
    self.provider = provider
    self.credentialProvider = credentialProvider
    self.contextAssembler = contextAssembler
    self.policyEngine = policyEngine
    self.driver = driver
    self.store = store
    self.approvalPresenter = approvalPresenter
    self.questionPresenter = questionPresenter
    self.activityMonitor = activityMonitor
    self.leaseCoordinator = leaseCoordinator
  }

  convenience init() {
    self.init(contextAssembler: AgentContextAssembler())
  }

  convenience init(contextAssembler: AgentContextAssembler) {
    self.init(
      provider: AgentConfigurableLLMProvider(),
      credentialProvider: AgentCredentialStore.shared,
      contextAssembler: contextAssembler,
      policyEngine: AgentPolicyEngine(),
      driver: MacComputerDriver(),
      store: .shared,
      approvalPresenter: AgentApprovalPresenter(),
      questionPresenter: AgentQuestionPresenter(),
      activityMonitor: AgentUserActivityMonitor(),
      leaseCoordinator: .shared
    )
  }

  var isActive: Bool {
    lease != nil
  }

  var canResume: Bool {
    isActive && isPaused
  }

  var hasTrajectory: Bool {
    taskSummary != nil || !trajectoryEvents.isEmpty
  }

  @discardableResult
  func beginIntentCapture() -> Bool {
    guard lease == nil,
          let acquiredLease = leaseCoordinator.acquire(.agent)
    else { return false }

    lease = acquiredLease
    completionSummary = nil
    taskSummary = nil
    trajectoryEvents.removeAll(keepingCapacity: true)
    auditTrail.removeAll(keepingCapacity: true)
    approvedApplicationBundleIdentifiers.removeAll(keepingCapacity: true)
    isPaused = false
    pauseRevision = 0
    transition(to: .capturing, message: L10n.Agent.capturingStatus)
    return true
  }

  func markAnnotating() {
    guard lease != nil else { return }
    transition(to: .annotating, message: L10n.Agent.annotatingStatus)
  }

  func cancelIntentCapture() {
    guard currentSessionID == nil else { return }
    activityMonitor.stop()
    releaseLease()
    transition(to: .idle, message: L10n.Agent.readyStatus)
  }

  func start(intent: AgentIntent, initialSnapshot: FrozenDisplaySnapshot) {
    guard lease != nil, currentSessionID == nil else { return }
    currentSessionID = intent.sessionID
    taskSummary = intent.userText
    startActivityMonitoring()

    activeTask = Task { [weak self] in
      guard let self else { return }
      await run(intent: intent, initialSnapshot: initialSnapshot)
    }
  }

  func pauseForUserActivity() {
    guard isActive, currentSessionID != nil, !isPaused else { return }
    isPaused = true
    pauseRevision += 1
    executionTask?.cancel()
    executionTask = nil
    driver.cancelPendingInput()
    transition(to: .paused, message: L10n.Agent.pausedStatus)
    recordInBackground(AgentAuditEvent(
      kind: .paused,
      message: "Paused because the user used the mouse or keyboard."
    ))
    AppToastManager.shared.show(
      message: L10n.Agent.pausedByUser,
      style: .warning,
      position: .bottomCenter
    )
  }

  func resume() {
    guard isActive, currentSessionID != nil, isPaused else { return }
    isPaused = false
    transition(to: .observing, message: L10n.Agent.observingStatus)
    startActivityMonitoring()
    let waiters = resumeWaiters
    resumeWaiters.removeAll()
    waiters.forEach { $0.resume() }
    recordInBackground(AgentAuditEvent(kind: .resumed, message: "Resumed by the user."))
  }

  func stopImmediately(reason: String = "Stopped by the user.") {
    guard isActive else { return }
    let sessionID = currentSessionID
    activeTask?.cancel()
    activeTask = nil
    executionTask?.cancel()
    executionTask = nil
    activityMonitor.stop()
    driver.cancelPendingInput()
    isPaused = false
    let waiters = resumeWaiters
    resumeWaiters.removeAll()
    waiters.forEach { $0.resume() }
    currentSessionID = nil
    auditTrail.removeAll()
    approvedApplicationBundleIdentifiers.removeAll()
    releaseLease()
    transition(to: .idle, message: L10n.Agent.readyStatus)

    if let sessionID {
      let finalEvent = AgentAuditEvent(kind: .stopped, message: reason)
      trajectoryEvents.append(finalEvent)
      completionSummary = reason
      Task {
        try? await store.endSession(
          sessionID,
          finalEvent: finalEvent
        )
      }
    }
    DiagnosticLogger.shared.log(.info, .agent, "Agent session stopped", context: ["reason": reason])
  }

  private func run(
    intent: AgentIntent,
    initialSnapshot: FrozenDisplaySnapshot
  ) async {
    do {
      let startEvent = AgentAuditEvent(
        kind: .sessionStarted,
        message: intent.userText,
        metadata: [
          "displayID": String(intent.displayID),
          "application": intent.initialApplication.applicationName,
          "bundleIdentifier": intent.initialApplication.bundleIdentifier ?? "",
        ]
      )
      try await store.startSession(intent.sessionID, initialEvent: startEvent)
      auditTrail = [startEvent]
      trajectoryEvents = [startEvent]
      try await runLoop(intent: intent, initialSnapshot: initialSnapshot)
    } catch is CancellationError {
      return
    } catch {
      await failSession(error, sessionID: intent.sessionID)
    }
  }

  private func runLoop(
    intent: AgentIntent,
    initialSnapshot: FrozenDisplaySnapshot
  ) async throws {
    let configuration = AgentProviderConfiguration.current()
    guard configuration.isValid else { throw AgentProviderError.invalidConfiguration }
    let apiKey = try credentialProvider.resolvedAPIKey()
    if !configuration.isLocalEndpoint, apiKey == nil {
      throw AgentProviderError.missingAPIKey
    }

    var nextSnapshot: FrozenDisplaySnapshot? = initialSnapshot
    var applicationHint: AgentApplicationContext? = intent.initialApplication
    var decisionCount = 0
    var consecutiveFailures = 0
    let startedAt = Date()

    while decisionCount < configuration.maxActions,
          Date().timeIntervalSince(startedAt) < 15 * 60 {
      try Task.checkCancellation()
      await waitIfPaused()
      try Task.checkCancellation()
      let cycleRevision = pauseRevision

      transition(to: .observing, message: L10n.Agent.observingStatus)
      let snapshot: FrozenDisplaySnapshot = if let preparedSnapshot = nextSnapshot {
        preparedSnapshot
      } else {
        try await captureFreshSnapshot(displayID: intent.displayID)
      }
      nextSnapshot = nil

      let assembly = await contextAssembler.assemble(
        snapshot: snapshot,
        anchor: decisionCount == 0 ? intent.anchor : nil,
        applicationHint: applicationHint
      )
      applicationHint = nil
      driver.updateAccessibilityElements(assembly.accessibilityElements)
      let observationEvent = AgentAuditEvent(
        kind: .observation,
        message: "Observed \(assembly.observation.application.applicationName).",
        metadata: [
          "observationID": assembly.observation.id.uuidString,
          "displayID": String(assembly.observation.display.displayID),
          "axElements": String(assembly.observation.accessibilityElements.count),
          "ocrLines": String(assembly.observation.ocrLines.count),
        ]
      )
      try await record(observationEvent, sessionID: intent.sessionID)
      _ = try await store.retainScreenshotIfEnabled(
        assembly.observation.screenshot,
        observationID: assembly.observation.id,
        sessionID: intent.sessionID
      )

      await waitIfPaused()
      try Task.checkCancellation()
      if cycleRevision != pauseRevision {
        continue
      }

      transition(to: .planning, message: L10n.Agent.planningStatus)
      let decision = try await provider.nextAction(
        request: AgentProviderRequest(
          intent: intent,
          observation: assembly.observation,
          auditTrail: auditTrail
        ),
        configuration: configuration,
        apiKey: apiKey
      )
      decisionCount += 1
      await waitIfPaused()
      try Task.checkCancellation()
      if cycleRevision != pauseRevision {
        continue
      }

      try await record(AgentAuditEvent(
        kind: .modelDecision,
        message: decision.action.safeSummary,
        metadata: ["tool": decision.action.auditName, "model": decision.model]
      ), sessionID: intent.sessionID)

      switch decision.action {
      case .askUser(let question):
        activityMonitor.stop()
        transition(to: .awaitingUser, message: L10n.Agent.awaitingUserStatus)
        guard let answer = await questionPresenter.ask(question) else {
          stopImmediately(reason: "The user cancelled the clarification question.")
          return
        }
        try await record(AgentAuditEvent(
          kind: .userResponse,
          message: answer,
          metadata: ["question": String(question.prefix(300))]
        ), sessionID: intent.sessionID)
        startActivityMonitoring()
        consecutiveFailures = 0
        continue

      case .complete(let summary):
        await completeSession(summary: summary, sessionID: intent.sessionID)
        return

      default:
        break
      }

      let policyContext = AgentPolicyContext(
        userIntentText: intent.userText,
        initialApplication: intent.initialApplication,
        currentApplication: assembly.observation.application,
        action: decision.action,
        accessibilityElements: assembly.observation.accessibilityElements,
        approvedApplicationBundleIdentifiers: approvedApplicationBundleIdentifiers,
        observationDisplayID: assembly.observation.display.displayID
      )
      switch policyEngine.evaluate(policyContext) {
      case .allow:
        break

      case .deny(let reason):
        consecutiveFailures += 1
        try await record(AgentAuditEvent(
          kind: .policyDenial,
          message: reason,
          metadata: ["tool": decision.action.auditName]
        ), sessionID: intent.sessionID)
        if consecutiveFailures >= 3 {
          throw AgentDriverError.actionFailed(reason)
        }
        continue

      case .requireApproval(let request):
        activityMonitor.stop()
        transition(to: .awaitingApproval, message: L10n.Agent.awaitingApprovalStatus)
        let response = await approvalPresenter.present(request)
        switch response {
        case .approveOnce:
          try await record(AgentAuditEvent(
            kind: .policyApproval,
            message: request.detail,
            metadata: ["scope": "action"]
          ), sessionID: intent.sessionID)
        case .approveApplication(let bundleIdentifier):
          approvedApplicationBundleIdentifiers.insert(bundleIdentifier)
          try await record(AgentAuditEvent(
            kind: .policyApproval,
            message: request.detail,
            metadata: ["scope": "application", "bundleIdentifier": bundleIdentifier]
          ), sessionID: intent.sessionID)
        case .deny:
          consecutiveFailures += 1
          try await record(AgentAuditEvent(
            kind: .policyDenial,
            message: "The user denied the proposed action.",
            metadata: ["tool": decision.action.auditName]
          ), sessionID: intent.sessionID)
          startActivityMonitoring()
          continue
        case .stop:
          stopImmediately(reason: "Stopped from the approval prompt.")
          return
        }
        startActivityMonitoring()
      }

      transition(to: .executing, message: L10n.Agent.executingStatus)
      do {
        let pendingExecution = Task { try await driver.execute(decision.action) }
        executionTask = pendingExecution
        let result = try await pendingExecution.value
        executionTask = nil
        try await record(AgentAuditEvent(
          kind: .actionResult,
          message: result.summary,
          metadata: ["tool": decision.action.auditName, "status": "success"]
        ), sessionID: intent.sessionID)
        consecutiveFailures = 0
      } catch is CancellationError {
        executionTask = nil
        if isPaused {
          await waitIfPaused()
          continue
        }
        throw CancellationError()
      } catch {
        executionTask = nil
        consecutiveFailures += 1
        try await record(AgentAuditEvent(
          kind: .actionResult,
          message: error.localizedDescription,
          metadata: ["tool": decision.action.auditName, "status": "failed"]
        ), sessionID: intent.sessionID)
        if consecutiveFailures >= 3 {
          throw error
        }
      }

      try await Task.sleep(nanoseconds: 140_000_000)
    }

    throw AgentDriverError.actionFailed(
      "Agent Mode reached its action or time limit before completing the task."
    )
  }

  private func captureFreshSnapshot(
    displayID: CGDirectDisplayID
  ) async throws -> FrozenDisplaySnapshot {
    let session = try await FrozenAreaCaptureSession.prepare(
      displayIDs: [displayID],
      showCursor: false,
      excludeDesktopIcons: false,
      excludeDesktopWidgets: false,
      excludeOwnApplication: true
    )
    defer { session.invalidate() }
    guard let snapshot = session.snapshot(for: displayID) else {
      throw AgentDriverError.actionFailed("The task display is no longer available.")
    }
    return snapshot
  }

  private func waitIfPaused() async {
    guard isPaused else { return }
    await withCheckedContinuation { continuation in
      resumeWaiters.append(continuation)
    }
  }

  private func record(
    _ event: AgentAuditEvent,
    sessionID: UUID
  ) async throws {
    auditTrail.append(event)
    trajectoryEvents.append(event)
    try await store.append(event, sessionID: sessionID)
  }

  private func recordInBackground(_ event: AgentAuditEvent) {
    guard let sessionID = currentSessionID else { return }
    auditTrail.append(event)
    trajectoryEvents.append(event)
    Task {
      try? await store.append(event, sessionID: sessionID)
    }
  }

  private func completeSession(summary: String, sessionID: UUID) async {
    guard currentSessionID == sessionID else { return }
    let finalEvent = AgentAuditEvent(kind: .completed, message: summary)
    try? await store.endSession(sessionID, finalEvent: finalEvent)
    trajectoryEvents.append(finalEvent)
    completionSummary = summary
    cleanupActiveSession()
    transition(to: .completed, message: L10n.Agent.completedStatus)
    AppToastManager.shared.show(
      message: summary,
      style: .success,
      position: .bottomCenter
    )
    DiagnosticLogger.shared.log(.info, .agent, "Agent session completed")
  }

  private func failSession(_ error: Error, sessionID: UUID) async {
    guard currentSessionID == sessionID else { return }
    let safeMessage = error.localizedDescription
    let finalEvent = AgentAuditEvent(kind: .failed, message: safeMessage)
    try? await store.endSession(
      sessionID,
      finalEvent: finalEvent
    )
    trajectoryEvents.append(finalEvent)
    completionSummary = safeMessage
    cleanupActiveSession()
    transition(to: .failed, message: safeMessage)
    AppToastManager.shared.show(
      message: safeMessage,
      style: .error,
      position: .bottomCenter
    )
    DiagnosticLogger.shared.logError(.agent, error, "Agent session failed")
  }

  private func cleanupActiveSession() {
    activeTask = nil
    executionTask?.cancel()
    executionTask = nil
    activityMonitor.stop()
    driver.cancelPendingInput()
    currentSessionID = nil
    isPaused = false
    let waiters = resumeWaiters
    resumeWaiters.removeAll()
    waiters.forEach { $0.resume() }
    approvedApplicationBundleIdentifiers.removeAll()
    auditTrail.removeAll()
    releaseLease()
  }

  private func startActivityMonitoring() {
    guard currentSessionID != nil, !isPaused else { return }
    activityMonitor.start(
      onUserActivity: { [weak self] in
        self?.pauseForUserActivity()
      },
      onEmergencyStop: { [weak self] in
        self?.stopImmediately(reason: "Stopped with the global Escape key.")
      }
    )
  }

  private func releaseLease() {
    guard let lease else { return }
    leaseCoordinator.release(lease)
    self.lease = nil
  }

  private func transition(to phase: AgentSessionPhase, message: String) {
    self.phase = phase
    statusMessage = message
    DiagnosticLogger.shared.log(
      .debug,
      .agent,
      "Agent session phase changed",
      context: ["phase": phase.rawValue]
    )
  }
}
