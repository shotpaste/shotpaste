//
//  AudioAdapterTrackRoleIntegrationTests.swift
//  ShotPasteTests
//
//  Track-level metadata integration coverage for the audio adapter writer.
//

import AVFoundation
@testable import ShotPaste
import XCTest

final class AudioAdapterTrackRoleIntegrationTests: XCTestCase {
  func testSystemRoleMetadataItem_hasContractIdentifierValueAndDataType() throws {
    let items = try RecordingAudioTrackRoleMetadata.items(for: .system)
    assertRoleMetadata(items, role: .system)
  }

  func testMicrophoneRoleMetadataItem_hasContractIdentifierValueAndDataType() throws {
    let items = try RecordingAudioTrackRoleMetadata.items(for: .microphone)
    assertRoleMetadata(items, role: .microphone)
  }

  func testUnknownRoleMetadata_isRejected() {
    XCTAssertThrowsError(try RecordingAudioTrackRoleMetadata.items(for: "unknown")) { error in
      XCTAssertEqual(
        error as? RecordingAudioTrackRoleMetadata.Error,
        .unsupportedRole("unknown")
      )
    }
    XCTAssertThrowsError(try RecordingAudioTrackRoleMetadata.items(for: .mixed))
  }

  func testRoleMetadataValidation_rejectsDuplicateIdentifierAndValue() throws {
    let item = try RecordingAudioTrackRoleMetadata.items(for: .system)
    let duplicate = item + item

    XCTAssertFalse(RecordingAudioTrackRoleMetadata.isValid(duplicate))
    XCTAssertThrowsError(try RecordingAudioTrackRoleMetadata.validate(duplicate))
  }

  func testWriterInputsKeepAACSettingsWhenTrackMetadataIsAttached() throws {
    let systemSettings = RecordingAudioEncodingSettings.makeSystemAudioSettings()
    let microphoneSettings = RecordingAudioEncodingSettings.makeMicrophoneAudioSettings()
    let systemInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
    let microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: microphoneSettings)

    systemInput.metadata = try RecordingAudioTrackRoleMetadata.items(for: .system)
    microphoneInput.metadata = try RecordingAudioTrackRoleMetadata.items(for: .microphone)

    XCTAssertEqual(systemInput.metadata.count, 1)
    XCTAssertEqual(microphoneInput.metadata.count, 1)
    XCTAssertEqual(systemInput.outputSettings?[AVSampleRateKey] as? Int, 48_000)
    XCTAssertEqual(systemInput.outputSettings?[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(systemInput.outputSettings?[AVEncoderBitRateKey] as? Int, 128_000)
    XCTAssertEqual(microphoneInput.outputSettings?[AVSampleRateKey] as? Int, 48_000)
    XCTAssertEqual(microphoneInput.outputSettings?[AVNumberOfChannelsKey] as? Int, 2)
    XCTAssertEqual(microphoneInput.outputSettings?[AVEncoderBitRateKey] as? Int, 128_000)
  }

  /// Keep a source-level guard around the ordering that AVAssetWriter requires:
  /// track metadata must be assigned before the manager starts the writer.
  /// This does not exercise capture hardware, but prevents a future refactor
  /// from moving the assignments after the lifecycle boundary.
  func testSetupAssetWriter_assignsBothRolesBeforeStartWriting() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // Recording
      .deletingLastPathComponent() // Features
      .deletingLastPathComponent() // ShotPasteTests
      .deletingLastPathComponent() // mac
      .appendingPathComponent("ShotPaste/Services/Capture/ScreenRecordingManager.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertNotNil(source.range(of: "session.assetWriter?.startWriting()"))
    guard let setupStart = source.range(of: "private func setupAssetWriter(")?.lowerBound,
          let setupEnd = source.range(
            of: "\n  private func preferredVideoCodec",
            range: setupStart..<source.endIndex
          )?.lowerBound else {
      XCTFail("Could not find the manager's writer start boundary")
      return
    }

    for marker in [
      "audioIn.metadata = try RecordingAudioTrackRoleMetadata.items(for: .system)",
      "micIn.metadata = try RecordingAudioTrackRoleMetadata.items(for: .microphone)",
    ] {
      guard let markerIndex = source.range(of: marker)?.lowerBound else {
        XCTFail("Missing writer metadata assignment: \(marker)")
        continue
      }
      XCTAssertTrue(
        markerIndex > setupStart && markerIndex < setupEnd,
        "Metadata must be attached inside setupAssetWriter before it returns"
      )
    }
  }

  private func assertRoleMetadata(
    _ items: [AVMetadataItem],
    role: AudioAdapterTrackRole,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(items.count, 1, file: file, line: line)
    guard let item = items.first else { return }

    XCTAssertEqual(
      item.identifier,
      AVMetadataIdentifier(RecordingAudioTrackRoleMetadata.identifier),
      file: file,
      line: line
    )
    XCTAssertEqual(item.keySpace, .quickTimeMetadata, file: file, line: line)
    XCTAssertEqual(item.key as? String, RecordingAudioTrackRoleMetadata.key, file: file, line: line)
    XCTAssertEqual(item.value as? String, role.rawValue, file: file, line: line)
    XCTAssertEqual(
      item.dataType,
      RecordingAudioTrackRoleMetadata.dataType,
      file: file,
      line: line
    )
    XCTAssertTrue(
      RecordingAudioTrackRoleMetadata.isValid(items, expectedRole: role),
      file: file,
      line: line
    )
  }
}
