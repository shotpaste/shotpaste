//
//  PreferencesLoginItemManager.swift
//  ShotPaste
//
//  Wrapper for SMAppService to manage launch at login
//

import ServiceManagement

enum LoginItemUpdateResult {
  case applied(isEnabled: Bool)
  case requiresApproval
  case failed(String)
}

/// Manages the app's login item status using SMAppService
enum LoginItemManager {
  /// Enable or disable launch at login
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> LoginItemUpdateResult {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      DiagnosticLogger.shared.log(
        .info,
        .preferences,
        "Launch at login preference updated",
        context: ["enabled": enabled ? "true" : "false"]
      )
      ShotPasteConfigurationSyncCoordinator.shared.scheduleSync(reason: .explicitChange)
      if SMAppService.mainApp.status == .requiresApproval {
        return .requiresApproval
      }
      return .applied(isEnabled: isEnabled)
    } catch {
      DiagnosticLogger.shared.logError(
        .preferences,
        error,
        "Launch at login preference update failed",
        context: ["enabled": enabled ? "true" : "false"]
      )
      return .failed(error.localizedDescription)
    }
  }

  /// Check if launch at login is currently enabled
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }
}
