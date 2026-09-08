//
//  ScreenRecordingManager.swift
//  ShotPaste
//
//  Core manager for screen recording functionality using ScreenCaptureKit
//

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class ScreenRecordingManager: NSObject, ObservableObject {
  static let shared = ScreenRecordingManager()

  // MARK: - Published State

  @Published private(set) var state: RecordingState = .idle
  @Published private(set) var elapsedSeconds: Int = 0
  @Published private(set) var error: RecordingError?
  /// Main-actor state mirror of the latest current-generation stream failure.
  /// The matching notification lets coordinators call stop and preserve output.
  @Published private(set) var streamFailureEvent: RecordingStreamFailureEvent?

  var formattedDuration: String {
    let mins = elapsedSeconds / 60
    let secs = elapsedSeconds % 60
    return String(format: "%02d:%02d", mins, secs)
  }

  var isRecording: Bool {
    state == .recording
  }

  var isPaused: Bool {
    state == .paused
  }

  var isActive: Bool {
    state != .idle
  }

  // MARK: - Recording Components

  private var stream: SCStream?
  private let session = RecordingSession() // Thread-safe session for frame writing
  private var microphoneCapturer: MicrophoneAudioCapturer?

  /// Live 0...1 audio level derived read-only from capture buffers; drives the
  /// recording status-bar waveform. Observed directly by the status bar UI.
  let audioLevelMeter = RecordingAudioLevelMeter()

  // MARK: - Timing

  private var timer: Timer?
  private var startTime: Date?
  private var pausedDuration: TimeInterval = 0
  private var pauseStartTime: Date?

  // MARK: - Configuration

  private var recordingRect: CGRect = .zero
  private(set) var recordingPurpose: RecordingPurpose = .screenVideo
  private var videoFormat: VideoFormat = .mov
  private var videoQuality: VideoQuality = .high
  private var fps: Int = 30
  private var captureSystemAudio: Bool = true
  private var captureMicrophone: Bool = false
  private var microphoneDeviceID: String?
  private var showCursorInRecording: Bool = true
  private var excludeOwnApplicationFromCapture: Bool = true
  private var excludeDesktopIconsFromCapture: Bool = false
  private var excludeDesktopWidgetsFromCapture: Bool = false
  private var excludedWindowIDs = Set<CGWindowID>()
  private var exceptedWindowIDs = Set<CGWindowID>()
  private var outputURL: URL?
  private var finalOutputURL: URL?
  private var recordingProcessingDirectory: URL?
  private var shouldPreserveProcessingOutputOnCleanup = false
  private var mouseTracker: RecordingMouseTracker?
  private var exportDirectoryAccess: SandboxFileAccessManager.ScopedAccess?
  private var registeredOutputTypes: Set<SCStreamOutputType> = []
  private var registeredOutputTypesByGeneration: [UInt64: Set<SCStreamOutputType>] = [:]
  private var streamsByGeneration: [UInt64: SCStream] = [:]
  private let captureGenerationGate = RecordingCaptureGenerationGate()
  /// Main-actor single-flight owner.  The generation is part of the owner so
  /// an old async task cannot release a newer teardown, and the operation is
  /// part of the owner so stop/cancel/start-failure all share one latch.
  private var teardownOwner: RecordingTeardownOwner?

  private struct CaptureGeometry {
    let sourceRect: CGRect
    let globalCaptureRect: CGRect
    let outputWidth: Int
    let outputHeight: Int
  }

  /// Dedicated queues to avoid audio starvation behind video processing work.
  private let videoProcessingQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.recording.video",
    qos: .userInitiated
  )
  private let audioProcessingQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.recording.audio",
    qos: .userInteractive
  )
  private struct RecordingAudioNormalizationResult {
    let outputURL: URL?
    let audioSourceURL: URL?
  }

  override private init() {
    super.init()
  }

  // MARK: - Public API

  /// Prepare recording with specified parameters
  func prepareRecording(
    rect: CGRect,
    format: VideoFormat = .mov,
    quality: VideoQuality = .high,
    fps: Int = 30,
    captureSystemAudio: Bool = true,
    captureMicrophone: Bool = false,
    microphoneDeviceID: String? = nil,
    showCursor: Bool = true,
    saveDirectory: URL,
    processingDirectory: URL? = nil,
    fileName: String? = nil,
    excludeDesktopIcons: Bool = false,
    excludeDesktopWidgets: Bool = false,
    excludeOwnApplication: Bool = true,
    excludedWindowIDs: [CGWindowID] = [],
    context: CaptureContext = .empty,
    purpose: RecordingPurpose = .screenVideo
  ) async throws {
    guard state == .idle, teardownOwner == nil else {
      DiagnosticLogger.shared.log(.debug, .recording, "prepareRecording blocked: recorder busy", context: [
        "state": "\(state)",
      ])
      throw RecordingError.alreadyActive
    }
    state = .preparing
    error = nil
    streamFailureEvent = nil
    let generation = captureGenerationGate.begin()
    session.beginGeneration(generation)

    // A prior failed/cancelled setup may still own a stream while its async
    // teardown is winding down.  Retire those streams before creating any new
    // stream, while their callbacks are already rejected by the new generation.
    let obsoleteStreams = streamsByGeneration
      .filter { $0.key != generation }
      .map { ($0.key, $0.value) }
    for (obsoleteGeneration, obsoleteStream) in obsoleteStreams {
      await teardownStream(obsoleteStream, generation: obsoleteGeneration)
    }
    guard captureGenerationGate.isCurrent(generation) else {
      throw RecordingError.cancelled
    }

    let effectiveFormat = AudioAdapterCaptureCore.effectiveFormat(for: format, purpose: purpose)
    let effectiveQuality: VideoQuality = purpose == .audioAdapter ? .low : quality
    let effectiveFPS = purpose == .audioAdapter ? AudioAdapterCaptureCore.frameRate : fps
    let effectiveShowCursor = purpose == .audioAdapter ? false : showCursor
    let effectiveExcludeOwnApplication = purpose == .audioAdapter ? true : excludeOwnApplication

    DiagnosticLogger.shared.log(.info, .recording, "Recording prepare started", context: [
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
      "origin": "\(Int(rect.origin.x)),\(Int(rect.origin.y))",
      "format": effectiveFormat.rawValue,
      "quality": effectiveQuality.rawValue,
      "fps": "\(effectiveFPS)",
      "purpose": purpose == .audioAdapter ? "audioAdapter" : "screenVideo",
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "microphoneDevice": microphoneDeviceID ?? RecordingMicrophoneDeviceProvider.systemDefaultID,
      "showCursor": "\(effectiveShowCursor)",
      "excludeOwnApp": "\(effectiveExcludeOwnApplication)",
      "excludeDesktopIcons": "\(excludeDesktopIcons)",
      "excludeDesktopWidgets": "\(excludeDesktopWidgets)",
      "excludedWindows": "\(excludedWindowIDs.count)",
      "saveDirectory": saveDirectory.lastPathComponent,
      "processingDirectory": processingDirectory?.lastPathComponent ?? "same-as-final",
    ])

    recordingPurpose = purpose
    videoFormat = effectiveFormat
    videoQuality = effectiveQuality
    self.fps = effectiveFPS
    self.captureSystemAudio = captureSystemAudio
    self.captureMicrophone = captureMicrophone
    self.microphoneDeviceID = microphoneDeviceID
    showCursorInRecording = effectiveShowCursor
    excludeOwnApplicationFromCapture = effectiveExcludeOwnApplication
    excludeDesktopIconsFromCapture = excludeDesktopIcons
    excludeDesktopWidgetsFromCapture = excludeDesktopWidgets
    self.excludedWindowIDs = Set(excludedWindowIDs)
    exceptedWindowIDs.removeAll()

    let captureManager = ScreenCaptureManager.shared
    await captureManager.checkPermission()
    guard captureGenerationGate.isCurrent(generation) else {
      throw RecordingError.cancelled
    }

    if case .notGranted = captureManager.permissionStatus {
      _ = await captureManager.requestPermission()
      guard captureGenerationGate.isCurrent(generation) else {
        throw RecordingError.cancelled
      }
    }

    switch captureManager.permissionStatus {
    case .notGranted:
      DiagnosticLogger.shared.log(.warning, .recording, "Recording permission denied")
      cleanup(generation: generation)
      error = .permissionDenied
      throw RecordingError.permissionDenied
    case .grantedButUnavailableDueToAppIdentity(let reason):
      DiagnosticLogger.shared.log(.warning, .recording, "Recording permission unavailable for app identity", context: [
        "reason": reason,
      ])
      cleanup(generation: generation)
      error = .setupFailed(reason)
      throw RecordingError.setupFailed(reason)
    case .granted:
      break
    }

    // Permission is available; now load shareable content for actual setup.
    let content: SCShareableContent
    do {
      content = try await loadShareableContentForCurrentFilters()
    } catch {
      guard captureGenerationGate.isCurrent(generation) else {
        throw RecordingError.cancelled
      }
      DiagnosticLogger.shared.logError(.recording, error, "Failed to load shareable content for recording")
      let message = L10n.Recording.shareableContentLoadFailed(error.localizedDescription)
      cleanup(generation: generation)
      self.error = .setupFailed(message)
      throw RecordingError.setupFailed(message)
    }
    guard captureGenerationGate.isCurrent(generation) else {
      throw RecordingError.cancelled
    }

    let requestedRect = rect

    // Find the display containing the rect using NSScreen (same coordinate system as input rect)
    // Then get the matching SCDisplay by displayID.
    // When the rect spans multiple displays (e.g. at display boundaries), pick the screen with
    // the largest intersection area so the most-overlapping display wins.
    var targetScreen: NSScreen?
    var bestOverlap: CGFloat = 0
    for screen in NSScreen.screens {
      let intersection = screen.frame.intersection(requestedRect)
      if !intersection.isNull {
        let overlap = intersection.width * intersection.height
        if overlap > bestOverlap {
          bestOverlap = overlap
          targetScreen = screen
        }
      }
    }

    // Get the display ID from NSScreen
    let targetDisplayID: CGDirectDisplayID = if let screen = targetScreen,
                                                let displayID = screen
                                                .deviceDescription[
                                                  NSDeviceDescriptionKey("NSScreenNumber")
                                                ] as? CGDirectDisplayID {
      displayID
    } else {
      CGMainDisplayID()
    }

    DiagnosticLogger.shared.log(.debug, .recording, "Recording display resolved", context: [
      "targetDisplayID": "\(targetDisplayID)",
      "bestOverlap": String(format: "%.0f", bestOverlap),
      "screenCount": "\(NSScreen.screens.count)",
      "requestedRect": "\(Int(requestedRect.origin.x)),\(Int(requestedRect.origin.y)) \(Int(requestedRect.width))x\(Int(requestedRect.height))",
      "usedFallback": "\(targetScreen == nil)",
    ])

    // Find matching SCDisplay
    guard let display = content.displays.first(where: { $0.displayID == Int(targetDisplayID) })
      ?? content.displays.first
    else {
      DiagnosticLogger.shared.log(.error, .recording, "Recording display resolution failed", context: [
        "targetDisplayID": "\(targetDisplayID)",
        "availableDisplays": "\(content.displays.count)",
        "screens": "\(NSScreen.screens.count)",
      ])
      cleanup(generation: generation)
      error = .noDisplayFound
      throw RecordingError.noDisplayFound
    }

    // Get scale factor for Retina from the matching NSScreen
    let scaleFactor: CGFloat = if let screen = targetScreen {
      screen.backingScaleFactor
    } else if let screen = NSScreen.screens.first(where: {
      Int($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)
        == display.displayID
    }) {
      screen.backingScaleFactor
    } else {
      2.0
    }

    var captureGeometry: CaptureGeometry
    do {
      captureGeometry = try resolveCaptureGeometry(
        display: display,
        rect: requestedRect,
        scaleFactor: scaleFactor
      )
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Recording geometry resolution failed", context: [
        "displayID": "\(display.displayID)",
        "scaleFactor": String(format: "%.2f", scaleFactor),
        "requestedRect": "\(Int(requestedRect.width))x\(Int(requestedRect.height))",
      ])
      cleanup(generation: generation)
      throw error
    }

    if purpose == .audioAdapter {
      // Keep the source rectangle selected by the caller, but force the
      // ScreenCaptureKit output dimensions to the adapter's physical carrier
      // size. This also makes the invariant hold on Retina and non-Retina
      // displays regardless of the selection's point dimensions.
      captureGeometry = CaptureGeometry(
        sourceRect: captureGeometry.sourceRect,
        globalCaptureRect: captureGeometry.globalCaptureRect,
        outputWidth: AudioAdapterCaptureCore.outputWidth,
        outputHeight: AudioAdapterCaptureCore.outputHeight
      )
    }
    recordingRect = captureGeometry.globalCaptureRect
    DiagnosticLogger.shared.log(.debug, .recording, "Recording geometry resolved", context: [
      "displayID": "\(display.displayID)",
      "sourceRect": String(
        format: "%.2f,%.2f %.2fx%.2f",
        captureGeometry.sourceRect.origin.x,
        captureGeometry.sourceRect.origin.y,
        captureGeometry.sourceRect.size.width,
        captureGeometry.sourceRect.size.height
      ),
      "outputSize": "\(captureGeometry.outputWidth)x\(captureGeometry.outputHeight)",
    ])

    // Generate the output URL from the user-configurable template with a safe fallback.
    let resolvedFileName = CaptureOutputNaming.resolveBaseName(
      customName: fileName,
      kind: .recording,
      context: context
    )
    exportDirectoryAccess?.stop()
    let directoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(saveDirectory)
    exportDirectoryAccess = directoryAccess

    let scopedSaveDirectory = directoryAccess.url
    let writerDirectory = processingDirectory ?? scopedSaveDirectory
    recordingProcessingDirectory = processingDirectory

    do {
      try FileManager.default.createDirectory(at: scopedSaveDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: writerDirectory, withIntermediateDirectories: true)
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to create recording save directory")
      cleanup(generation: generation)
      self.error = .writeFailed(error.localizedDescription)
      throw RecordingError.writeFailed(error.localizedDescription)
    }

    finalOutputURL = CaptureOutputNaming.makeUniqueFileURL(
      in: scopedSaveDirectory,
      baseName: resolvedFileName,
      fileExtension: effectiveFormat.fileExtension
    )
    if let finalOutputURL {
      do {
        try FileManager.default.createDirectory(
          at: finalOutputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Failed to create recording output subdirectory")
        cleanup(generation: generation)
        self.error = .writeFailed(error.localizedDescription)
        throw RecordingError.writeFailed(error.localizedDescription)
      }
    }
    let writerBaseName = finalOutputURL?.deletingPathExtension().lastPathComponent ?? resolvedFileName
    outputURL = CaptureOutputNaming.makeUniqueFileURL(
      in: writerDirectory,
      baseName: writerBaseName,
      fileExtension: effectiveFormat.fileExtension
    )
    DiagnosticLogger.shared.log(.debug, .recording, "Recording output file prepared", context: [
      "file": finalOutputURL?.lastPathComponent ?? "nil",
      "writerFile": outputURL?.lastPathComponent ?? "nil",
      "processingDirectory": writerDirectory.lastPathComponent,
    ])

    do {
      // Setup AVAssetWriter
      try setupAssetWriter(
        width: captureGeometry.outputWidth,
        height: captureGeometry.outputHeight,
        captureSystemAudio: captureSystemAudio,
        captureMicrophone: captureMicrophone
      )

      try await setupStream(
        display: display,
        captureGeometry: captureGeometry,
        captureSystemAudio: captureSystemAudio,
        captureMicrophone: captureMicrophone,
        content: content,
        generation: generation
      )
      guard captureGenerationGate.isCurrent(generation) else {
        throw RecordingError.cancelled
      }

      // Setup independent microphone capture if requested
      if captureMicrophone {
        let capturer = MicrophoneAudioCapturer(preferredDeviceID: microphoneDeviceID)
        capturer.delegate = self
        captureGenerationGate.bind(microphone: capturer, generation: generation)
        microphoneCapturer = capturer
      }

      if purpose == .screenVideo {
        mouseTracker = RecordingMouseTracker(recordingRect: captureGeometry.globalCaptureRect, fps: fps)
      } else {
        mouseTracker = nil
      }
      DiagnosticLogger.shared.log(.info, .recording, "Recording prepare completed", context: [
        "file": outputURL?.lastPathComponent ?? "nil",
        "outputSize": "\(captureGeometry.outputWidth)x\(captureGeometry.outputHeight)",
      ])
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Recording preparation failed", context: [
        "stage": "writer-or-stream",
      ])
      let failure = (error as? RecordingError)
        ?? (Task.isCancelled ? RecordingError.cancelled : .setupFailed(error.localizedDescription))
      await teardownFailedStart(generation: generation, failure: failure)
      throw error
    }
  }

  /// Start the recording
  func startRecording() async throws {
    guard state == .preparing else {
      DiagnosticLogger.shared.log(.debug, .recording, "startRecording blocked: recorder not prepared", context: [
        "state": "\(state)",
      ])
      throw RecordingError.alreadyActive
    }

    guard let generation = captureGenerationGate.current() else {
      cleanup()
      throw RecordingError.cancelled
    }

    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ),
    captureGenerationGate.isHealthy(generation),
    !session.hasStreamFailure(generation: generation)
    else {
      await teardownFailedStart(generation: generation, failure: .cancelled)
      throw RecordingError.cancelled
    }

    DiagnosticLogger.shared.log(.debug, .recording, "Recording writer start requested")
    session.assetWriter?.startWriting()

    // Validate writer status
    guard session.assetWriter?.status == .writing else {
      let errorMsg = session.assetWriter?.error?.localizedDescription ?? L10n.Recording.failedToStartWriting
      if let writerError = session.assetWriter?.error {
        DiagnosticLogger.shared.logError(.recording, writerError, "Recording writer failed to start")
      } else {
        DiagnosticLogger.shared.log(.error, .recording, "Recording writer failed to start", context: [
          "writerStatus": "\(session.assetWriter?.status.rawValue ?? -1)",
        ])
      }
      let failure = RecordingError.setupFailed(errorMsg)
      await teardownFailedStart(generation: generation, failure: failure)
      throw failure
    }

    // Session will start lazily when first sample buffer arrives
    // This ensures timestamp synchronization with SCStream

    guard captureGenerationGate.isHealthy(generation),
          !session.hasStreamFailure(generation: generation),
          state == .preparing
    else {
      await teardownFailedStart(generation: generation, failure: .cancelled)
      throw RecordingError.cancelled
    }

    session.isCapturing = true
    session.setOnFirstVideoFrame(generation: generation) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self,
              self.captureGenerationGate.isHealthy(generation),
              !self.session.hasStreamFailure(generation: generation)
        else { return }
        self.mouseTracker?.start()
      }
    }

    do {
      guard let activeStream = streamsByGeneration[generation] else {
        throw RecordingError.setupFailed(L10n.Recording.failedToStartWriting)
      }
      try await activeStream.startCapture()
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to start stream capture")
      let failure = (error as? RecordingError)
        ?? RecordingError.setupFailed(error.localizedDescription)
      await teardownFailedStart(generation: generation, failure: failure)
      throw failure
    }

    if Task.isCancelled {
      await teardownFailedStart(generation: generation, failure: .cancelled)
      throw RecordingError.cancelled
    }

    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ),
    captureGenerationGate.isHealthy(generation),
    !session.hasStreamFailure(generation: generation),
    state == .preparing
    else {
      await teardownFailedStart(generation: generation, failure: .cancelled)
      throw RecordingError.cancelled
    }

    if recordingPurpose == .audioAdapter {
      // A tiny adapter recording is not considered started until ScreenCaptureKit
      // has delivered its first complete video sample. This prevents microphone
      // timestamps and user-visible state/timing from getting ahead of the
      // writer's source-time anchor.
      let firstFrameReady = await waitForAudioAdapterFirstVideoFrame(generation: generation)
      let canCompleteAdapterStart = RecordingCaptureLifecyclePolicy.canEnterRecording(
        capturedGeneration: generation,
        currentGeneration: captureGenerationGate.current(),
        sessionGenerationIsCurrent: session.isCurrentGeneration(generation),
        state: state,
        firstVideoFrameReady: firstFrameReady && session.firstVideoFrameReady,
        streamFailed: !captureGenerationGate.isHealthy(generation) || session.hasStreamFailure(generation: generation)
      )
      guard canCompleteAdapterStart else {
        let failure: RecordingError = Task.isCancelled
          ? .cancelled
          : .setupFailed(L10n.Recording.failedToStartWriting)
        await teardownFailedStart(generation: generation, failure: failure)
        throw failure
      }

      // This is the atomic health-check/one-shot claim.  didStopWithError
      // marks the generation failed under the same gate lock; if it wins
      // first, this claim fails.  Once claimed, do not await or re-check
      // health before the microphone/state/timer transition: a later failure
      // is an active failure event for the coordinator to stop and preserve.
      guard captureGenerationGate.claimAdapterRecordingStart(generation) else {
        await teardownFailedStart(generation: generation, failure: .cancelled)
        throw RecordingError.cancelled
      }

      // Start the independent microphone only after the first video frame has
      // anchored the writer timeline. State and the user timer follow it too.
      microphoneCapturer?.start()
      state = .recording
      DiagnosticLogger.shared.log(.info, .recording, "Audio adapter recording started", context: [
        "rect": "\(Int(recordingRect.width))x\(Int(recordingRect.height))",
        "fps": "\(fps)",
        "format": videoFormat.rawValue,
        "systemAudio": "\(captureSystemAudio)",
        "microphone": "\(captureMicrophone)",
      ])
      startTime = Date()
      elapsedSeconds = 0
      pausedDuration = 0
      startTimer()
      return
    }

    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ),
    captureGenerationGate.isHealthy(generation),
    !session.hasStreamFailure(generation: generation),
    state == .preparing
    else {
      await teardownFailedStart(generation: generation, failure: .cancelled)
      throw RecordingError.cancelled
    }

    // Start independent microphone capture
    microphoneCapturer?.start()

    state = .recording
    DiagnosticLogger.shared.log(.info, .recording, "Recording started", context: [
      "rect": "\(Int(recordingRect.width))x\(Int(recordingRect.height))",
      "fps": "\(fps)",
      "format": videoFormat.rawValue,
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "microphoneDevice": microphoneDeviceID ?? RecordingMicrophoneDeviceProvider.systemDefaultID,
    ])
    startTime = Date()
    elapsedSeconds = 0
    pausedDuration = 0
    startTimer()
  }

  /// Pause the recording
  func pauseRecording() {
    guard state == .recording else {
      DiagnosticLogger.shared.log(.debug, .recording, "pauseRecording ignored", context: ["state": "\(state)"])
      return
    }
    session.isCapturing = false
    mouseTracker?.pause()
    audioLevelMeter.freeze()
    pauseStartTime = Date()
    state = .paused
    DiagnosticLogger.shared.log(.info, .recording, "Recording paused")
  }

  /// Resume the recording
  func resumeRecording() {
    guard state == .paused, let pauseStart = pauseStartTime else {
      DiagnosticLogger.shared.log(.debug, .recording, "resumeRecording ignored", context: ["state": "\(state)"])
      return
    }
    pausedDuration += Date().timeIntervalSince(pauseStart)
    pauseStartTime = nil

    // Set accumulated pause offset in CoreMedia time before resuming capture
    let offset = CMTime(seconds: pausedDuration, preferredTimescale: 1_000_000)
    session.setAccumulatedPauseOffset(offset)

    session.isCapturing = true
    mouseTracker?.resume()
    audioLevelMeter.unfreeze()
    state = .recording
    DiagnosticLogger.shared.log(.info, .recording, "Recording resumed", context: [
      "pauseOffsetSeconds": String(format: "%.3f", pausedDuration),
    ])
  }

  /// Toggle pause/resume
  func togglePause() {
    if state == .recording {
      pauseRecording()
    } else if state == .paused {
      resumeRecording()
    }
  }

  func addRuntimeExcludedWindow(windowID: CGWindowID) async {
    guard state != .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion ignored: recorder idle", context: [
        "windowID": "\(windowID)",
      ])
      return
    }
    guard excludedWindowIDs.insert(windowID).inserted else {
      DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion already present", context: [
        "windowID": "\(windowID)",
      ])
      return
    }
    guard let activeStream = stream else {
      DiagnosticLogger.shared.log(.warning, .recording, "Runtime window exclusion skipped: no active stream", context: [
        "windowID": "\(windowID)",
        "state": "\(state)",
      ])
      return
    }
    DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion added", context: [
      "windowID": "\(windowID)",
      "excludedWindows": "\(excludedWindowIDs.count)",
    ])
    await updateContentFilter(for: activeStream)
  }

  func removeRuntimeExcludedWindow(windowID: CGWindowID) async {
    guard state != .idle else {
      DiagnosticLogger.shared.log(
        .debug,
        .recording,
        "Runtime window exclusion removal ignored: recorder idle",
        context: [
          "windowID": "\(windowID)",
        ]
      )
      return
    }
    guard excludedWindowIDs.remove(windowID) != nil else {
      DiagnosticLogger.shared.log(
        .debug,
        .recording,
        "Runtime window exclusion removal skipped: unknown window",
        context: [
          "windowID": "\(windowID)",
        ]
      )
      return
    }
    guard let activeStream = stream else {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Runtime window exclusion removal skipped: no active stream",
        context: [
          "windowID": "\(windowID)",
          "state": "\(state)",
        ]
      )
      return
    }
    DiagnosticLogger.shared.log(.debug, .recording, "Runtime window exclusion removed", context: [
      "windowID": "\(windowID)",
      "excludedWindows": "\(excludedWindowIDs.count)",
    ])
    await updateContentFilter(for: activeStream)
  }

  /// Stop the recording and save the file
  func stopRecording() async -> URL? {
    let requestedState = state
    guard let generation = captureGenerationGate.current(),
          RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
            capturedGeneration: generation,
            currentGeneration: captureGenerationGate.current(),
            sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
          ),
          claimTeardown(generation: generation, operation: .stop)
    else {
      DiagnosticLogger.shared.log(.debug, .recording, "stopRecording ignored", context: [
        "state": "\(state)",
        "teardownOwner": "\(String(describing: teardownOwner))",
      ])
      return nil
    }
    let owner = RecordingTeardownOwner(generation: generation, operation: .stop)
    defer {
      cleanup(generation: generation, owner: owner)
      releaseTeardown(owner)
    }

    DiagnosticLogger.shared.log(.info, .recording, "Recording stop requested", context: [
      "state": "\(requestedState)",
      "elapsedSeconds": "\(elapsedSeconds)",
      "outputFile": outputURL?.lastPathComponent ?? "nil",
    ])

    // Snapshot every value used after an await. A stop belongs to this
    // generation even if a stale task is resumed after a later preparation.
    let isAudioAdapter = recordingPurpose == .audioAdapter
    let stopVideoFormat = videoFormat
    let stopCaptureSystemAudio = captureSystemAudio
    let stopCaptureMicrophone = captureMicrophone
    let stopRecordingRect = recordingRect
    let stopFPS = fps
    let stopElapsedSeconds = elapsedSeconds
    let stopFinalOutputURL = finalOutputURL
    let writerURL = outputURL
    let stopAudioTrackVolumes = configuredAudioTrackVolumes
    let mouseSamples = isAudioAdapter ? [] : (mouseTracker?.stop() ?? [])
    let mouseSamplesPerSecond = mouseTracker?.samplesPerSecond ?? stopFPS
    let mouseDiagnostics = mouseTracker?.diagnostics

    session.isCapturing = false
    session.setOnFirstVideoFrame(generation: generation, nil)

    timer?.invalidate()
    timer = nil

    if let activeStream = streamsByGeneration[generation] {
      await teardownStream(activeStream, generation: generation)
    }
    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ) else {
      return nil
    }

    microphoneCapturer?.stop()

    session.finishInputs()

    await session.finishWriting()
    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ) else {
      return nil
    }

    let videoWriteStats = session.videoWriteStats()

    await logRecordingFrameDiagnostics(outputURL: writerURL, stats: videoWriteStats, configuredFPS: stopFPS)
    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ) else {
      return nil
    }

    let audioNormalization = if isAudioAdapter {
      // The adapter deliberately exposes the writer's original separate audio
      // tracks. Do not invoke the compatibility exporter or create an editor
      // audio-source sidecar for this internal MOV.
      RecordingAudioNormalizationResult(outputURL: writerURL, audioSourceURL: nil)
    } else {
      await normalizeRecordingAudioForCompatibilityIfNeeded(
        writerURL: writerURL,
        fileType: stopVideoFormat.fileType,
        audioTrackVolumes: stopAudioTrackVolumes
      )
    }
    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ) else {
      return nil
    }
    let editorAudioSourceURL = isAudioAdapter
      ? nil
      : storeRecordingAudioSourceIfNeeded(audioNormalization.audioSourceURL)
    let url: URL?
    if isAudioAdapter {
      // The adapter's processing directory is caller-owned (the tiny-region
      // session directory). Return the writer's original MOV and leave that
      // directory intact; moving/exporting it would either alter the internal
      // artifact or let generic processing cleanup delete the caller's file.
      url = audioNormalization.outputURL
      recordingProcessingDirectory = nil
    } else {
      url = finalizeRecordingOutput(
        writerURL: audioNormalization.outputURL,
        proposedFinalURL: stopFinalOutputURL
      )
    }
    outputURL = url
    if let url {
      if !isAudioAdapter {
        let audioSourceTrackRoles = editorAudioSourceURL == nil ? [] : RecordingAudioSourceTrackRole.roles(
          capturesSystemAudio: stopCaptureSystemAudio,
          capturesMicrophone: stopCaptureMicrophone
        )
        let audioSourceTracks = await recordingAudioSourceTracks(
          for: editorAudioSourceURL,
          roles: audioSourceTrackRoles
        )
        guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
          capturedGeneration: generation,
          currentGeneration: captureGenerationGate.current(),
          sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
        ) else {
          return nil
        }
        if mouseSamples.count >= 2 || editorAudioSourceURL != nil {
          do {
            let metadata = RecordingMetadata(
              coordinateSpace: .topLeftNormalized,
              captureSize: stopRecordingRect.size,
              samplesPerSecond: mouseSamplesPerSecond,
              mouseSamples: mouseSamples,
              audioSourceURL: editorAudioSourceURL,
              audioSourceTrackRoles: audioSourceTrackRoles,
              audioSourceTracks: audioSourceTracks
            )
            try RecordingMetadataStore.save(metadata, for: url)
            DiagnosticLogger.shared.log(.info, .recording, "Recording metadata saved", context: [
              "file": url.lastPathComponent,
              "samples": "\(mouseSamples.count)",
              "hasEditorAudioSource": editorAudioSourceURL == nil ? "false" : "true",
              "editorAudioSourceRoles": audioSourceTrackRoles.map(\.rawValue).joined(separator: ","),
              "editorAudioSourceTrackIDs": audioSourceTracks.map { "\($0.trackID):\($0.role.rawValue)" }
                .joined(separator: ","),
            ])
          } catch {
            DiagnosticLogger.shared.logError(.recording, error, "Failed to save recording metadata")
            deleteStoredRecordingAudioSourceIfUnused(editorAudioSourceURL)
          }
        } else {
          DiagnosticLogger.shared.log(.debug, .recording, "Recording metadata skipped", context: [
            "samples": "\(mouseSamples.count)",
          ])
        }
        if let diagnostics = mouseDiagnostics {
          DiagnosticLogger.shared.log(.info, .recording, "Mouse tracking diagnostics", context: [
            "samples": "\(diagnostics.sampleCount)",
            "durationSeconds": String(format: "%.3f", diagnostics.duration),
            "effectiveSamplesPerSecond": String(format: "%.2f", diagnostics.effectiveSamplesPerSecond),
            "averageIntervalMs": String(format: "%.2f", diagnostics.averageIntervalMs),
            "p95IntervalMs": String(format: "%.2f", diagnostics.p95IntervalMs),
          ])
        }
      }
      DiagnosticLogger.shared.log(.info, .recording, "Recording stopped: \(url.lastPathComponent) (\(stopElapsedSeconds)s)")
    } else {
      if !isAudioAdapter {
        deleteStoredRecordingAudioSourceIfUnused(editorAudioSourceURL)
      }
      DiagnosticLogger.shared.log(.error, .recording, "Recording stopped without output URL")
    }

    // Reset state
    cleanup(generation: generation)

    return url
  }

  /// Cancel the recording without saving
  @discardableResult
  func cancelRecording(moveOutputToTrash: Bool = false) async -> RecordingCancellationOutcome {
    let requestedState = state
    guard let generation = captureGenerationGate.current(),
          RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
            capturedGeneration: generation,
            currentGeneration: captureGenerationGate.current(),
            sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
          ),
          claimTeardown(generation: generation, operation: .cancel)
    else {
      DiagnosticLogger.shared.log(.debug, .recording, "cancelRecording ignored", context: [
        "state": "\(state)",
        "teardownOwner": "\(String(describing: teardownOwner))",
      ])
      return .noOutput
    }
    let owner = RecordingTeardownOwner(generation: generation, operation: .cancel)
    defer {
      cleanup(generation: generation, owner: owner)
      releaseTeardown(owner)
    }

    DiagnosticLogger.shared.log(.info, .recording, "Recording cancel requested", context: [
      "state": "\(requestedState)",
      "outputFile": outputURL?.lastPathComponent ?? "nil",
    ])

    let cancellationOutputURL = outputURL

    session.isCapturing = false
    session.cancelFirstVideoFrameWait(generation: generation)
    session.setOnFirstVideoFrame(generation: generation, nil)

    timer?.invalidate()
    timer = nil

    if let activeStream = streamsByGeneration[generation] {
      await teardownStream(activeStream, generation: generation)
    }
    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ) else {
      return .noOutput
    }

    microphoneCapturer?.stop()
    session.cancelWriting()
    mouseTracker?.reset()
    DiagnosticLogger.shared.log(.info, .recording, "Recording cancelled")
    if let url = cancellationOutputURL {
      guard FileManager.default.fileExists(atPath: url.path) else {
        DiagnosticLogger.shared.log(.debug, .recording, "Cancelled recording output was not created", context: [
          "file": url.lastPathComponent,
        ])
        cleanup(generation: generation)
        return .noOutput
      }
      do {
        if moveOutputToTrash {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
          try FileManager.default.removeItem(at: url)
        }
        DiagnosticLogger.shared.log(.debug, .recording, "Cancelled recording output disposed", context: [
          "file": url.lastPathComponent,
          "destination": moveOutputToTrash ? "trash" : "removed",
        ])
        cleanup(generation: generation)
        return .disposed
      } catch {
        shouldPreserveProcessingOutputOnCleanup = true
        DiagnosticLogger.shared.logError(.recording, error, "Failed to dispose cancelled recording output", context: [
          "file": url.lastPathComponent,
          "destination": moveOutputToTrash ? "trash" : "removed",
        ])
        cleanup(generation: generation)
        return .preserved(url)
      }
    }

    cleanup(generation: generation)
    return .noOutput
  }

  // MARK: - Private Methods

  private func normalizeRecordingAudioForCompatibilityIfNeeded(
    writerURL: URL?,
    fileType: AVFileType,
    audioTrackVolumes: [Float]
  ) async -> RecordingAudioNormalizationResult {
    guard let writerURL else {
      return RecordingAudioNormalizationResult(outputURL: nil, audioSourceURL: nil)
    }

    do {
      let result = try await RecordingAudioCompatibilityExporter.normalizeIfNeeded(
        at: writerURL,
        fileType: fileType,
        appliesMixdownHeadroom: true,
        audioTrackVolumes: audioTrackVolumes
      )
      if result.didNormalize {
        DiagnosticLogger.shared.log(.info, .recording, "Recording audio normalized for compatibility", context: [
          "file": writerURL.lastPathComponent,
          "sourceAudioTracks": "\(result.audioTrackCount)",
          "outputAudioTracks": "1",
          "audioCodec": "aac-lc",
          "sampleRate": "\(RecordingAudioEncodingSettings.sampleRate)",
          "channels": "\(RecordingAudioEncodingSettings.channelCount)",
          "mixdownInputVolume": String(
            format: "%.3f",
            RecordingAudioCompatibilityExporter.mixdownInputVolume(audioTrackCount: result.audioTrackCount)
          ),
          "editorAudioSource": result.audioSourceURL?.lastPathComponent ?? "nil",
        ])
      } else {
        DiagnosticLogger.shared.log(.debug, .recording, "Recording audio normalization skipped", context: [
          "file": writerURL.lastPathComponent,
          "audioTracks": "\(result.audioTrackCount)",
        ])
      }
      return RecordingAudioNormalizationResult(
        outputURL: result.outputURL,
        audioSourceURL: result.audioSourceURL
      )
    } catch {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Recording audio normalization failed; preserving original file",
        context: [
          "file": writerURL.lastPathComponent,
          "error": error.localizedDescription,
        ]
      )
      return RecordingAudioNormalizationResult(outputURL: writerURL, audioSourceURL: nil)
    }
  }

  private var configuredAudioTrackVolumes: [Float] {
    func value(forKey key: String) -> Float {
      let stored = UserDefaults.standard.object(forKey: key) as? Double ?? 0.8
      return Float(min(max(stored, 0), 1))
    }

    var volumes: [Float] = []
    if captureSystemAudio {
      volumes.append(value(forKey: PreferencesKeys.recordingSystemAudioVolume))
    }
    if captureMicrophone {
      volumes.append(value(forKey: PreferencesKeys.recordingMicrophoneVolume))
    }
    return volumes
  }

  private func storeRecordingAudioSourceIfNeeded(_ sourceURL: URL?) -> URL? {
    guard let sourceURL else { return nil }
    defer {
      try? FileManager.default.removeItem(at: sourceURL)
    }

    do {
      let storedURL = try RecordingMetadataStore.storeAudioSource(from: sourceURL)
      DiagnosticLogger.shared.log(.info, .recording, "Stored editor audio source", context: [
        "file": storedURL.lastPathComponent,
      ])
      return storedURL
    } catch {
      DiagnosticLogger.shared.log(.warning, .recording, "Failed to store editor audio source", context: [
        "file": sourceURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
      return nil
    }
  }

  private func deleteStoredRecordingAudioSourceIfUnused(_ sourceURL: URL?) {
    guard let sourceURL else { return }
    do {
      try FileManager.default.removeItem(at: sourceURL)
      DiagnosticLogger.shared.log(.debug, .recording, "Removed unused editor audio source", context: [
        "file": sourceURL.lastPathComponent,
      ])
    } catch {
      DiagnosticLogger.shared.log(.warning, .recording, "Failed to remove unused editor audio source", context: [
        "file": sourceURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
    }
  }

  private func recordingAudioSourceTracks(
    for sourceURL: URL?,
    roles: [RecordingAudioSourceTrackRole]
  ) async -> [RecordingAudioSourceTrack] {
    guard let sourceURL, !roles.isEmpty else { return [] }

    do {
      let asset = AVURLAsset(url: sourceURL)
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        .sorted { $0.trackID < $1.trackID }
      guard audioTracks.count == roles.count else {
        DiagnosticLogger.shared.log(.warning, .recording, "Editor audio source role count mismatch", context: [
          "file": sourceURL.lastPathComponent,
          "audioTracks": "\(audioTracks.count)",
          "roles": "\(roles.count)",
        ])
        return []
      }

      return zip(audioTracks, roles).map { track, role in
        RecordingAudioSourceTrack(trackID: Int(track.trackID), role: role)
      }
    } catch {
      DiagnosticLogger.shared.log(.warning, .recording, "Failed to inspect editor audio source tracks", context: [
        "file": sourceURL.lastPathComponent,
        "error": error.localizedDescription,
      ])
      return []
    }
  }

  private func finalizeRecordingOutput(writerURL: URL?, proposedFinalURL: URL?) -> URL? {
    guard let writerURL else { return nil }

    guard FileManager.default.fileExists(atPath: writerURL.path) else {
      DiagnosticLogger.shared.log(
        .error,
        .recording,
        "Recording writer output missing before final move",
        context: ["file": writerURL.lastPathComponent]
      )
      cleanupRecordingProcessingDirectoryIfNeeded()
      return nil
    }

    guard let proposedFinalURL else {
      cleanupRecordingProcessingDirectoryIfNeeded()
      return writerURL
    }

    if sameFilePath(writerURL, proposedFinalURL) {
      cleanupRecordingProcessingDirectoryIfNeeded()
      return writerURL
    }

    do {
      let movedURL = try moveRecordingOutput(from: writerURL, to: proposedFinalURL)
      cleanupRecordingProcessingDirectoryIfNeeded()
      DiagnosticLogger.shared.log(.info, .recording, "Recording output moved to final directory", context: [
        "file": movedURL.lastPathComponent,
        "processingDirectory": writerURL.deletingLastPathComponent().lastPathComponent,
        "finalDirectory": movedURL.deletingLastPathComponent().lastPathComponent,
      ])
      return movedURL
    } catch {
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Recording final move failed; attempting temp recovery",
        context: ["file": writerURL.lastPathComponent]
      )
    }

    let recoveredURL = TempCaptureManager.shared.makeRecoveredRecordingURL(for: writerURL)
    do {
      let movedURL = try moveRecordingOutput(from: writerURL, to: recoveredURL)
      cleanupRecordingProcessingDirectoryIfNeeded()
      DiagnosticLogger.shared.log(.info, .recording, "Recording output recovered to temp captures", context: [
        "file": movedURL.lastPathComponent,
      ])
      return movedURL
    } catch {
      shouldPreserveProcessingOutputOnCleanup = true
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        "Recording temp recovery failed; preserving writer output",
        context: ["file": writerURL.lastPathComponent]
      )
      return writerURL
    }
  }

  private func moveRecordingOutput(from sourceURL: URL, to proposedDestinationURL: URL) throws -> URL {
    let destinationURL = uniqueDestinationURL(for: proposedDestinationURL)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func uniqueDestinationURL(for proposedURL: URL) -> URL {
    guard FileManager.default.fileExists(atPath: proposedURL.path) else {
      return proposedURL
    }

    let directory = proposedURL.deletingLastPathComponent()
    let fileExtension = proposedURL.pathExtension
    let baseName = proposedURL.deletingPathExtension().lastPathComponent
    return CaptureOutputNaming.makeUniqueFileURL(
      in: directory,
      baseName: baseName,
      fileExtension: fileExtension
    )
  }

  private func cleanupRecordingProcessingDirectoryIfNeeded() {
    guard let directory = recordingProcessingDirectory else { return }
    defer {
      recordingProcessingDirectory = nil
      shouldPreserveProcessingOutputOnCleanup = false
    }

    if shouldPreserveProcessingOutputOnCleanup,
       let outputURL,
       isURL(outputURL, inside: directory),
       FileManager.default.fileExists(atPath: outputURL.path) {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Recording processing directory preserved because final output still lives there",
        context: ["file": outputURL.lastPathComponent]
      )
      return
    }

    TempCaptureManager.shared.deleteRecordingProcessingDirectory(directory)
  }

  private func sameFilePath(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
      == rhs.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func isURL(_ url: URL, inside directory: URL) -> Bool {
    let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
    let urlPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    return urlPath.hasPrefix(directoryPath + "/")
  }

  private func setupAssetWriter(width: Int, height: Int, captureSystemAudio: Bool, captureMicrophone: Bool) throws {
    guard let url = outputURL else {
      DiagnosticLogger.shared.log(.error, .recording, "Asset writer setup failed: missing output URL")
      throw RecordingError.setupFailed(L10n.Recording.noOutputURL)
    }

    // Remove existing file if any
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Failed to remove existing recording output", context: [
          "file": url.lastPathComponent,
        ])
      }
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: videoFormat.fileType)
    writer.shouldOptimizeForNetworkUse = videoFormat == .mp4
    session.assetWriter = writer
    session.configureExpectedVideoDimensions(
      width: width,
      height: height,
      requiresExact: recordingPurpose == .audioAdapter
    )

    let isAudioAdapter = recordingPurpose == .audioAdapter
    var selectedCodec = isAudioAdapter ? AVVideoCodecType.h264 : preferredVideoCodec()
    var selectedBitrate = calculatedVideoBitrate(width: width, height: height, codec: selectedCodec)
    var videoSettings = isAudioAdapter
      ? AudioAdapterCaptureCore.makeVideoSettings()
      : makeVideoSettings(
        width: width,
        height: height,
        codec: selectedCodec,
        bitrate: selectedBitrate
      )

    var videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    // If HEVC cannot be added (unsupported path), fallback to H.264.
    if !isAudioAdapter, !writer.canAdd(videoIn), selectedCodec == .hevc {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "HEVC writer input unavailable; falling back to H.264",
        context: [
          "outputSize": "\(width)x\(height)",
          "format": videoFormat.rawValue,
        ]
      )
      selectedCodec = .h264
      selectedBitrate = calculatedVideoBitrate(width: width, height: height, codec: selectedCodec)
      videoSettings = makeVideoSettings(
        width: width,
        height: height,
        codec: selectedCodec,
        bitrate: selectedBitrate
      )
      videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    }

    guard writer.canAdd(videoIn) else {
      DiagnosticLogger.shared.log(.error, .recording, "Cannot add recording video writer input", context: [
        "outputSize": "\(width)x\(height)",
        "format": videoFormat.rawValue,
      ])
      throw RecordingError.setupFailed(L10n.Recording.cannotAddVideoWriterInput)
    }

    videoIn.expectsMediaDataInRealTime = true
    session.videoInput = videoIn
    writer.add(videoIn)
    DiagnosticLogger.shared.log(.info, .recording, "Video encoding settings", context: [
      "codec": selectedCodec == .hevc ? "hevc" : "h264",
      "qualityPreset": videoQuality.rawValue,
      "bitrateBps": "\(selectedBitrate)",
      "fps": "\(fps)",
      "outputSize": "\(width)x\(height)",
    ])

    // Create pixel buffer adaptor for BGRA input from ScreenCaptureKit
    let sourcePixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoIn,
      sourcePixelBufferAttributes: sourcePixelBufferAttributes
    )
    session.pixelBufferAdaptor = adaptor

    // Audio settings (AAC) for system audio
    if captureSystemAudio {
      let audioSettings = RecordingAudioEncodingSettings.makeSystemAudioSettings()
      let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audioIn.expectsMediaDataInRealTime = true
      guard writer.canAdd(audioIn) else {
        DiagnosticLogger.shared.log(.error, .recording, "Cannot add system audio writer input")
        throw RecordingError.setupFailed(L10n.Recording.cannotAddSystemAudioWriterInput)
      }
      // Track-level metadata is assigned before startWriting so AVAssetWriter
      // serializes the role into the audio track's mdta atom. Keep this on the
      // shared screen-writer path: ordinary screen recordings retain the same
      // AAC settings and gain only a harmless, correctly-scoped role label.
      audioIn.metadata = try RecordingAudioTrackRoleMetadata.items(for: .system)
      session.audioInput = audioIn
      writer.add(audioIn)
    }

    // Microphone audio settings (AAC) - separate track
    if captureMicrophone {
      let micSettings = RecordingAudioEncodingSettings.makeMicrophoneAudioSettings()
      let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
      micIn.expectsMediaDataInRealTime = true
      guard writer.canAdd(micIn) else {
        DiagnosticLogger.shared.log(.error, .recording, "Cannot add microphone writer input")
        throw RecordingError.setupFailed(L10n.Recording.cannotAddMicrophoneWriterInput)
      }
      // See the system-audio input above. The role is carried by this track,
      // never inferred from the order in which AVAsset exposes tracks.
      micIn.metadata = try RecordingAudioTrackRoleMetadata.items(for: .microphone)
      session.microphoneInput = micIn
      writer.add(micIn)
    }
  }

  private func preferredVideoCodec() -> AVVideoCodecType {
    let selected = UserDefaults.standard.string(forKey: PreferencesKeys.recordingVideoCodec)?.lowercased()
    return selected == "hevc" ? .hevc : .h264
  }

  private func calculatedVideoBitrate(width: Int, height: Int, codec: AVVideoCodecType) -> Int {
    if recordingPurpose == .audioAdapter {
      return AudioAdapterCaptureCore.videoBitrate(width: width, height: height, fps: fps)
    }
    return RecordingVideoEncodingSettings.calculatedBitrate(
      width: width,
      height: height,
      fps: fps,
      quality: videoQuality,
      codec: codec
    )
  }

  private func makeVideoSettings(
    width: Int,
    height: Int,
    codec: AVVideoCodecType,
    bitrate: Int
  ) -> [String: Any] {
    RecordingVideoEncodingSettings.makeVideoSettings(
      width: width,
      height: height,
      fps: fps,
      quality: videoQuality,
      codec: codec,
      bitrate: bitrate
    )
  }

  private func resolveCaptureGeometry(
    display: SCDisplay,
    rect: CGRect,
    scaleFactor: CGFloat
  ) throws -> CaptureGeometry {
    guard let matchingScreen = NSScreen.screens.first(where: {
      Int($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)
        == display.displayID
    }) else {
      DiagnosticLogger.shared.log(.error, .recording, "Recording geometry failed: no matching NSScreen", context: [
        "displayID": "\(display.displayID)",
        "screens": "\(NSScreen.screens.count)",
      ])
      throw RecordingError.noDisplayFound
    }

    let screenFrame = matchingScreen.frame
    let relativeRect = CGRect(
      x: rect.origin.x - screenFrame.origin.x,
      y: rect.origin.y - screenFrame.origin.y,
      width: rect.width,
      height: rect.height
    )

    let screenBounds = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
    let clampedRect = relativeRect.intersection(screenBounds)
    guard !clampedRect.isEmpty else {
      DiagnosticLogger.shared.log(
        .error,
        .recording,
        "Recording geometry failed: selection outside display bounds",
        context: [
          "displayID": "\(display.displayID)",
          "relativeRect": "\(Int(relativeRect.width))x\(Int(relativeRect.height))",
          "screenBounds": "\(Int(screenBounds.width))x\(Int(screenBounds.height))",
        ]
      )
      throw RecordingError.setupFailed(L10n.Recording.selectionOutsideDisplayBounds)
    }

    let alignedRect = pixelAlignedRect(clampedRect, scaleFactor: scaleFactor, bounds: screenBounds)
    guard !alignedRect.isEmpty else {
      DiagnosticLogger.shared.log(.error, .recording, "Recording geometry failed: pixel-aligned rect empty", context: [
        "displayID": "\(display.displayID)",
        "scaleFactor": String(format: "%.2f", scaleFactor),
      ])
      throw RecordingError.setupFailed(L10n.Recording.selectionOutsideDisplayBounds)
    }

    // ScreenCaptureKit sourceRect uses top-left origin relative to display.
    let flippedY = screenFrame.height - alignedRect.origin.y - alignedRect.height
    let sourceRect = CGRect(
      x: alignedRect.origin.x,
      y: flippedY,
      width: alignedRect.width,
      height: alignedRect.height
    )
    let globalCaptureRect = CGRect(
      x: alignedRect.origin.x + screenFrame.origin.x,
      y: alignedRect.origin.y + screenFrame.origin.y,
      width: alignedRect.width,
      height: alignedRect.height
    )

    return CaptureGeometry(
      sourceRect: sourceRect,
      globalCaptureRect: globalCaptureRect,
      outputWidth: max(1, Int((alignedRect.width * scaleFactor).rounded())),
      outputHeight: max(1, Int((alignedRect.height * scaleFactor).rounded()))
    )
  }

  private func pixelAlignedRect(_ rect: CGRect, scaleFactor: CGFloat, bounds: CGRect) -> CGRect {
    guard scaleFactor > 0 else { return rect.intersection(bounds) }

    let minX = floor(rect.minX * scaleFactor) / scaleFactor
    let minY = floor(rect.minY * scaleFactor) / scaleFactor
    let maxX = ceil(rect.maxX * scaleFactor) / scaleFactor
    let maxY = ceil(rect.maxY * scaleFactor) / scaleFactor

    let aligned = CGRect(
      x: minX,
      y: minY,
      width: max(0, maxX - minX),
      height: max(0, maxY - minY)
    )

    return aligned.intersection(bounds)
  }

  private func setupStream(
    display: SCDisplay,
    captureGeometry: CaptureGeometry,
    captureSystemAudio: Bool,
    captureMicrophone: Bool,
    content: SCShareableContent,
    generation: UInt64
  ) async throws {
    let filter = makeContentFilter(display: display, content: content)

    let config = SCStreamConfiguration()
    // Higher queue depth helps absorb transient encoder backpressure at 60 FPS.
    config.queueDepth = fps >= 60 ? 8 : 5
    config.width = captureGeometry.outputWidth
    config.height = captureGeometry.outputHeight
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = showCursorInRecording
    config.sourceRect = captureGeometry.sourceRect
    let captureResolutionMode: String
    if recordingPurpose == .audioAdapter, #available(macOS 14.0, *) {
      // `.nominal` honors the explicit 32x32 dimensions instead of promoting
      // this tiny carrier to the display's native resolution.
      config.captureResolution = .nominal
      captureResolutionMode = "nominal"
    } else if #available(macOS 14.2, *) {
      config.captureResolution = .best
      captureResolutionMode = "best"
    } else {
      // Fallback for macOS 13/14.0/14.1:
      // rely on explicit native-scaled dimensions + pixel-aligned sourceRect.
      captureResolutionMode = "fallback-native-dimensions"
    }

    // System audio configuration
    if captureSystemAudio {
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true
      config.sampleRate = 48000
      config.channelCount = 2
    }

    // Microphone permission check (captured independently via MicrophoneAudioCapturer)
    if captureMicrophone {
      let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
      switch micStatus {
      case .notDetermined:
        DiagnosticLogger.shared.log(.debug, .recording, "Requesting microphone permission for recording")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard captureGenerationGate.isCurrent(generation) else {
          throw RecordingError.cancelled
        }
        if !granted {
          DiagnosticLogger.shared.log(.warning, .recording, "Microphone permission denied during request")
          throw RecordingError.microphonePermissionDenied
        }
      case .denied, .restricted:
        DiagnosticLogger.shared.log(.warning, .recording, "Microphone permission unavailable", context: [
          "status": audioAuthorizationStatusLabel(micStatus),
        ])
        throw RecordingError.microphonePermissionDenied
      case .authorized:
        break
      @unknown default:
        DiagnosticLogger.shared.log(.warning, .recording, "Unknown microphone permission status")
      }
    }

    guard captureGenerationGate.isCurrent(generation) else {
      throw RecordingError.cancelled
    }

    let activeStream = SCStream(filter: filter, configuration: config, delegate: self)
    stream = activeStream
    streamsByGeneration[generation] = activeStream
    captureGenerationGate.bind(stream: activeStream, generation: generation)
    registeredOutputTypesByGeneration[generation] = []
    registeredOutputTypes = []

    do {
      try activeStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoProcessingQueue)
      registeredOutputTypesByGeneration[generation, default: []].insert(.screen)
      registeredOutputTypes.insert(.screen)

      if captureSystemAudio {
        try activeStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioProcessingQueue)
        registeredOutputTypesByGeneration[generation, default: []].insert(.audio)
        registeredOutputTypes.insert(.audio)
      }
    } catch {
      // Do not teardown here. The outer prepareRecording catch claims the
      // generation-scoped start-failure owner before awaiting teardown. Keep
      // the successful registrations above so that owner can remove every
      // output (including a partial screen-only registration) and stop the
      // stream exactly once.
      throw error
    }

    DiagnosticLogger.shared.log(.info, .recording, "Stream configuration", context: [
      "outputSize": "\(captureGeometry.outputWidth)x\(captureGeometry.outputHeight)",
      "fps": "\(fps)",
      "captureResolutionMode": captureResolutionMode,
      "sourceRect": String(
        format: "%.2f,%.2f %.2fx%.2f",
        captureGeometry.sourceRect.origin.x,
        captureGeometry.sourceRect.origin.y,
        captureGeometry.sourceRect.size.width,
        captureGeometry.sourceRect.size.height
      ),
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "outputTypes": registeredOutputTypes.map { streamOutputTypeLabel($0) }.sorted().joined(separator: "+"),
    ])
  }

  private func makeContentFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
    let iconManager = DesktopIconManager.shared

    if excludeOwnApplicationFromCapture {
      var excludedApps: [SCRunningApplication] = []
      if let bundleID = Bundle.main.bundleIdentifier {
        excludedApps += content.applications.filter { $0.bundleIdentifier == bundleID }
      }

      var exceptedWindows = content.windows.filter { exceptedWindowIDs.contains($0.windowID) }
      if excludeDesktopIconsFromCapture {
        excludedApps += iconManager.getFinderApps(from: content)
        exceptedWindows += iconManager.getVisibleFinderWindows(from: content)
      }
      if excludeDesktopWidgetsFromCapture {
        excludedApps += iconManager.getWidgetApps(from: content)
      }

      return SCContentFilter(
        display: display,
        excludingApplications: uniqueApplications(excludedApps),
        exceptingWindows: uniqueWindows(exceptedWindows)
      )
    }

    // When own-app capture is enabled, desktop icons/widgets still need app-level filtering.
    // Window-level filtering is unreliable for Finder desktop icons on some macOS setups.
    if excludeDesktopIconsFromCapture || excludeDesktopWidgetsFromCapture {
      var excludedApps: [SCRunningApplication] = []
      var exceptedWindows: [SCWindow] = []

      if excludeDesktopIconsFromCapture {
        excludedApps += iconManager.getFinderApps(from: content)
        exceptedWindows += iconManager.getVisibleFinderWindows(from: content)
      }
      if excludeDesktopWidgetsFromCapture {
        excludedApps += iconManager.getWidgetApps(from: content)
      }

      if !excludedApps.isEmpty {
        return SCContentFilter(
          display: display,
          excludingApplications: uniqueApplications(excludedApps),
          exceptingWindows: uniqueWindows(exceptedWindows)
        )
      }
    }

    var excludedWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
    if excludeDesktopIconsFromCapture {
      excludedWindows += iconManager.getDesktopIconWindows(from: content)
    }
    if excludeDesktopWidgetsFromCapture {
      excludedWindows += iconManager.getWidgetWindows(from: content)
    }

    return SCContentFilter(
      display: display,
      excludingWindows: uniqueWindows(excludedWindows)
    )
  }

  private func uniqueWindows(_ windows: [SCWindow]) -> [SCWindow] {
    var seenWindowIDs = Set<CGWindowID>()
    return windows.filter { seenWindowIDs.insert($0.windowID).inserted }
  }

  private func uniqueApplications(_ applications: [SCRunningApplication]) -> [SCRunningApplication] {
    var seenBundleIDs = Set<String>()
    var uniqueApps: [SCRunningApplication] = []

    for application in applications {
      let bundleID = application.bundleIdentifier
      guard seenBundleIDs.insert(bundleID).inserted else { continue }
      uniqueApps.append(application)
    }

    return uniqueApps
  }

  private func currentDisplay(from content: SCShareableContent) -> SCDisplay? {
    let targetDisplayID: CGDirectDisplayID = if let screen = NSScreen.screens
      .first(where: { $0.frame.intersects(recordingRect) }),
      let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
      displayID
    } else {
      CGMainDisplayID()
    }

    return content.displays.first(where: { $0.displayID == Int(targetDisplayID) })
      ?? content.displays.first
  }

  private func loadShareableContentForCurrentFilters() async throws -> SCShareableContent {
    let requiresDesktopWindowEnumeration = excludeDesktopIconsFromCapture || excludeDesktopWidgetsFromCapture
    if requiresDesktopWindowEnumeration {
      // Finder/widget exclusion needs desktop windows in the shareable snapshot.
      return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    return try await SCShareableContent.current
  }

  private func updateContentFilter(for activeStream: SCStream) async {
    do {
      let content = try await loadShareableContentForCurrentFilters()
      guard let display = currentDisplay(from: content) else {
        DiagnosticLogger.shared.log(
          .warning,
          .recording,
          "Recording content filter update skipped: no current display",
          context: [
            "displays": "\(content.displays.count)",
            "windows": "\(content.windows.count)",
          ]
        )
        return
      }
      let filter = makeContentFilter(display: display, content: content)
      try await activeStream.updateContentFilter(filter)
      DiagnosticLogger.shared.log(.debug, .recording, "Recording content filter updated", context: [
        "displayID": "\(display.displayID)",
        "excludedWindows": "\(excludedWindowIDs.count)",
        "exceptedWindows": "\(exceptedWindowIDs.count)",
      ])
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to update recording content filter")
    }
  }

  /// Race the one-shot first-frame waiter with a bounded timeout. The waiter is
  /// explicitly cancelled on timeout (and on task cancellation), so no
  /// continuation can survive a failed adapter start or resume later into a
  /// subsequent recording.
  private func waitForAudioAdapterFirstVideoFrame(generation: UInt64) async -> Bool {
    guard captureGenerationGate.isHealthy(generation),
          session.isCurrentGeneration(generation),
          !session.hasStreamFailure(generation: generation)
    else {
      return false
    }

    let session = session
    let gate = captureGenerationGate
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await session.waitForFirstVideoFrame(generation: generation)
      }
      group.addTask {
        do {
          try await Task.sleep(
            nanoseconds: UInt64(AudioAdapterCaptureCore.firstVideoFrameTimeout * 1_000_000_000)
          )
          if gate.isCurrent(generation) {
            session.cancelFirstVideoFrameWait(generation: generation)
          }
          return false
        } catch {
          // Parent/task cancellation is also a failed start. A successful
          // frame wins before this timeout child is cancelled and is observed
          // through the other child below.
          return false
        }
      }

      let result = await group.next() ?? false
      group.cancelAll()
      if !result, gate.isCurrent(generation) {
        session.cancelFirstVideoFrameWait(generation: generation)
      }
      return result
        && gate.isHealthy(generation)
        && session.isCurrentGeneration(generation)
        && !session.hasStreamFailure(generation: generation)
        && !Task.isCancelled
    }
  }

  private func startTimer() {
    timer = Timer.scheduledTimer(
      timeInterval: 1.0,
      target: self,
      selector: #selector(updateElapsedTime),
      userInfo: nil,
      repeats: true
    )
  }

  @objc private func updateElapsedTime() {
    guard let start = startTime, state == .recording else { return }
    elapsedSeconds = Int(Date().timeIntervalSince(start) - pausedDuration)
  }

  private func logRecordingFrameDiagnostics(
    outputURL: URL?,
    stats: RecordingSession.VideoWriteStats,
    configuredFPS: Int
  ) async {
    guard stats.receivedFrames > 0 || outputURL != nil else { return }

    let droppedFrames = stats.droppedFramesDueToBackpressure + stats.failedAppendFrames
    let dropRate = stats.receivedFrames > 0
      ? (Double(droppedFrames) / Double(stats.receivedFrames)) * 100
      : 0

    var context: [String: String] = [
      "configuredFPS": "\(configuredFPS)",
      "receivedFrames": "\(stats.receivedFrames)",
      "appendedFrames": "\(stats.appendedFrames)",
      "droppedBackpressure": "\(stats.droppedFramesDueToBackpressure)",
      "failedAppend": "\(stats.failedAppendFrames)",
      "dropRatePercent": String(format: "%.2f", dropRate),
      "microphoneSamplesReceived": "\(stats.microphoneSamplesReceived)",
      "microphoneSamplesAppended": "\(stats.microphoneSamplesAppended)",
    ]

    if let outputURL {
      context["outputFile"] = outputURL.lastPathComponent
      context["outputExists"] = "\(FileManager.default.fileExists(atPath: outputURL.path))"
      if let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int {
        context["outputSizeBytes"] = "\(size)"
      }
      let asset = AVURLAsset(url: outputURL)
      if let track = try? await asset.loadTracks(withMediaType: .video).first {
        let nominalFrameRate = await (try? track.load(.nominalFrameRate)) ?? 0
        if nominalFrameRate > 0 {
          context["outputNominalFPS"] = String(format: "%.2f", nominalFrameRate)
        }

        let minFrameDuration = try? await track.load(.minFrameDuration)
        if let minFrameDuration,
           minFrameDuration.isValid,
           minFrameDuration.seconds > 0 {
          context["outputFrameDurationMs"] = String(format: "%.2f", minFrameDuration.seconds * 1000)
        }
      }
      if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
        context["outputAudioTracks"] = "\(audioTracks.count)"
      }
    }

    DiagnosticLogger.shared.log(.info, .recording, "Recording frame diagnostics", context: context)
  }

  private func claimTeardown(
    generation: UInt64,
    operation: RecordingTeardownOperation
  ) -> Bool {
    guard RecordingCaptureLifecyclePolicy.canClaimTeardown(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      state: state,
      owner: teardownOwner,
      operation: operation
    ) else {
      return false
    }

    teardownOwner = RecordingTeardownOwner(generation: generation, operation: operation)
    // This write is deliberately part of the synchronous claim.  A stop or
    // cancel task that resumes later cannot enter while the owner is active.
    state = .stopping
    return true
  }

  private func releaseTeardown(_ owner: RecordingTeardownOwner) {
    guard teardownOwner == owner else { return }
    teardownOwner = nil
  }

  /// Idempotent cleanup for every startCapture/post-await failure.  It claims
  /// the same teardown owner as stop/cancel; if either already owns the
  /// generation, that owner performs the actual stream/writer cleanup.
  private func teardownFailedStart(
    generation: UInt64,
    failure: RecordingError
  ) async {
    guard captureGenerationGate.isCurrent(generation),
          session.isCurrentGeneration(generation),
          claimTeardown(generation: generation, operation: .startFailure)
    else {
      return
    }

    let owner = RecordingTeardownOwner(generation: generation, operation: .startFailure)
    defer {
      cleanup(generation: generation, owner: owner)
      releaseTeardown(owner)
    }

    error = failure
    session.isCapturing = false
    session.cancelFirstVideoFrameWait(generation: generation)
    session.setOnFirstVideoFrame(generation: generation, nil)
    microphoneCapturer?.stop()

    if let activeStream = streamsByGeneration[generation] {
      await teardownStream(activeStream, generation: generation)
    }

    guard RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
      capturedGeneration: generation,
      currentGeneration: captureGenerationGate.current(),
      sessionGenerationIsCurrent: session.isCurrentGeneration(generation)
    ) else {
      return
    }
    session.cancelWriting()
  }

  private func cleanup(
    generation: UInt64? = nil,
    owner: RecordingTeardownOwner? = nil
  ) {
    let resolvedGeneration = generation ?? captureGenerationGate.current()
    // A start task that loses a stop/cancel race must not reset the session
    // underneath the active owner.  The owner will clean it after its await.
    if let activeOwner = teardownOwner,
       activeOwner.generation == resolvedGeneration,
       activeOwner != owner {
      return
    }

    if let resolvedGeneration {
      guard captureGenerationGate.isCurrent(resolvedGeneration) else { return }
      captureGenerationGate.invalidate(resolvedGeneration)
      session.cancelFirstVideoFrameWait(generation: resolvedGeneration)
    } else {
      session.cancelFirstVideoFrameWait()
    }

    timer?.invalidate()
    timer = nil
    startTime = nil
    pauseStartTime = nil
    pausedDuration = 0
    exportDirectoryAccess?.stop()
    exportDirectoryAccess = nil
    excludedWindowIDs.removeAll()
    exceptedWindowIDs.removeAll()
    session.setOnFirstVideoFrame((nil as (() -> Void)?))
    session.cancelFirstVideoFrameWait()
    microphoneDeviceID = nil
    showCursorInRecording = true
    excludeOwnApplicationFromCapture = true
    excludeDesktopIconsFromCapture = false
    excludeDesktopWidgetsFromCapture = false
    mouseTracker = nil
    microphoneCapturer = nil
    audioLevelMeter.reset()
    session.reset()
    recordingPurpose = .screenVideo
    cleanupRecordingProcessingDirectoryIfNeeded()
    finalOutputURL = nil
    outputURL = nil
    streamFailureEvent = nil
    state = .idle
    elapsedSeconds = 0
  }

  private func teardownStream(_ activeStream: SCStream, generation: UInt64? = nil) async {
    let resolvedGeneration = generation ?? streamsByGeneration.first {
      $0.value === activeStream
    }?.key
    let outputTypes = resolvedGeneration.flatMap {
      registeredOutputTypesByGeneration[$0]
    } ?? (stream === activeStream ? registeredOutputTypes : [])

    // Remove outputs first so SCStream can release pipeline buffers immediately.
    for outputType in outputTypes {
      do {
        try activeStream.removeStreamOutput(self, type: outputType)
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Failed to remove recording stream output", context: [
          "type": streamOutputTypeLabel(outputType),
        ])
      }
    }

    do {
      try await activeStream.stopCapture()
    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "Failed to stop recording stream during teardown")
    }

    // Only clear each registration set after all removal attempts.  A stale
    // teardown must not erase a newer stream's registrations.
    if let resolvedGeneration {
      registeredOutputTypesByGeneration.removeValue(forKey: resolvedGeneration)
      streamsByGeneration.removeValue(forKey: resolvedGeneration)
    }
    if stream === activeStream {
      registeredOutputTypes.removeAll()
      stream = nil
    }
  }

  /// Add a window to the active recording filter.
  /// In display capture this behaves as an "excepted" window. In application capture
  /// it becomes an extra included overlay window so annotation/click effects stay visible.
  func addExceptedWindow(windowID: CGWindowID) async {
    guard let activeStream = stream else {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Excepted recording window skipped: no active stream",
        context: [
          "windowID": "\(windowID)",
        ]
      )
      return
    }
    guard excludeOwnApplicationFromCapture else {
      DiagnosticLogger.shared.log(
        .debug,
        .recording,
        "Excepted recording window skipped: own app is included",
        context: [
          "windowID": "\(windowID)",
        ]
      )
      return
    }

    exceptedWindowIDs.insert(windowID)
    DiagnosticLogger.shared.log(.debug, .recording, "Excepted recording window added", context: [
      "windowID": "\(windowID)",
      "exceptedWindows": "\(exceptedWindowIDs.count)",
    ])
    await updateContentFilter(for: activeStream)
  }

  private func audioAuthorizationStatusLabel(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
  }

  private func streamOutputTypeLabel(_ type: SCStreamOutputType) -> String {
    switch type {
    case .screen: return "screen"
    case .audio: return "audio"
    case .microphone: return "microphone"
    @unknown default: return "unknown"
    }
  }
}

