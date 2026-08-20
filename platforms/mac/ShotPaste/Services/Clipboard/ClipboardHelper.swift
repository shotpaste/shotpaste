//
//  ClipboardHelper.swift
//  ShotPaste
//
//  Format-aware clipboard write utility.
//  Writes one pasteboard item with file and pixel-data representations
//  so receiving apps see a single image while choosing the type they support.
//

import AppKit
import Foundation
import ImageIO
import os.log
import UniformTypeIdentifiers

private nonisolated let logger = Logger(subsystem: "ShotPaste", category: "ClipboardHelper")

/// Centralized helper for copying images to clipboard while respecting the configured format.
///
/// Strategy: write the file URL via `writeObjects([NSURL])` to obtain sandbox extensions,
/// then augment the first pasteboard item with pixel-data representations via `addTypes`
/// so file-aware apps (Finder, Preview) use the URL and image-consuming apps
/// (Telegram, Slack, Chrome, etc.) use image data, without treating the same
/// screenshot as separate clipboard items.
/// Temp files must NOT be deleted immediately — the receiving app needs them at paste time.
/// Orphaned temp files are cleaned up on next launch by `TempCaptureManager.cleanupOrphanedFiles()`.
enum ClipboardHelper {
  nonisolated static let maximumTIFFPixelCount = 32_000_000

  nonisolated static func shouldCreateTIFFRepresentation(
    pixelWidth: Int,
    pixelHeight: Int
  ) -> Bool {
    guard pixelWidth >= 0, pixelHeight >= 0 else { return false }
    let pixelCount = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
    return !pixelCount.overflow && pixelCount.partialValue <= maximumTIFFPixelCount
  }

  static func copyText(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    markInternalWrite(on: pasteboard)
  }

  // MARK: - File-based copy

  /// Copy one or more file URLs to the clipboard.
  ///
  /// Used for non-image captures and multi-selection where Finder-style file copy
  /// semantics are more appropriate than rendering image pixel data.
  static func copyFileURLs(_ urls: [URL]) {
    guard !urls.isEmpty else { return }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls.map { $0 as NSURL })
    markInternalWrite(on: pasteboard)

