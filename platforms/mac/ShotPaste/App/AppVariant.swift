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
    if let configuredValue = Bundle.main.object(
      forInfoDictionaryKey: "ShotPasteVariant"
    ) as? String,
      let configuredVariant = AppVariant(rawValue: configuredValue) {
      return configuredVariant
    }

    // Keep non-app contexts such as previews usable. Canonical app and test
    // products always carry ShotPasteVariant and verify it against this model.
    #if DEBUG
      return .debug
    #else
      return .release
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

  var urlScheme: String {
    switch self {
    case .debug: "shotpaste-debug"
    case .release: "shotpaste"
    }
  }

  private var globalResourceNamespace: String {
    bundleIdentifier
  }

  var internalPasteboardWriteMarkerIdentifier: String {
    "\(globalResourceNamespace).internal-media-write"
  }

  var quickAccessActionTypeIdentifier: String {
    "\(globalResourceNamespace).quick-access-action"
  }

  var quickAccessReorderTypeIdentifier: String {
    "\(globalResourceNamespace).quick-access-reorder"
  }

  var erasesDatabaseOnSchemaChange: Bool {
    self == .debug
  }

  var performsAutomaticUpdateChecks: Bool {
    self == .release
  }

  /// Provider response shape diagnostics are useful while debugging, but must
  /// stay out of Release logs because even metadata is not needed in normal
  /// production operation.
  var logsTranslationResponseSummaries: Bool {
    self == .debug
  }

  var applicationSupportDirectoryName: String {
    dataDirectoryName
  }

  var diagnosticLogDirectoryName: String {
    dataDirectoryName
  }

  var defaultExportDirectoryName: String {
    dataDirectoryName
  }

  private var dataDirectoryName: String {
    switch self {
    case .debug: "ShotPaste Debug"
    case .release: "ShotPaste"
    }
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

  var menuBarIconAssetName: String {
    switch self {
    case .debug: "MenubarIconDebug"
    case .release: "MenubarIcon"
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

  /// The private working area used by the audio-adapter capture pipeline.
  ///
  /// Keeping this path behind the same variant-aware root as the rest of the
  /// application data is important: a Debug capture must never be picked up
  /// by a Release recovery pass (or vice versa).
  static func audioAdapterDirectory(
    in applicationSupportDirectory: URL,
    variant: AppVariant
  ) -> URL {
    applicationSupportRoot(in: applicationSupportDirectory, variant: variant)
      .appendingPathComponent("AudioAdapter", isDirectory: true)
  }

  static func audioAdapterSessionsDirectory(
    in applicationSupportDirectory: URL,
    variant: AppVariant
  ) -> URL {
    audioAdapterDirectory(in: applicationSupportDirectory, variant: variant)
      .appendingPathComponent("Sessions", isDirectory: true)
  }

  static var applicationSupportRoot: URL? {
    guard let baseDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    return applicationSupportRoot(in: baseDirectory, variant: .current)
  }

  static var audioAdapterSessionsDirectory: URL? {
    guard let baseDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else { return nil }
    return audioAdapterSessionsDirectory(in: baseDirectory, variant: .current)
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
