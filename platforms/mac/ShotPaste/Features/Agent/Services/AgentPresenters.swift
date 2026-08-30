//
//  AgentPresenters.swift
//  ShotPaste
//
//  Native approval, clarification, and completion surfaces for Agent Mode.
//

import AppKit
import Foundation

nonisolated enum AgentApprovalResponse: Equatable, Sendable {
  case approveOnce
  case approveApplication(String)
  case deny
  case stop
}

@MainActor
protocol AgentApprovalPresenting: AnyObject {
  func present(_ request: AgentApprovalRequest) async -> AgentApprovalResponse
}

@MainActor
protocol AgentQuestionPresenting: AnyObject {
  func ask(_ question: String) async -> String?
}

@MainActor
final class AgentApprovalPresenter: AgentApprovalPresenting {
  func present(_ request: AgentApprovalRequest) async -> AgentApprovalResponse {
    let previousApplication = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = request.title
    alert.informativeText = request.detail
    alert.icon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
    alert.addButton(withTitle: L10n.Agent.approveOnce)

    let applicationBundleIdentifier: String?
    switch request.proposedScope {
    case .application(let bundleIdentifier):
      applicationBundleIdentifier = bundleIdentifier
      alert.addButton(withTitle: L10n.Agent.allowApplicationForSession)
      alert.addButton(withTitle: L10n.Agent.denyAction)
    case .actionOnly:
      applicationBundleIdentifier = nil
      alert.addButton(withTitle: L10n.Agent.denyAction)
    }
    alert.addButton(withTitle: L10n.Agent.stopAgent)
    alert.buttons.last?.keyEquivalent = "\u{1B}"

    let response = alert.runModal()
    previousApplication?.activate(options: [])
    switch response {
    case .alertFirstButtonReturn:
      return .approveOnce
    case .alertSecondButtonReturn:
      if let applicationBundleIdentifier {
        return .approveApplication(applicationBundleIdentifier)
      }
      return .deny
    case .alertThirdButtonReturn:
      return applicationBundleIdentifier == nil ? .stop : .deny
    default:
      return .stop
    }
  }
}

@MainActor
final class AgentQuestionPresenter: AgentQuestionPresenting {
  func ask(_ question: String) async -> String? {
    let previousApplication = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
    input.placeholderString = L10n.Agent.answerPlaceholder

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = L10n.Agent.questionTitle
    alert.informativeText = question
    alert.accessoryView = input
    alert.addButton(withTitle: L10n.Agent.continueAction)
    alert.addButton(withTitle: L10n.Common.cancel)
    alert.buttons.last?.keyEquivalent = "\u{1B}"
    alert.window.initialFirstResponder = input

    let response = alert.runModal()
    previousApplication?.activate(options: [])
    guard response == .alertFirstButtonReturn else { return nil }
    let answer = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return answer.isEmpty ? nil : answer
  }
}
