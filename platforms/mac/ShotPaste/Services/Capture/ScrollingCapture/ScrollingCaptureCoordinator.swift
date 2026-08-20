//
//  ScrollingCaptureCoordinator.swift
//  ShotPaste
//
//  Phase-01 coordinator for guided scrolling capture sessions.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class ScrollingCaptureCoordinator {
  static let shared = ScrollingCaptureCoordinator()

  private let captureManager = ScreenCaptureManager.shared
  private let maxOutputHeight = ScrollingCaptureConfiguration.maxOutputHeight
  private let liveRefreshIntervalNanoseconds: UInt64 = 50_000_000
  private let defaultMinimumRefreshSpacing: TimeInterval = 0.09
  private let fastMinimumRefreshSpacing: TimeInterval = 0.06
  private let defaultScrollSettleDelay: TimeInterval = 0.05
  private let fastScrollSettleDelay: TimeInterval = 0.03
  private let scrollIdleTimeout: TimeInterval = 0.28
  private let defaultMinimumPendingScrollPoints: CGFloat = 10
  private let fastMinimumPendingScrollPoints: CGFloat = 8
  private let defaultForcedRefreshScrollPoints: CGFloat = 42
  private let fastForcedRefreshScrollPoints: CGFloat = 28
  private let previewTruthLagToleranceMs = 90
  private let liveFrameDebugSampleInterval = 30
  private let scrollHitSlop: CGFloat = 32
  private let autoScrollIntervalNanoseconds: UInt64 = 40_000_000
  private let autoScrollPausedIntervalNanoseconds: UInt64 = 150_000_000
  private let autoScrollDeltaY: Int32 = -15
  private let processingQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.scrolling-capture.processing",
    qos: .userInitiated
  )

  private var sessionModel: ScrollingCaptureSessionModel?
  private var hudWindow: ScrollingCaptureHUDWindow?
  private var autoScrollWindow: ScrollingCaptureAutoScrollWindow?
  private var previewWindow: ScrollingCapturePreviewWindow?
  private var regionOverlayWindows: [RecordingRegionOverlayWindow] = []
  private var sessionModelObservation: AnyCancellable?
  private var latestImage: CGImage?
  private var stitcher: ScrollingCaptureStitcher?
  private var liveFrameSource: ScrollingCaptureFrameSource?
  private let liveFrameRing = ScrollingCaptureFrameRing(capacity: 8)
  private var commitScheduler: ScrollingCaptureCommitScheduler?
  private var sessionMetrics = ScrollingCaptureSessionMetrics()
  private var didFlushSessionMetrics = false
  private var selectedRect: CGRect?
  private var saveDirectory: URL?
  private var format: ImageFormat = .png
  private var prefetchedContentTask: ShareableContentPrefetchTask?
  private var scrollMonitor: Any?
  private var localSessionKeyMonitor: Any?
  private var globalSessionKeyMonitor: Any?
  private var pendingRefreshTask: Task<Void, Never>?
  private var autoScrollTask: Task<Void, Never>?
  private var autoScrollTaskID: UUID?
  private var autoScrollStationaryUpdateCount = 0
  private var prepareCaptureContextTask: Task<Void, Never>?
  private var preparedCaptureContext: ScreenCaptureManager.PreparedAreaCaptureContext?
  private var captureScaleFactor: CGFloat = 2
  private var pendingScrollDistancePoints: CGFloat = 0
  private var pendingScrollDirection: Int?
  /// Converts NSEvent wheel sign into the stitcher's signed content-motion
  /// convention. Learned from the first visually accepted frame so reverse
  /// scrolling remains fully supported after the initial direction lock.
  private var scrollEventToMotionSign: Int?
  private var lastScrollEventTime: TimeInterval?
  private var lastRefreshTime: TimeInterval?
  private var lastAcceptedDeltaPixels: Int?
  private var isRefreshingPreview = false
  private var sessionGeneration = 0
  private var livePreviewFrameSequence = 0
  private var isStreamCommitEnabled = false
  private var lastScheduledCommitSequenceNumber = 0
  private var lastScheduledCommitUpdate: ScrollingCaptureStitchUpdate?
  private var lastLivePreviewPublishedAt: TimeInterval?
  private var lastCommittedObservationAt: TimeInterval?
  private var onSessionEnded: (@MainActor () -> Void)?

  var isActive: Bool {
    sessionModel != nil
  }

  func beginSession(
    rect: CGRect,
    saveDirectory: URL,
    format: ImageFormat,
    prefetchedContentTask: ShareableContentPrefetchTask?,
    onSessionEnded: (@MainActor () -> Void)? = nil
  ) {
    cancel()
    sessionGeneration += 1

    self.onSessionEnded = onSessionEnded
    let model = ScrollingCaptureSessionModel(selectedRect: rect)
    sessionModel = model
    selectedRect = rect
    self.saveDirectory = saveDirectory
    self.format = format
    self.prefetchedContentTask = prefetchedContentTask
    captureScaleFactor = scaleFactor(for: rect)
    sessionModelObservation?.cancel()
    sessionModelObservation = nil
    pendingScrollDistancePoints = 0
    pendingScrollDirection = nil
    scrollEventToMotionSign = nil
    lastScrollEventTime = nil
    lastRefreshTime = nil
    lastAcceptedDeltaPixels = nil
    isRefreshingPreview = false
    autoScrollStationaryUpdateCount = 0
    preparedCaptureContext = nil
    prepareCaptureContextTask = nil
    liveFrameSource = nil
    liveFrameRing.reset()
    commitScheduler = makeCommitScheduler()
    livePreviewFrameSequence = 0
    isStreamCommitEnabled = false
    lastScheduledCommitSequenceNumber = 0
    lastScheduledCommitUpdate = nil
    lastLivePreviewPublishedAt = nil
    lastCommittedObservationAt = nil
    sessionMetrics = ScrollingCaptureSessionMetrics()
    didFlushSessionMetrics = false

    showRegionOverlay(for: rect)
    bindRegionOverlayGuidance(to: model)
    hudWindow = ScrollingCaptureHUDWindow(
      anchorRect: rect,
      model: model,
      onStart: { [weak self] in self?.startCapture() },
      onDone: { [weak self] in self?.finish() },
      onCancel: { [weak self] in self?.cancel() }
    )
    autoScrollWindow = ScrollingCaptureAutoScrollWindow(
      anchorRect: rect,
      model: model,
      onToggleAutoScroll: { [weak self] in self?.toggleAutoScrolling() }
    )
    previewWindow = ScrollingCapturePreviewWindow(anchorRect: rect, model: model)

    hudWindow?.orderFrontRegardless()
    autoScrollWindow?.orderFrontRegardless()
    previewWindow?.orderFrontRegardless()
    installSessionKeyMonitorsIfNeeded()
    prewarmCaptureContext(for: rect)
    updatePreviewTruthState()

    if ScrollingCaptureConfiguration.showHints {
      AppToastManager.shared.show(
        message: L10n.ScrollingCaptureStatus.readyHintToast,
        style: .info,
        position: .topCenter
      )
    }

    DiagnosticLogger.shared.log(
      .info,
      .capture,
      "Scrolling capture session ready",
      context: ["rect": "\(Int(rect.width))x\(Int(rect.height))"]
    )
  }

  func cancel() {
    tearDownSession(metricsReason: "cancelled")
  }

  private func tearDownSession(metricsReason: String) {
    stopAutoScrolling()
    flushSessionMetricsIfNeeded(reason: metricsReason)
    sessionGeneration += 1
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    prepareCaptureContextTask?.cancel()
    prepareCaptureContextTask = nil
    commitScheduler?.cancel()
    commitScheduler = nil
    stopLivePreviewIfNeeded()
    removeSessionKeyMonitors()
    sessionModelObservation?.cancel()
    sessionModelObservation = nil

    if let scrollMonitor {
      NSEvent.removeMonitor(scrollMonitor)
      self.scrollMonitor = nil
    }

    for overlay in regionOverlayWindows {
      overlay.close()
    }
    regionOverlayWindows.removeAll()
    hudWindow?.orderOut(nil)
    autoScrollWindow?.orderOut(nil)
    previewWindow?.orderOut(nil)
    hudWindow = nil
    autoScrollWindow = nil
    previewWindow = nil
    sessionModel = nil
    latestImage = nil
    stitcher = nil
    liveFrameRing.reset()
    selectedRect = nil
    saveDirectory = nil
    prefetchedContentTask = nil
    preparedCaptureContext = nil
    pendingScrollDistancePoints = 0
    pendingScrollDirection = nil
    scrollEventToMotionSign = nil
    lastScrollEventTime = nil
    lastRefreshTime = nil
    lastAcceptedDeltaPixels = nil
    isRefreshingPreview = false
    autoScrollStationaryUpdateCount = 0
    commitScheduler = nil
    livePreviewFrameSequence = 0
    isStreamCommitEnabled = false
    lastScheduledCommitSequenceNumber = 0
    lastScheduledCommitUpdate = nil
    lastLivePreviewPublishedAt = nil
    lastCommittedObservationAt = nil
    sessionMetrics = ScrollingCaptureSessionMetrics()
    didFlushSessionMetrics = false

    let sessionEndHandler = onSessionEnded
    onSessionEnded = nil
    sessionEndHandler?()
  }

  private func startCapture() {
    guard let sessionModel else { return }
    guard sessionModel.phase == .ready else { return }

    setRegionOverlayInteractionEnabled(false)
    sessionModel.phase = .capturing
    sessionModel.runtimeState = .streaming
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.capturingFirstFrame,
      guidance: .holdSteady
    )
    updatePreviewTruthState()
    installScrollMonitorIfNeeded()

    Task { @MainActor in
      await startLivePreviewIfPossible()
      if sessionModel.isUsingLivePreview {
        await waitForInitialLiveFrame()
        if liveFrameRing.latest == nil {
          sessionMetrics.recordLivePreviewFallbackActivation()
          stopLivePreviewIfNeeded(clearImage: false)
        }
      }
      _ = await refreshPreview(reason: "Initial frame captured")
      isStreamCommitEnabled = true
      if sessionModel.isUsingLivePreview,
         liveFrameRing.latestFrame(after: liveFrameRing.lastCommittedSequenceNumber) != nil {
        scheduleCommitRefresh(reason: "Stream frame after initial commit")
      }
    }
  }

  private func toggleAutoScrolling() {
    if sessionModel?.isAutoScrolling == true {
      stopAutoScrolling()
    } else {
      startAutoScrolling()
    }
  }

  private func startAutoScrolling() {
    guard requestAccessibilityPermissionForAutoScrollIfNeeded() else { return }
    guard let sessionModel, sessionModel.phase == .capturing else { return }
    guard sessionModel.canToggleAutoScroll else { return }
    guard autoScrollTask == nil else { return }

    autoScrollStationaryUpdateCount = 0
    sessionModel.isAutoScrolling = true
    let taskID = UUID()
    autoScrollTaskID = taskID
    autoScrollTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.autoScrollTaskID == taskID {
          self.sessionModel?.isAutoScrolling = false
          self.autoScrollTask = nil
          self.autoScrollTaskID = nil
        }
      }

      while autoScrollTaskID == taskID, !Task.isCancelled {
        guard
          let sessionModel = self.sessionModel,
          sessionModel.phase == .capturing,
          sessionModel.isAutoScrolling
        else {
          break
        }
        guard let rect = selectedRect else { break }

        let mouseLocation = NSEvent.mouseLocation
        if let scrollTargetPoint = ScrollingCaptureAutoScrollPolicy.scrollTargetPoint(
          mouseLocation: mouseLocation,
          selectedRect: rect
        ) {
          if sessionModel.guidanceKind == .placeMouseInsideSelection {
            sessionModel.setStatus(
              L10n.ScrollingCaptureStatus.sessionActive(
                sessionModel.acceptedFrameCount,
                sessionModel.stitchedPixelHeight
              ),
              guidance: .scrollDownSteadily
            )
          }

          postScrollEvent(
            deltaY: autoScrollDeltaY,
            at: scrollTargetPoint
          )
          try? await Task.sleep(nanoseconds: autoScrollIntervalNanoseconds)
        } else {
          sessionModel.setStatus(
            L10n.ScrollingCaptureStatus.autoScrollPausedMoveMouseInside,
            guidance: .placeMouseInsideSelection
          )
          try? await Task.sleep(nanoseconds: autoScrollPausedIntervalNanoseconds)
        }
      }
    }
  }

  private func stopAutoScrolling() {
    sessionModel?.isAutoScrolling = false
    autoScrollStationaryUpdateCount = 0
    autoScrollTaskID = nil
    autoScrollTask?.cancel()
    autoScrollTask = nil
  }

  private func requestAccessibilityPermissionForAutoScrollIfNeeded() -> Bool {
    if AXIsProcessTrusted() {
      return true
    }

    let options = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)

    sessionModel?.setStatus(
      L10n.ScrollingCaptureStatus.autoScrollNeedsAccessibility,
      guidance: .continueManually
    )
    AppToastManager.shared.show(
      message: L10n.ScrollingCaptureStatus.autoScrollNeedsAccessibility,
      style: .warning
    )
    DiagnosticLogger.shared.log(
      .warning,
      .capture,
      "Auto-scroll blocked by missing Accessibility permission"
    )
    return false
  }

  private func postScrollEvent(deltaY: Int32, at point: CGPoint) {
    guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
    guard
      let scrollEvent = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
      )
    else {
      return
    }

    source.localEventsSuppressionInterval = 0
    scrollEvent.location = quartzGlobalPoint(fromAppKitGlobalPoint: point)
    scrollEvent.post(tap: .cgSessionEventTap)
  }

  private func quartzGlobalPoint(fromAppKitGlobalPoint point: CGPoint) -> CGPoint {
    let mainScreenHeight = NSScreen.screens.first(where: { $0.displayID == CGMainDisplayID() })?.frame.height
      ?? CGDisplayBounds(CGMainDisplayID()).height
    return CGPoint(x: point.x, y: mainScreenHeight - point.y)
  }

  private func finish() {
    stopAutoScrolling()
    guard let sessionModel else { return }
    guard sessionModel.phase == .capturing else {
      if sessionModel.isInteractionLocked {
        sessionMetrics.recordFinalizingBlockedInput()
      }
      return
    }

    beginFinalizing()
    // Give immediate completion feedback. The final stream-frame commit,
    // canvas crop, encoding, and history insertion continue asynchronously.
    setCaptureWindowsVisible(false)

    Task { @MainActor in
      await waitForPendingPreviewRefresh()

      let hasUncommittedStreamFrame = sessionModel.isUsingLivePreview
        && liveFrameRing.latestFrame(after: liveFrameRing.lastCommittedSequenceNumber) != nil
      if abs(pendingScrollDistancePoints) > 2 || hasUncommittedStreamFrame {
        _ = await refreshPreview(reason: "Final visible frame captured before save")
      }

      if latestImage == nil, !sessionModel.isUsingLivePreview {
        _ = await refreshPreview(reason: "Current frame captured before save")
      }

      stopLivePreviewIfNeeded()

      // Stitching already happened incrementally during scrolling; finishing
      // only crops the canvas, off the main thread.
      let activeStitcher = stitcher
      let mergedImage: CGImage? = await withCheckedContinuation { continuation in
        processingQueue.async {
          continuation.resume(returning: activeStitcher?.mergedImage())
        }
      }
      if let mergedImage {
        latestImage = mergedImage
        sessionModel.previewImage = mergedImage
      }

      guard let latestImage, let saveDirectory else {
        sessionMetrics.recordFinalizingCompleted(at: ProcessInfo.processInfo.systemUptime)
        sessionModel.phase = .capturing
        sessionModel.runtimeState = .paused
        sessionModel.setStatus(
          L10n.ScrollingCaptureStatus.noSavableResultReady,
          guidance: .keepCapturing
        )
        sessionModel.previewCaption = L10n.ScrollingCapture.captionNoSavableResultReady
        updatePreviewTruthState()
        setCaptureWindowsVisible(true)
        await startLivePreviewIfPossible()
        AppToastManager.shared.show(message: L10n.ScrollingCapture.toastNoStitchedFrameReady, style: .warning)
        return
      }

      sessionMetrics.recordFinalizingCompleted(at: ProcessInfo.processInfo.systemUptime)
      sessionModel.phase = .saving
      sessionModel.runtimeState = .saving
      sessionModel.setStatus(
        L10n.ScrollingCaptureStatus.savingStitchedImage,
        guidance: .savingLongScreenshot
      )
      sessionModel.previewCaption = L10n.ScrollingCapture.captionSavingStitchedResult
      updatePreviewTruthState()

      let imageToSave = latestImage
      let directoryToSave = saveDirectory
      let formatToSave = format
      let outputScaleFactor = captureScaleFactor
      // The canvas is immutable from this point. End the capture session now so
      // One Shot and global shortcuts are immediately available while encoding,
      // file I/O, and history insertion continue in this task.
      tearDownSession(metricsReason: "saving")

      let result = await captureManager.saveProcessedImage(
        imageToSave,
        to: directoryToSave,
        format: formatToSave,
        scaleFactor: outputScaleFactor,
        emitCompletion: false
      )

      switch result {
      case .success(let url):
        _ = await PostCaptureActionHandler.shared.handleScreenshotCapture(
          url: url,
          origin: .scrollingCapture,
          successMessage: L10n.ScrollingCapture.toastSavedStitchedImage
        )
        SoundManager.playScreenshotCapture()
      case .failure(let error):
        AppToastManager.shared.show(message: error.localizedDescription, style: .error)
      }
    }
  }

  private func installScrollMonitorIfNeeded() {
    guard scrollMonitor == nil else { return }

    scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      DispatchQueue.main.async {
        self?.handleScrollEvent(event)
      }
    }
  }

  private func handleScrollEvent(_ event: NSEvent) {
    guard let selectedRect, let sessionModel else { return }
    guard sessionModel.phase == .capturing else { return }
    guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return }
    guard selectedRect.insetBy(dx: -scrollHitSlop, dy: -scrollHitSlop).contains(NSEvent.mouseLocation) else {
      return
    }

    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
    let deltaY = CGFloat(event.scrollingDeltaY) * multiplier
    guard abs(deltaY) > 0.5 else { return }
    sessionMetrics.recordScrollEvent(deltaY: deltaY)

    let direction = deltaY > 0 ? 1 : -1
    if let pendingScrollDirection, pendingScrollDirection != direction {
      // A real direction reversal starts a fresh hint window. The visual
      // matcher remains authoritative and the bidirectional canvas can grow
      // past either historical extent.
      pendingScrollDistancePoints = deltaY
    } else {
      pendingScrollDistancePoints += deltaY
    }
    pendingScrollDirection = direction
    lastScrollEventTime = ProcessInfo.processInfo.systemUptime

    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.aligningLatestContent,
      guidance: .continueManually
    )
    if sessionModel.isUsingLivePreview {
      // While the stream runs, its frames drive stitching directly; scroll
      // events only steer guidance and signed delta hints.
      updatePreviewTruthState()
      return
    }
    startLiveRefreshLoopIfNeeded()
    updatePreviewTruthState()
  }

  private func refreshPreview(
    reason: String,
    expectedSignedDeltaPixelsOverride: Int? = nil
  ) async -> ScrollingCaptureStitchUpdate? {
    let generation = sessionGeneration
    guard let sessionModel else { return nil }
    guard sessionModel.phase == .capturing || sessionModel.phase == .finalizing else { return nil }
    guard !isRefreshingPreview else { return nil }
    let isFinalizingRefresh = sessionModel.phase == .finalizing

    sessionModel.runtimeState = isFinalizingRefresh ? .finalizing : .committing
    updatePreviewTruthState()
    let refreshStartedAt = CFAbsoluteTimeGetCurrent()
    isRefreshingPreview = true
    defer {
      isRefreshingPreview = false
      if generation == sessionGeneration {
        lastRefreshTime = ProcessInfo.processInfo.systemUptime
        updatePreviewTruthState()
      }
    }

    do {
      let expectedSignedDeltaPixels: Int?
      let batchScrollDirection = pendingScrollDirection
      if let expectedSignedDeltaPixelsOverride {
        expectedSignedDeltaPixels = expectedSignedDeltaPixelsOverride
      } else if abs(pendingScrollDistancePoints) > 2 {
        expectedSignedDeltaPixels = normalizedExpectedDeltaPixels(
          from: Int(round(pendingScrollDistancePoints * captureScaleFactor))
        )
      } else {
        expectedSignedDeltaPixels = nil
      }
      pendingScrollDistancePoints = 0
      pendingScrollDirection = nil

      let captureStartedAt = CFAbsoluteTimeGetCurrent()
      guard let commitFrame = try await captureFrameForCommit(
        allowStillFallback: !sessionModel.isUsingLivePreview
      ) else {
        sessionModel.runtimeState = isFinalizingRefresh ? .finalizing : .paused
        sessionModel.setStatus(
          isFinalizingRefresh
            ? L10n.ScrollingCaptureStatus.couldntCaptureLastFrame
            : L10n.ScrollingCaptureStatus.unableToCaptureArea,
          guidance: isFinalizingRefresh ? .lockingCurrentCapture : .previewNeedsRecovery
        )
        let totalDurationMs = Self.elapsedMilliseconds(since: refreshStartedAt)
        let captureDurationMs = Self.elapsedMilliseconds(since: captureStartedAt)
        sessionMetrics.recordRefreshFailure(
          reason: reason,
          captureDurationMs: captureDurationMs,
          stitchDurationMs: 0,
          totalDurationMs: totalDurationMs
        )
        logScrollingCaptureRefreshFailure(
          reason: reason,
          stage: "capture-frame-missing",
          captureDurationMs: captureDurationMs,
          stitchDurationMs: 0,
          totalDurationMs: totalDurationMs
        )
        updatePreviewTruthState()
        return nil
      }
      let capturedImage = commitFrame.image
      let captureDurationMs = Self.elapsedMilliseconds(since: captureStartedAt)
      guard generation == sessionGeneration, self.sessionModel != nil else { return nil }

      let stitchStartedAt = CFAbsoluteTimeGetCurrent()
      // Capture-time UI always uses the incrementally maintained thumbnail.
      // The full canvas is cropped exactly once when Done is pressed, including
      // when ScreenCaptureKit has fallen back to still captures.
      let shouldRenderMergedImage = false
      let (update, processedStitcher, processedPreviewImage) = await stitchCapturedImage(
        capturedImage,
        expectedSignedDeltaPixels: expectedSignedDeltaPixels,
        renderMergedImage: shouldRenderMergedImage
      )
      let stitchDurationMs = Self.elapsedMilliseconds(since: stitchStartedAt)
      guard generation == sessionGeneration, let sessionModel = self.sessionModel else { return nil }
      if let processedStitcher {
        stitcher = processedStitcher
      }

      guard let update else {
        sessionModel.runtimeState = isFinalizingRefresh ? .finalizing : .paused
        sessionModel.setStatus(
          isFinalizingRefresh
            ? L10n.ScrollingCaptureStatus.couldntRefreshLastFrame
            : L10n.ScrollingCaptureStatus.unableToRenderPreview,
          guidance: isFinalizingRefresh ? .lockingCurrentCapture : .previewNeedsRecovery
        )
        let totalDurationMs = Self.elapsedMilliseconds(since: refreshStartedAt)
        sessionMetrics.recordRefreshFailure(
          reason: reason,
          captureDurationMs: captureDurationMs,
          stitchDurationMs: stitchDurationMs,
          totalDurationMs: totalDurationMs
        )
        logScrollingCaptureRefreshFailure(
          reason: reason,
          stage: "stitch-update-missing",
          captureDurationMs: captureDurationMs,
          stitchDurationMs: stitchDurationMs,
          totalDurationMs: totalDurationMs,
          commitFrame: commitFrame
        )
        updatePreviewTruthState()
        return nil
      }

      liveFrameRing.markCommitted(sequenceNumber: commitFrame.sequenceNumber)
      let previewPublishStartedAt = CFAbsoluteTimeGetCurrent()
      if let mergedImage = update.mergedImage {
        latestImage = mergedImage
      }
      if processedStitcher != nil {
        sessionModel.previewImage =
          processedPreviewImage
            ?? update.mergedImage
            ?? sessionModel.previewImage
      }
      if case .appended = update.outcome,
         scrollEventToMotionSign == nil,
         let batchScrollDirection {
        let motionSign: Int? = switch update.mergeDirection {
        case .appendFromBottom: 1
        case .appendFromTop: -1
        case .unresolved: nil
        }
        if let motionSign {
          scrollEventToMotionSign = motionSign * batchScrollDirection
        }
      }
      recordCommittedObservation(for: update.outcome)
      sessionModel.acceptedFrameCount = update.acceptedFrameCount
      sessionModel.stitchedPixelHeight = update.outputHeight
      let previewPublishDurationMs = Self.elapsedMilliseconds(since: previewPublishStartedAt)
      let totalDurationMs = Self.elapsedMilliseconds(since: refreshStartedAt)
      sessionMetrics.recordRefreshSuccess(
        reason: reason,
        captureDurationMs: captureDurationMs,
        stitchDurationMs: stitchDurationMs,
        previewPublishDurationMs: previewPublishDurationMs,
        totalDurationMs: totalDurationMs,
        outcome: update.outcome,
        alignmentDebug: update.alignmentDebug,
        safety: update.safety
      )
      logScrollingCaptureStitchUpdate(
        reason: reason,
        expectedSignedDeltaPixels: expectedSignedDeltaPixels,
        shouldRenderMergedImage: shouldRenderMergedImage,
        commitFrame: commitFrame,
        update: update,
        captureDurationMs: captureDurationMs,
        stitchDurationMs: stitchDurationMs,
        previewPublishDurationMs: previewPublishDurationMs,
        totalDurationMs: totalDurationMs
      )

      if isFinalizingRefresh {
        sessionModel.runtimeState = .finalizing
        sessionModel.previewCaption = finalizingPreviewCaption(for: update)
        sessionModel.setStatus(
          finalizingStatusText(for: update),
          guidance: finalizingGuidanceKind(for: update)
        )
        updatePreviewTruthState()
        return update
      }

      switch update.outcome {
      case .initialized:
        lastAcceptedDeltaPixels = nil
        sessionModel.runtimeState = previewRuntimeState()
        sessionModel.previewCaption = L10n.ScrollingCapture.captionFirstFrameLocked
        sessionModel.setStatus(
          L10n.ScrollingCaptureStatus.firstFrameLocked,
          guidance: .holdSteady
        )
      case .appended(let deltaY):
        lastAcceptedDeltaPixels = deltaY
        sessionModel.runtimeState = previewRuntimeState()
        sessionModel.previewCaption = L10n.ScrollingCapture.framesStitchedDelta(update.acceptedFrameCount, deltaY)
        sessionModel.setStatus(
          L10n.ScrollingCaptureStatus.sessionActive(update.acceptedFrameCount, update.outputHeight),
          guidance: .continueManually
        )
      case .ignoredNoMovement:
        sessionModel.runtimeState = previewRuntimeState()
        if update.likelyReachedBoundary {
          sessionModel.previewCaption = L10n.ScrollingCapture.framesStitchedNoNewContent(update.acceptedFrameCount)
          sessionModel.setStatus(
            L10n.ScrollingCaptureStatus.endReachedNoNewContent,
            guidance: .pressDoneNoNewContent
          )
        } else {
          sessionModel.setStatus(
            L10n.ScrollingCaptureStatus.waitingForNewContent,
            guidance: .continueManually
          )
        }
      case .ignoredAlignmentFailed:
        sessionModel.runtimeState = update.matchFailureCount >= 2 ? .paused : previewRuntimeState()
        if update.matchFailureCount >= 2 {
          sessionModel.setStatus(
            L10n.ScrollingCaptureStatus.alignmentPaused,
            guidance: .slowDown
          )
        } else {
          sessionModel.setStatus(
            L10n.ScrollingCaptureStatus.couldntAlignFrame,
            guidance: .keepSteadierPace
          )
        }
      case .reachedHeightLimit:
        sessionModel.runtimeState = .paused
        sessionModel.previewCaption = L10n.ScrollingCapture.framesStitchedHeightLimitReached(update.acceptedFrameCount)
        sessionModel.setStatus(
          L10n.ScrollingCaptureStatus.heightLimitReached(maxOutputHeight),
          guidance: .heightLimitReached
        )
      }
      handleAutoScrollStitchUpdate(update)
      updatePreviewTruthState()
      return update
    } catch {
      let totalDurationMs = Self.elapsedMilliseconds(since: refreshStartedAt)
      sessionMetrics.recordRefreshFailure(
        reason: reason,
        captureDurationMs: 0,
        stitchDurationMs: 0,
        totalDurationMs: totalDurationMs
      )
      logScrollingCaptureRefreshFailure(
        reason: reason,
        stage: "thrown-error",
        captureDurationMs: 0,
        stitchDurationMs: 0,
        totalDurationMs: totalDurationMs,
        errorDescription: error.localizedDescription
      )
      sessionModel.runtimeState = isFinalizingRefresh ? .finalizing : .paused
      DiagnosticLogger.shared.log(
        .error,
        .capture,
        "Scrolling capture preview refresh failed",
        context: ["error": error.localizedDescription]
      )
      sessionModel.setStatus(
        isFinalizingRefresh
          ? L10n.ScrollingCaptureStatus.finalizingCurrentCapture
          : L10n.ScrollingCaptureStatus.previewRefreshFailed,
        guidance: isFinalizingRefresh ? .lockingCurrentCapture : .previewNeedsRecovery
      )
      updatePreviewTruthState()
      return nil
    }
  }

  private func showRegionOverlay(for rect: CGRect) {
    for overlay in regionOverlayWindows {
      overlay.close()
    }
    regionOverlayWindows.removeAll()

    for screen in NSScreen.screens {
      let overlay = RecordingRegionOverlayWindow(screen: screen, highlightRect: rect)
      overlay.interactionDelegate = self
      overlay.setSelectionAccentColor(.systemBlue)
      overlay.setGuidanceUsesPlainText(true)
      overlay.setInteractionEnabled(true)
      overlay.updateGuidance(currentRegionOverlayGuidance())
      overlay.orderFrontRegardless()
      regionOverlayWindows.append(overlay)
    }
  }

  private func bindRegionOverlayGuidance(to model: ScrollingCaptureSessionModel) {
    sessionModelObservation?.cancel()
    sessionModelObservation = model.$guidanceKind.sink { [weak self] _ in
      DispatchQueue.main.async {
        self?.syncRegionOverlayGuidance()
      }
    }
    syncRegionOverlayGuidance()
  }

  private func syncRegionOverlayGuidance() {
    let guidance = currentRegionOverlayGuidance()
    for overlay in regionOverlayWindows {
      overlay.updateGuidance(guidance)
    }
  }

  private func currentRegionOverlayGuidance() -> RecordingRegionOverlayGuidance? {
    guard let sessionModel, sessionModel.phase != .ready else { return nil }
    let guidance = sessionModel.selectionGuidance
    let tone: RecordingRegionOverlayGuidanceTone = switch guidance.tone {
    case .neutral:
      .neutral
    case .active:
      .active
    case .warning:
      .warning
    case .progress:
      .progress
    }

    return RecordingRegionOverlayGuidance(
      title: guidance.title,
      detail: guidance.detail,
      tone: tone
    )
  }

  private func setRegionOverlayInteractionEnabled(_ enabled: Bool) {
    for overlay in regionOverlayWindows {
      overlay.setInteractionEnabled(enabled)
    }
  }

  private func setCaptureWindowsVisible(_ visible: Bool) {
    if visible {
      for overlay in regionOverlayWindows {
        overlay.orderFrontRegardless()
      }
      hudWindow?.orderFrontRegardless()
      autoScrollWindow?.orderFrontRegardless()
      previewWindow?.orderFrontRegardless()
    } else {
      for overlay in regionOverlayWindows {
        overlay.orderOut(nil)
      }
      hudWindow?.orderOut(nil)
      autoScrollWindow?.orderOut(nil)
      previewWindow?.orderOut(nil)
    }
  }

  private func updateSelectedRect(_ rect: CGRect, reprepareSession: Bool) {
    let normalizedRect = rect.standardized
    selectedRect = normalizedRect
    sessionModel?.selectedRect = normalizedRect
    captureScaleFactor = scaleFactor(for: normalizedRect)

    for overlay in regionOverlayWindows {
      overlay.updateHighlightRect(normalizedRect)
    }
    hudWindow?.updateAnchorRect(normalizedRect)
    autoScrollWindow?.updateAnchorRect(normalizedRect)
    previewWindow?.updateAnchorRect(normalizedRect)

    if reprepareSession {
      refreshSelectionPreparation()
    }
  }

  private func refreshSelectionPreparation() {
    guard let selectedRect, let sessionModel, sessionModel.phase == .ready else { return }

    preparedCaptureContext = nil
    prepareCaptureContextTask?.cancel()
    prepareCaptureContextTask = nil
    latestImage = nil
    stitcher = nil
    liveFrameRing.reset()
    lastAcceptedDeltaPixels = nil
    livePreviewFrameSequence = 0
    lastScheduledCommitSequenceNumber = 0
    lastScheduledCommitUpdate = nil
    lastLivePreviewPublishedAt = nil
    lastCommittedObservationAt = nil
    sessionModel.previewImage = nil
    sessionModel.livePreviewImage = nil
    sessionModel.isUsingLivePreview = false
    sessionModel.previewCaption = L10n.ScrollingCapture.captionStartCaptureToLockFirstFrame
    sessionModel.acceptedFrameCount = 0
    sessionModel.stitchedPixelHeight = 0
    sessionModel.runtimeState = .ready
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.adjustRegion,
      guidance: .frameOnlyScrollingContent
    )

    prewarmCaptureContext(for: selectedRect)
    updatePreviewTruthState()
  }

  private func prewarmCaptureContext(for rect: CGRect) {
    prepareCaptureContextTask?.cancel()
    prepareCaptureContextTask = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        let context = try await captureManager.prepareAreaCapture(
          rect: rect,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: true,
          includeAllShareableOwnWindows: true,
          prefetchedContentTask: prefetchedContentTask
        )

        guard !Task.isCancelled else { return }
        preparedCaptureContext = context
        captureScaleFactor = max(context.scaleFactor, context.minimumOutputScaleFactor)
      } catch {
        if error is CancellationError {
          return
        }
        DiagnosticLogger.shared.log(
          .warning,
          .capture,
          "Scrolling capture prewarm failed",
          context: ["error": error.localizedDescription]
        )
      }
    }
  }

  private func ensurePreparedCaptureContext() async throws -> ScreenCaptureManager.PreparedAreaCaptureContext {
    if let preparedCaptureContext {
      return preparedCaptureContext
    }

    if let prepareCaptureContextTask {
      await prepareCaptureContextTask.value
      self.prepareCaptureContextTask = nil
      if let preparedCaptureContext {
        return preparedCaptureContext
      }
    }

    guard let selectedRect else {
      throw CaptureError.cancelled
    }

    let context = try await captureManager.prepareAreaCapture(
      rect: selectedRect,
      excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
      excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
      excludeOwnApplication: true,
      includeAllShareableOwnWindows: true,
      prefetchedContentTask: prefetchedContentTask
    )
    preparedCaptureContext = context
    captureScaleFactor = max(context.scaleFactor, context.minimumOutputScaleFactor)
    return context
  }

  private func capturePreparedAreaForSession() async throws -> CGImage? {
    do {
      let context = try await ensurePreparedCaptureContext()
      return try await captureManager.capturePreparedArea(context)?.image
    } catch {
      preparedCaptureContext = nil
      prepareCaptureContextTask?.cancel()
      prepareCaptureContextTask = nil
      throw error
    }
  }

  private struct CommitFrame {
    let image: CGImage
    let sequenceNumber: Int?
    let source: ScrollingCaptureCommitFrameSource
    let frameAgeMs: Int?
    let isDuplicateFrame: Bool
  }

  private func captureFrameForCommit(allowStillFallback: Bool) async throws -> CommitFrame? {
    let context = try await ensurePreparedCaptureContext()
    let streamFrame: ScrollingCaptureFrame? = if let lastCommittedSequenceNumber = liveFrameRing
      .lastCommittedSequenceNumber {
      liveFrameRing.latestFrame(after: lastCommittedSequenceNumber)
    } else {
      liveFrameRing.latest
    }

    if let streamFrame,
       let normalizedImage = normalizeCommitFrame(streamFrame.image, context: context) {
      let now = ProcessInfo.processInfo.systemUptime
      let isDuplicate = liveFrameRing.lastCommittedSequenceNumber
        .map { streamFrame.sequenceNumber <= $0 } ?? false
      let frameAgeMs = max(0, Int(((now - streamFrame.capturedAt) * 1_000).rounded()))
      sessionMetrics.recordCommitFrameSelected(
        source: .stream,
        frameAgeMs: frameAgeMs,
        isDuplicateFrame: isDuplicate
      )
      let commitFrame = CommitFrame(
        image: normalizedImage,
        sequenceNumber: streamFrame.sequenceNumber,
        source: .stream,
        frameAgeMs: frameAgeMs,
        isDuplicateFrame: isDuplicate
      )
      logScrollingCaptureCommitFrameSelected(commitFrame)
      return commitFrame
    }

    if let streamFrame {
      logScrollingCaptureDebug(
        "commit-frame-normalization-failed",
        context: [
          "source": "stream",
          "inputSize": "\(streamFrame.image.width)x\(streamFrame.image.height)",
          "logicalSize": "\(Int(context.logicalCropSize.width))x\(Int(context.logicalCropSize.height))",
          "sourceScale": Self.formattedDebugDouble(Double(context.scaleFactor)),
          "outputScale": Self.formattedDebugDouble(Double(captureScaleFactor)),
        ]
      )
    }

    // While the stream is live, a missing ring frame means nothing new arrived;
    // the still-capture path only exists as the no-stream fallback.
    guard allowStillFallback else { return nil }

    guard let capturedImage = try await capturePreparedAreaForSession() else {
      logScrollingCaptureDebug(
        "commit-frame-missing",
        context: [
          "reason": "prepared-capture-returned-nil",
          "ringFrames": "\(liveFrameRing.frames.count)",
          "lastCommittedSequence": optionalString(liveFrameRing.lastCommittedSequenceNumber),
        ]
      )
      return nil
    }
    guard let normalizedImage = normalizeCommitFrame(capturedImage, context: context) else {
      logScrollingCaptureDebug(
        "commit-frame-normalization-failed",
        context: [
          "source": "still-fallback",
          "inputSize": "\(capturedImage.width)x\(capturedImage.height)",
          "logicalSize": "\(Int(context.logicalCropSize.width))x\(Int(context.logicalCropSize.height))",
          "sourceScale": Self.formattedDebugDouble(Double(context.scaleFactor)),
          "outputScale": Self.formattedDebugDouble(Double(captureScaleFactor)),
        ]
      )
      return nil
    }
    sessionMetrics.recordCommitFrameSelected(
      source: .stillFallback,
      frameAgeMs: nil,
      isDuplicateFrame: false
    )
    let commitFrame = CommitFrame(
      image: normalizedImage,
      sequenceNumber: nil,
      source: .stillFallback,
      frameAgeMs: nil,
      isDuplicateFrame: false
    )
    logScrollingCaptureCommitFrameSelected(commitFrame)
    return commitFrame
  }

  private func normalizeCommitFrame(
    _ image: CGImage,
    context: ScreenCaptureManager.PreparedAreaCaptureContext
  ) -> CGImage? {
    ScrollingCaptureCommitFrameNormalizer.normalize(
      image,
      logicalSize: context.logicalCropSize,
      sourceScaleFactor: context.scaleFactor,
      minimumOutputScaleFactor: context.minimumOutputScaleFactor,
      colorSpaceName: context.configuration.colorSpaceName
    )
  }

  private func startLiveRefreshLoopIfNeeded() {
    guard pendingRefreshTask == nil else { return }

    pendingRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.pendingRefreshTask = nil }

      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: liveRefreshIntervalNanoseconds)
        if Task.isCancelled {
          return
        }
        guard let sessionModel, sessionModel.phase == .capturing else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let idleDuration = lastScrollEventTime.map { now - $0 } ?? .greatestFiniteMagnitude
        let pendingDistance = abs(pendingScrollDistancePoints)
        let hasPendingMotion = pendingDistance > 2
        let hasEnoughSettledMotion = pendingDistance >= minimumPendingScrollPoints()
          && idleDuration >= scrollSettleDelay()
        let shouldRefresh = hasPendingMotion
          && (hasEnoughSettledMotion || pendingDistance >= forcedRefreshScrollPoints())
          && canStartRefresh(at: now)

        if shouldRefresh {
          scheduleCommitRefresh(reason: "Live stitched preview")
          return
        }

        if idleDuration >= scrollIdleTimeout {
          if hasPendingMotion, canStartRefresh(at: now) {
            scheduleCommitRefresh(reason: "Latest visible frame")
          }
          return
        }
      }
    }
  }

  private func canStartRefresh(at now: TimeInterval) -> Bool {
    guard !isRefreshingPreview else { return false }
    guard let lastRefreshTime else { return true }
    return now - lastRefreshTime >= minimumRefreshSpacing()
  }

  private func waitForPendingPreviewRefresh() async {
    await commitScheduler?.waitForIdle()
    while isRefreshingPreview {
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func startLivePreviewIfPossible() async {
    guard let sessionModel else { return }
    guard sessionModel.phase == .capturing else { return }

    do {
      let context = try await ensurePreparedCaptureContext()
      let frameSource = liveFrameSource ?? ScrollingCaptureFrameSource()
      liveFrameSource = frameSource

      try await frameSource.start(
        with: context,
        frameHandler: { [weak self] frame in
          self?.publishLivePreviewFrame(frame)
        },
        failureHandler: { [weak self] errorDescription in
          self?.handleLivePreviewFailure(errorDescription)
        }
      )
      sessionMetrics.recordLivePreviewStart(success: true)
      sessionModel.livePreviewImage = nil
      sessionModel.isUsingLivePreview = true
      sessionModel.runtimeState = .streaming
      sessionModel.previewCaption = L10n.ScrollingCapture.captionLivePreviewRunning
      updatePreviewTruthState()
      logScrollingCaptureDebug(
        "live-stream-started",
        context: [
          "sourceRect": "\(Int(context.sourceRect.width))x\(Int(context.sourceRect.height))",
          "outputSize": "\(context.outputWidth)x\(context.outputHeight)",
          "streamScale": Self.formattedDebugDouble(Double(context.scaleFactor)),
          "commitScale": Self.formattedDebugDouble(Double(captureScaleFactor)),
          "ringFrames": "\(liveFrameRing.frames.count)",
        ]
      )
    } catch {
      sessionMetrics.recordLivePreviewStart(success: false)
      sessionMetrics.recordLivePreviewFallbackActivation()
      sessionModel.isUsingLivePreview = false
      updatePreviewTruthState()
      logScrollingCaptureDebug(
        "live-stream-fallback",
        context: ["error": error.localizedDescription]
      )
      DiagnosticLogger.shared.log(
        .warning,
        .capture,
        "Scrolling capture live preview fallback to stitched preview",
        context: ["error": error.localizedDescription]
      )
    }
  }

  private func stopLivePreviewIfNeeded(clearImage: Bool = true) {
    liveFrameSource?.stop()
    liveFrameSource = nil
    liveFrameRing.reset()
    lastLivePreviewPublishedAt = nil
    if clearImage {
      sessionModel?.livePreviewImage = nil
    }
    sessionModel?.isUsingLivePreview = false
    updatePreviewTruthState()
  }

  private func waitForInitialLiveFrame() async {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.25
    while liveFrameRing.latest == nil,
          ProcessInfo.processInfo.systemUptime < deadline,
          sessionModel?.phase == .capturing {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func publishLivePreviewFrame(_ frame: ScrollingCaptureFrame) {
    guard let sessionModel, sessionModel.phase == .capturing else { return }
    if frame.motionScore == 0, !shouldProcessStationaryHeartbeat() {
      return
    }

    let publishStartedAt = CFAbsoluteTimeGetCurrent()
    let observedFrame = liveFrameRing.append(frame)
    livePreviewFrameSequence = observedFrame.sequenceNumber
    sessionModel.livePreviewImage = observedFrame.image
    sessionModel.isUsingLivePreview = true
    if !(commitScheduler?.isRunning ?? false), sessionModel.runtimeState != .paused {
      sessionModel.runtimeState = .previewing
    }
    lastLivePreviewPublishedAt = observedFrame.capturedAt
    let publishDurationMs = Self.elapsedMilliseconds(since: publishStartedAt)
    sessionMetrics.recordLivePreviewFramePublished(
      at: observedFrame.capturedAt,
      publishDurationMs: publishDurationMs
    )
    updatePreviewTruthState()

    // Real-time pipeline: every distinct stream frame drives stitching directly.
    // The scheduler coalesces bursts to the newest frame, so the stream callback
    // never blocks and stationary periods produce no new frames at all.
    if isStreamCommitEnabled {
      scheduleCommitRefresh(reason: "Stream frame")
    }
    if shouldLogLiveFrameSample(observedFrame) {
      logScrollingCaptureDebug(
        "live-frame-sample",
        context: [
          "sequence": "\(observedFrame.sequenceNumber)",
          "imageSize": imageSizeString(observedFrame.image),
          "ringFrames": "\(liveFrameRing.frames.count)",
          "lastCommittedSequence": optionalString(liveFrameRing.lastCommittedSequenceNumber),
          "publishMs": "\(publishDurationMs)",
          "previewTruth": previewTruthStateName(sessionModel.previewTruthState),
          "activePreview": sessionModel.previewImage == nil ? "live" : "stitched",
        ]
      )
    }
  }

  private func handleLivePreviewFailure(_ errorDescription: String) {
    sessionMetrics.recordLivePreviewFailure()
    DiagnosticLogger.shared.log(
      .warning,
      .capture,
      "Scrolling capture live preview stream stopped",
      context: ["error": errorDescription]
    )
    stopLivePreviewIfNeeded(clearImage: false)
    sessionModel?.runtimeState = .paused
    updatePreviewTruthState()
  }

  private func normalizedExpectedDeltaPixels(from rawValue: Int) -> Int? {
    guard rawValue != 0, let scrollEventToMotionSign else { return nil }

    let sign = (rawValue > 0 ? 1 : -1) * scrollEventToMotionSign
    let magnitude = abs(rawValue)
    guard let lastAcceptedDeltaPixels, lastAcceptedDeltaPixels > 0 else {
      return sign * min(max(16, magnitude), 1_600)
    }

    let blendedMagnitude = Int(round(Double(magnitude + lastAcceptedDeltaPixels) / 2.0))
    let lowerBound = max(16, Int(Double(lastAcceptedDeltaPixels) * 0.55))
    let upperBound = max(lowerBound + 28, Int(Double(lastAcceptedDeltaPixels) * 1.85))
    let clampedMagnitude = min(max(lowerBound, blendedMagnitude), upperBound)
    return sign * clampedMagnitude
  }

  private func stitchCapturedImage(
    _ capturedImage: CGImage,
    expectedSignedDeltaPixels: Int?,
    renderMergedImage: Bool
  ) async -> (ScrollingCaptureStitchUpdate?, ScrollingCaptureStitcher?, CGImage?) {
    let currentStitcher = stitcher
    let maxOutputHeight = maxOutputHeight
    let previewMaxWidth = ScrollingCapturePreviewLayout.renderPixelWidth
    let previewMaxHeight = ScrollingCapturePreviewLayout.renderPixelHeight

    return await withCheckedContinuation { continuation in
      processingQueue.async {
        autoreleasepool {
          if let currentStitcher {
            let update = currentStitcher.append(
              capturedImage,
              maxOutputHeight: maxOutputHeight,
              expectedSignedDeltaPixels: expectedSignedDeltaPixels,
              renderMergedImage: renderMergedImage
            )
            // The preview thumbnail is maintained incrementally by the canvas,
            // so producing it here stays cheap and queue-confined.
            let previewImage = currentStitcher.previewImage(
              maxPixelWidth: previewMaxWidth,
              maxPixelHeight: previewMaxHeight
            )
            continuation.resume(returning: (update, currentStitcher, previewImage))
          } else {
            let newStitcher = ScrollingCaptureStitcher()
            let update = newStitcher.start(
              with: capturedImage,
              maxOutputHeight: maxOutputHeight
            )
            let previewImage = newStitcher.previewImage(
              maxPixelWidth: previewMaxWidth,
              maxPixelHeight: previewMaxHeight
            )
            continuation.resume(returning: (update, newStitcher, previewImage))
          }
        }
      }
    }
  }

  private func minimumRefreshSpacing() -> TimeInterval {
    lastAcceptedDeltaPixels == nil ? defaultMinimumRefreshSpacing : fastMinimumRefreshSpacing
  }

  private func scrollSettleDelay() -> TimeInterval {
    lastAcceptedDeltaPixels == nil ? defaultScrollSettleDelay : fastScrollSettleDelay
  }

  private func minimumPendingScrollPoints() -> CGFloat {
    lastAcceptedDeltaPixels == nil ? defaultMinimumPendingScrollPoints : fastMinimumPendingScrollPoints
  }

  private func forcedRefreshScrollPoints() -> CGFloat {
    guard let lastAcceptedDeltaPixels, lastAcceptedDeltaPixels > 0 else {
      return defaultForcedRefreshScrollPoints
    }

    let estimatedPoints = CGFloat(lastAcceptedDeltaPixels) / max(captureScaleFactor, 1)
    let adaptivePoints = estimatedPoints * 0.42
    return min(defaultForcedRefreshScrollPoints, max(fastForcedRefreshScrollPoints, adaptivePoints))
  }

  private func scaleFactor(for rect: CGRect) -> CGFloat {
    let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
    return max(screen?.backingScaleFactor ?? 2, 2)
  }

  private func previewRuntimeState() -> ScrollingCaptureRuntimeState {
    guard let sessionModel, sessionModel.phase == .capturing else { return .ready }
    if sessionModel.isUsingLivePreview, sessionModel.livePreviewImage != nil {
      return .previewing
    }
    return .streaming
  }

  private func performScheduledCommit(_ request: ScrollingCaptureCommitScheduler.Request) async {
    guard sessionModel?.phase == .capturing else { return }
    if sessionModel?.isUsingLivePreview == true,
       liveFrameRing.latestFrame(after: liveFrameRing.lastCommittedSequenceNumber) == nil {
      // Stream-driven schedule with no new frame; nothing to stitch.
      return
    }
    let update = await refreshPreview(
      reason: request.reason,
      expectedSignedDeltaPixelsOverride: request.expectedSignedDeltaPixels
    )
    lastScheduledCommitSequenceNumber = request.sequenceNumber
    lastScheduledCommitUpdate = update
    updatePreviewTruthState()
  }

  private func makeCommitScheduler() -> ScrollingCaptureCommitScheduler {
    ScrollingCaptureCommitScheduler(
      onRequestCoalesced: { [weak self] in
        self?.sessionMetrics.recordCommitCoalesced()
      },
      operation: { [weak self] request in
        guard let self else { return }
        await performScheduledCommit(request)
      }
    )
  }

  @discardableResult
  private func scheduleCommitRefresh(
    reason: String,
    expectedSignedDeltaPixelsOverride: Int? = nil
  ) -> ScrollingCaptureCommitScheduler.Request? {
    guard let sessionModel, sessionModel.phase == .capturing else { return nil }
    sessionMetrics.recordCommitScheduled()
    let request = commitScheduler?.schedule(
      reason: reason,
      expectedSignedDeltaPixels: expectedSignedDeltaPixelsOverride
    )
    updatePreviewTruthState()
    return request
  }

  private func beginFinalizing() {
    guard let sessionModel else { return }

    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    sessionModel.phase = .finalizing
    sessionModel.runtimeState = .finalizing
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.finalizingCurrentCapture,
      guidance: .lockingCurrentCapture
    )
    sessionModel.previewCaption = L10n.ScrollingCapture.captionFinalizingStitchedResult
    sessionMetrics.recordFinalizingStarted(at: ProcessInfo.processInfo.systemUptime)
    updatePreviewTruthState()
  }

  private func installSessionKeyMonitorsIfNeeded() {
    guard localSessionKeyMonitor == nil else { return }

    localSessionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }
      guard let self else { return event }
      return handleSessionEscapeKey() ? nil : event
    }

    globalSessionKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return }
      DispatchQueue.main.async {
        _ = self?.handleSessionEscapeKey()
      }
    }
  }

  private func removeSessionKeyMonitors() {
    if let localSessionKeyMonitor {
      NSEvent.removeMonitor(localSessionKeyMonitor)
      self.localSessionKeyMonitor = nil
    }

    if let globalSessionKeyMonitor {
      NSEvent.removeMonitor(globalSessionKeyMonitor)
      self.globalSessionKeyMonitor = nil
    }
  }

  @discardableResult
  private func handleSessionEscapeKey() -> Bool {
    guard let sessionModel else { return false }

    switch sessionModel.phase {
    case .ready:
      sessionMetrics.recordPreStartEscapeCancel()
      cancel()
      return true
    case .finalizing, .saving:
      sessionMetrics.recordFinalizingBlockedInput()
      return true
    case .capturing:
      return false
    }
  }

  private func recordCommittedObservation(for outcome: ScrollingCaptureStitchOutcome) {
    switch outcome {
    case .initialized, .appended, .ignoredNoMovement:
      lastCommittedObservationAt = ProcessInfo.processInfo.systemUptime
    case .ignoredAlignmentFailed, .reachedHeightLimit:
      break
    }
  }

  private func handleAutoScrollStitchUpdate(_ update: ScrollingCaptureStitchUpdate) {
    guard sessionModel?.isAutoScrolling == true else { return }

    if update.likelyReachedBoundary {
      autoScrollStationaryUpdateCount += 1
    } else {
      autoScrollStationaryUpdateCount = 0
    }

    if update.likelyReachedBoundary {
      // A single unchanged compositor sample is common during inertial scroll.
      // Require sustained stationary heartbeats and at least one real append
      // before treating it as the end of the scrollable content.
      guard ScrollingCaptureAutoScrollPolicy.shouldConfirmBoundary(
        acceptedFrameCount: update.acceptedFrameCount,
        stationaryUpdateCount: autoScrollStationaryUpdateCount
      ) else { return }
    }

    switch ScrollingCaptureAutoScrollPolicy.stitchAction(for: update) {
    case .finishCapture:
      stopAutoScrolling()
      finish()
    case .stopScrolling:
      stopAutoScrolling()
    case .keepScrolling:
      break
    }
  }

  private func shouldProcessStationaryHeartbeat() -> Bool {
    if sessionModel?.isAutoScrolling == true {
      return true
    }
    guard let lastScrollEventTime else { return false }
    return ProcessInfo.processInfo.systemUptime - lastScrollEventTime <= scrollIdleTimeout * 2
  }

  private func finalizingPreviewCaption(for update: ScrollingCaptureStitchUpdate) -> String {
    switch update.outcome {
    case .initialized:
      L10n.ScrollingCapture.finalizingFramesLocked(update.acceptedFrameCount)
    case .ignoredNoMovement:
      update.likelyReachedBoundary
        ? L10n.ScrollingCapture.captionFinalizingCurrentResultNoNewContent
        : L10n.ScrollingCapture.finalizingFramesLocked(update.acceptedFrameCount)
    case .appended(let deltaY):
      L10n.ScrollingCapture.finalFrameLocked(update.acceptedFrameCount, deltaY)
    case .ignoredAlignmentFailed:
      L10n.ScrollingCapture.captionFinalizingCurrentResultLastFrameSkipped
    case .reachedHeightLimit:
      L10n.ScrollingCapture.framesStitchedHeightLimitReached(update.acceptedFrameCount)
    }
  }

  private func finalizingStatusText(for update: ScrollingCaptureStitchUpdate) -> String {
    switch update.outcome {
    case .initialized, .appended:
      L10n.ScrollingCaptureStatus.finalizingFrames(update.acceptedFrameCount)
    case .ignoredNoMovement:
      update.likelyReachedBoundary
        ? L10n.ScrollingCaptureStatus.finalizingNoNewContent
        : L10n.ScrollingCaptureStatus.finalizingFrames(update.acceptedFrameCount)
    case .ignoredAlignmentFailed:
      L10n.ScrollingCaptureStatus.finalizingCouldntAlignLastFrame
    case .reachedHeightLimit:
      L10n.ScrollingCaptureStatus.finalizingHeightLimitReached
    }
  }

  private func finalizingGuidanceKind(for update: ScrollingCaptureStitchUpdate)
    -> ScrollingCaptureSelectionGuidanceKind {
    switch update.outcome {
    case .reachedHeightLimit:
      .savingCurrentResult
    case .initialized, .appended, .ignoredNoMovement, .ignoredAlignmentFailed:
      .lockingCurrentCapture
    }
  }

  private func updatePreviewTruthState() {
    guard let sessionModel else { return }

    let schedulerPendingCount = commitScheduler?.activeRequestCount ?? 0
    let pendingCommitCount = max(schedulerPendingCount, isRefreshingPreview ? 1 : 0)
    sessionModel.pendingCommitCount = pendingCommitCount

    let previewLagMs: Int = if let lastLivePreviewPublishedAt {
      if let lastCommittedObservationAt {
        max(
          0,
          Int(((lastLivePreviewPublishedAt - lastCommittedObservationAt) * 1_000).rounded())
        )
      } else if sessionModel.isUsingLivePreview {
        previewTruthLagToleranceMs + 1
      } else {
        0
      }
    } else {
      0
    }
    sessionModel.previewCommitLagMs = previewLagMs

    let previewTruthState: ScrollingCapturePreviewTruthState
    switch sessionModel.phase {
    case .ready:
      previewTruthState = .ready
    case .capturing:
      if sessionModel.runtimeState == .paused {
        if sessionModel.livePreviewImage != nil || sessionModel.isUsingLivePreview {
          previewTruthState = .pausedRecovery
        } else if sessionModel.previewImage != nil || sessionModel.acceptedFrameCount > 0 {
          previewTruthState = .committedOnly
        } else {
          previewTruthState = .pausedRecovery
        }
      } else if sessionModel.isUsingLivePreview, sessionModel.livePreviewImage != nil {
        let hasCommittedTruth = lastCommittedObservationAt != nil || sessionModel.acceptedFrameCount > 0
        let hasCommittedPreview = sessionModel.previewImage != nil || sessionModel.acceptedFrameCount > 0
        let hasUncommittedScroll = abs(pendingScrollDistancePoints) > 2 || pendingCommitCount > 0

        if hasCommittedPreview {
          previewTruthState = hasUncommittedScroll ? .liveAhead : .committedOnly
        } else {
          let isLiveAhead = !hasCommittedTruth || previewLagMs > previewTruthLagToleranceMs
          previewTruthState = isLiveAhead ? .liveAhead : .liveSynced
        }
      } else if sessionModel.previewImage != nil || sessionModel.acceptedFrameCount > 0 {
        previewTruthState = .committedOnly
      } else {
        previewTruthState = .ready
      }
    case .finalizing:
      previewTruthState = .finalizing
    case .saving:
      previewTruthState = .saving
    }

    sessionModel.previewTruthState = previewTruthState
    if previewTruthState == .liveAhead {
      sessionMetrics.recordPreviewTruthLiveAhead(lagMs: previewLagMs)
    }
  }

  private func logScrollingCaptureCommitFrameSelected(_ commitFrame: CommitFrame) {
    logScrollingCaptureDebug(
      "commit-frame-selected",
      context: [
        "source": commitFrameSourceName(commitFrame.source),
        "sequence": optionalString(commitFrame.sequenceNumber),
        "lastCommittedSequence": optionalString(liveFrameRing.lastCommittedSequenceNumber),
        "ringFrames": "\(liveFrameRing.frames.count)",
        "frameAgeMs": optionalString(commitFrame.frameAgeMs),
        "duplicate": String(commitFrame.isDuplicateFrame),
        "inputSize": imageSizeString(commitFrame.image),
      ]
    )
  }

  private func logScrollingCaptureStitchUpdate(
    reason: String,
    expectedSignedDeltaPixels: Int?,
    shouldRenderMergedImage: Bool,
    commitFrame: CommitFrame,
    update: ScrollingCaptureStitchUpdate,
    captureDurationMs: Int,
    stitchDurationMs: Int,
    previewPublishDurationMs: Int,
    totalDurationMs: Int
  ) {
    var context: [String: String] = [
      "reason": reason,
      "source": commitFrameSourceName(commitFrame.source),
      "sequence": optionalString(commitFrame.sequenceNumber),
      "frameAgeMs": optionalString(commitFrame.frameAgeMs),
      "duplicate": String(commitFrame.isDuplicateFrame),
      "inputSize": imageSizeString(commitFrame.image),
      "expectedDeltaPx": optionalString(expectedSignedDeltaPixels),
      "outcome": stitchOutcomeName(update.outcome),
      "safety": stitchSafetyName(update.safety),
      "acceptedFrames": "\(update.acceptedFrameCount)",
      "outputHeightPx": "\(update.outputHeight)",
      "matchFailures": "\(update.matchFailureCount)",
      "mergeDirection": mergeDirectionName(update.mergeDirection),
      "likelyBoundary": String(update.likelyReachedBoundary),
      "captureMs": "\(captureDurationMs)",
      "stitchMs": "\(stitchDurationMs)",
      "previewPublishMs": "\(previewPublishDurationMs)",
      "totalMs": "\(totalDurationMs)",
      "renderMergedFullImage": String(shouldRenderMergedImage),
      "ringFrames": "\(liveFrameRing.frames.count)",
      "lastCommittedSequence": optionalString(liveFrameRing.lastCommittedSequenceNumber),
    ]

    addOutcomeDetails(update.outcome, to: &context)

    if let alignmentDebug = update.alignmentDebug {
      context["alignmentPath"] = alignmentDebug.path.rawValue
      context["confidence"] = Self.formattedDebugDouble(alignmentDebug.confidence)
      context["peakCorrelation"] = optionalString(alignmentDebug.peakCorrelation)
      context["peakToSecondRatio"] = optionalString(alignmentDebug.peakToSecondRatio)
      context["appendDeltaY"] = optionalString(alignmentDebug.appendDeltaY)
      context["horizontalShiftPx"] = "\(alignmentDebug.horizontalShift)"
      context["confidentBands"] = "\(alignmentDebug.confidentBandCount)"

      if let expectedSignedDeltaPixels, let appendDeltaY = alignmentDebug.appendDeltaY {
        context["deltaMagnitudeErrorPx"] = "\(abs(abs(expectedSignedDeltaPixels) - appendDeltaY))"
      }
    } else {
      context["alignmentPath"] = "none"
    }

    logScrollingCaptureDebug("stitch-update", context: context)
  }

  private func logScrollingCaptureRefreshFailure(
    reason: String,
    stage: String,
    captureDurationMs: Int,
    stitchDurationMs: Int,
    totalDurationMs: Int,
    commitFrame: CommitFrame? = nil,
    errorDescription: String? = nil
  ) {
    var context: [String: String] = [
      "reason": reason,
      "stage": stage,
      "captureMs": "\(captureDurationMs)",
      "stitchMs": "\(stitchDurationMs)",
      "totalMs": "\(totalDurationMs)",
      "ringFrames": "\(liveFrameRing.frames.count)",
      "lastCommittedSequence": optionalString(liveFrameRing.lastCommittedSequenceNumber),
    ]

    if let commitFrame {
      context["source"] = commitFrameSourceName(commitFrame.source)
      context["sequence"] = optionalString(commitFrame.sequenceNumber)
      context["frameAgeMs"] = optionalString(commitFrame.frameAgeMs)
      context["inputSize"] = imageSizeString(commitFrame.image)
    }

    if let errorDescription {
      context["error"] = errorDescription
    }

    logScrollingCaptureDebug("refresh-failure", context: context)
  }

  private func logScrollingCaptureDebug(_ event: String, context: [String: String]) {
    var context = context
    context["generation"] = "\(sessionGeneration)"
    DiagnosticLogger.shared.log(
      .debug,
      .capture,
      "ScrollingCaptureDebug \(event)",
      context: context
    )
  }

  private func shouldLogLiveFrameSample(_ frame: ScrollingCaptureFrame) -> Bool {
    frame.sequenceNumber == 1 || frame.sequenceNumber % liveFrameDebugSampleInterval == 0
  }

  private func flushSessionMetricsIfNeeded(reason: String) {
    guard !didFlushSessionMetrics else { return }
    guard sessionMetrics.hadActivity else { return }

    didFlushSessionMetrics = true
    logScrollingCaptureDebug(
      "session-summary",
      context: sessionMetrics.summaryContext(reason: reason)
    )
    DiagnosticLogger.shared.log(
      .info,
      .capture,
      "Scrolling capture session metrics",
      context: sessionMetrics.summaryContext(reason: reason)
    )
  }

  private static func elapsedMilliseconds(since startedAt: CFAbsoluteTime) -> Int {
    Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1_000).rounded())
  }

  private func commitFrameSourceName(_ source: ScrollingCaptureCommitFrameSource) -> String {
    switch source {
    case .stream:
      "stream"
    case .stillFallback:
      "still-fallback"
    }
  }

  private func stitchOutcomeName(_ outcome: ScrollingCaptureStitchOutcome) -> String {
    switch outcome {
    case .initialized:
      "initialized"
    case .appended:
      "appended"
    case .ignoredNoMovement:
      "ignored-no-movement"
    case .ignoredAlignmentFailed:
      "ignored-alignment-failed"
    case .reachedHeightLimit:
      "reached-height-limit"
    }
  }

  private func addOutcomeDetails(
    _ outcome: ScrollingCaptureStitchOutcome,
    to context: inout [String: String]
  ) {
    if case .appended(let deltaY) = outcome {
      context["outcomeDeltaY"] = "\(deltaY)"
    }
  }

  private func stitchSafetyName(_ safety: ScrollingCaptureStitchSafety) -> String {
    switch safety {
    case .confirmed:
      "confirmed"
    case .tentative(let reason):
      "tentative:\(reason)"
    case .unsafe(let reason):
      "unsafe:\(reason)"
    }
  }

  private func mergeDirectionName(_ direction: ScrollingCaptureMergeDirection) -> String {
    switch direction {
    case .unresolved:
      "unresolved"
    case .appendFromBottom:
      "append-from-bottom"
    case .appendFromTop:
      "append-from-top"
    }
  }

  private func previewTruthStateName(_ state: ScrollingCapturePreviewTruthState) -> String {
    switch state {
    case .ready:
      "ready"
    case .committedOnly:
      "committed-only"
    case .liveSynced:
      "live-synced"
    case .liveAhead:
      "live-ahead"
    case .pausedRecovery:
      "paused-recovery"
    case .finalizing:
      "finalizing"
    case .saving:
      "saving"
    }
  }

  private func imageSizeString(_ image: CGImage) -> String {
    "\(image.width)x\(image.height)"
  }

  private func optionalString(_ value: Int?) -> String {
    value.map(String.init) ?? "none"
  }

  private func optionalString(_ value: Double?) -> String {
    guard let value else { return "none" }
    return Self.formattedDebugDouble(value)
  }

  private static func formattedDebugDouble(_ value: Double) -> String {
    String(format: "%.3f", value)
  }
}

