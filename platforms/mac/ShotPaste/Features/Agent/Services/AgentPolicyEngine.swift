//
//  AgentPolicyEngine.swift
//  ShotPaste
//
//  Local, model-independent safety policy for Agent Mode actions.
//

import CoreGraphics
import Foundation

nonisolated enum AgentApprovalScope: Equatable, Sendable {
  case actionOnly
  case application(bundleIdentifier: String)
}

nonisolated struct AgentApprovalRequest: Equatable, Sendable {
  enum Risk: String, Equatable, Sendable {
    case crossApplication
    case externalCommunication
    case upload
    case purchase
    case deletion
    case publication
    case securitySettings
    case formSubmission
    case fileMovement
    case unverifiedTarget
  }

  let risk: Risk
  let title: String
  let detail: String
  let proposedScope: AgentApprovalScope
}

nonisolated enum AgentPolicyDecision: Equatable, Sendable {
  case allow
  case requireApproval(AgentApprovalRequest)
  case deny(reason: String)
}

nonisolated struct AgentPolicyContext: Sendable {
  let userIntentText: String
  let initialApplication: AgentApplicationContext
  let currentApplication: AgentApplicationContext
  let action: AgentToolAction
  let accessibilityElements: [AgentAccessibilityElementSnapshot]
  let approvedApplicationBundleIdentifiers: Set<String>
  /// The display the observation snapshot belongs to; coordinate actions
  /// must land on this display to be hit-tested locally.
  let observationDisplayID: CGDirectDisplayID
}

