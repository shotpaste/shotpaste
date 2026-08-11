//
//  PreferencesLoginItemManager.swift
//  LiteScreen
//
//  Wrapper for SMAppService to manage launch at login
//

import ServiceManagement

/// Manages the app's login item status using SMAppService
enum LoginItemManager {
  /// Enable or disable launch at login
  static func setEnabled(_ enabled: Bool) {
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
      LiteScreenConfigurationSyncCoordinator.shared.scheduleSync(reason: .explicitChange)
    } catch {
      DiagnosticLogger.shared.logError(
        .preferences,
        error,
        "Launch at login preference update failed",
        context: ["enabled": enabled ? "true" : "false"]
      )
    }
  }

  /// Check if launch at login is currently enabled
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }
}