extension ScrollingCaptureCoordinator: RecordingRegionOverlayDelegate {
  func overlayDidRequestReselection(_: RecordingRegionOverlayWindow) {}

  func overlay(_: RecordingRegionOverlayWindow, didMoveRegionTo rect: CGRect) {
    guard let sessionModel, sessionModel.phase == .ready else { return }
    updateSelectedRect(rect, reprepareSession: false)
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.releaseToLockUpdatedRegion,
      guidance: .releaseToLockArea
    )
  }

  func overlayDidFinishMoving(_: RecordingRegionOverlayWindow) {
    guard let sessionModel, sessionModel.phase == .ready else { return }
    refreshSelectionPreparation()
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.regionUpdated,
      guidance: .areaUpdated
    )
  }

  func overlay(_: RecordingRegionOverlayWindow, didReselectWithRect rect: CGRect) {
    guard let sessionModel, sessionModel.phase == .ready else { return }
    updateSelectedRect(rect, reprepareSession: true)
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.regionUpdated,
      guidance: .areaUpdated
    )
  }

  func overlay(_: RecordingRegionOverlayWindow, didResizeRegionTo rect: CGRect) {
    guard let sessionModel, sessionModel.phase == .ready else { return }
    updateSelectedRect(rect, reprepareSession: false)
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.releaseToLockUpdatedRegion,
      guidance: .releaseToLockArea
    )
  }

  func overlayDidFinishResizing(_: RecordingRegionOverlayWindow) {
    guard let sessionModel, sessionModel.phase == .ready else { return }
    refreshSelectionPreparation()
    sessionModel.setStatus(
      L10n.ScrollingCaptureStatus.regionUpdated,
      guidance: .areaUpdated
    )
  }
}
