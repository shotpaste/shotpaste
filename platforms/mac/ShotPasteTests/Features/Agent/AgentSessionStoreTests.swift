//
//  AgentSessionStoreTests.swift
//  ShotPasteTests
//

import CoreGraphics
import Foundation
@testable import ShotPaste
import XCTest

final class AgentSessionStoreTests: XCTestCase {
  func testStopBeforeAsyncStartStillCreatesTerminalAuditAndRejectsLateStart() async throws {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteAgentStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let store = AgentSessionStore(baseDirectoryURL: baseURL)
    let sessionID = UUID()

    try await store.endSession(
      sessionID,
      finalEvent: AgentAuditEvent(kind: .stopped, message: "Stopped immediately")
    )

    let eventsURL = await store.eventsFileURL(sessionID)
    let events = try String(contentsOf: eventsURL, encoding: .utf8)
    XCTAssertTrue(events.contains("\"kind\":\"stopped\""))
    do {
      try await store.startSession(
        sessionID,
        initialEvent: AgentAuditEvent(kind: .sessionStarted, message: "Late start")
      )
      XCTFail("Expected a late session start to be rejected")
    } catch let error as AgentSessionStoreError {
      XCTAssertEqual(error, .sessionEnded)
    }
  }

  func testScreenshotsAreNotRetainedByDefault() async throws {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteAgentStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentSessionStoreTests-\(UUID().uuidString)"))
    let store = AgentSessionStore(baseDirectoryURL: baseURL)
    let sessionID = UUID()
    try await store.startSession(
      sessionID,
      initialEvent: AgentAuditEvent(kind: .sessionStarted, message: "Test task")
    )

    let retainedURL = try await store.retainScreenshotIfEnabled(
      try makeImage(),
      observationID: UUID(),
      sessionID: sessionID,
      defaults: defaults
    )

    XCTAssertNil(retainedURL)
    let screenshotsURL = await store.sessionDirectoryURL(sessionID)
      .appendingPathComponent("Screenshots", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: screenshotsURL.path))
    let eventsURL = await store.eventsFileURL(sessionID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventsURL.path))
  }

  func testExplicitRetentionWritesOnlyToSeparateAgentSessionDirectory() async throws {
    let baseURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteAgentStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentSessionStoreTests-\(UUID().uuidString)"))
    defaults.set(true, forKey: PreferencesKeys.agentScreenshotRetentionEnabled)
    let store = AgentSessionStore(baseDirectoryURL: baseURL)
    let sessionID = UUID()
    try await store.startSession(
      sessionID,
      initialEvent: AgentAuditEvent(kind: .sessionStarted, message: "Test task")
    )

    let candidateURL = try await store.retainScreenshotIfEnabled(
      try makeImage(),
      observationID: UUID(),
      sessionID: sessionID,
      defaults: defaults
    )
    let retainedURL = try XCTUnwrap(candidateURL)

    XCTAssertTrue(retainedURL.path.hasPrefix(baseURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
  }

  private func makeImage() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try XCTUnwrap(context.makeImage())
  }
}
