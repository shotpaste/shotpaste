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

/// Compatibility name for callers of the audio post-capture API. The shared
/// validator owns the rejection vocabulary so every audio entry point reports
/// the same reason.
typealias AudioCapturePostProcessingRejection = AudioAssetValidationRejection

/// Outcome returned to an audio coordinator after all post-capture actions
/// have been awaited. The coordinator can start transcription only when
/// `transcriptionCanContinue` is true, and can distinguish that from history
/// persistence being disabled or failing.
@MainActor
struct AudioCapturePostProcessingResult: Equatable {
  let accepted: Bool
  let historyPersisted: Bool
  /// The UUID returned by SQLite after the history row was actually inserted.
  /// A generated UUID is never returned for disabled/failed history writes.
  let historyRecordID: UUID?
  let transcriptionCanContinue: Bool
  let quickAccessItem: QuickAccessItem?
  let rejection: AudioCapturePostProcessingRejection?

  var succeeded: Bool {
    accepted && historyPersisted
  }

  var canContinueTranscription: Bool {
    transcriptionCanContinue
  }
}

/// Handles execution of post-capture actions based on user preferences
@MainActor
final class PostCaptureActionHandler {
  static let shared = PostCaptureActionHandler(
    preferences: PreferencesManager.shared,
    quickAccess: QuickAccessManager.shared,
    fileAccess: SandboxFileAccessManager.shared
  )

  private let preferences: PreferencesProviding
  private let quickAccess: QuickAccessManaging
  private let fileAccess: SandboxFileAccessing

  init(
    preferences: PreferencesProviding,
    quickAccess: QuickAccessManaging,
    fileAccess: SandboxFileAccessing
  ) {
    self.preferences = preferences
    self.quickAccess = quickAccess
    self.fileAccess = fileAccess
  }

  // MARK: - Public API

  /// Media kind used to route clipboard and Quick Access operations while the
  /// preferences matrix continues to use `CaptureType.recording` for all
  /// recording-like outputs.
  private enum PostCaptureMediaKind: Equatable {
    case screenshot
    case video
    case audio

    var label: String {
      switch self {
      case .screenshot:
        "screenshot"
      case .video:
        "video"
      case .audio:
        "audio"
      }
    }
  }

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
      pinToScreen: pinToScreen,
      mediaKind: .screenshot
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
    await executeActions(
      for: .recording,
      url: url,
      skipQuickAccess: skipQuickAccess,
      mediaKind: .video
    )

