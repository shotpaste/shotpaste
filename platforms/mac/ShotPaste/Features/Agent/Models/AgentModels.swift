//
//  AgentModels.swift
//  ShotPaste
//
//  Provider-neutral models for the macOS Agent Mode observation/action loop.
//

import ApplicationServices
import CoreGraphics
import Foundation

nonisolated enum AgentSessionPhase: String, Codable, CaseIterable, Sendable {
  case idle
  case capturing
  case annotating
  case observing
  case planning
  case awaitingApproval
  case awaitingUser
  case executing
  case paused
  case completed
  case failed

  var isRunning: Bool {
    switch self {
    case .capturing, .annotating, .observing, .planning, .awaitingApproval,
         .awaitingUser, .executing, .paused:
      true
    case .idle, .completed, .failed:
      false
    }
  }
}

nonisolated struct AgentNormalizedPoint: Codable, Equatable, Sendable {
  let x: Double
  let y: Double

  var isValid: Bool {
    x.isFinite && y.isFinite && (0 ... 1).contains(x) && (0 ... 1).contains(y)
  }

  var clamped: AgentNormalizedPoint {
    AgentNormalizedPoint(
      x: min(max(x.isFinite ? x : 0, 0), 1),
      y: min(max(y.isFinite ? y : 0, 0), 1)
    )
  }
}

nonisolated struct AgentNormalizedRect: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var center: AgentNormalizedPoint {
    AgentNormalizedPoint(x: x + width / 2, y: y + height / 2).clamped
  }
}

nonisolated struct AgentDisplayContext: Codable, Equatable, Sendable {
  let displayID: CGDirectDisplayID
  let logicalWidth: Int
  let logicalHeight: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let scaleFactor: Double
}

nonisolated struct AgentApplicationContext: Codable, Equatable, Sendable {
  let processIdentifier: Int32
  let bundleIdentifier: String?
  let applicationName: String
  let windowTitle: String?

  static let unknown = AgentApplicationContext(
    processIdentifier: 0,
    bundleIdentifier: nil,
    applicationName: "Unknown application",
    windowTitle: nil
  )
}

nonisolated struct AgentAccessibilityElementSnapshot: Codable, Equatable, Sendable {
  let id: String
  let role: String
  let subrole: String?
  let title: String?
  let elementDescription: String?
  let value: String?
  let enabled: Bool
  let focused: Bool
  let normalizedFrame: AgentNormalizedRect?
  let isSecure: Bool

  var policyText: String {
    [role, subrole, title, elementDescription, value]
      .compactMap { $0 }
      .joined(separator: " ")
  }
}

nonisolated struct AgentOCRLineSnapshot: Codable, Equatable, Sendable {
  let id: String
  let text: String
  let confidence: Float
  let normalizedFrame: AgentNormalizedRect
}

nonisolated struct AgentIntent: Codable, Equatable, Sendable {
  let sessionID: UUID
  let userText: String
  let anchor: AgentNormalizedPoint
  let displayID: CGDirectDisplayID
  let initialApplication: AgentApplicationContext
  let createdAt: Date
}

struct AgentObservation {
  let id: UUID
  let capturedAt: Date
  let display: AgentDisplayContext
  let application: AgentApplicationContext
  let anchor: AgentNormalizedPoint?
  let accessibilityElements: [AgentAccessibilityElementSnapshot]
  let ocrLines: [AgentOCRLineSnapshot]
  let screenshot: CGImage
}

struct AgentContextAssembly {
  let observation: AgentObservation
  let accessibilityElements: [String: AXUIElement]
}

nonisolated enum AgentMouseButton: String, Codable, Equatable, Sendable {
  case left
  case right
}

nonisolated struct AgentActivateApplicationAction: Equatable, Sendable {
  let bundleIdentifier: String?
  let applicationName: String?
  let windowTitle: String?
}

nonisolated struct AgentClickAction: Equatable, Sendable {
  let elementID: String?
  let displayID: CGDirectDisplayID?
  let point: AgentNormalizedPoint?
  let button: AgentMouseButton
  let clickCount: Int
}

nonisolated struct AgentTypeTextAction: Equatable, Sendable {
  let text: String
  let elementID: String?
}

nonisolated struct AgentKeyPressAction: Equatable, Sendable {
  let keys: [String]
}

nonisolated struct AgentScrollAction: Equatable, Sendable {
  let displayID: CGDirectDisplayID
  let point: AgentNormalizedPoint
  let deltaX: Int32
  let deltaY: Int32
}

nonisolated struct AgentDragAction: Equatable, Sendable {
  let displayID: CGDirectDisplayID
  let start: AgentNormalizedPoint
  let end: AgentNormalizedPoint
  let durationMilliseconds: Int
}

nonisolated enum AgentToolAction: Equatable, Sendable {
  case activateApplication(AgentActivateApplicationAction)
  case click(AgentClickAction)
  case typeText(AgentTypeTextAction)
  case pressKeys(AgentKeyPressAction)
  case scroll(AgentScrollAction)
  case drag(AgentDragAction)
  case wait(milliseconds: Int)
  case askUser(question: String)
  case complete(summary: String)

  var auditName: String {
    switch self {
    case .activateApplication: "activate_application"
    case .click: "click"
    case .typeText: "type_text"
    case .pressKeys: "press_keys"
    case .scroll: "scroll"
    case .drag: "drag"
    case .wait: "wait"
    case .askUser: "ask_user"
    case .complete: "report_complete"
    }
  }

  /// Deliberately excludes typed text so diagnostics and audit summaries cannot
  /// accidentally become an alternate credential store.
  var safeSummary: String {
    switch self {
    case .activateApplication(let action):
      let app = action.applicationName ?? action.bundleIdentifier ?? "application"
      if let windowTitle = action.windowTitle, !windowTitle.isEmpty {
        return "Activate \(app), window \(windowTitle)"
      }
      return "Activate \(app)"
    case .click(let action):
      let target = action.elementID ?? "coordinate"
      return "\(action.button.rawValue) click x\(action.clickCount) on \(target)"
    case .typeText(let action):
      return "Type \(action.text.count) character(s)"
    case .pressKeys(let action):
      return "Press \(action.keys.joined(separator: "+"))"
    case .scroll(let action):
      return "Scroll dx=\(action.deltaX), dy=\(action.deltaY)"
    case .drag:
      return "Drag pointer"
    case .wait(let milliseconds):
      return "Wait \(milliseconds) ms"
    case .askUser(let question):
      return "Ask user: \(question.prefix(160))"
    case .complete(let summary):
      return "Complete: \(summary.prefix(160))"
    }
  }
}

