//
//  CaptureHistoryRecord.swift
//  ShotPaste
//
//  GRDB model for persisted capture history entries
//

import Foundation
import GRDB

/// Type of capture stored in history
enum CaptureHistoryType: String, Codable, Equatable, CaseIterable, Sendable {
  case screenshot
  case video
  case gif
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
    case .text:
      "doc.plaintext"
    case .file:
      "doc"
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
    switch origin {
    case .scrollingCapture:
      return .scrollingScreenshot
    case .clipboard:
      return .clipboard
    case .capture:
      switch captureType {
      case .screenshot:
        return .screenshot
      case .video, .gif:
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
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60
    return String(format: "%02d:%02ds", mins, secs)
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
