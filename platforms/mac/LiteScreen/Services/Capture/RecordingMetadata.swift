//
//  RecordingMetadata.swift
//  LiteScreen
//
//  Internal metadata for recordings that need editor-only context.
//

import CoreGraphics
import Foundation
import os.log

private let recordingMetadataLogger = Logger(subsystem: "Lite Screen", category: "RecordingMetadata")

struct RecordedMouseSample: Codable, Equatable {
  var time: TimeInterval
  var normalizedX: CGFloat
  var normalizedY: CGFloat
  var isInsideCapture: Bool

  var normalizedPoint: CGPoint {
    CGPoint(x: normalizedX, y: normalizedY)
  }
}

enum RecordingCoordinateSpace: String, Codable {
  case topLeftNormalized
}

enum RecordingAudioSourceTrackRole: String, Codable, Equatable {
  case systemAudio
  case microphone

  static func roles(capturesSystemAudio: Bool, capturesMicrophone: Bool) -> [RecordingAudioSourceTrackRole] {
    var roles: [RecordingAudioSourceTrackRole] = []
    if capturesSystemAudio {
      roles.append(.systemAudio)
    }
    if capturesMicrophone {
      roles.append(.microphone)
    }
    return roles
  }
}

struct RecordingAudioSourceTrack: Codable, Equatable {
  var trackID: Int
  var role: RecordingAudioSourceTrackRole
}

struct RecordingMetadata: Codable, Equatable {
  static let currentVersion = 5

  var version: Int
  var coordinateSpace: RecordingCoordinateSpace
  var captureSize: CGSize
  var samplesPerSecond: Int
  var mouseSamples: [RecordedMouseSample]
  var audioSourceURL: URL?
  var audioSourceTrackRoles: [RecordingAudioSourceTrackRole]
  var audioSourceTracks: [RecordingAudioSourceTrack]

  init(
    version: Int = RecordingMetadata.currentVersion,
    coordinateSpace: RecordingCoordinateSpace = .topLeftNormalized,
    captureSize: CGSize,
    samplesPerSecond: Int,
    mouseSamples: [RecordedMouseSample],
    audioSourceURL: URL? = nil,
    audioSourceTrackRoles: [RecordingAudioSourceTrackRole] = [],
    audioSourceTracks: [RecordingAudioSourceTrack] = []
  ) {
    self.version = version
    self.coordinateSpace = coordinateSpace
    self.captureSize = captureSize
    self.samplesPerSecond = samplesPerSecond
    self.mouseSamples = mouseSamples
    self.audioSourceURL = audioSourceURL
    self.audioSourceTrackRoles = audioSourceTrackRoles
    self.audioSourceTracks = audioSourceTracks
  }
}

@MainActor
enum RecordingMetadataStore {
  private struct StoreLocation {
    let entriesURL: URL
    let indexURL: URL
    let audioSourcesURL: URL
  }

  private struct MetadataIndex: Codable {
    var entries: [MetadataIndexEntry] = []
  }

  private struct MetadataIndexEntry: Codable, Equatable {
    var id: UUID
    var lastKnownPath: String
    var bookmarkData: Data
    var staleSince: Date?
  }

  private enum CleanupDisposition {
    case keep(MetadataIndexEntry)
    case delete
  }

  private static let appSupportFolderName = "Lite Screen"
  private static let capturesFolderName = "Captures"
  private static let storeFolderName = "RecordingMetadata"
  private static let entriesFolderName = "Entries"
  private static let audioSourcesFolderName = "AudioSources"
  private static let indexFileName = "index.json"
  private static let metadataFileExtension = "json"
  private static let orphanGracePeriod: TimeInterval = 24 * 60 * 60

