//
//  PostCaptureActionHandler.swift
//  ShotPaste
//
//  Executes post-capture actions based on user preferences
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os.log

private let logger = Logger(subsystem: "ShotPaste", category: "PostCaptureActionHandler")

/// Handles execution of post-capture actions based on user preferences
@MainActor
final class PostCaptureActionHandler {
  static let shared = PostCaptureActionHandler(
    preferences: PreferencesManager.shared,
    quickAccess: QuickAccessManager.shared,
    fileAccess: SandboxFileAccessManager.shared,
    screenshotPresetAutoApplier: ScreenshotPresetAutoApplier.shared
  )

  private let preferences: PreferencesProviding
  private let quickAccess: QuickAccessManaging
  private let fileAccess: SandboxFileAccessing
  private let screenshotPresetAutoApplier: ScreenshotPresetAutoApplier

  init(
    preferences: PreferencesProviding,
    quickAccess: QuickAccessManaging,
    fileAccess: SandboxFileAccessing,
    screenshotPresetAutoApplier: ScreenshotPresetAutoApplier
  ) {
    self.preferences = preferences
    self.quickAccess = quickAccess
    self.fileAccess = fileAccess
    self.screenshotPresetAutoApplier = screenshotPresetAutoApplier
  }

  // MARK: - Public API

  /// Execute all enabled post-capture actions for a screenshot
  @discardableResult
  func handleScreenshotCapture(
    url: URL,
    pinToScreen: Bool = false,
    origin: CaptureHistoryOrigin = .capture,
    successMessage: String = "Screenshot saved"
  ) async -> QuickAccessItem? {
    let quickAccessItem = await executeActions(
      for: .screenshot,
      url: url,
      pinToScreen: pinToScreen
    )

    // Add to capture history
    if await addScreenshotToHistory(url: url, origin: origin) {
      showSuccessNotificationIfEnabled(for: .screenshot, message: successMessage)
    }

    return quickAccessItem
  }