nonisolated struct AgentProviderCapabilities: Equatable, Sendable {
  let acceptsImages: Bool
  let supportsToolCalls: Bool
}

nonisolated struct AgentProviderConfiguration: Equatable, Sendable {
  static let defaultEndpoint = "https://api3.wlai.vip/v1/chat/completions"
  static let defaultModel = "gpt-5.6-luna"

  let endpoint: String
  let model: String
  let thinkingEnabled: Bool
  let sendsImages: Bool
  let maxActions: Int

  static func current(defaults: UserDefaults = .standard) -> AgentProviderConfiguration {
    let endpoint = defaults.string(forKey: PreferencesKeys.agentProviderEndpoint)
      ?? Self.defaultEndpoint
    let model = defaults.string(forKey: PreferencesKeys.agentProviderModel)
      ?? Self.defaultModel
    let thinkingEnabled = defaults.object(forKey: PreferencesKeys.agentThinkingEnabled) as? Bool ?? true
    let sendsImages = defaults.object(forKey: PreferencesKeys.agentProviderSendsImages) as? Bool ?? true
    let storedMaxActions = defaults.integer(forKey: PreferencesKeys.agentMaxActions)

    return AgentProviderConfiguration(
      endpoint: endpoint,
      model: model,
      thinkingEnabled: thinkingEnabled,
      sendsImages: sendsImages,
      maxActions: storedMaxActions > 0 ? min(max(storedMaxActions, 1), 100) : 30
    )
  }

  var endpointURL: URL? {
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(),
          components.user == nil,
          components.password == nil,
          scheme == "https" || (scheme == "http" && Self.localHosts.contains(host))
    else { return nil }

    let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if normalizedPath.isEmpty {
      components.path = "/chat/completions"
    }
    return components.url
  }

  var isLocalEndpoint: Bool {
    guard let host = endpointURL?.host?.lowercased() else { return false }
    return Self.localHosts.contains(host)
  }

  var isValid: Bool {
    endpointURL != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
}

nonisolated struct AgentProviderRequest {
  let intent: AgentIntent
  let observation: AgentObservation
  let auditTrail: [AgentAuditEvent]
}

nonisolated struct AgentProviderDecision: Equatable, Sendable {
  let action: AgentToolAction
  let model: String
}

protocol LLMProvider: Sendable {
  var capabilities: AgentProviderCapabilities { get }

  func nextAction(
    request: AgentProviderRequest,
    configuration: AgentProviderConfiguration,
    apiKey: String?
  ) async throws -> AgentProviderDecision
}

nonisolated enum AgentAuditKind: String, Codable, Sendable {
  case sessionStarted
  case observation
  case modelDecision
  case policyApproval
  case policyDenial
  case actionResult
  case userResponse
  case paused
  case resumed
  case completed
  case failed
  case stopped
}

nonisolated struct AgentAuditEvent: Codable, Equatable, Sendable {
  let timestamp: Date
  let kind: AgentAuditKind
  let message: String
  let metadata: [String: String]

  init(
    timestamp: Date = Date(),
    kind: AgentAuditKind,
    message: String,
    metadata: [String: String] = [:]
  ) {
    self.timestamp = timestamp
    self.kind = kind
    self.message = message
    self.metadata = metadata
  }
}

nonisolated struct AgentExecutionResult: Equatable, Sendable {
  let summary: String
}

nonisolated enum AgentProviderError: LocalizedError, Equatable {
  case missingAPIKey
  case invalidConfiguration
  case invalidResponse
  case unsuccessfulStatusCode(Int, String?)
  case unsupportedTool(String)
  case invalidToolArguments(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "The LLM API key is missing."
    case .invalidConfiguration:
      "The LLM endpoint or model configuration is invalid."
    case .invalidResponse:
      "The LLM provider returned an invalid response."
    case .unsuccessfulStatusCode(let statusCode, let message):
      message.map { "The LLM provider returned HTTP \(statusCode): \($0)" }
        ?? "The LLM provider returned HTTP \(statusCode)."
    case .unsupportedTool(let name):
      "The LLM requested an unsupported tool: \(name)."
    case .invalidToolArguments(let name):
      "The LLM returned invalid arguments for \(name)."
    }
  }
}

nonisolated enum AgentDriverError: LocalizedError, Equatable {
  case accessibilityPermissionRequired
  case applicationNotFound
  case elementUnavailable
  case invalidCoordinates
  case unsupportedKey(String)
  case actionFailed(String)

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionRequired:
      "Accessibility permission is required to control the Mac."
    case .applicationNotFound:
      "The requested application is not running."
    case .elementUnavailable:
      "The requested accessibility element is no longer available."
    case .invalidCoordinates:
      "The requested coordinates are invalid."
    case .unsupportedKey(let key):
      "The requested key is not supported: \(key)."
    case .actionFailed(let message):
      message
    }
  }
}
