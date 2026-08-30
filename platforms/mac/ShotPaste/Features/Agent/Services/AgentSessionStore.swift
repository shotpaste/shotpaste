//
//  AgentSessionStore.swift
//  ShotPaste
//
//  Separate Agent Mode audit storage. Screenshots are never persisted unless
//  the user explicitly enables retention.
//

import AppKit
import Foundation

actor AgentSessionStore {
  static let shared = AgentSessionStore()

  private let baseDirectoryURL: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private var activeSessions: Set<UUID> = []
  private var endedSessions: Set<UUID> = []

  init(
    baseDirectoryURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.baseDirectoryURL = baseDirectoryURL
      ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ShotPaste", isDirectory: true)
      .appendingPathComponent("AgentSessions", isDirectory: true)
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
  }

  func startSession(_ sessionID: UUID, initialEvent: AgentAuditEvent) throws {
    guard !endedSessions.contains(sessionID) else {
      throw AgentSessionStoreError.sessionEnded
    }
    let directory = sessionDirectoryURL(sessionID)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    activeSessions.insert(sessionID)
    try append(initialEvent, sessionID: sessionID)
  }

  func append(_ event: AgentAuditEvent, sessionID: UUID) throws {
    guard !endedSessions.contains(sessionID) else {
      throw AgentSessionStoreError.sessionEnded
    }
    guard activeSessions.contains(sessionID) || fileManager.fileExists(atPath: sessionDirectoryURL(sessionID).path)
    else {
      throw AgentSessionStoreError.sessionNotStarted
    }

    let data = try encoder.encode(event)
    var line = data
    line.append(0x0A)
    let eventsURL = eventsFileURL(sessionID)
    if !fileManager.fileExists(atPath: eventsURL.path) {
      guard fileManager.createFile(atPath: eventsURL.path, contents: line) else {
        throw AgentSessionStoreError.writeFailed
      }
      return
    }

    let handle = try FileHandle(forWritingTo: eventsURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  func retainScreenshotIfEnabled(
    _ image: CGImage,
    observationID: UUID,
    sessionID: UUID,
    defaults: UserDefaults = .standard
  ) throws -> URL? {
    guard defaults.bool(forKey: PreferencesKeys.agentScreenshotRetentionEnabled) else {
      return nil
    }
    guard activeSessions.contains(sessionID) else {
      throw AgentSessionStoreError.sessionNotStarted
    }

    let screenshotsDirectory = sessionDirectoryURL(sessionID)
      .appendingPathComponent("Screenshots", isDirectory: true)
    try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
    let url = screenshotsDirectory.appendingPathComponent("\(observationID.uuidString).png")
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw AgentSessionStoreError.imageEncodingFailed
    }
    try data.write(to: url, options: .atomic)
    return url
  }

  func endSession(_ sessionID: UUID, finalEvent: AgentAuditEvent) throws {
    guard !endedSessions.contains(sessionID) else { return }
    if !fileManager.fileExists(atPath: sessionDirectoryURL(sessionID).path) {
      try fileManager.createDirectory(
        at: sessionDirectoryURL(sessionID),
        withIntermediateDirectories: true
      )
      activeSessions.insert(sessionID)
    }
    try append(finalEvent, sessionID: sessionID)
    activeSessions.remove(sessionID)
    endedSessions.insert(sessionID)
  }

  func sessionDirectoryURL(_ sessionID: UUID) -> URL {
    baseDirectoryURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
  }

  func eventsFileURL(_ sessionID: UUID) -> URL {
    sessionDirectoryURL(sessionID).appendingPathComponent("events.jsonl")
  }
}

enum AgentSessionStoreError: LocalizedError, Equatable {
  case sessionNotStarted
  case sessionEnded
  case writeFailed
  case imageEncodingFailed

  var errorDescription: String? {
    switch self {
    case .sessionNotStarted:
      "The Agent session audit store has not been started."
    case .sessionEnded:
      "The Agent session audit store has already ended."
    case .writeFailed:
      "The Agent session audit event could not be written."
    case .imageEncodingFailed:
      "The Agent observation screenshot could not be encoded."
    }
  }
}
