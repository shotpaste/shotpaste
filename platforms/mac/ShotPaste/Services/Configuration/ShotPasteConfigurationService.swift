//
//  ShotPasteConfigurationService.swift
//  ShotPaste
//
//  Facade for exporting and importing ShotPaste TOML configuration files.
//

import Foundation

@MainActor
final class ShotPasteConfigurationService {
  static let shared = ShotPasteConfigurationService()
  private nonisolated static let managedConfigFileQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.configuration.managed-file",
    qos: .utility
  )

  private let defaults = UserDefaults.standard
  private var nextManagedConfigOperationID = 0
  private var latestManagedConfigOperationID = 0

  private init() {}

  struct ScopedAccess: Sendable {
    let url: URL
    private let accessURL: URL
    private let didStartAccessing: Bool

    init(url: URL, accessURL: URL, didStartAccessing: Bool) {
      self.url = url
      self.accessURL = accessURL
      self.didStartAccessing = didStartAccessing
    }

    nonisolated func stop() {
      if didStartAccessing {
        accessURL.stopAccessingSecurityScopedResource()
      }
    }
  }

  private struct ManagedConfigFileSyncOutcome: Sendable {
    let result: ShotPasteConfigurationSyncResult
    let sourceToMarkApplied: String?
  }

  var suggestedConfigURL: URL {
    ShotPasteConfigurationPaths.suggestedConfigURL
  }

  var suggestedConfigDirectoryURL: URL {
    ShotPasteConfigurationPaths.suggestedConfigDirectoryURL
  }

  var suggestedConfigParentDirectoryURL: URL {
    suggestedConfigDirectoryURL.deletingLastPathComponent()
  }

  var suggestedConfigRootDirectoryURL: URL {
    ShotPasteConfigurationPaths.userHomeDirectory
  }

  var resolvedConfigFileURL: URL {
    if let fileURL = resolveBookmarkURL(forKey: PreferencesKeys.configurationFileBookmark) {
      return fileURL
    }
    if let directoryURL = resolveBookmarkURL(forKey: PreferencesKeys.configurationDirectoryBookmark) {
      return configFileURL(inDirectory: directoryURL)
    }
    return suggestedConfigURL
  }

  var hasPersistedConfigPermission: Bool {
    guard let accessURL = resolvedConfigAccessURL(for: resolvedConfigFileURL) else {
      return false
    }

    let didStart = accessURL.startAccessingSecurityScopedResource()
    if didStart {
      accessURL.stopAccessingSecurityScopedResource()
    }
    return didStart
  }

  var needsUserSelectedConfigAccess: Bool {
    isRunningSandboxed && !hasPersistedConfigPermission
  }

  func exportTOML() -> String {
    ShotPasteConfigurationExporter.exportTOML()
  }

  static func syncDecision(
    fileSource: String,
    currentSource: String,
    defaults: UserDefaults = .standard
  ) -> ShotPasteConfigurationSyncDecision {
    if fileSource == currentSource {
      return .alreadyCurrent
    }

    if ShotPasteConfigurationAutoImporter.isCurrentFileApplied(fileSource, defaults: defaults) {
      return .syncAutomatically
    }

    return .askBeforeReplacing
  }

  func export(to url: URL) throws {
    let toml = exportTOML()
    let shouldMarkApplied = isSuggestedConfigFile(url)
    let operationID = shouldMarkApplied ? beginManagedConfigOperation() : nil
    try Self.managedConfigFileQueue.sync {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try toml.write(to: url, atomically: true, encoding: .utf8)
    }

    if shouldMarkApplied, let operationID {
      markCurrentFileAppliedIfLatest(toml, operationID: operationID)
    }
  }

  func importTOML(_ source: String) -> ShotPasteConfigurationImportResult {
    ShotPasteConfigurationImporter.importTOML(source)
  }

  func `import`(from url: URL) throws -> ShotPasteConfigurationImportResult {
    let source = try String(contentsOf: url, encoding: .utf8)
    return importTOML(source)
  }

  func importBackupReplacingManagedConfig(
    from url: URL,
    managedConfigURL: URL? = nil
  ) throws -> ShotPasteConfigurationImportResult {
    let source = try String(contentsOf: url, encoding: .utf8)
    let validationIssues = ShotPasteConfigurationImporter.validateTOML(source)

    guard !validationIssues.contains(where: { $0.severity == .error }) else {
      return ShotPasteConfigurationImportResult(appliedChangeCount: 0, issues: validationIssues)
    }

    let operationID = beginManagedConfigOperation()
    try replaceManagedConfig(with: source, at: managedConfigURL)
    let result = importTOML(source)
    if !result.hasErrors {
      markCurrentFileAppliedIfLatest(source, operationID: operationID)
    }
    return result
  }

  func restoreDefaultsReplacingManagedConfig() throws -> ShotPasteConfigurationImportResult {
    let source = ShotPasteConfigurationDefaultDocument.toml()
    let validationIssues = ShotPasteConfigurationImporter.validateTOML(source)

    guard !validationIssues.contains(where: { $0.severity == .error }) else {
      return ShotPasteConfigurationImportResult(appliedChangeCount: 0, issues: validationIssues)
    }

    let operationID = beginManagedConfigOperation()
    try replaceManagedConfig(with: source)

    let result = importTOML(source)
    if !result.hasErrors {
      markCurrentFileAppliedIfLatest(source, operationID: operationID)
    }
    return result
  }

  func prepareManagedConfigForOpening(at url: URL? = nil) throws -> ShotPasteConfigurationSyncResult {
    try syncManagedConfigIfSafe(at: url)
  }

  func syncManagedConfigIfSafe(at url: URL? = nil) throws -> ShotPasteConfigurationSyncResult {
    if url == nil, needsUserSelectedConfigAccess {
      return ShotPasteConfigurationSyncResult(status: .permissionRequired, fileURL: resolvedConfigFileURL)
    }

    let operationID = beginManagedConfigOperation()
    let currentSource = exportTOML()
    let access = beginAccessingConfigFile(url)
    defer { access.stop() }

    let lastAppliedSignature = defaults.string(forKey: PreferencesKeys.configurationLastAppliedSignature)
    let outcome = try Self.managedConfigFileQueue.sync {
      try Self.syncManagedConfigFile(
        currentSource: currentSource,
        fileURL: access.url,
        lastAppliedSignature: lastAppliedSignature
      )
    }
    if let source = outcome.sourceToMarkApplied {
      markCurrentFileAppliedIfLatest(source, operationID: operationID)
    }
    return outcome.result
  }

  func syncManagedConfigIfSafeInBackground(at url: URL? = nil) async throws -> ShotPasteConfigurationSyncResult {
    if url == nil, needsUserSelectedConfigAccess {
      return ShotPasteConfigurationSyncResult(status: .permissionRequired, fileURL: resolvedConfigFileURL)
    }

    let operationID = beginManagedConfigOperation()
    let currentSource = exportTOML()
    let lastAppliedSignature = defaults.string(forKey: PreferencesKeys.configurationLastAppliedSignature)
    let access = beginAccessingConfigFile(url)
    defer { access.stop() }

    let fileURL = access.url
    let outcome = try await Task.detached(priority: .utility) {
      try Self.managedConfigFileQueue.sync {
        try Self.syncManagedConfigFile(
          currentSource: currentSource,
          fileURL: fileURL,
          lastAppliedSignature: lastAppliedSignature
        )
      }
    }.value

    if let source = outcome.sourceToMarkApplied {
      markCurrentFileAppliedIfLatest(source, operationID: operationID)
    }
    return outcome.result
  }

  @discardableResult
  func syncManagedConfigToCurrentSettings(at url: URL? = nil) throws -> URL {
    let operationID = beginManagedConfigOperation()
    let source = exportTOML()
    let targetURL = try replaceManagedConfig(with: source, at: url)
    markCurrentFileAppliedIfLatest(source, operationID: operationID)
    return targetURL
  }

  @discardableResult
  func syncManagedConfigToCurrentSettingsIfUnchanged(
    at url: URL? = nil,
    expectedFileSignature: String?
  ) throws -> URL {
    let operationID = beginManagedConfigOperation()
    let source = exportTOML()
    let targetURL = url ?? resolvedConfigFileURL
    let access = beginAccessingConfigFile(targetURL)
    defer { access.stop() }

    try Self.managedConfigFileQueue.sync {
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

      if let expectedFileSignature {
        guard fileManager.fileExists(atPath: targetURL.path) else {
          throw ShotPasteConfigurationSyncError.fileChangedSinceConfirmation
        }
        let currentFileSource = try String(contentsOf: targetURL, encoding: .utf8)
        let currentFileSignature = ShotPasteConfigurationAutoImporter.contentSignature(for: currentFileSource)
        guard currentFileSignature == expectedFileSignature else {
          throw ShotPasteConfigurationSyncError.fileChangedSinceConfirmation
        }
      }

      try source.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    markCurrentFileAppliedIfLatest(source, operationID: operationID)
    return targetURL
  }

  @discardableResult
  func replaceManagedConfig(with source: String, at url: URL? = nil) throws -> URL {
    let targetURL = url ?? resolvedConfigFileURL
    let access = beginAccessingConfigFile(targetURL)
    defer { access.stop() }

    try Self.managedConfigFileQueue.sync {
      let directory = targetURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try source.write(to: targetURL, atomically: true, encoding: .utf8)
    }
    return targetURL
  }

  @discardableResult
  func ensureSuggestedConfigExists() throws -> URL {
    try ensureConfigExists(at: resolvedConfigFileURL)
  }

  @discardableResult
  func ensureConfigExists(at url: URL) throws -> URL {
    let access = beginAccessingConfigFile(url)
    defer { access.stop() }

    let toml = exportTOML()
    let shouldMarkApplied = isSuggestedConfigFile(url)
    var didCreateFile = false
    try Self.managedConfigFileQueue.sync {
      let fileManager = FileManager.default
      let directory = url.deletingLastPathComponent()
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

      if !fileManager.fileExists(atPath: url.path) {
        try toml.write(to: url, atomically: true, encoding: .utf8)
        didCreateFile = true
      }
    }
    if didCreateFile, shouldMarkApplied {
      let operationID = beginManagedConfigOperation()
      markCurrentFileAppliedIfLatest(toml, operationID: operationID)
    }

    return url
  }

  func configFileURL(inDirectory directoryURL: URL) -> URL {
    directoryURL
      .standardizedFileURL
      .appendingPathComponent("config.toml")
  }

  func isSuggestedConfigDirectory(_ url: URL) -> Bool {
    normalizedPath(url) == normalizedPath(suggestedConfigDirectoryURL)
  }

  func isSuggestedConfigParentDirectory(_ url: URL) -> Bool {
    normalizedPath(url) == normalizedPath(suggestedConfigParentDirectoryURL)
  }

  func isSuggestedConfigRootDirectory(_ url: URL) -> Bool {
    normalizedPath(url) == normalizedPath(suggestedConfigRootDirectoryURL)
  }

  func isSuggestedConfigFile(_ url: URL) -> Bool {
    normalizedPath(url) == normalizedPath(suggestedConfigURL)
  }

  func rememberConfigFileAccess(_ url: URL) throws {
    try rememberAccess(to: url, key: PreferencesKeys.configurationFileBookmark)
  }

  func rememberConfigDirectoryAccess(_ url: URL) throws {
    try rememberAccess(to: url, key: PreferencesKeys.configurationDirectoryBookmark)
  }

  func beginAccessingConfigFile(_ targetURL: URL? = nil) -> ScopedAccess {
    let fileURL = targetURL?.standardizedFileURL ?? resolvedConfigFileURL
    let accessURL = resolvedConfigAccessURL(for: fileURL) ?? fileURL
    let didStart = accessURL.startAccessingSecurityScopedResource()
    return ScopedAccess(url: fileURL, accessURL: accessURL, didStartAccessing: didStart)
  }

  private func rememberAccess(to url: URL, key: String) throws {
    let bookmarkData = try url.standardizedFileURL.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    defaults.set(bookmarkData, forKey: key)
  }

  private func beginManagedConfigOperation() -> Int {
    nextManagedConfigOperationID += 1
    latestManagedConfigOperationID = nextManagedConfigOperationID
    return nextManagedConfigOperationID
  }

  private func markCurrentFileAppliedIfLatest(_ source: String, operationID: Int) {
    guard operationID == latestManagedConfigOperationID else { return }
    ShotPasteConfigurationAutoImporter.markCurrentFileApplied(source, defaults: defaults)
  }

  private func resolvedConfigAccessURL(for targetURL: URL) -> URL? {
    if let fileURL = resolveBookmarkURL(forKey: PreferencesKeys.configurationFileBookmark),
       normalizedPath(fileURL) == normalizedPath(targetURL) {
      return fileURL
    }

    if let directoryURL = resolveBookmarkURL(forKey: PreferencesKeys.configurationDirectoryBookmark) {
      let targetPath = normalizedPath(targetURL)
      let directoryPath = normalizedPath(directoryURL)
      if targetPath == directoryPath || targetPath.hasPrefix(directoryPath + "/") {
        return directoryURL
      }
    }

    return nil
  }

  private func resolveBookmarkURL(forKey key: String, removeInvalidBookmark: Bool = true) -> URL? {
    guard let bookmarkData = defaults.data(forKey: key) else {
      return nil
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      ).standardizedFileURL

      if isStale {
        try? rememberAccess(to: url, key: key)
      }

      return url
    } catch {
      if removeInvalidBookmark {
        defaults.removeObject(forKey: key)
      }
      return nil
    }
  }

  private nonisolated static func syncManagedConfigFile(
    currentSource: String,
    fileURL: URL,
    lastAppliedSignature: String?
  ) throws -> ManagedConfigFileSyncOutcome {
    let fileManager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let currentSignature = ShotPasteConfigurationAutoImporter.contentSignature(for: currentSource)
    guard fileManager.fileExists(atPath: fileURL.path) else {
      try currentSource.write(to: fileURL, atomically: true, encoding: .utf8)
      return ManagedConfigFileSyncOutcome(
        result: ShotPasteConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          observedFileSignature: nil,
          exportedSettingsSignature: currentSignature
        ),
        sourceToMarkApplied: currentSource
      )
    }

    let fileSource = try String(contentsOf: fileURL, encoding: .utf8)
    let fileSignature = ShotPasteConfigurationAutoImporter.contentSignature(for: fileSource)
    if fileSource == currentSource {
      return ManagedConfigFileSyncOutcome(
        result: ShotPasteConfigurationSyncResult(
          status: .alreadyCurrent,
          fileURL: fileURL,
          observedFileSignature: fileSignature,
          exportedSettingsSignature: currentSignature
        ),
        sourceToMarkApplied: fileSource
      )
    }

    if lastAppliedSignature == fileSignature {
      try currentSource.write(to: fileURL, atomically: true, encoding: .utf8)
      return ManagedConfigFileSyncOutcome(
        result: ShotPasteConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          observedFileSignature: fileSignature,
          exportedSettingsSignature: currentSignature
        ),
        sourceToMarkApplied: currentSource
      )
    }

    return ManagedConfigFileSyncOutcome(
      result: ShotPasteConfigurationSyncResult(
        status: .needsConfirmation,
        fileURL: fileURL,
        observedFileSignature: fileSignature,
        exportedSettingsSignature: currentSignature
      ),
      sourceToMarkApplied: nil
    )
  }

  private func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private var isRunningSandboxed: Bool {
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
  }
}
