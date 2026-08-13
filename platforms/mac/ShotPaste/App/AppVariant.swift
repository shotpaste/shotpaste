//
//  AppVariant.swift
//  ShotPaste
//
//  Keeps Debug-only runtime identity and storage separate from the Release app.
//

import Foundation

nonisolated enum AppVariant: String, CaseIterable, Sendable {
  case debug
  case release

  static var current: AppVariant {
    #if DEBUG
      .debug
    #else
      .release
    #endif
  }

  var bundleIdentifier: String {
    switch self {
    case .debug: "com.ahtcfg24.shotpaste.debug"
    case .release: "com.ahtcfg24.shotpaste"
    }
  }

  var displayName: String {
    switch self {
    case .debug: "ShotPaste Debug"
    case .release: "ShotPaste"
    }
  }

  var executableName: String {
    switch self {
    case .debug: "ShotPasteDebug"
    case .release: "ShotPaste"
    }
  }

  var applicationSupportDirectoryName: String {
    displayName
  }

  var diagnosticLogDirectoryName: String {
    displayName
  }

  var defaultExportDirectoryName: String {
    displayName
  }

  var configurationDirectoryName: String {
    switch self {
    case .debug: "shotpaste-debug"
    case .release: "shotpaste"
    }
  }

  var fallbackCaptureDirectoryName: String {
    switch self {
    case .debug: "ShotPaste_Debug_Captures"
    case .release: "ShotPaste_Captures"
    }
  }

  var problemReportsDirectoryName: String {
    switch self {
    case .debug: "ShotPasteDebugProblemReports"
    case .release: "ShotPasteProblemReports"
    }
  }

  var problemReportFilePrefix: String {
    switch self {
    case .debug: "shotpaste-debug-problem-report-"
    case .release: "shotpaste-problem-report-"
    }
  }

  var defaultMCPPort: Int {
    switch self {
    case .debug: 48_124
    case .release: 48_123
    }
  }

  var mcpClientName: String {
    switch self {
    case .debug: "shotpaste-debug"
    case .release: "shotpaste"
    }
  }
}

nonisolated enum AppDataLocations {
  static func applicationSupportRoot(
    in applicationSupportDirectory: URL,
    variant: AppVariant
  ) -> URL {
    applicationSupportDirectory
      .appendingPathComponent(variant.applicationSupportDirectoryName, isDirectory: true)
  }

  static func configurationDirectory(
    in homeDirectory: URL,
    variant: AppVariant
  ) -> URL {
    homeDirectory
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent(variant.configurationDirectoryName, isDirectory: true)
  }

  static func defaultExportDirectory(
    in baseDirectory: URL,
    variant: AppVariant
  ) -> URL {
    baseDirectory
      .appendingPathComponent(variant.defaultExportDirectoryName, isDirectory: true)
  }

  static func diagnosticLogDirectory(
    in libraryDirectory: URL,
    variant: AppVariant
  ) -> URL {
    libraryDirectory
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent(variant.diagnosticLogDirectoryName, isDirectory: true)
  }

  static var applicationSupportRoot: URL? {
    guard let baseDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    return applicationSupportRoot(in: baseDirectory, variant: .current)
  }

  static var fallbackCaptureDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(AppVariant.current.fallbackCaptureDirectoryName, isDirectory: true)
  }

  static var problemReportsDirectory: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(AppVariant.current.problemReportsDirectoryName, isDirectory: true)
  }

  static func defaultExportDirectory(
    for variant: AppVariant,
    fileManager: FileManager = .default
  ) -> URL {
    let baseDirectory = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
    return defaultExportDirectory(in: baseDirectory, variant: variant)
  }
}

@MainActor
enum DebugDataIsolationMigration {
  static let currentVersion = 1

