//
//  HistoryThumbnailGenerator.swift
//  ShotPaste
//
//  Lazy thumbnail generation and caching for capture history
//

import AppKit
import AVFoundation
import Foundation
import ImageIO
import os.log
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "ShotPaste", category: "HistoryThumbnailGenerator")

/// Generates and caches thumbnails for capture history items
final class HistoryThumbnailGenerator {
  static let shared = HistoryThumbnailGenerator()

  private let cacheVersion = "preview-v2"
  private let maxDimension: CGFloat = 208
  private let compressionFactor: CGFloat = 0.58
  private let workerQueue = DispatchQueue(
    label: "shotpaste.history-thumbnail-generator.worker",
    qos: .utility,
    attributes: .concurrent
  )
  private let thumbnailsDirectoryURL: URL
  private let stateQueue = DispatchQueue(label: "shotpaste.history-thumbnail-generator.state")
  private let memoryCache = NSCache<NSString, NSImage>()
  private var inFlightRequests: [String: [(NSImage?) -> Void]] = [:]
  private var memoryCacheKeysByRecordId: [UUID: Set<String>] = [:]

  var thumbnailsDirectory: URL {
    thumbnailsDirectoryURL
  }

  init(thumbnailsDirectory: URL? = nil) {
    thumbnailsDirectoryURL = thumbnailsDirectory ?? Self.defaultThumbnailsDirectory()
    do {
      try FileManager.default.createDirectory(
        at: thumbnailsDirectoryURL,
        withIntermediateDirectories: true
      )
    } catch {
      DiagnosticLogger.shared.logError(.history, error, "History thumbnail directory creation failed")
    }
    memoryCache.countLimit = 160
    memoryCache.totalCostLimit = 48 * 1024 * 1024
  }

  private static func defaultThumbnailsDirectory() -> URL {
    AppDataLocations.applicationSupportRoot!
      .appendingPathComponent("HistoryThumbnails", isDirectory: true)
  }

  // MARK: - Public API

  func loadThumbnailImage(for record: CaptureHistoryRecord) async -> NSImage? {
    await withCheckedContinuation { continuation in
      loadThumbnailImage(for: record) { image in
        continuation.resume(returning: image)
      }
    }
  }

  func loadThumbnailImage(
    for record: CaptureHistoryRecord,
    completion: @escaping (NSImage?) -> Void
  ) {
    let identity = cacheIdentity(for: record)
    let cacheKey = NSString(string: identity.cacheKey)

    if let cachedImage = memoryCache.object(forKey: cacheKey) {
      DispatchQueue.main.async {
        completion(cachedImage)
      }
      return
    }

    let shouldStartWork = stateQueue.sync { () -> Bool in
      if inFlightRequests[identity.cacheKey] != nil {
        inFlightRequests[identity.cacheKey]?.append(completion)
        return false
      }

      inFlightRequests[identity.cacheKey] = [completion]
      return true
    }

    guard shouldStartWork else { return }

    workerQueue.async { [weak self] in
      guard let self else { return }
      let image = resolveThumbnailImage(for: record, identity: identity)

      if let image {
        let cost = max(Int(image.size.width * image.size.height * 4), 1)
        storeInMemory(image, identity: identity, cost: cost)
      }

      let completions = stateQueue.sync {
        self.inFlightRequests.removeValue(forKey: identity.cacheKey) ?? []
      }

      DispatchQueue.main.async {
        completions.forEach { $0(image) }
      }
    }
  }

  func preloadThumbnails(for records: [CaptureHistoryRecord]) {
    for record in records {
      loadThumbnailImage(for: record) { _ in }
    }
  }

  /// Generate a thumbnail for a history record and cache it to disk.
  /// Returns the cached thumbnail URL if successful.
  func generate(for record: CaptureHistoryRecord) async -> URL? {
    await withCheckedContinuation { continuation in
      let identity = cacheIdentity(for: record)
      let preferredURL = existingThumbnailURL(for: record, identity: identity)
      loadThumbnailImage(for: record) { image in
        guard image != nil else {
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: preferredURL ?? identity.thumbnailURL)
      }
    }
  }