  static func load(for videoURL: URL) -> RecordingMetadata? {
    do {
      let location = try requiredStoreLocation()
      var index = loadIndex(from: location)
      return try loadStoredMetadata(
        for: videoURL,
        location: location,
        index: &index
      )
    } catch {
      recordingMetadataLogger
        .error(
          "Failed to load recording metadata for \(videoURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      return nil
    }
  }

  static func save(_ metadata: RecordingMetadata, for videoURL: URL) throws {
    let location = try requiredStoreLocation()
    var index = loadIndex(from: location)

    let existingEntry = resolveEntry(for: videoURL, index: index)?.entry
    let entry = try makeEntry(id: existingEntry?.id ?? UUID(), for: videoURL)
    let metadataURL = metadataURL(for: entry.id, location: location)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(metadata)
    try data.write(to: metadataURL, options: .atomic)

    upsert(entry: entry, into: &index)
    try saveIndex(index, to: location)
  }

  static func storeAudioSource(from sourceURL: URL) throws -> URL {
    let location = try requiredStoreLocation()
    let fileExtension = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
    let destinationURL = location.audioSourcesURL
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)

    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  static func moveAssociation(from oldURL: URL, to newURL: URL) throws {
    let location = try requiredStoreLocation()
    var index = loadIndex(from: location)
    guard let resolved = resolveEntry(for: oldURL, index: index) else { return }

    let entry = try makeEntry(id: resolved.entry.id, for: newURL)
    index.entries[resolved.index] = entry
    try saveIndex(index, to: location)
  }

  static func delete(for videoURL: URL) throws {
    let location = try requiredStoreLocation()
    var index = loadIndex(from: location)
    try deleteStoredMetadata(for: videoURL, location: location, index: &index)
  }

  static func performOrphanCleanup(now: Date = Date()) throws {
    let location = try requiredStoreLocation()
    var index = loadIndex(from: location)
    var keptEntries: [MetadataIndexEntry] = []
    var metadataURLsToDelete: [URL] = []

    for entry in index.entries {
      let metadataURL = metadataURL(for: entry.id, location: location)

      guard FileManager.default.fileExists(atPath: metadataURL.path) else {
        metadataURLsToDelete.append(metadataURL)
        continue
      }

      switch cleanupDisposition(for: entry, now: now) {
      case .keep(let updatedEntry):
        keptEntries.append(updatedEntry)
      case .delete:
        metadataURLsToDelete.append(metadataURL)
      }
    }

    guard keptEntries != index.entries || !metadataURLsToDelete.isEmpty else { return }

    index.entries = keptEntries
    try saveIndex(index, to: location)

    for metadataURL in metadataURLsToDelete {
      deleteMetadataFileAndAudioSource(at: metadataURL, location: location)
    }
  }

  private static func requiredStoreLocation() throws -> StoreLocation {
    guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }

    let rootURL = appSupportURL
      .appendingPathComponent(appSupportFolderName, isDirectory: true)
      .appendingPathComponent(capturesFolderName, isDirectory: true)
      .appendingPathComponent(storeFolderName, isDirectory: true)
    let entriesURL = rootURL.appendingPathComponent(entriesFolderName, isDirectory: true)
    let audioSourcesURL = rootURL.appendingPathComponent(audioSourcesFolderName, isDirectory: true)
    let indexURL = rootURL.appendingPathComponent(indexFileName)

    try FileManager.default.createDirectory(
      at: entriesURL,
      withIntermediateDirectories: true,
      attributes: nil
    )
    try FileManager.default.createDirectory(
      at: audioSourcesURL,
      withIntermediateDirectories: true,
      attributes: nil
    )

    return StoreLocation(
      entriesURL: entriesURL,
      indexURL: indexURL,
      audioSourcesURL: audioSourcesURL
    )
  }

  private static func loadIndex(from location: StoreLocation) -> MetadataIndex {
    guard FileManager.default.fileExists(atPath: location.indexURL.path),
          let data = try? Data(contentsOf: location.indexURL)
    else {
      return MetadataIndex()
    }

    do {
      return try JSONDecoder().decode(MetadataIndex.self, from: data)
    } catch {
      recordingMetadataLogger
        .error(
          "Failed to decode metadata index at \(location.indexURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      return MetadataIndex()
    }
  }

  private static func saveIndex(_ index: MetadataIndex, to location: StoreLocation) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(index)
    try data.write(to: location.indexURL, options: .atomic)
  }

  private static func loadStoredMetadata(
    for videoURL: URL,
    location: StoreLocation,
    index: inout MetadataIndex
  ) throws -> RecordingMetadata? {
    guard let resolved = resolveEntry(for: videoURL, index: index) else {
      return nil
    }

    let metadataURL = metadataURL(for: resolved.entry.id, location: location)
    guard FileManager.default.fileExists(atPath: metadataURL.path) else {
      index.entries.remove(at: resolved.index)
      try saveIndex(index, to: location)
      return nil
    }

    let data = try Data(contentsOf: metadataURL)
    let metadata = try JSONDecoder().decode(RecordingMetadata.self, from: data)

    if index.entries[resolved.index] != resolved.entry {
      index.entries[resolved.index] = resolved.entry
      try saveIndex(index, to: location)
    }

    return metadata
  }

  private static func deleteStoredMetadata(
    for videoURL: URL,
    location: StoreLocation,
    index: inout MetadataIndex
  ) throws {
    guard let resolved = resolveEntry(for: videoURL, index: index) else {
      return
    }

    let metadataURL = metadataURL(for: resolved.entry.id, location: location)
    index.entries.remove(at: resolved.index)
    try saveIndex(index, to: location)

    deleteMetadataFileAndAudioSource(at: metadataURL, location: location)
  }