  static func applyIfNeeded(
    variant: AppVariant = .current,
    defaults: UserDefaults = .standard,
    legacyDefaultExportDirectory: URL? = nil,
    isolatedDefaultExportDirectory: URL? = nil,
    homeDirectory: URL = ShotPasteConfigurationPaths.userHomeDirectory
  ) {
    guard variant == .debug else { return }
    guard defaults.integer(forKey: PreferencesKeys.debugDataIsolationMigrationVersion) < currentVersion else {
      return
    }

    let legacyExportDirectory = legacyDefaultExportDirectory
      ?? AppDataLocations.defaultExportDirectory(for: .release)
    let isolatedExportDirectory = isolatedDefaultExportDirectory
      ?? AppDataLocations.defaultExportDirectory(for: .debug)

    if let storedExportPath = defaults.string(forKey: PreferencesKeys.exportLocation),
       URL(fileURLWithPath: storedExportPath, isDirectory: true).standardizedFileURL
       == legacyExportDirectory.standardizedFileURL {
      defaults.set(isolatedExportDirectory.path, forKey: PreferencesKeys.exportLocation)
      defaults.removeObject(forKey: PreferencesKeys.exportLocationBookmark)
    }

    if defaults.object(forKey: PreferencesKeys.mcpServerPort) != nil,
       defaults.integer(forKey: PreferencesKeys.mcpServerPort) == AppVariant.release.defaultMCPPort {
      defaults.set(AppVariant.debug.defaultMCPPort, forKey: PreferencesKeys.mcpServerPort)
    }

    migratePersistedDefaultShortcut(
      forKey: PreferencesKeys.oneShotShortcut,
      keyCode: ShortcutConfig.defaultOneShot.keyCode,
      defaults: defaults
    )
    migratePersistedDefaultShortcut(
      forKey: "historyShortcut",
      keyCode: ShortcutConfig.defaultHistory.keyCode,
      defaults: defaults
    )
    migratePersistedDefaultShortcut(
      forKey: "pauseResumeRecordingShortcut",
      keyCode: ShortcutConfig.defaultPauseResumeRecording.keyCode,
      defaults: defaults
    )

    let legacyConfigDirectory = ShotPasteConfigurationPaths.suggestedConfigDirectoryURL(
      homeDirectory: homeDirectory,
      variant: .release
    )
    let legacyConfigFile = legacyConfigDirectory.appendingPathComponent("config.toml")
    var resetManagedConfig = false

    if bookmarkURL(forKey: PreferencesKeys.configurationFileBookmark, defaults: defaults)?
      .standardizedFileURL == legacyConfigFile.standardizedFileURL {
      defaults.removeObject(forKey: PreferencesKeys.configurationFileBookmark)
      resetManagedConfig = true
    }

    if bookmarkURL(forKey: PreferencesKeys.configurationDirectoryBookmark, defaults: defaults)?
      .standardizedFileURL == legacyConfigDirectory.standardizedFileURL {
      defaults.removeObject(forKey: PreferencesKeys.configurationDirectoryBookmark)
      resetManagedConfig = true
    }

    if resetManagedConfig {
      defaults.removeObject(forKey: PreferencesKeys.configurationLastAppliedSignature)
    }

    defaults.set(currentVersion, forKey: PreferencesKeys.debugDataIsolationMigrationVersion)
  }

  private static func bookmarkURL(forKey key: String, defaults: UserDefaults) -> URL? {
    guard let data = defaults.data(forKey: key) else { return nil }
    var isStale = false
    return try? URL(
      resolvingBookmarkData: data,
      options: [.withoutUI, .withoutMounting],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
  }

  private static func migratePersistedDefaultShortcut(
    forKey key: String,
    keyCode: UInt32,
    defaults: UserDefaults
  ) {
    guard let data = defaults.data(forKey: key),
          let stored = try? JSONDecoder().decode(ShortcutConfig.self, from: data)
    else { return }

    let legacyDefault = ShortcutConfig(
      keyCode: keyCode,
      modifiers: ShortcutConfig.defaultModifiers(for: .release)
    )
    guard stored == legacyDefault else { return }

    let isolatedDefault = ShortcutConfig(
      keyCode: keyCode,
      modifiers: ShortcutConfig.defaultModifiers(for: .debug)
    )
    guard let isolatedData = try? JSONEncoder().encode(isolatedDefault) else { return }
    defaults.set(isolatedData, forKey: key)
  }
}