  /// Add a screenshot to capture history
  private func addScreenshotToHistory(
    url: URL,
    origin: CaptureHistoryOrigin = .capture
  ) async -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "Screenshot history add skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return false
    }

    let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
    var width: Int?
    var height: Int?
    if let source = imageSource {
      if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        if let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int {
          width = pixelWidth
        }
        if let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int {
          height = pixelHeight
        }
      }
    }

    CaptureHistoryStore.shared.addCapture(
      url: url,
      captureType: .screenshot,
      origin: origin,
      width: width,
      height: height
    )
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Screenshot queued for history",
      context: [
        "fileName": url.lastPathComponent,
        "width": width.map { "\($0)" } ?? "unknown",
        "height": height.map { "\($0)" } ?? "unknown",
      ]
    )
    return true
  }

  /// Execute all enabled post-capture actions for a video recording
  /// - Parameter skipQuickAccess: When true, skip adding to QuickAccess (e.g. GIF flow already added it)
  func handleVideoCapture(url: URL, skipQuickAccess: Bool = false) async {
    await executeActions(for: .recording, url: url, skipQuickAccess: skipQuickAccess)

    // Add to capture history
    if await addVideoToHistory(url: url) {
      showSuccessNotificationIfEnabled(for: .recording)
    }
  }

  /// Add a video or GIF to capture history
  private func addVideoToHistory(url: URL) async -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "Video history add skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return false
    }

    let isGIF = url.pathExtension.lowercased() == "gif"
    let captureType: CaptureHistoryType = isGIF ? .gif : .video

    var duration: TimeInterval?
    var width: Int?
    var height: Int?

    if !isGIF {
      let asset = AVURLAsset(url: url)
      let assetDuration: CMTime = if #available(macOS 15.0, *) {
        await (try? asset.load(.duration)) ?? .invalid
      } else {
        asset.duration
      }
      let seconds = CMTimeGetSeconds(assetDuration)
      if seconds.isFinite, seconds > 0 {
        duration = seconds
      }

      let videoTrack: AVAssetTrack? = if #available(macOS 15.0, *) {
        try? await asset.loadTracks(withMediaType: .video).first
      } else {
        asset.tracks(withMediaType: .video).first
      }
      if let track = videoTrack {
        let naturalSize: CGSize = if #available(macOS 15.0, *) {
          await (try? track.load(.naturalSize)) ?? .zero
        } else {
          track.naturalSize
        }
        width = Int(naturalSize.width)
        height = Int(naturalSize.height)
      }
    }

    CaptureHistoryStore.shared.addCapture(
      url: url,
      captureType: captureType,
      duration: duration,
      width: width,
      height: height
    )
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Video queued for history",
      context: [
        "fileName": url.lastPathComponent,
        "type": captureType.rawValue,
        "duration": duration.map { "\($0)" } ?? "unknown",
        "width": width.map { "\($0)" } ?? "unknown",
        "height": height.map { "\($0)" } ?? "unknown",
      ]
    )
    return true
  }

  /// Re-run clipboard automation after an in-place edit save succeeds.
  /// Screenshots: decode/encode run off-main (serialized so rapid successive
  /// saves keep last-save-wins clipboard order); only the pasteboard write
  /// hops back to main. Videos stay on the cheap file-URL path.
  func copyEditedCaptureToClipboardIfEnabled(for captureType: CaptureType, url: URL) {
    guard preferences.isActionEnabled(.copyFile, for: captureType) else {
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "Edited capture clipboard copy skipped by preference",
        context: ["captureType": captureType.rawValue, "fileName": url.lastPathComponent]
      )
      return
    }

    if captureType == .recording {
      copyToClipboard(url: url, isVideo: true)
    } else {
      let previous = editedClipboardTask
      editedClipboardTask = Task.detached(priority: .userInitiated) {
        await previous?.value
        await ClipboardHelper.copyImageOffMain(from: url)
      }
    }

    let label = captureType == .screenshot ? "screenshot" : "recording"
    logger.debug("Clipboard re-copy executed for edited \(url.lastPathComponent)")
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "Edited capture copied to clipboard",
      context: ["captureType": label, "fileName": url.lastPathComponent]
    )
  }

  /// Chained task serializing off-main edited-capture clipboard writes.
  private var editedClipboardTask: Task<Void, Never>?

  private func showSuccessNotificationIfEnabled(
    for captureType: CaptureType,
    message: String? = nil
  ) {
    let enabled = UserDefaults.standard
      .object(forKey: PreferencesKeys.screenshotSuccessNotificationEnabled) as? Bool ?? true
    guard enabled else { return }
    AppToastManager.shared.show(
      message: message ?? (captureType == .screenshot ? "Screenshot saved" : "Recording saved"),
      style: .success,
      position: .bottomCenter
    )
  }

  // MARK: - Private

  @discardableResult
  private func executeActions(
    for captureType: CaptureType,
    url: URL,
    skipQuickAccess: Bool = false,
    pinToScreen: Bool = false
  ) async -> QuickAccessItem? {
    let scopedAccess = fileAccess.beginAccessingURL(url)
    defer { scopedAccess.stop() }

    // Validate file exists before processing
    guard FileManager.default.fileExists(atPath: url.path) else {
      logger.error("Capture file missing at \(url.lastPathComponent), skipping post-capture actions")
      DiagnosticLogger.shared.log(
        .error,
        .action,
        "Post-capture actions skipped; file missing",
        context: ["captureType": captureType.rawValue, "fileName": url.lastPathComponent]
      )
      return nil
    }

    logger
      .info(
        "Executing post-capture actions for \(captureType == .screenshot ? "screenshot" : "recording"): \(url.lastPathComponent)"
      )
    if captureType == .screenshot {
      _ = screenshotPresetAutoApplier.applyDefaultPresetIfNeeded(to: url)
    }
    let isTempCapture = TempCaptureManager.shared.isTempFile(url)
    let locationLabel = isTempCapture ? "temp" : "export"
    let typeLabel = captureType == .screenshot ? "screenshot" : "recording"
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "Post-capture actions started",
      context: [
        "captureType": typeLabel,
        "fileName": url.lastPathComponent,
        "location": locationLabel,
        "skipQuickAccess": skipQuickAccess ? "true" : "false",
      ]
    )

    // Copy file to clipboard before slower UI actions. Auto-copy is expected
    // to update immediately after capture; it must not depend on thumbnail
    // generation, Quick Access animations, or editor opening.
    if preferences.isActionEnabled(.copyFile, for: captureType) {
      copyToClipboard(url: url, isVideo: captureType == .recording)
      let label = captureType == .screenshot ? "screenshot" : "recording"
      logger.debug("Clipboard copy executed for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .clipboard,
        "Post-capture clipboard action executed",
        context: ["captureType": label, "fileName": url.lastPathComponent]
      )
    }

    // Show Quick Access Overlay
    var quickAccessItem: QuickAccessItem?
    if !skipQuickAccess, preferences.isActionEnabled(.showQuickAccess, for: captureType) {
      switch captureType {
      case .screenshot:
        quickAccessItem = await quickAccess.addScreenshot(url: url)
      case .recording:
        quickAccessItem = await quickAccess.addVideo(url: url)
      }
      logger.debug("Quick access overlay shown for \(url.lastPathComponent)")
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Post-capture quick access action executed",
        context: ["captureType": typeLabel, "fileName": url.lastPathComponent]
      )
    } else {
      DiagnosticLogger.shared.log(
        .debug,
        .action,
        "Post-capture quick access action skipped",
        context: [
          "captureType": typeLabel,
          "fileName": url.lastPathComponent,
          "skipQuickAccess": skipQuickAccess ? "true" : "false",
        ]
      )
    }

    if captureType == .screenshot, pinToScreen {
      if let quickAccessItem {
        quickAccess.pinScreenshot(id: quickAccessItem.id)
      } else {
        quickAccessItem = await quickAccess.pinScreenshot(url: url)
      }
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "Post-capture pin action executed",
        context: ["fileName": url.lastPathComponent]
      )
    }

    return quickAccessItem
  }

  /// Copy file to clipboard (format-aware image data for screenshots, file URL for videos)
  private func copyToClipboard(url: URL, isVideo: Bool) {
    if isVideo {
      ClipboardHelper.copyMediaFile(from: url)
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "File URL written to clipboard",
        context: ["fileName": url.lastPathComponent, "kind": "video"]
      )
    } else {
      ClipboardHelper.copyImage(from: url)
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "Image written to clipboard",
        context: ["fileName": url.lastPathComponent]
      )
    }
  }
}
