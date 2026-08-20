//
//  CaptureStorageManager.swift
//  ShotPaste
//
//  Manages temporary capture storage in the current app variant's Application Support folder.
//  Provides cache size calculation and safe cleanup operations.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "ShotPaste", category: "CaptureStorageManager")

@MainActor
final class CaptureStorageManager {
  static let shared = CaptureStorageManager()

  private let fileManager = FileManager.default
  private let capturesFolderName = "Captures"
  private let mediaClipboardFolderName = "MediaClipboard"

  private init() {}

  // MARK: - Directory

  /// URL to the captures cache directory for the current app variant.
  var capturesDirectoryURL: URL? {
    AppDataLocations.applicationSupportRoot?
      .appendingPathComponent(capturesFolderName, isDirectory: true)
  }

  var mediaClipboardDirectoryURL: URL? {
    AppDataLocations.applicationSupportRoot?
      .appendingPathComponent(mediaClipboardFolderName, isDirectory: true)
  }

  /// Ensures the captures directory exists, creating it if needed.
  @discardableResult
  func ensureCapturesDirectory() -> URL? {
    guard let url = capturesDirectoryURL else {
      DiagnosticLogger.shared.log(
        .error,
        .fileAccess,
        "Captures directory unavailable; Application Support URL missing"
      )
      return nil
    }

    if !fileManager.fileExists(atPath: url.path) {
      do {
        try fileManager.createDirectory(
          at: url, withIntermediateDirectories: true, attributes: nil
        )
        logger.info("Created captures directory at \(url.path, privacy: .public)")
        DiagnosticLogger.shared.log(
          .info,
          .fileAccess,
          "Captures directory created",
          context: ["directory": url.lastPathComponent]
        )
      } catch {
        logger.error(
          "Failed to create captures directory: \(error.localizedDescription, privacy: .public)"
        )
        DiagnosticLogger.shared.logError(.fileAccess, error, "Captures directory creation failed")
        return nil
      }
    }

    return url
  }

  // MARK: - Cache Size

  /// Calculates total size of all files in the captures directory (in bytes).
  /// Runs on a background thread.
  func calculateCacheSize() async -> Int64 {
    let directories = [capturesDirectoryURL, mediaClipboardDirectoryURL]
      .compactMap { $0 }
      .filter { fileManager.fileExists(atPath: $0.path) }
    guard !directories.isEmpty else { return 0 }

    return await Task.detached {
      let fm = FileManager.default
      var totalSize: Int64 = 0
      for directory in directories {
        guard let enumerator = fm.enumerator(
          at: directory,
          includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
          options: [.skipsHiddenFiles],
          errorHandler: nil
        ) else { continue }

        while let fileURL = enumerator.nextObject() as? URL {
          guard
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true,
            let size = values.fileSize
          else {
            continue
          }
          totalSize += Int64(size)
        }
      }
      return totalSize
    }.value
  }

  /// Formats a byte count into a human-readable string (e.g. "12.3 MB").
  static func formattedSize(_ bytes: Int64) -> String {
    if bytes == 0 {
      return L10n.CaptureStorage.empty
    }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
  }
}
