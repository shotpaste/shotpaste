//
//  ShotPasteConfigurationSyncCoordinator.swift
//  ShotPaste
//
//  Debounced background sync from live app settings into config.toml.
//

import Combine
import Foundation

@MainActor
final class ShotPasteConfigurationSyncCoordinator: ObservableObject {
  enum Status: Equatable {
    case idle
    case scheduled
    case syncing
    case upToDate(Date)
    case synced(Date)
    case needsPermission
    case conflict(URL)
    case failed(String)
  }

  enum Reason: String {
    case appLaunch
    case appTerminate
    case defaultsChanged
    case explicitChange
    case manual
    case openConfig
  }

  static let shared = ShotPasteConfigurationSyncCoordinator()

  @Published private(set) var status: Status = .idle

  private let notificationCenter: NotificationCenter
  private let debounceInterval: TimeInterval
  private let syncManagedConfigIfSafe: @MainActor () throws -> ShotPasteConfigurationSyncResult
  private let syncManagedConfigIfSafeInBackground: @MainActor () async throws -> ShotPasteConfigurationSyncResult
  private let syncCurrentSettings: @MainActor (URL?, String?) throws -> URL
  private let currentSettingsSignature: @MainActor () -> String
  private var defaultsObserver: NSObjectProtocol?
  private var debounceTask: Task<Void, Never>?
  private var isStarted = false
  private var activeSyncCount = 0
  private var needsFollowUpSync = false
  private var lastAttemptedSettingsSignature: String?
  private var nextSyncSequence = 0
  private var latestStatusSequence = 0

  init(
    service: ShotPasteConfigurationService,
    notificationCenter: NotificationCenter = .default,
    debounceInterval: TimeInterval = 1.2
  ) {
    self.notificationCenter = notificationCenter
    self.debounceInterval = debounceInterval
    syncManagedConfigIfSafe = {
      try service.syncManagedConfigIfSafe()
    }
    syncManagedConfigIfSafeInBackground = {
      try await service.syncManagedConfigIfSafeInBackground()
    }
    syncCurrentSettings = { url, expectedFileSignature in
      try service.syncManagedConfigToCurrentSettingsIfUnchanged(
        at: url,
        expectedFileSignature: expectedFileSignature
      )
    }
    currentSettingsSignature = {
      ShotPasteConfigurationAutoImporter.contentSignature(for: service.exportTOML())
    }
  }

  convenience init(
    notificationCenter: NotificationCenter = .default,
    debounceInterval: TimeInterval = 1.2
  ) {
    self.init(
      service: ShotPasteConfigurationService.shared,
      notificationCenter: notificationCenter,
      debounceInterval: debounceInterval
    )
  }

  init(
    notificationCenter: NotificationCenter = .default,
    debounceInterval: TimeInterval,
    syncManagedConfigIfSafe: @escaping @MainActor () throws -> ShotPasteConfigurationSyncResult,
    syncManagedConfigIfSafeInBackground: (@MainActor () async throws -> ShotPasteConfigurationSyncResult)? = nil,
    syncCurrentSettingsAfterConfirmation: @escaping @MainActor (URL?, String?) throws -> URL,
    currentSettingsSignature: @escaping @MainActor () -> String = { "" }
  ) {
    self.notificationCenter = notificationCenter
    self.debounceInterval = debounceInterval
    self.syncManagedConfigIfSafe = syncManagedConfigIfSafe
    if let syncManagedConfigIfSafeInBackground {
      self.syncManagedConfigIfSafeInBackground = syncManagedConfigIfSafeInBackground
    } else {
      self.syncManagedConfigIfSafeInBackground = {
        try syncManagedConfigIfSafe()
      }
    }
    syncCurrentSettings = syncCurrentSettingsAfterConfirmation
    self.currentSettingsSignature = currentSettingsSignature
  }

  /// `stop()` owns all observer and task cleanup, so destruction has no
  /// actor-bound work once callers have stopped the coordinator.
  nonisolated deinit {}