  /// Load a thumbnail from disk for a record
  func thumbnailURL(for record: CaptureHistoryRecord) -> URL? {
    let identity = cacheIdentity(for: record)
    return existingThumbnailURL(for: record, identity: identity)
  }

  /// Delete all cached thumbnails and clear thumbnail paths in database
  func clearAllThumbnails() {
    let fm = FileManager.default
    let contents: [URL]
    do {
      contents = try fm.contentsOfDirectory(
        at: thumbnailsDirectory,
        includingPropertiesForKeys: nil
      )
    } catch {
      DiagnosticLogger.shared.logError(.history, error, "History thumbnails clear failed to list directory")
      return
    }

    for url in contents {
      do {
        try fm.removeItem(at: url)
      } catch {
        DiagnosticLogger.shared.logError(
          .history,
          error,
          "History thumbnail delete failed during clear all",
          context: ["fileName": url.lastPathComponent]
        )
      }
    }

    memoryCache.removeAllObjects()

    // Clear all thumbnail paths in database
    DispatchQueue.main.async {
      CaptureHistoryStore.shared.clearAllThumbnailPaths()
      logger.info("All history thumbnails cleared")
      DiagnosticLogger.shared.log(
        .info,
        .history,
        "All history thumbnails cleared",
        context: ["thumbnailCount": "\(contents.count)"]
      )
    }
  }

  // MARK: - Private

  private func resolveThumbnailImage(for record: CaptureHistoryRecord, identity: ThumbnailCacheIdentity) -> NSImage? {
    if let cachedURL = existingThumbnailURL(for: record, identity: identity),
       let cachedImage = decodeThumbnail(at: cachedURL) {
      return cachedImage
    }

    guard FileManager.default.fileExists(atPath: record.filePath) else {
      logger.debug("File missing, skipping thumbnail: \(record.fileName)")
      DiagnosticLogger.shared.log(
        .debug,
        .history,
        "History thumbnail skipped; source file missing",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
      return nil
    }

    let generatedThumbnail: GeneratedThumbnail? = switch record.captureType {
    case .screenshot, .gif:
      generateImageThumbnail(for: record, identity: identity)
    case .video:
      generateVideoThumbnail(for: record, identity: identity)
    case .text, .file:
      nil
    }

    guard let generatedThumbnail else { return nil }

    DispatchQueue.main.async {
      CaptureHistoryStore.shared.updateThumbnailPath(id: record.id, path: generatedThumbnail.url.path)
    }

    return generatedThumbnail.image
  }

  private func generateImageThumbnail(for record: CaptureHistoryRecord,
                                      identity: ThumbnailCacheIdentity) -> GeneratedThumbnail? {
    let url = record.fileURL
    let scopedAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)
    defer { scopedAccess.stop() }

    guard let cgImage = downsampledImage(at: url) else {
      logger.warning("Failed to load image for thumbnail: \(record.fileName)")
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History image thumbnail generation failed",
        context: ["fileName": record.fileName]
      )
      return nil
    }