// MARK: - MicrophoneAudioCapturerDelegate

extension ScreenRecordingManager: MicrophoneAudioCapturerDelegate {
  nonisolated func microphoneCapturer(
    _ capturer: MicrophoneAudioCapturer,
    didOutput sampleBuffer: CMSampleBuffer
  ) {
    guard let generation = captureGenerationGate.generation(for: capturer) else { return }
    session.appendMicrophoneSample(sampleBuffer, generation: generation)
    guard captureGenerationGate.isHealthy(generation), !session.hasStreamFailure(generation: generation) else { return }
    audioLevelMeter.ingest(sampleBuffer, source: .microphone)
  }
}

// MARK: - SCStreamOutput

extension ScreenRecordingManager: SCStreamOutput {
  nonisolated func stream(
    _ activeStream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    autoreleasepool {
      guard sampleBuffer.isValid else { return }
      guard let generation = captureGenerationGate.generation(for: activeStream) else { return }

      // Write frames using the thread-safe session (no @MainActor crossing)
      switch type {
      case .screen:
        session.appendVideoSample(sampleBuffer, generation: generation)
      case .audio:
        session.appendAudioSample(sampleBuffer, generation: generation)
        guard captureGenerationGate.isHealthy(generation), !session.hasStreamFailure(generation: generation) else { return }
        audioLevelMeter.ingest(sampleBuffer, source: .system)
      case .microphone:
        session.appendMicrophoneSample(sampleBuffer, generation: generation)
        guard captureGenerationGate.isHealthy(generation), !session.hasStreamFailure(generation: generation) else { return }
        audioLevelMeter.ingest(sampleBuffer, source: .microphone)
      @unknown default:
        break
      }
    }
  }
}

