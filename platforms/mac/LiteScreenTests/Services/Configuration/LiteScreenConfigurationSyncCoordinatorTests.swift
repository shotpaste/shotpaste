//
//  LiteScreenConfigurationSyncCoordinatorTests.swift
//  LiteScreenTests
//
//  Tests for debounced config.toml background sync orchestration.
//

@testable import LiteScreen
import XCTest

@MainActor
final class LiteScreenConfigurationSyncCoordinatorTests: XCTestCase {
  func testScheduleSyncDebouncesRepeatedRequests() async throws {
    let fileURL = temporaryConfigURL()
    let notificationCenter = NotificationCenter()
    var syncCount = 0
    let coordinator = makeCoordinator(
      notificationCenter: notificationCenter,
      debounceInterval: 0.01,
      sync: {
        syncCount += 1
        return LiteScreenConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          exportedSettingsSignature: "synced"
        )
      }
    )
    defer { coordinator.stop() }

    coordinator.start()
    coordinator.scheduleSync(reason: .defaultsChanged)
    coordinator.scheduleSync(reason: .defaultsChanged)
    coordinator.scheduleSync(reason: .defaultsChanged)

    try await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(syncCount, 1)
    guard case .synced = coordinator.status else {
      XCTFail("Expected synced status")
      return
    }
  }

  func testFlushPendingSyncRunsImmediatelyAndCancelsDebounce() async throws {
    let fileURL = temporaryConfigURL()
    var syncCount = 0
    let coordinator = makeCoordinator(
      debounceInterval: 0.5,
      sync: {
        syncCount += 1
        return LiteScreenConfigurationSyncResult(
          status: .alreadyCurrent,
          fileURL: fileURL,
          exportedSettingsSignature: "current"
        )
      }
    )
    defer { coordinator.stop() }

    coordinator.start()
    coordinator.scheduleSync(reason: .defaultsChanged)
    try coordinator.flushPendingSync(reason: .openConfig)
    try await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(syncCount, 1)
    guard case .upToDate = coordinator.status else {
      XCTFail("Expected up-to-date status")
      return
    }
  }

  func testSyncNowReportsConflictWithoutConfirmedOverwrite() throws {
    let fileURL = temporaryConfigURL()
    var syncCount = 0
    var overwriteCount = 0
    let coordinator = makeCoordinator(
      sync: {
        syncCount += 1
        return LiteScreenConfigurationSyncResult(status: .needsConfirmation, fileURL: fileURL)
      },
      confirmedSync: { _, _ in
        overwriteCount += 1
        return fileURL
      }
    )
    defer { coordinator.stop() }

    coordinator.start()
    let result = try coordinator.syncNow(reason: .manual)

    XCTAssertEqual(syncCount, 1)
    XCTAssertEqual(overwriteCount, 0)
    XCTAssertEqual(result.status, .needsConfirmation)
    XCTAssertEqual(coordinator.status, .conflict(fileURL))
  }

  func testConfirmedSyncUsesOverwriteClosure() throws {
    let fileURL = temporaryConfigURL()
    var overwriteURL: URL?
    var overwriteSignature: String?
    let coordinator = makeCoordinator(
      confirmedSync: { url, expectedSignature in
        overwriteURL = url
        overwriteSignature = expectedSignature
        return fileURL
      }
    )
    defer { coordinator.stop() }

    coordinator.start()
    let returnedURL = try coordinator.syncCurrentSettingsAfterConfirmation(
      at: fileURL,
      expectedFileSignature: "approved"
    )

    XCTAssertEqual(returnedURL, fileURL)
    XCTAssertEqual(overwriteURL, fileURL)
    XCTAssertEqual(overwriteSignature, "approved")
    guard case .synced = coordinator.status else {
      XCTFail("Expected synced status")
      return
    }
  }

  func testPermissionRequiredStatusIsExposed() throws {
    let fileURL = temporaryConfigURL()
    let coordinator = makeCoordinator(
      sync: {
        LiteScreenConfigurationSyncResult(status: .permissionRequired, fileURL: fileURL)
      }
    )
    defer { coordinator.stop() }

    coordinator.start()
    let result = try coordinator.syncNow(reason: .manual)

    XCTAssertEqual(result.status, .permissionRequired)
    XCTAssertEqual(coordinator.status, .needsPermission)
  }

  func testDefaultsChangeWithUnchangedExportSignatureDoesNotScheduleFollowUpSync() async throws {
    let fileURL = temporaryConfigURL()
    let notificationCenter = NotificationCenter()
    var syncCount = 0
    let coordinator = makeCoordinator(
      notificationCenter: notificationCenter,
      debounceInterval: 0.01,
      sync: {
        syncCount += 1
        return LiteScreenConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          exportedSettingsSignature: "same-settings"
        )
      },
      currentSettingsSignature: { "same-settings" }
    )
    defer { coordinator.stop() }

    coordinator.start()
    try coordinator.syncNow(reason: .manual)
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: nil)
    try await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(syncCount, 1)
  }

  func testDefaultsChangeSignatureIsComputedOnceAfterDebounceNotPerRequest() async throws {
    let fileURL = temporaryConfigURL()
    var signatureCount = 0
    let coordinator = makeCoordinator(
      debounceInterval: 0.05,
      sync: {
        LiteScreenConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          exportedSettingsSignature: "old"
        )
      },
      currentSettingsSignature: {
        signatureCount += 1
        return "new"
      }
    )
    defer { coordinator.stop() }

    coordinator.start()
    try coordinator.syncNow(reason: .manual)
    XCTAssertEqual(signatureCount, 0)

    coordinator.scheduleSync(reason: .defaultsChanged)
    coordinator.scheduleSync(reason: .defaultsChanged)
    coordinator.scheduleSync(reason: .defaultsChanged)
    XCTAssertEqual(signatureCount, 0)

    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(signatureCount, 1)
  }

  func testManualSyncStatusWinsOverOlderInFlightBackgroundSync() async throws {
    let fileURL = temporaryConfigURL()
    let backgroundStarted = expectation(description: "background sync started")
    var resumeBackground: CheckedContinuation<Void, Never>?
    var manualSyncCount = 0
    let coordinator = makeCoordinator(
      sync: {
        manualSyncCount += 1
        return LiteScreenConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          exportedSettingsSignature: "manual"
        )
      },
      backgroundSync: {
        backgroundStarted.fulfill()
        await withCheckedContinuation { continuation in
          resumeBackground = continuation
        }
        return LiteScreenConfigurationSyncResult(
          status: .needsConfirmation,
          fileURL: fileURL,
          exportedSettingsSignature: "background"
        )
      },
      currentSettingsSignature: { "manual" }
    )
    defer { coordinator.stop() }

    coordinator.start()
    let backgroundTask = Task { @MainActor in
      try await coordinator.syncNowInBackground(reason: .defaultsChanged)
    }
    await fulfillment(of: [backgroundStarted], timeout: 1.0)

    let result = try coordinator.syncNow(reason: .openConfig)
    XCTAssertEqual(result.status, .synced)
    XCTAssertEqual(manualSyncCount, 1)

    resumeBackground?.resume()
    _ = try await backgroundTask.value

    guard case .synced = coordinator.status else {
      XCTFail("Expected newer manual sync status to remain visible")
      return
    }
  }

  func testFlushPendingSyncRunsWhenBackgroundSyncIsInFlight() async throws {
    let fileURL = temporaryConfigURL()
    let backgroundStarted = expectation(description: "background sync started")
    var resumeBackground: CheckedContinuation<Void, Never>?
    var flushSyncCount = 0
    let coordinator = makeCoordinator(
      sync: {
        flushSyncCount += 1
        return LiteScreenConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          exportedSettingsSignature: "flush"
        )
      },
      backgroundSync: {
        backgroundStarted.fulfill()
        await withCheckedContinuation { continuation in
          resumeBackground = continuation
        }
        return LiteScreenConfigurationSyncResult(
          status: .synced,
          fileURL: fileURL,
          exportedSettingsSignature: "background"
        )
      },
      currentSettingsSignature: { "flush" }
    )
    defer { coordinator.stop() }

    coordinator.start()
    let backgroundTask = Task { @MainActor in
      try await coordinator.syncNowInBackground(reason: .defaultsChanged)
    }
    await fulfillment(of: [backgroundStarted], timeout: 1.0)

    let result = try coordinator.flushPendingSync(reason: .appTerminate)
    XCTAssertEqual(result?.status, .synced)
    XCTAssertEqual(flushSyncCount, 1)

    resumeBackground?.resume()
    _ = try await backgroundTask.value
  }

  private func makeCoordinator(
    notificationCenter: NotificationCenter = NotificationCenter(),
    debounceInterval: TimeInterval = 0.01,
    sync: @escaping @MainActor () throws -> LiteScreenConfigurationSyncResult = {
      LiteScreenConfigurationSyncResult(status: .alreadyCurrent, fileURL: URL(fileURLWithPath: "/tmp/config.toml"))
    },
    backgroundSync: (@MainActor () async throws -> LiteScreenConfigurationSyncResult)? = nil,
    confirmedSync: @escaping @MainActor (URL?, String?) throws -> URL = { url, _ in
      url ?? URL(fileURLWithPath: "/tmp/config.toml")
    },
    currentSettingsSignature: @escaping @MainActor () -> String = { "" }
  ) -> LiteScreenConfigurationSyncCoordinator {
    LiteScreenConfigurationSyncCoordinator(
      notificationCenter: notificationCenter,
      debounceInterval: debounceInterval,
      syncManagedConfigIfSafe: sync,
      syncManagedConfigIfSafeInBackground: backgroundSync,
      syncCurrentSettingsAfterConfirmation: confirmedSync,
      currentSettingsSignature: currentSettingsSignature
    )
  }

  private func temporaryConfigURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("litescreen-config-sync-\(UUID().uuidString).toml")
  }
}
