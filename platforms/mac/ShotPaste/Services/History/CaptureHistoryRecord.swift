//
//  CaptureHistoryRecord.swift
//  ShotPaste
//
//  GRDB model for persisted capture history entries
//

import Foundation
import GRDB
import UniformTypeIdentifiers

/// Type of capture stored in history
enum CaptureHistoryType: String, Codable, Equatable, CaseIterable, Sendable {
  // These case names are persisted in SQLite and are part of the history
  // compatibility contract. Do not rename existing cases.
  case screenshot
  case video
  case gif
  case audio
  case text
  case file

  var systemIconName: String {
    switch self {
    case .screenshot:
      "photo"
    case .video:
      "film"
    case .gif:
      "photo.stack"
    case .audio:
      "waveform"
    case .text:
      "doc.plaintext"
    case .file:
      "doc"
    }
  }

  var isRecording: Bool {
    switch self {
    case .video, .gif, .audio:
      true
    case .screenshot, .text, .file:
      false
    }
  }
}

/// File-type policy shared by audio post-capture and Quick Access restore.
///
/// Audio recording currently emits M4A, but accepting other known audio UTIs
/// keeps history useful for future audio-only capture providers. Video
/// extensions are rejected before UTI inspection so an audio-only MOV/MP4 can
/// never enter the audio path by accident.
enum CaptureHistoryAudioURLPolicy {
  private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
  private static let knownAudioExtensions: Set<String> = [
    "m4a", "m4b", "aac", "aif", "aiff", "caf", "flac", "mp3", "ogg", "wav",
  ]

  static func accepts(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let extensionName = url.pathExtension.lowercased()
    guard !videoExtensions.contains(extensionName) else { return false }
    if knownAudioExtensions.contains(extensionName) {
      return true
    }
    return UTType(filenameExtension: extensionName)?.conforms(to: .audio) == true
  }
}

/// UI-facing processing states backed by the metadata-only history/task index.
/// Existing databases remain unchanged; the index is updated independently.
enum CaptureHistoryAudioProcessingStatus: String, Codable, Equatable, Sendable {
  case saving
  case transcribing
  case polishing
  case organizing
  case waitingForModel
  case notStarted
  case inProgress
  case complete
  case organizationPending
  case organized
  case failed
  case unavailable

  var displayName: String {
    switch self {
    case .saving:
      L10n.AudioRecording.saving
    case .transcribing:
      L10n.AudioRecording.transcribing
    case .polishing:
      L10n.AudioRecording.polishing
    case .organizing:
      L10n.AudioRecording.organizingInterviewQA
    case .waitingForModel:
      L10n.AudioRecording.waiting
    case .notStarted:
      L10n.AudioRecording.notStarted
    case .inProgress:
      L10n.AudioRecording.inProgress
    case .complete:
      L10n.AudioRecording.complete
    case .organizationPending:
      L10n.AudioRecording.organizationPending
    case .organized:
      L10n.AudioRecording.organized
    case .failed:
      L10n.AudioRecording.failed
    case .unavailable:
      L10n.AudioRecording.unavailable
    }
  }
}

/// Product-level source used by the history filters. `captureType` still
/// describes the payload so existing rendering and file handling stay intact.
enum CaptureHistoryOrigin: String, Codable, Equatable, Sendable {
  case capture
  case scrollingCapture
  case clipboard
}

/// The four categories shared by the macOS and Windows history panels.
enum CaptureHistoryCategory: String, Codable, Equatable, CaseIterable, Sendable {
  case screenshot
  case scrollingScreenshot
  case recording
  case clipboard

  var systemIconName: String {
    switch self {
    case .screenshot:
      "photo"
    case .scrollingScreenshot:
      "rectangle.portrait.on.rectangle.portrait"
    case .recording:
      "record.circle"
    case .clipboard:
      "clipboard"
    }
  }
}

/// Record of a capture or clipboard payload persisted locally in history.
struct CaptureHistoryRecord: Identifiable, Codable, Equatable, FetchableRecord, PersistableRecord {
  let id: UUID
  var filePath: String
  var fileName: String
  let captureType: CaptureHistoryType
  var fileSize: Int64
  let capturedAt: Date
  var width: Int?
  var height: Int?
  var duration: TimeInterval?
  var thumbnailPath: String?
  var isDeleted: Bool
  var origin: CaptureHistoryOrigin = .capture

  var category: CaptureHistoryCategory {
    // Audio is always a recording, even if a malformed/imported row carries a
    // clipboard origin. This prevents the recording filter from dropping it.
    if captureType == .audio {
      return .recording
    }

    switch origin {
    case .scrollingCapture:
      return .scrollingScreenshot
    case .clipboard:
      return .clipboard
    case .capture:
      switch captureType {
      case .screenshot:
        return .screenshot
      case .video, .gif, .audio:
        return .recording
      case .text, .file:
        // Text and generic files were only ever produced by clipboard import.
        return .clipboard
      }
    }
  }

  /// Human-readable file size
  var formattedFileSize: String {
    HistoryFormatterCache.fileSize.string(fromByteCount: fileSize)
  }

  /// Formatted capture date
  var formattedDate: String {
    HistoryFormatterCache.recordDate.string(from: capturedAt)
  }

  /// Formatted duration string for display (e.g., "01:30s")
  var formattedDuration: String? {
    guard let duration, duration.isFinite, duration >= 0 else {
      return nil
    }
    return Self.formattedDuration(for: duration)
  }

  static func formattedDuration(for duration: TimeInterval) -> String {
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%02d:%02ds", mins, secs)
  }

  /// Future transcription/organization state without changing the history
  /// schema. A later sidecar or optional metadata field can replace this
  /// placeholder while old rows continue decoding unchanged.
  var audioProcessingStatus: CaptureHistoryAudioProcessingStatus? {
    guard captureType == .audio else { return nil }
    return AudioHistoryProcessingStatusStore.shared.status(for: id)
  }

  /// Local thumbnail URL in App Support, if the thumbnail file exists
  var thumbnailURL: URL? {
    guard let thumbnailPath else { return nil }
    let url = URL(fileURLWithPath: thumbnailPath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// File URL from stored path
  var fileURL: URL {
    URL(fileURLWithPath: filePath)
  }

  /// Whether the underlying file still exists on disk
  var fileExists: Bool {
    FileManager.default.fileExists(atPath: filePath)
  }

  /// Plain text payload for clipboard text records.
  var textContent: String? {
    guard captureType == .text else { return nil }
    return try? String(contentsOf: fileURL, encoding: .utf8)
  }

  /// A bounded preview keeps large clipboard strings from being loaded by every card render.
  var textPreview: String? {
    guard captureType == .text, let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return nil
    }
    defer { try? handle.close() }
    do {
      let data = try handle.read(upToCount: 4_096) ?? Data()
      return String(decoding: data, as: UTF8.self)
    } catch {
      return nil
    }
  }

  var displayTitle: String {
    guard captureType == .text, let textPreview else { return fileName }
    let firstLine = textPreview
      .components(separatedBy: .newlines)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !firstLine.isEmpty else { return fileName }
    return firstLine
  }
}