    // Add to capture history
    if await addVideoToHistory(url: url) {
      showSuccessNotificationIfEnabled(for: .recording)
    }
  }

  /// Execute post-capture actions for an audio-only recording.
  ///
  /// Audio uses the recording preference matrix, but is deliberately routed
  /// through `addAudio`/file-URL clipboard handling. MOV and MP4 are rejected
  /// even if their tracks happen to contain audio.
  @discardableResult
  func handleAudioCapture(
    url: URL,
    skipQuickAccess: Bool = false,
    preferredHistoryID: UUID? = nil
  ) async -> AudioCapturePostProcessingResult {
    let validation = await AudioAssetValidator.validate(url: url)
    guard validation.isValid, let duration = validation.duration else {
      let rejection = validation.rejection ?? .invalidDuration
      logAudioRejection(rejection, url: url)
      return AudioCapturePostProcessingResult(
        accepted: false,
        historyPersisted: false,
        historyRecordID: nil,
        transcriptionCanContinue: false,
        quickAccessItem: nil,
        rejection: rejection
      )
    }

    let existingRecord = CaptureHistoryStore.shared.record(
      forFilePath: url.path,
      preferredID: preferredHistoryID
    )
    let historyRecordID = addAudioToHistory(
      url: url,
      duration: duration,
      preferredID: preferredHistoryID
    )
    let quickAccessItem: QuickAccessItem?
    if let historyRecordID {
      AudioHistoryProcessingStatusStore.shared.preparePostCapture(
        historyRecordID: historyRecordID,
        sessionID: preferredHistoryID ?? historyRecordID
      )
      var actionState = AudioHistoryProcessingStatusStore.shared.postActionState(
        for: historyRecordID
      )
      // A row without a checkpoint predates this idempotent handoff. Do not
      // replay external actions during launch recovery.
      if existingRecord != nil {
        actionState = .init(clipboardCompleted: true, quickAccessCompleted: true)
        AudioHistoryProcessingStatusStore.shared.markPostAction(
          historyRecordID: historyRecordID,
          clipboardCompleted: true,
          quickAccessCompleted: true
        )
      }
      quickAccessItem = await executeActions(
        for: .recording,
        url: url,
        skipQuickAccess: skipQuickAccess || actionState.quickAccessCompleted,
        mediaKind: .audio,
        skipClipboard: actionState.clipboardCompleted
      )
      AudioHistoryProcessingStatusStore.shared.markPostAction(
        historyRecordID: historyRecordID,
        clipboardCompleted: true,
        quickAccessCompleted: true
      )
    } else {
      // Preserve the existing behavior when history is disabled: explicitly
      // enabled clipboard/Quick Access actions may still run.
      quickAccessItem = await executeActions(
        for: .recording,
        url: url,
        skipQuickAccess: skipQuickAccess,
        mediaKind: .audio
      )
    }
    if historyRecordID != nil {
      showSuccessNotificationIfEnabled(for: .recording)
    }

    return AudioCapturePostProcessingResult(
      accepted: true,
      historyPersisted: historyRecordID != nil,
      historyRecordID: historyRecordID,
      // The coordinator persists the transcription task after this method, so
      // only a real history row is a durable hand-off point. A disabled or
      // failed history store must not claim transcription eligibility.
      transcriptionCanContinue: historyRecordID != nil,
      quickAccessItem: quickAccessItem,
      rejection: nil
    )
  }

  func handleAudioCapture(
    url: URL,
    skipQuickAccess: Bool
  ) async -> AudioCapturePostProcessingResult {
    await handleAudioCapture(
      url: url,
      skipQuickAccess: skipQuickAccess,
      preferredHistoryID: nil
    )
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
      let assetDuration = await (try? asset.load(.duration)) ?? .invalid
      let seconds = CMTimeGetSeconds(assetDuration)
      if seconds.isFinite, seconds > 0 {
        duration = seconds
      }

      let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
      if let track = videoTrack {
        let naturalSize = await (try? track.load(.naturalSize)) ?? .zero
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

  /// Add an audio file to history using metadata from the already completed
  /// validation gate. This intentionally performs no second weak extension or
  /// duration check after any post-capture side effect.
  private func addAudioToHistory(
    url: URL,
    duration: TimeInterval,
    preferredID: UUID? = nil
  ) -> UUID? {
    let persistedID = CaptureHistoryStore.shared.addCaptureReturningID(
      url: url,
      captureType: .audio,
      duration: duration,
      fileName: url.lastPathComponent,
      id: preferredID ?? UUID(),
      preferredID: preferredID
    )
    DiagnosticLogger.shared.log(
      .debug,
      .history,
      "Audio queued for history",
      context: [
        "fileName": url.lastPathComponent,
        "type": CaptureHistoryType.audio.rawValue,
        "duration": "\(duration)",
          "persisted": persistedID == nil ? "false" : "true",
      ]
    )
    return persistedID
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
      ClipboardHelper.copyMediaFile(from: url)
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
    pinToScreen: Bool = false,
    mediaKind: PostCaptureMediaKind,
    skipClipboard: Bool = false
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
    let isTempCapture = TempCaptureManager.shared.isTempFile(url)
    let locationLabel = isTempCapture ? "temp" : "export"
    let typeLabel = mediaKind.label
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
    if !skipClipboard && preferences.isActionEnabled(.copyFile, for: captureType) {
      await copyToClipboard(url: url, mediaKind: mediaKind)
      let label = mediaKind.label
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
        switch mediaKind {
        case .video:
          quickAccessItem = await quickAccess.addVideo(url: url)
        case .audio:
          quickAccessItem = await quickAccess.addAudio(url: url)
        case .screenshot:
          // This is unreachable because screenshot captures use the outer
          // branch, but keeping it explicit protects future callers.
          quickAccessItem = nil
        }
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

  /// Copy screenshots as image data and audio/video as file URLs.
  private func copyToClipboard(url: URL, mediaKind: PostCaptureMediaKind) async {
    if mediaKind != .screenshot {
      ClipboardHelper.copyMediaFile(from: url)
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "File URL written to clipboard",
        context: ["fileName": url.lastPathComponent, "kind": mediaKind.label]
      )
    } else {
      await ClipboardHelper.copyImageOffMain(from: url)
      DiagnosticLogger.shared.log(
        .debug,
        .clipboard,
        "Image written to clipboard",
        context: ["fileName": url.lastPathComponent]
      )
    }
  }

  private func logAudioRejection(
    _ rejection: AudioCapturePostProcessingRejection,
    url: URL
  ) {
    DiagnosticLogger.shared.log(
      .warning,
      .action,
      "Audio post-capture rejected",
      context: [
        "reason": rejection.rawValue,
        "fileName": url.lastPathComponent,
        "extension": url.pathExtension.lowercased(),
      ]
    )
  }
}