  func start() {
    guard !isStarted else { return }
    isStarted = true
    defaultsObserver = notificationCenter.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { [weak self] in
        await self?.scheduleSyncFromDefaultsChange()
      }
    }
  }

  func stop() {
    debounceTask?.cancel()
    debounceTask = nil
    if let defaultsObserver {
      notificationCenter.removeObserver(defaultsObserver)
    }
    defaultsObserver = nil
    isStarted = false
    activeSyncCount = 0
    needsFollowUpSync = false
    nextSyncSequence += 1
    latestStatusSequence = nextSyncSequence
    status = .idle
  }

  func scheduleSync(reason: Reason) {
    guard isStarted else { return }

    if isSyncing {
      needsFollowUpSync = true
      return
    }

    debounceTask?.cancel()
    status = .scheduled
    let delay = UInt64(debounceInterval * 1_000_000_000)
    debounceTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: delay)
      guard let self, !Task.isCancelled else { return }
      debounceTask = nil
      // The unchanged-signature skip runs here — once after edits settle, never
      // per notification. The signature is a full TOML export + SHA256, so
      // computing it per UserDefaults change (e.g. every slider tick) stalls
      // the main thread (see issue #335).
      if reason == .defaultsChanged,
         let lastAttemptedSettingsSignature,
         currentSettingsSignature() == lastAttemptedSettingsSignature {
        if status == .scheduled {
          status = .idle
        }
        return
      }
      do {
        try await syncNowInBackground(reason: reason)
      } catch {
        DiagnosticLogger.shared.logError(
          .preferences,
          error,
          "TOML configuration background sync failed"
        )
      }
    }
  }

  @discardableResult
  func flushPendingSync(reason: Reason) throws -> ShotPasteConfigurationSyncResult? {
    guard debounceTask != nil || isSyncing || needsFollowUpSync else { return nil }
    return try syncNow(reason: reason)
  }

  func cancelPendingSync() {
    debounceTask?.cancel()
    debounceTask = nil
    if status == .scheduled, !isSyncing {
      status = .idle
    }
  }

  @discardableResult
  func syncNow(reason: Reason = .manual) throws -> ShotPasteConfigurationSyncResult {
    cancelPendingSync()
    let sequence = beginSync()
    var syncResult: ShotPasteConfigurationSyncResult?
    defer {
      finishSyncing(after: syncResult, sequence: sequence)
    }

    do {
      let result = try syncManagedConfigIfSafe()
      syncResult = result
      updateStatus(for: result, sequence: sequence)
      log(result, reason: reason)
      return result
    } catch {
      updateFailureStatus(error, sequence: sequence)
      throw error
    }
  }

  @discardableResult
  func syncNowInBackground(reason: Reason = .manual) async throws -> ShotPasteConfigurationSyncResult {
    cancelPendingSync()
    let sequence = beginSync()

    do {
      let result = try await syncManagedConfigIfSafeInBackground()
      updateStatus(for: result, sequence: sequence)
      log(result, reason: reason)
      finishSyncing(after: result, sequence: sequence)
      return result
    } catch {
      updateFailureStatus(error, sequence: sequence)
      finishSyncing(after: nil, sequence: sequence)
      throw error
    }
  }

  @discardableResult
  func syncCurrentSettingsAfterConfirmation(
    at url: URL? = nil,
    expectedFileSignature: String? = nil
  ) throws -> URL {
    cancelPendingSync()
    let sequence = beginSync()
    var syncResult: ShotPasteConfigurationSyncResult?
    defer {
      finishSyncing(after: syncResult, sequence: sequence)
    }

    do {
      let fileURL = try syncCurrentSettings(url, expectedFileSignature)
      let settingsSignature = currentSettingsSignature()
      let result = ShotPasteConfigurationSyncResult(
        status: .synced,
        fileURL: fileURL,
        exportedSettingsSignature: settingsSignature
      )
      syncResult = result
      lastAttemptedSettingsSignature = settingsSignature
      updateStatus(for: result, sequence: sequence)
      DiagnosticLogger.shared.log(
        .info,
        .preferences,
        "TOML configuration sync confirmed",
        context: ["file": fileURL.path]
      )
      return fileURL
    } catch {
      updateFailureStatus(error, sequence: sequence)
      throw error
    }
  }

  private var isSyncing: Bool {
    activeSyncCount > 0
  }

  private func beginSync() -> Int {
    activeSyncCount += 1
    nextSyncSequence += 1
    status = .syncing
    return nextSyncSequence
  }

  private func updateStatus(for result: ShotPasteConfigurationSyncResult, sequence: Int) {
    guard sequence >= latestStatusSequence else { return }
    latestStatusSequence = sequence
    lastAttemptedSettingsSignature = result.exportedSettingsSignature
    let now = Date()
    switch result.status {
    case .alreadyCurrent:
      status = .upToDate(now)
    case .synced:
      status = .synced(now)
    case .needsConfirmation:
      status = .conflict(result.fileURL)
    case .permissionRequired:
      status = .needsPermission
    }
  }

  private func scheduleSyncFromDefaultsChange() {
    scheduleSync(reason: .defaultsChanged)
  }

  private func updateFailureStatus(_ error: Error, sequence: Int) {
    guard sequence >= latestStatusSequence else { return }
    latestStatusSequence = sequence
    status = .failed(error.localizedDescription)
  }

  private func finishSyncing(after result: ShotPasteConfigurationSyncResult?, sequence _: Int) {
    activeSyncCount = max(0, activeSyncCount - 1)
    guard activeSyncCount == 0, needsFollowUpSync else { return }

    let syncedSignature = result?.exportedSettingsSignature
    let needsSync = syncedSignature == nil || currentSettingsSignature() != syncedSignature
    needsFollowUpSync = false
    if needsSync {
      scheduleSync(reason: .defaultsChanged)
    }
  }

  private func log(_ result: ShotPasteConfigurationSyncResult, reason: Reason) {
    DiagnosticLogger.shared.log(
      .debug,
      .preferences,
      "TOML configuration sync checked",
      context: [
        "reason": reason.rawValue,
        "status": "\(result.status)",
        "file": result.fileURL.path,
      ]
    )
  }
}