nonisolated struct AgentPolicyEngine: Sendable {
  func evaluate(_ context: AgentPolicyContext) -> AgentPolicyDecision {
    if let prohibitedAutomationDecision = prohibitedAutomationDecision(for: context) {
      return prohibitedAutomationDecision
    }

    let normalizedIntent = Self.normalize(context.userIntentText)
    if Self.fileDeletionTokens.contains(where: { normalizedIntent.contains($0) }) {
      switch context.action {
      case .askUser, .complete, .wait:
        break
      default:
        return .deny(reason: "Agent Mode does not delete files or folders.")
      }
    }

    let focusedSecureElement = context.accessibilityElements.contains { $0.focused && $0.isSecure }
    if case .typeText(let action) = context.action {
      let targetIsSecure = targetElement(action.elementID, in: context)?.isSecure == true
        || focusedSecureElement
      let intentRequestsSecret = Self.secretTokens.contains { normalizedIntent.contains($0) }
      if targetIsSecure || intentRequestsSecret {
        return .deny(reason: "Agent Mode never enters passwords, credentials, or secure-field text.")
      }
    }

    if case .pressKeys = context.action, focusedSecureElement {
      return .deny(reason: "Agent Mode never sends keystrokes to password or secure text fields.")
    }

    if let crossApplicationDecision = crossApplicationDecision(for: context) {
      return crossApplicationDecision
    }

    switch context.action {
    case .activateApplication:
      return .allow

    case .click(let action):
      guard action.clickCount == 1 || action.clickCount == 2 else {
        return .deny(reason: "Only single-click and double-click actions are supported.")
      }
      // A coordinate fallback must not bypass semantic approval. Keep the
      // requested element as a primary target, then add the element at the
      // pointer landing point when the Driver will post a CGEvent.
      var primaryTargetIDs: Set<String> = []
      var targets: [AgentAccessibilityElementSnapshot] = []
      var targetIDs: Set<String> = []
      var requiresUnverifiedTargetApproval = false

      func appendTargets(_ elements: [AgentAccessibilityElementSnapshot]) {
        targets.append(contentsOf: elements.filter { targetIDs.insert($0.id).inserted })
      }

      if let elementID = action.elementID,
         let element = targetElement(elementID, in: context) {
        primaryTargetIDs.insert(element.id)
        appendTargets([element])

        if let frame = usableFrame(of: element) {
          let hitElements = hitTestElements(at: frame.center, in: context)
          appendTargets(hitElements)
          if let pointerTarget = hitElements.min(by: Self.isSmallerFrame) {
            primaryTargetIDs.insert(pointerTarget.id)
          }
        } else if let displayID = action.displayID, let point = action.point {
          guard point.isValid else {
            return .deny(reason: "The click coordinates are invalid.")
          }
          guard displayID == context.observationDisplayID else {
            return .deny(reason: "The click falls back to coordinates on an unobserved display.")
          }
          let hitElements = hitTestElements(at: point, in: context)
          appendTargets(hitElements)
          if let pointerTarget = hitElements.min(by: Self.isSmallerFrame) {
            primaryTargetIDs.insert(pointerTarget.id)
          } else {
            requiresUnverifiedTargetApproval = true
          }
        } else if action.button != .left || action.clickCount != 1 {
          // Only a single left click can use AXPress without a pointer
          // location. Right-click and double-click require a frame or explicit
          // fallback coordinates in MacComputerDriver.
          return .deny(reason: "The click target has no usable pointer location.")
        }
      } else {
        guard let displayID = action.displayID, let point = action.point else {
          return .deny(reason: "The click target could not be resolved.")
        }
        guard point.isValid else {
          return .deny(reason: "The click coordinates are invalid.")
        }
        guard displayID == context.observationDisplayID else {
          return approval(
            risk: .unverifiedTarget,
            title: L10n.Agent.unverifiedTargetApprovalTitle,
            detail: L10n.Agent.unverifiedTargetApprovalDetail
          )
        }
        let hitElements = hitTestElements(at: point, in: context)
        appendTargets(hitElements)
        if let pointerTarget = hitElements.min(by: Self.isSmallerFrame) {
          primaryTargetIDs.insert(pointerTarget.id)
        } else {
          requiresUnverifiedTargetApproval = true
        }
      }

      // Both the explicitly requested semantic element and the innermost
      // pointer target are primary. Neither may be disabled.
      if targets.contains(where: { primaryTargetIDs.contains($0.id) && !$0.enabled }) {
        return .deny(reason: "The requested accessibility element is disabled.")
      }
      // Scan every containing element so a text-less child cannot mask the
      // risk carried by an ancestor such as Send, Delete, or a secure field.
      for element in targets {
        let normalizedTarget = Self.normalize(element.policyText)
        if element.isSecure || Self.secretTokens.contains(where: { normalizedTarget.contains($0) }) {
          return .deny(reason: "Agent Mode does not interact with password or credential controls.")
        }
      }
      let combinedPolicyText = targets.map(\.policyText).joined(separator: " ")
      if isFileDeletionTarget(combinedPolicyText, in: context) {
        return .deny(reason: "Agent Mode does not delete files or folders.")
      }
      if let decision = riskDecision(
        for: combinedPolicyText,
        actionSummary: context.action.safeSummary
      ) {
        return decision
      }
      if requiresUnverifiedTargetApproval {
        return approval(
          risk: .unverifiedTarget,
          title: L10n.Agent.unverifiedTargetApprovalTitle,
          detail: L10n.Agent.unverifiedTargetApprovalDetail
        )
      }
      return .allow

    case .typeText:
      return .allow

    case .pressKeys(let action):
      let normalizedKeys = Set(action.keys.map(Self.normalize))
      let surfaceText = context.accessibilityElements
        .filter(\.focused)
        .map(\.policyText)
        .joined(separator: " ")
      if normalizedKeys.contains("return") || normalizedKeys.contains("enter") {
        if let decision = riskDecision(
          for: surfaceText,
          actionSummary: context.action.safeSummary,
          fallbackRisk: .formSubmission
        ) {
          return decision
        }
      }
      if normalizedKeys.contains("delete") || normalizedKeys.contains("backspace"),
         normalizedKeys.contains("command") {
        if context.currentApplication.bundleIdentifier == "com.apple.finder" {
          return .deny(reason: "Agent Mode does not delete files or folders.")
        }
        return approval(
          risk: .deletion,
          title: "Confirm deletion shortcut",
          detail: "Agent Mode wants to press \(action.keys.joined(separator: "+")), which may delete content."
        )
      }
      return .allow

    case .scroll:
      return .allow

    case .drag:
      if context.currentApplication.bundleIdentifier == "com.apple.finder" {
        return approval(
          risk: .fileMovement,
          title: "Confirm Finder drag",
          detail: "Agent Mode wants to drag an item in Finder. This may move a file or folder."
        )
      }
      return .allow

    case .wait, .askUser, .complete:
      return .allow
    }
  }

  private func prohibitedAutomationDecision(
    for context: AgentPolicyContext
  ) -> AgentPolicyDecision? {
    if case .activateApplication(let action) = context.action,
       Self.isRestrictedAutomationApplication(
         bundleIdentifier: action.bundleIdentifier,
         applicationName: action.applicationName
       ) {
      return .deny(reason: "Agent Mode does not operate shells, terminals, or AppleScript tools.")
    }

    switch context.action {
    case .click, .typeText, .pressKeys, .drag:
      if Self.isRestrictedAutomationApplication(
        bundleIdentifier: context.currentApplication.bundleIdentifier,
        applicationName: context.currentApplication.applicationName
      ) {
        return .deny(reason: "Agent Mode does not operate shells, terminals, or AppleScript tools.")
      }
    default:
      break
    }

    switch context.action {
    case .typeText, .pressKeys:
      let focusedSurface = context.accessibilityElements
        .filter(\.focused)
        .map(\.policyText)
        .joined(separator: " ")
      let normalizedSurface = Self.normalize(focusedSurface)
      if Self.shellSurfaceTokens.contains(where: { normalizedSurface.contains($0) }) {
        return .deny(reason: "Agent Mode does not type or send keys into shell and terminal surfaces.")
      }
    default:
      break
    }

    return nil
  }

  private func isFileDeletionTarget(
    _ text: String,
    in context: AgentPolicyContext
  ) -> Bool {
    let normalized = Self.normalize(text)
    if Self.fileDeletionTokens.contains(where: { normalized.contains($0) }) {
      return true
    }
    guard context.currentApplication.bundleIdentifier == "com.apple.finder" else {
      return false
    }
    return Self.deletionTokens.contains(where: { normalized.contains($0) })
  }

  private func crossApplicationDecision(for context: AgentPolicyContext) -> AgentPolicyDecision? {
    let initialBundle = context.initialApplication.bundleIdentifier
    let requestedBundle: String? = if case .activateApplication(let action) = context.action {
      action.bundleIdentifier
    } else {
      context.currentApplication.bundleIdentifier
    }

    if case .activateApplication(let action) = context.action,
       requestedBundle == nil {
      let requestedName = action.applicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let requestedName,
            requestedName.localizedCaseInsensitiveCompare(context.initialApplication.applicationName) != .orderedSame
      else { return nil }
      return .requireApproval(AgentApprovalRequest(
        risk: .crossApplication,
        title: "Allow access to another application?",
        detail: "This task started in \(context.initialApplication.applicationName). Agent Mode now wants to activate \(requestedName).",
        proposedScope: .actionOnly
      ))
    }

    guard let requestedBundle,
          requestedBundle != initialBundle,
          !context.approvedApplicationBundleIdentifiers.contains(requestedBundle)
    else { return nil }

    let requestedName: String = if case .activateApplication(let action) = context.action {
      action.applicationName ?? requestedBundle
    } else {
      context.currentApplication.applicationName
    }

    return .requireApproval(AgentApprovalRequest(
      risk: .crossApplication,
      title: "Allow access to another application?",
      detail: "This task started in \(context.initialApplication.applicationName). Agent Mode now wants to act in \(requestedName) (\(requestedBundle)).",
      proposedScope: .application(bundleIdentifier: requestedBundle)
    ))
  }

  private func targetElement(
    _ elementID: String?,
    in context: AgentPolicyContext
  ) -> AgentAccessibilityElementSnapshot? {
    guard let elementID else { return nil }
    return context.accessibilityElements.first { $0.id == elementID }
  }

  /// Returns every accessibility element whose non-degenerate frame contains
  /// the normalized point, so coordinate clicks inherit element-level policy
  /// from all containing elements, not just the innermost one. Degenerate
  /// frames (zero width or height) are excluded so they cannot distort the
  /// disabled-element check.
  private func hitTestElements(
    at point: AgentNormalizedPoint,
    in context: AgentPolicyContext
  ) -> [AgentAccessibilityElementSnapshot] {
    context.accessibilityElements
      .filter { element in
        guard let frame = element.normalizedFrame,
              frame.width > 0, frame.height > 0
        else { return false }
        return point.x >= frame.x && point.x <= frame.x + frame.width
          && point.y >= frame.y && point.y <= frame.y + frame.height
      }
  }

  private func usableFrame(
    of element: AgentAccessibilityElementSnapshot
  ) -> AgentNormalizedRect? {
    guard let frame = element.normalizedFrame,
          frame.x.isFinite, frame.y.isFinite,
          frame.width.isFinite, frame.height.isFinite,
          frame.width > 0, frame.height > 0
    else { return nil }
    return frame
  }

  /// Orders elements by frame area so the innermost containing element wins.
  private static func isSmallerFrame(
    _ lhs: AgentAccessibilityElementSnapshot,
    _ rhs: AgentAccessibilityElementSnapshot
  ) -> Bool {
    let lhsArea = lhs.normalizedFrame.map { $0.width * $0.height } ?? 0
    let rhsArea = rhs.normalizedFrame.map { $0.width * $0.height } ?? 0
    return lhsArea < rhsArea
  }

  private func riskDecision(
    for text: String,
    actionSummary: String,
    fallbackRisk: AgentApprovalRequest.Risk? = nil
  ) -> AgentPolicyDecision? {
    let normalized = Self.normalize(text)
    for rule in Self.riskRules where rule.tokens.contains(where: normalized.contains) {
      return approval(
        risk: rule.risk,
        title: rule.title,
        detail: "Agent Mode proposes: \(actionSummary). The target appears to be “\(text.prefix(180))”."
      )
    }

    guard let fallbackRisk else { return nil }
    return approval(
      risk: fallbackRisk,
      title: "Confirm form submission",
      detail: "Agent Mode wants to press Return/Enter. This may submit the current form or message."
    )
  }

  private func approval(
    risk: AgentApprovalRequest.Risk,
    title: String,
    detail: String
  ) -> AgentPolicyDecision {
    .requireApproval(AgentApprovalRequest(
      risk: risk,
      title: title,
      detail: detail,
      proposedScope: .actionOnly
    ))
  }

  private static func normalize(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private static func isRestrictedAutomationApplication(
    bundleIdentifier: String?,
    applicationName: String?
  ) -> Bool {
    if let bundleIdentifier,
       restrictedAutomationBundleIdentifiers.contains(bundleIdentifier.lowercased()) {
      return true
    }
    guard let applicationName else { return false }
    let normalizedName = normalize(applicationName)
    return restrictedAutomationApplicationNames.contains { normalizedName == $0 }
  }

  private static let riskRules: [(
    risk: AgentApprovalRequest.Risk,
    title: String,
    tokens: [String]
  )] = [
    (.externalCommunication, "Confirm sending", [
      "send", "submit message", "reply", "post comment", "发送", "傳送", "送信", "보내기", "enviar",
    ]),
    (.upload, "Confirm upload", [
      "upload", "attach file", "上传", "上傳", "アップロード", "업로드", "subir",
    ]),
    (.purchase, "Confirm purchase", [
      "buy", "purchase", "place order", "pay now", "checkout", "购买", "購買", "付款", "注文", "구매",
    ]),
    (.deletion, "Confirm deletion", [
      "delete", "remove", "erase", "trash", "删除", "刪除", "移除", "削除", "삭제",
    ]),
    (.publication, "Confirm publication", [
      "publish", "deploy", "make public", "发布", "發佈", "公开", "公開", "公開する", "게시",
    ]),
    (.securitySettings, "Confirm security change", [
      "security", "privacy", "permission", "firewall", "password", "安全", "隐私", "隱私", "权限", "權限",
    ]),
  ]

  private static let secretTokens = [
    "password", "passcode", "credential", "secret", "密码", "密碼", "パスワード", "비밀번호",
  ]

  private static let deletionTokens = [
    "delete", "remove", "erase", "trash", "删除", "刪除", "移除", "削除", "삭제",
  ]

  private static let fileDeletionTokens = [
    "delete file", "delete folder", "remove file", "remove folder", "erase file", "erase folder",
    "move to trash", "empty trash", "trash file", "trash folder", "删除文件", "删除文件夹",
    "刪除檔案", "刪除資料夾", "ファイルを削除", "フォルダを削除", "파일 삭제", "폴더 삭제",
  ]

  private static let restrictedAutomationBundleIdentifiers: Set<String> = [
    "com.apple.automator",
    "com.apple.scripteditor2",
    "com.apple.terminal",
    "com.googlecode.iterm2",
    "dev.warp.warp-stable",
  ]

  private static let restrictedAutomationApplicationNames: Set<String> = [
    "automator", "iterm", "iterm2", "script editor", "terminal", "warp", "脚本编辑器", "终端",
  ]

  private static let shellSurfaceTokens = [
    "terminal", "shell", "console", "command line", "终端", "命令行", "シェル", "터미널",
  ]
}