  private static func resolveEntry(
    for videoURL: URL,
    index: MetadataIndex
  ) -> (index: Int, entry: MetadataIndexEntry)? {
    let targetPath = normalizedPath(for: videoURL)

    if let exactIndex = index.entries.firstIndex(where: { $0.lastKnownPath == targetPath }) {
      return (exactIndex, refreshedEntry(index.entries[exactIndex], with: videoURL))
    }

    for (indexPosition, entry) in index.entries.enumerated() {
      guard let bookmarkedURL = resolveBookmarkedURL(for: entry) else { continue }
      guard normalizedPath(for: bookmarkedURL) == targetPath else { continue }
      return (indexPosition, refreshedEntry(entry, with: videoURL))
    }

    return nil
  }

  private static func upsert(entry: MetadataIndexEntry, into index: inout MetadataIndex) {
    if let existingIndex = index.entries.firstIndex(where: { $0.id == entry.id }) {
      index.entries[existingIndex] = entry
    } else {
      index.entries.append(entry)
    }
  }

  private static func makeEntry(id: UUID, for videoURL: URL) throws -> MetadataIndexEntry {
    try MetadataIndexEntry(
      id: id,
      lastKnownPath: normalizedPath(for: videoURL),
      bookmarkData: videoBookmarkData(for: videoURL),
      staleSince: nil
    )
  }

  private static func refreshedEntry(_ entry: MetadataIndexEntry, with videoURL: URL) -> MetadataIndexEntry {
    var refreshed = entry
    refreshed.lastKnownPath = normalizedPath(for: videoURL)
    refreshed.staleSince = nil

    if let bookmarkData = try? videoBookmarkData(for: videoURL) {
      refreshed.bookmarkData = bookmarkData
    }

    return refreshed
  }

  private static func videoBookmarkData(for videoURL: URL) throws -> Data {
    try SandboxFileAccessManager.shared.withScopedAccess(to: videoURL) {
      try videoURL.standardizedFileURL.bookmarkData(
        options: [.minimalBookmark],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    }
  }

  private static func resolveBookmarkedURL(for entry: MetadataIndexEntry) -> URL? {
    var isStale = false

    do {
      return try URL(
        resolvingBookmarkData: entry.bookmarkData,
        options: [.withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      .standardizedFileURL
      .resolvingSymlinksInPath()
    } catch {
      return nil
    }
  }

  private static func cleanupDisposition(
    for entry: MetadataIndexEntry,
    now: Date
  ) -> CleanupDisposition {
    if let bookmarkedURL = resolveBookmarkedURL(for: entry),
       FileManager.default.fileExists(atPath: bookmarkedURL.path) {
      return .keep(refreshedCleanupEntry(entry, resolvedURL: bookmarkedURL))
    }

    let lastKnownURL = URL(fileURLWithPath: entry.lastKnownPath)
    if FileManager.default.fileExists(atPath: lastKnownURL.path) {
      return .keep(refreshedCleanupEntry(entry, resolvedURL: lastKnownURL))
    }

    guard let staleSince = entry.staleSince else {
      var staleEntry = entry
      staleEntry.staleSince = now
      return .keep(staleEntry)
    }

    if now.timeIntervalSince(staleSince) >= orphanGracePeriod {
      return .delete
    }

    return .keep(entry)
  }

  private static func refreshedCleanupEntry(
    _ entry: MetadataIndexEntry,
    resolvedURL: URL
  ) -> MetadataIndexEntry {
    var refreshed = entry
    refreshed.lastKnownPath = normalizedPath(for: resolvedURL)
    refreshed.staleSince = nil

    if let bookmarkData = try? videoBookmarkData(for: resolvedURL) {
      refreshed.bookmarkData = bookmarkData
    }

    return refreshed
  }

  private static func normalizedPath(for videoURL: URL) -> String {
    videoURL.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private static func metadataURL(for id: UUID, location: StoreLocation) -> URL {
    location.entriesURL
      .appendingPathComponent(id.uuidString)
      .appendingPathExtension(metadataFileExtension)
  }

  private static func deleteMetadataFileAndAudioSource(at metadataURL: URL, location: StoreLocation) {
    if
      let data = try? Data(contentsOf: metadataURL),
      let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data),
      let audioSourceURL = metadata.audioSourceURL,
      isStoredAudioSourceURL(audioSourceURL, location: location),
      FileManager.default.fileExists(atPath: audioSourceURL.path) {
      try? FileManager.default.removeItem(at: audioSourceURL)
    }

    if FileManager.default.fileExists(atPath: metadataURL.path) {
      try? FileManager.default.removeItem(at: metadataURL)
    }
  }

  private static func isStoredAudioSourceURL(_ url: URL, location: StoreLocation) -> Bool {
    let sourcePath = url.standardizedFileURL.resolvingSymlinksInPath().path
    let rootPath = location.audioSourcesURL.standardizedFileURL.resolvingSymlinksInPath().path
    return sourcePath.hasPrefix(rootPath + "/")
  }
}
