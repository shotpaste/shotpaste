//
//  RecordingMetadataStoreTests.swift
//  ShotPasteTests
//
//  Tests for recording metadata persistence.
//

import AVFoundation
import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class RecordingMetadataStoreTests: XCTestCase {
  private var tempDirectory: URL!
  private var videoURLs: [URL] = []

  override func setUp() async throws {
    try await super.setUp()
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShotPasteTests_RecordingMetadata_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    for url in videoURLs {
      try? RecordingMetadataStore.delete(for: url)
    }
    videoURLs.removeAll()
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    try await super.tearDown()
  }

  func testRecordingMetadata_currentVersionRoundTripsThroughCodable() throws {
    let metadata = makeCurrentMetadata()
    let data = try JSONEncoder().encode(metadata)
    let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: data)

    XCTAssertEqual(decoded, metadata)
    XCTAssertEqual(decoded.version, RecordingMetadata.currentVersion)
    XCTAssertEqual(decoded.coordinateSpace, .topLeftNormalized)
  }

  func testRecordingAudioSourceTrackRolesFollowWriterOrder() {
    XCTAssertEqual(
      RecordingAudioSourceTrackRole.roles(capturesSystemAudio: true, capturesMicrophone: true),
      [.systemAudio, .microphone]
    )
    XCTAssertEqual(
      RecordingAudioSourceTrackRole.roles(capturesSystemAudio: true, capturesMicrophone: false),
      [.systemAudio]
    )
    XCTAssertEqual(
      RecordingAudioSourceTrackRole.roles(capturesSystemAudio: false, capturesMicrophone: true),
      [.microphone]
    )
  }

  func testRecordingMetadataStore_saveLoadRoundTripsCurrentMetadata() throws {
    let videoURL = try makeVideoFile(named: "roundtrip.mov")
    let metadata = makeCurrentMetadata()

    try RecordingMetadataStore.save(metadata, for: videoURL)
    let loaded = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))

    XCTAssertEqual(loaded, metadata)
  }

  func testRecordingMetadataStore_deleteRemovesMetadata() throws {
    let videoURL = try makeVideoFile(named: "delete.mov")
    let metadata = makeCurrentMetadata()

    try RecordingMetadataStore.save(metadata, for: videoURL)
    XCTAssertNotNil(RecordingMetadataStore.load(for: videoURL))

    try RecordingMetadataStore.delete(for: videoURL)
    XCTAssertNil(RecordingMetadataStore.load(for: videoURL))
  }

  func testRecordingMetadataStore_storeAudioSourceAndDeleteRemovesSidecar() throws {
    let videoURL = try makeVideoFile(named: "audio-source.mov")
    let sourceURL = tempDirectory.appendingPathComponent("multitrack-source.mov")
    try Data("multitrack".utf8).write(to: sourceURL)

    let storedSourceURL = try RecordingMetadataStore.storeAudioSource(from: sourceURL)
    var metadata = makeCurrentMetadata()
    metadata.audioSourceURL = storedSourceURL
    metadata.audioSourceTrackRoles = [.systemAudio, .microphone]
    metadata.audioSourceTracks = [
      RecordingAudioSourceTrack(trackID: 2, role: .systemAudio),
      RecordingAudioSourceTrack(trackID: 3, role: .microphone),
    ]

    try RecordingMetadataStore.save(metadata, for: videoURL)
    let loaded = try XCTUnwrap(RecordingMetadataStore.load(for: videoURL))
    XCTAssertEqual(loaded.audioSourceURL, storedSourceURL)
    XCTAssertEqual(loaded.audioSourceTrackRoles, [.systemAudio, .microphone])
    XCTAssertEqual(loaded.audioSourceTracks, metadata.audioSourceTracks)
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedSourceURL.path))

    try RecordingMetadataStore.delete(for: videoURL)
    XCTAssertNil(RecordingMetadataStore.load(for: videoURL))
    XCTAssertFalse(FileManager.default.fileExists(atPath: storedSourceURL.path))
  }

  private func makeCurrentMetadata() -> RecordingMetadata {
    RecordingMetadata(
      coordinateSpace: .topLeftNormalized,
      captureSize: CGSize(width: 1_280, height: 720),
      samplesPerSecond: 60,
      mouseSamples: [
        RecordedMouseSample(time: 0.0, normalizedX: 0.1, normalizedY: 0.2, isInsideCapture: true),
        RecordedMouseSample(time: 0.5, normalizedX: 0.7, normalizedY: 0.8, isInsideCapture: true),
      ]
    )
  }

  private func makeVideoFile(named name: String) throws -> URL {
    let url = tempDirectory.appendingPathComponent(name)
    try Data("video".utf8).write(to: url)
    videoURLs.append(url)
    return url
  }
}
