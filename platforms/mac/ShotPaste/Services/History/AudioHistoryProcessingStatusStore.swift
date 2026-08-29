//
//  AudioHistoryProcessingStatusStore.swift
//  ShotPaste
//
//  Metadata-only bridge from a persisted history UUID to the audio processing
//  sidecar. Transcript text, media URLs, and prompts are deliberately absent.
//

import Foundation

nonisolated final class AudioHistoryProcessingStatusStore: @unchecked Sendable {
  static let didChangeNotification = Notification.Name(
    "ShotPaste.AudioHistoryProcessingStatusDidChange"
  )
  struct Entry: Codable, Equatable, Sendable {
    let historyRecordID: UUID
    let sessionID: UUID
    let taskID: UUID
    var stage: String
    var updatedAt: Date
    var clipboardCompleted: Bool = false
    var quickAccessCompleted: Bool = false

    private enum CodingKeys: String, CodingKey {
      case historyRecordID, sessionID, taskID, stage, updatedAt
      case clipboardCompleted, quickAccessCompleted
    }

    init(
      historyRecordID: UUID,
      sessionID: UUID,
      taskID: UUID,
      stage: String,
      updatedAt: Date,
      clipboardCompleted: Bool = false,
      quickAccessCompleted: Bool = false
    ) {
      self.historyRecordID = historyRecordID
      self.sessionID = sessionID
      self.taskID = taskID
      self.stage = stage
      self.updatedAt = updatedAt
      self.clipboardCompleted = clipboardCompleted
      self.quickAccessCompleted = quickAccessCompleted
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        historyRecordID: try container.decode(UUID.self, forKey: .historyRecordID),
        sessionID: try container.decode(UUID.self, forKey: .sessionID),
        taskID: try container.decode(UUID.self, forKey: .taskID),
        stage: try container.decode(String.self, forKey: .stage),
        updatedAt: try container.decode(Date.self, forKey: .updatedAt),
        clipboardCompleted: try container.decodeIfPresent(Bool.self, forKey: .clipboardCompleted) ?? false,
        quickAccessCompleted: try container.decodeIfPresent(Bool.self, forKey: .quickAccessCompleted) ?? false
      )
    }
  }

  struct PostActionState: Equatable, Sendable {
    let clipboardCompleted: Bool
    let quickAccessCompleted: Bool
  }

  static let shared = AudioHistoryProcessingStatusStore()

  private let indexURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    indexURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    let defaultDirectory = AppDataLocations.audioAdapterSessionsDirectory
      ?? fileManager.temporaryDirectory.appendingPathComponent(
        "ShotPaste-AudioAdapter-Sessions",
        isDirectory: true
      )
    self.indexURL = (indexURL ?? defaultDirectory.appendingPathComponent(
      "history-processing-index.json",
      isDirectory: false
    )).standardizedFileURL
    self.fileManager = fileManager

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func associate(
    historyRecordID: UUID,
    sessionID: UUID,
    taskID: UUID,
    stage: String = "saving",
    at date: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }
    var entries = loadEntriesUnlocked()
    let existing = entries[historyRecordID.uuidString]
    entries[historyRecordID.uuidString] = Entry(
      historyRecordID: historyRecordID,
      sessionID: sessionID,
      taskID: taskID,
      stage: stage,
      updatedAt: date,
      clipboardCompleted: existing?.clipboardCompleted ?? false,
      quickAccessCompleted: existing?.quickAccessCompleted ?? false
    )
    persistEntriesUnlocked(entries)
  }

  /// Creates the metadata-only handoff before clipboard/Quick Access work so
  /// a recovery retry can identify the same history row.
  func preparePostCapture(historyRecordID: UUID, sessionID: UUID, at date: Date = Date()) {
    lock.lock()
    defer { lock.unlock() }
    var entries = loadEntriesUnlocked()
    let existing = entries[historyRecordID.uuidString]
    entries[historyRecordID.uuidString] = Entry(
      historyRecordID: historyRecordID,
      sessionID: sessionID,
      taskID: existing?.taskID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
      stage: existing?.stage ?? "saving",
      updatedAt: date,
      clipboardCompleted: existing?.clipboardCompleted ?? false,
      quickAccessCompleted: existing?.quickAccessCompleted ?? false
    )
    persistEntriesUnlocked(entries)
  }

  func postActionState(for historyRecordID: UUID) -> PostActionState {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = loadEntriesUnlocked()[historyRecordID.uuidString] else {
      return PostActionState(clipboardCompleted: false, quickAccessCompleted: false)
    }
    return PostActionState(
      clipboardCompleted: entry.clipboardCompleted,
      quickAccessCompleted: entry.quickAccessCompleted
    )
  }

  func markPostAction(
    historyRecordID: UUID,
    clipboardCompleted: Bool? = nil,
    quickAccessCompleted: Bool? = nil,
    at date: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }
    var entries = loadEntriesUnlocked()
    guard var entry = entries[historyRecordID.uuidString] else { return }
    if let clipboardCompleted { entry.clipboardCompleted = clipboardCompleted }
    if let quickAccessCompleted { entry.quickAccessCompleted = quickAccessCompleted }
    entry.updatedAt = date
    entries[historyRecordID.uuidString] = entry
    persistEntriesUnlocked(entries)
  }

  func update(
    sessionID: UUID,
    taskID: UUID?,
    stage: String,
    at date: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }
    var entries = loadEntriesUnlocked()
    var changed = false
    for key in entries.keys {
      guard var entry = entries[key], entry.sessionID == sessionID else { continue }
      if let taskID, entry.taskID != taskID { continue }
      guard entry.stage != stage else { continue }
      entry.stage = stage
      entry.updatedAt = date
      entries[key] = entry
      changed = true
    }
    if changed { persistEntriesUnlocked(entries) }
  }

  func status(for historyRecordID: UUID) -> CaptureHistoryAudioProcessingStatus {
    lock.lock()
    defer { lock.unlock() }
    var entries = loadEntriesUnlocked()
    if entries[historyRecordID.uuidString] == nil,
       let rebuilt = rebuildEntryUnlocked(for: historyRecordID) {
      entries[historyRecordID.uuidString] = rebuilt
      persistEntriesUnlocked(entries)
    }
    guard let entry = entries[historyRecordID.uuidString] else {
      return .notStarted
    }
    switch entry.stage {
    case "saving": return .saving
    case "transcribing": return .transcribing
    case "polishing": return .polishing
    case "organizing": return .organizing
    case "waitingForModel": return .waitingForModel
    case "completed": return .complete
    case "failed", "cancelled": return .failed
    default: return .notStarted
    }
  }

  func entry(for historyRecordID: UUID) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    var entries = loadEntriesUnlocked()
    if entries[historyRecordID.uuidString] == nil,
       let rebuilt = rebuildEntryUnlocked(for: historyRecordID) {
      entries[historyRecordID.uuidString] = rebuilt
      persistEntriesUnlocked(entries)
    }
    return entries[historyRecordID.uuidString]
  }

  /// Rebuilds only UUID/stage metadata from a session manifest and processing
  /// history sidecar when the advisory index is missing or corrupt. No prompt,
  /// transcript, or media URL is read into the history model.
  private func rebuildEntryUnlocked(for historyRecordID: UUID) -> Entry? {
    let root = indexURL.deletingLastPathComponent()
    guard let directories = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for directory in directories {
      guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
            values.isDirectory == true,
            let sessionID = UUID(uuidString: directory.lastPathComponent),
            let manifestData = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            let manifestObject = try? decoder.decode(AudioAdapterSessionManifest.self, from: manifestData),
            manifestObject.historyRecordReference == historyRecordID else { continue }
      let sidecarURL = directory
        .appendingPathComponent(AudioProcessingTaskStore.processingDirectoryName)
        .appendingPathComponent(AudioProcessingTaskStore.historyFileName)
      if let sidecarData = try? Data(contentsOf: sidecarURL),
         let history = try? decoder.decode(AudioProcessingHistoryRecord.self, from: sidecarData) {
        return Entry(
          historyRecordID: historyRecordID,
          sessionID: sessionID,
          taskID: history.taskID,
          stage: history.stage.rawValue,
          updatedAt: history.updatedAt
        )
      }
      return Entry(
        historyRecordID: historyRecordID,
        sessionID: sessionID,
        taskID: manifestObject.transcriptionTaskReference ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        stage: manifestObject.stage == .completed ? "completed" : "saving",
        updatedAt: manifestObject.updatedAt
      )
    }
    return nil
  }

  private func loadEntriesUnlocked() -> [String: Entry] {
    guard let data = try? Data(contentsOf: indexURL),
          let entries = try? decoder.decode([String: Entry].self, from: data) else {
      return [:]
    }
    return entries
  }

  private func persistEntriesUnlocked(_ entries: [String: Entry]) {
    do {
      try fileManager.createDirectory(
        at: indexURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try encoder.encode(entries)
      try data.write(to: indexURL, options: [.atomic])
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
      }
    } catch {
      // Status is advisory UI metadata. A failed index write must never alter
      // capture/task gates or surface transcript content.
    }
  }
}
