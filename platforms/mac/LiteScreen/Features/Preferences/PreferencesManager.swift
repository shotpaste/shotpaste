//
//  PreferencesManager.swift
//  LiteScreen
//
//  Centralized state management for complex preferences
//

import Combine
import Foundation

/// Actions that can be triggered after capture
enum AfterCaptureAction: String, CaseIterable, Codable {
  case showQuickAccess
  case copyFile
  case save

  var displayName: String {
    switch self {
    case .showQuickAccess: L10n.Actions.showQuickAccessOverlay
    case .copyFile: L10n.AfterCapture.copyFileAction
    case .save: L10n.AfterCapture.saveAction
    }
  }
}

/// Types of capture operations
enum CaptureType: String, CaseIterable, Codable {
  case screenshot
  case recording

  var displayName: String {
    switch self {
    case .screenshot:
      L10n.CaptureKind.screenshot
    case .recording:
      L10n.CaptureKind.recording
    }
  }
}

/// Manager for complex preferences that require more than simple @AppStorage
@MainActor
final class PreferencesManager: ObservableObject {
  static let shared = PreferencesManager()

  // MARK: - Published State

  @Published var afterCaptureActions: [AfterCaptureAction: [CaptureType: Bool]] = [:]

  // MARK: - Private

  private let afterCaptureActionsKey = "afterCaptureActions"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    loadAfterCaptureActions()
  }

  // MARK: - After Capture Actions

  /// Set whether an action is enabled for a capture type
  func setAction(_ action: AfterCaptureAction, for type: CaptureType, enabled: Bool) {
    if afterCaptureActions[action] == nil {
      afterCaptureActions[action] = [:]
    }
    afterCaptureActions[action]?[type] = enabled
    DiagnosticLogger.shared.log(
      .info,
      .preferences,
      "After-capture action changed",
      context: [
        "action": action.rawValue,
        "captureType": type.rawValue,
        "enabled": enabled ? "true" : "false",
      ]
    )
    saveAfterCaptureActions()
  }

  /// Check if an action is enabled for a capture type
  func isActionEnabled(_ action: AfterCaptureAction, for type: CaptureType) -> Bool {
    afterCaptureActions[action]?[type] ?? defaultValue(for: action, type: type)
  }

  /// Default values for after-capture actions
  private func defaultValue(for action: AfterCaptureAction, type _: CaptureType) -> Bool {
    switch action {
    case .showQuickAccess, .save, .copyFile:
      true
    }
  }

  // MARK: - Persistence

  private func saveAfterCaptureActions() {
    // Convert to serializable format
    var serializable: [String: [String: Bool]] = [:]
    for (action, typeDict) in afterCaptureActions {
      var innerDict: [String: Bool] = [:]
      for (captureType, enabled) in typeDict {
        innerDict[captureType.rawValue] = enabled
      }
      serializable[action.rawValue] = innerDict
    }

    do {
      let data = try JSONEncoder().encode(serializable)
      defaults.set(data, forKey: afterCaptureActionsKey)
    } catch {
      DiagnosticLogger.shared.logError(
        .preferences,
        error,
        "Failed to save after-capture actions",
        context: ["actionCount": "\(afterCaptureActions.count)"]
      )
    }
  }

  private func loadAfterCaptureActions() {
    guard let data = defaults.data(forKey: afterCaptureActionsKey) else {
      initializeDefaults()
      return
    }

    let serializable: [String: [String: Bool]]
    do {
      serializable = try JSONDecoder().decode([String: [String: Bool]].self, from: data)
    } catch {
      DiagnosticLogger.shared.logError(
        .preferences,
        error,
        "Failed to decode after-capture actions; using defaults",
        context: ["dataBytes": "\(data.count)"]
      )
      initializeDefaults()
      return
    }

    // Convert back to typed format
    for (actionRaw, typeDict) in serializable {
      guard let action = AfterCaptureAction(rawValue: actionRaw) else {
        DiagnosticLogger.shared.log(
          .warning,
          .preferences,
          "Unknown after-capture action ignored",
          context: ["action": actionRaw]
        )
        continue
      }
      for (typeRaw, enabled) in typeDict {
        guard let captureType = CaptureType(rawValue: typeRaw) else {
          DiagnosticLogger.shared.log(
            .warning,
            .preferences,
            "Unknown after-capture capture type ignored",
            context: ["captureType": typeRaw]
          )
          continue
        }
        if afterCaptureActions[action] == nil {
          afterCaptureActions[action] = [:]
        }
        afterCaptureActions[action]?[captureType] = enabled
      }
    }
    DiagnosticLogger.shared.log(
      .debug,
      .preferences,
      "After-capture actions loaded",
      context: ["actionCount": "\(afterCaptureActions.count)"]
    )
  }

  private func initializeDefaults() {
    for action in AfterCaptureAction.allCases {
      afterCaptureActions[action] = [:]
      for type in CaptureType.allCases {
        afterCaptureActions[action]?[type] = defaultValue(for: action, type: type)
      }
    }
    DiagnosticLogger.shared.log(.debug, .preferences, "After-capture action defaults initialized")
  }
}