// MARK: - SCStreamDelegate

extension ScreenRecordingManager: SCStreamDelegate {
  nonisolated func stream(_ activeStream: SCStream, didStopWithError error: Error) {
    guard let generation = captureGenerationGate.generation(for: activeStream) else { return }
    DiagnosticLogger.shared.logError(.recording, error, "Screen recording stream stopped unexpectedly")
    // Mark the cross-queue gate first.  An adapter start claim and this
    // failure are serialized by one lock: failure-first rejects the claim;
    // claim-first is reported as an active failure for the coordinator.
    guard let gateObservation = captureGenerationGate.markStreamFailed(generation),
          let observation = session.markStreamFailure(generation: generation)
    else {
      return
    }

    // Publish only on the main actor, and only while this generation remains
    // current.  The event is metadata-only; a coordinator can call
    // stopRecording() to finish and preserve the original writer output.
    let errorType = String(describing: type(of: error))
    Task { @MainActor [weak self] in
      guard let self,
            self.captureGenerationGate.isCurrent(generation),
            self.session.isCurrentGeneration(generation),
            self.state != .idle,
            self.state != .stopping,
            self.recordingPurpose == .screenVideo || gateObservation.wasAdapterStartClaimed
      else { return }

      let event = RecordingStreamFailureEvent(
        generation: generation,
        purpose: self.recordingPurpose,
        wasFirstVideoFrameReady: observation.wasFirstVideoFrameReady,
        wasCapturing: observation.wasCapturing,
        errorType: errorType,
        wasAdapterStartClaimed: gateObservation.wasAdapterStartClaimed
      )
      self.streamFailureEvent = event
      NotificationCenter.default.post(
        name: .recordingStreamDidFail,
        object: self,
        userInfo: [RecordingStreamFailureEvent.userInfoKey: event]
      )
    }
  }
}