    logger.info("Clipboard: copied \(urls.count) file url(s)")
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "Copy file URLs",
      context: ["count": "\(urls.count)"]
    )
  }

  /// Copy a video/GIF/media file to clipboard as a file attachment.
  ///
  /// `writeObjects([NSURL])` stays the primary write because AppKit attaches
  /// the security-scoped handoff receivers need for sandboxed file reads.
  /// The extra URL/string representations live on the same pasteboard item and
  /// help Electron/WebView targets that inspect item-level fallback flavors.
  static func copyMediaFile(from url: URL) {
    DiagnosticLogger.shared.log(.info, .clipboard, "Copy media file", context: ["file": url.lastPathComponent])
    let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)
    defer { fileAccess.stop() }

    guard FileManager.default.fileExists(atPath: url.path) else {
      logger.error("ClipboardHelper: media file not found \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(.error, .clipboard, "Media file not found", context: ["file": url.lastPathComponent])
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let didWrite = pasteboard.writeObjects([url as NSURL])
    addFileURLFallbackRepresentations(to: pasteboard, fileURL: url)
    markInternalWrite(on: pasteboard)

    let readbackCount = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count ?? 0
    DiagnosticLogger.shared.log(
      didWrite && readbackCount > 0 ? .info : .warning,
      .clipboard,
      "Media file URL written to clipboard",
      context: [
        "file": url.lastPathComponent,
        "writeObjects": didWrite ? "true" : "false",
        "readbackCount": "\(readbackCount)",
        "types": pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "none",
        "itemTypes": pasteboard.pasteboardItems?.first?.types.map(\.rawValue).joined(separator: ",") ?? "none",
      ]
    )
  }

  /// Copy an image file to clipboard with both file reference and image data.
  ///
  /// Writes a single pasteboard item with file URL plus encoded image data
  /// representations so apps can pick their preferred type without seeing
  /// duplicate clipboard items.
  ///
  /// - Important: Do NOT delete the file after calling this — the receiving app
  ///   needs it to exist at paste time.
  static func copyImage(from url: URL) {
    DiagnosticLogger.shared.log(.info, .clipboard, "Copy image from file", context: ["file": url.lastPathComponent])
    let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)
    defer { fileAccess.stop() }

    guard FileManager.default.fileExists(atPath: url.path) else {
      logger.error("ClipboardHelper: file not found \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(.error, .clipboard, "File not found", context: ["file": url.lastPathComponent])
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    let image = NSImage(contentsOf: url)
    let encodedData = try? Data(contentsOf: url)
    let encodedType = pasteboardImageType(for: url.pathExtension)

    writeSingleImageItem(
      to: pasteboard,
      fileURL: url,
      image: image,
      tiffData: image?.tiffRepresentation,
      encodedData: encodedData,
      encodedType: encodedType
    )

    if image == nil {
      // Fallback: file exists but NSImage can't decode it (e.g. WebP on macOS 13).
      // The pasteboard item still exposes the file URL and original encoded data.
      logger.warning("ClipboardHelper: could not decode image, file/data-only clipboard for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .warning,
        .clipboard,
        "Image decode failed, file/data-only",
        context: ["file": url.lastPathComponent]
      )
    }

    logger.info("Clipboard: copied file \(url.lastPathComponent)")
  }

  /// Off-main variant of `copyImage(from:)` for the post-save re-copy path.
  /// File read, image decode and TIFF encode (the expensive parts, 50-150ms+ for
  /// Retina captures) run on the calling background queue; only the pasteboard
  /// write hops to main. Capture files live inside the app container, so no
  /// security scope is needed for the read — the scoped-access token is acquired
  /// on main for parity with the main-thread variant.
  nonisolated static func copyImageOffMain(from url: URL) async {
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "Copy image from file (off-main)",
      context: ["file": url.lastPathComponent]
    )

    guard FileManager.default.fileExists(atPath: url.path) else {
      logger.error("ClipboardHelper: file not found \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(.error, .clipboard, "File not found", context: ["file": url.lastPathComponent])
      return
    }

    // Very tall screenshots can require hundreds of MiB when decoded and then
    // again when represented as TIFF. PNG plus file URL is already sufficient
    // for modern image consumers, so only materialize TIFF below a conservative
    // pixel budget.
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    let properties = source.flatMap {
      CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
    }
    let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let shouldCreateTIFF = shouldCreateTIFFRepresentation(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )

    // Heavy work off-main
    let image = shouldCreateTIFF ? NSImage(contentsOf: url) : nil
    let tiffData = image?.tiffRepresentation
    let encodedData = try? Data(contentsOf: url, options: .mappedIfSafe)
    let encodedType = pasteboardImageType(for: url.pathExtension)

    await MainActor.run {
      let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(url)
      defer { fileAccess.stop() }

      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      writeSingleImageItem(
        to: pasteboard,
        fileURL: url,
        image: image,
        tiffData: tiffData,
        encodedData: encodedData,
        encodedType: encodedType
      )

      if image == nil, shouldCreateTIFF {
        logger.warning("ClipboardHelper: could not decode image, file/data-only clipboard for \(url.lastPathComponent)")
        DiagnosticLogger.shared.log(
          .warning,
          .clipboard,
          "Image decode failed, file/data-only",
          context: ["file": url.lastPathComponent]
        )
      }
    }

    logger.info("Clipboard: copied file \(url.lastPathComponent)")
  }

  // MARK: - Render-based copy

  /// Copy an in-memory NSImage to clipboard by saving to a temp file first,
  /// then writing the file URL. This ensures the pasted result uses the correct format.
  ///
  /// Used by annotation copy where the image is rendered on-the-fly.
  static func copyImage(_ image: NSImage, format: ImageFormatOption? = nil) {
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "Copy rendered image",
      context: ["format": (format ?? currentFormat()).rawValue]
    )
    let resolvedFormat = format ?? currentFormat()
    let ext = resolvedFormat.format.fileExtension

    guard let data = AnnotateExporter.imageData(from: image, for: ext) else {
      logger.error("ClipboardHelper: failed to encode image as \(resolvedFormat.rawValue)")
      DiagnosticLogger.shared.log(
        .error,
        .clipboard,
        "Image encode failed",
        context: ["format": resolvedFormat.rawValue]
      )
      // Fallback: write NSImage directly (will produce PNG but at least something lands)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.writeObjects([image])
      markInternalWrite(on: pasteboard)
      return
    }

    // Write to a temp file so the pasteboard can reference it
    let tempDir = TempCaptureManager.shared.tempCaptureDirectory
    let fileName = "ShotPaste_clipboard_\(UUID().uuidString).\(ext)"
    let tempURL = tempDir.appendingPathComponent(fileName)

    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      try data.write(to: tempURL, options: .atomic)
    } catch {
      logger.error("ClipboardHelper: failed to write temp file: \(error.localizedDescription)")
      DiagnosticLogger.shared.logError(.clipboard, error, "Temp file write failed")
      // Fallback
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.writeObjects([image])
      markInternalWrite(on: pasteboard)
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    writeSingleImageItem(
      to: pasteboard,
      fileURL: tempURL,
      image: image,
      tiffData: image.tiffRepresentation,
      encodedData: data,
      encodedType: pasteboardImageType(for: ext)
    )

    logger.info("Clipboard: copied rendered image as \(ext) via temp file")
  }

  // MARK: - Helpers

  private static func writeSingleImageItem(
    to pasteboard: NSPasteboard,
    fileURL: URL,
    image: NSImage?,
    tiffData: Data?,
    encodedData: Data?,
    encodedType: NSPasteboard.PasteboardType?
  ) {
    // Use writeObjects with NSURL to ensure macOS grants a sandbox extension
    // to the receiving app. NSPasteboardItem.setString(url, forType: .fileURL)
    // does NOT grant sandbox extensions — this was the root cause of Area
    // Capture's "auto copy" failing in sandboxed builds.
    pasteboard.writeObjects([fileURL as NSURL])

    // Augment the first pasteboard item with image data representations so
    // image-consuming apps (Telegram, Slack, etc.) can paste inline images
    // instead of a file reference.
    var extraTypes: [NSPasteboard.PasteboardType] = []
    if let encodedType {
      extraTypes.append(encodedType)
    }
    if image != nil {
      extraTypes.append(.tiff)
    }

    if !extraTypes.isEmpty {
      pasteboard.addTypes(extraTypes, owner: nil)

      if let encodedData, let encodedType {
        pasteboard.setData(encodedData, forType: encodedType)
      }
      if let tiffData {
        pasteboard.setData(tiffData, forType: .tiff)
      }
    }
    markInternalWrite(on: pasteboard)
  }

  private static func markInternalWrite(on pasteboard: NSPasteboard) {
    pasteboard.addTypes([MediaClipboardMonitor.internalWriteMarker], owner: nil)
    pasteboard.setData(Data(), forType: MediaClipboardMonitor.internalWriteMarker)
  }

  private static func addFileURLFallbackRepresentations(
    to pasteboard: NSPasteboard,
    fileURL: URL
  ) {
    pasteboard.addTypes([.URL, .string], owner: nil)
    pasteboard.setString(fileURL.absoluteString, forType: .URL)
    pasteboard.setString(fileURL.path, forType: .string)
  }

  private nonisolated static func pasteboardImageType(for fileExtension: String) -> NSPasteboard.PasteboardType? {
    let ext = fileExtension.lowercased()
    switch ext {
    case "png":
      return .png
    case "jpg", "jpeg":
      return NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    case "webp":
      return NSPasteboard.PasteboardType(UTType.webP.identifier)
    case "tif", "tiff":
      return .tiff
    default:
      guard let type = UTType(filenameExtension: ext), type.conforms(to: .image) else {
        return nil
      }
      return NSPasteboard.PasteboardType(type.identifier)
    }
  }

  /// Read the user's preferred screenshot format from UserDefaults
  private static func currentFormat() -> ImageFormatOption {
    if let raw = UserDefaults.standard.string(forKey: PreferencesKeys.screenshotFormat),
       let option = ImageFormatOption(rawValue: raw) {
      return option
    }
    return .png
  }
}