    return saveThumbnail(cgImage, identity: identity)
  }

  private func generateVideoThumbnail(for record: CaptureHistoryRecord,
                                      identity: ThumbnailCacheIdentity) -> GeneratedThumbnail? {
    let url = record.fileURL
    let scopedAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)
    defer { scopedAccess.stop() }

    let asset = AVURLAsset(url: url)

    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.maximumSize = CGSize(width: maxDimension * 2, height: maxDimension * 2)

    // Extract at mid-point or 1s, whichever is smaller
    let extractTime: TimeInterval = if let duration = record.duration, duration > 0 {
      min(duration / 2, 1.0)
    } else {
      0
    }

    let time = CMTimeMakeWithSeconds(extractTime, preferredTimescale: 600)

    do {
      let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)
      return saveThumbnail(cgImage, identity: identity)
    } catch {
      logger.error("Failed to generate video thumbnail: \(error.localizedDescription)")
      DiagnosticLogger.shared.logError(
        .history,
        error,
        "History video thumbnail generation failed",
        context: ["fileName": record.fileName]
      )
      return nil
    }
  }

  private func existingThumbnailURL(for record: CaptureHistoryRecord, identity: ThumbnailCacheIdentity) -> URL? {
    let currentURL = identity.thumbnailURL

    if FileManager.default.fileExists(atPath: currentURL.path) {
      return currentURL
    }

    guard
      let storedURL = record.thumbnailURL,
      storedURL.lastPathComponent == currentURL.lastPathComponent,
      FileManager.default.fileExists(atPath: storedURL.path)
    else {
      return nil
    }

    return storedURL
  }

  private func cacheIdentity(for record: CaptureHistoryRecord) -> ThumbnailCacheIdentity {
    let capturedAtMs = Int64((record.capturedAt.timeIntervalSince1970 * 1000).rounded())
    let signature = "\(capturedAtMs)-\(record.fileSize)"
    let cacheKey = "\(record.id.uuidString)-\(cacheVersion)-\(signature)"
    return ThumbnailCacheIdentity(
      recordId: record.id,
      cacheKey: cacheKey,
      thumbnailURL: thumbnailsDirectory.appendingPathComponent("\(cacheKey).jpg")
    )
  }

  private func deleteThumbnailFiles(for recordId: UUID, keeping keptURL: URL? = nil) {
    let prefix = "\(recordId.uuidString)-"
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: thumbnailsDirectory,
      includingPropertiesForKeys: nil
    )) ?? []

    for url in contents where url.lastPathComponent.hasPrefix(prefix) {
      if keptURL?.standardizedFileURL == url.standardizedFileURL {
        continue
      }
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        DiagnosticLogger.shared.logError(
          .history,
          error,
          "History thumbnail stale cache delete failed",
          context: ["fileName": url.lastPathComponent]
        )
      }
    }
  }

  private func storeInMemory(_ image: NSImage, identity: ThumbnailCacheIdentity, cost: Int) {
    memoryCache.setObject(image, forKey: NSString(string: identity.cacheKey), cost: cost)
    stateQueue.sync {
      var keys = memoryCacheKeysByRecordId[identity.recordId] ?? []
      keys.insert(identity.cacheKey)
      memoryCacheKeysByRecordId[identity.recordId] = keys
    }
  }

  private func downsampledImage(at url: URL) -> CGImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false,
    ]

    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
      return nil
    }

    let maxPixelSize = Int(maxDimension * 2)
    let downsampleOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]

    return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary)
  }

  private func decodeThumbnail(at url: URL) -> NSImage? {
    let options: [CFString: Any] = [
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
          let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
      return nil
    }

    return NSImage(
      cgImage: cgImage,
      size: NSSize(width: cgImage.width, height: cgImage.height)
    )
  }

  private func saveThumbnail(_ image: CGImage, identity: ThumbnailCacheIdentity) -> GeneratedThumbnail? {
    let url = identity.thumbnailURL

    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    ) else {
      logger.warning("Failed to create thumbnail destination for \(identity.recordId)")
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History thumbnail destination creation failed",
        context: ["recordId": identity.recordId.uuidString]
      )
      return nil
    }

    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: compressionFactor,
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      logger.warning("Failed to encode thumbnail as JPEG for \(identity.recordId)")
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History thumbnail JPEG encode failed",
        context: ["recordId": identity.recordId.uuidString]
      )
      return nil
    }

    deleteThumbnailFiles(for: identity.recordId, keeping: url)

    let thumbnailImage = NSImage(
      cgImage: image,
      size: NSSize(width: image.width, height: image.height)
    )

    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
      storeInMemory(thumbnailImage, identity: identity, cost: max(fileSize, 1))
      return GeneratedThumbnail(url: url, image: thumbnailImage)
    } catch {
      logger.error("Failed to read thumbnail metadata: \(error.localizedDescription)")
      DiagnosticLogger.shared.logError(
        .history,
        error,
        "History thumbnail metadata read failed",
        context: ["recordId": identity.recordId.uuidString]
      )
      return nil
    }
  }
}

private struct ThumbnailCacheIdentity {
  let recordId: UUID
  let cacheKey: String
  let thumbnailURL: URL
}

private struct GeneratedThumbnail {
  let url: URL
  let image: NSImage
}
