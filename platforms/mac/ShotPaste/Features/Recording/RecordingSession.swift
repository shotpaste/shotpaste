//
//  RecordingSession.swift
//  ShotPaste
//
//  Thread-safe session class for managing AVAssetWriter during screen recording.
//  Separated from ScreenRecordingManager to ensure complete isolation from @MainActor.
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

nonisolated enum RecordingTimelineReadinessPolicy {
  static func canPublishReady(
    startSessionIssued: Bool,
    appendSucceeded: Bool,
    dimensionsMatch: Bool
  ) -> Bool {
    startSessionIssued && appendSucceeded && dimensionsMatch
  }

  /// The writer's source-time anchor may be the first frame that was offered
  /// to AVAssetWriter, but audio must be gated by the first frame that was
  /// actually appended.  In particular, a T0 backpressure retry must publish
  /// T1 rather than reserving T0 for the audio timeline.
  static func firstAppendedTimestamp(
    existing: CMTime?,
    appendedTimestamp: CMTime
  ) -> CMTime? {
    existing ?? (appendedTimestamp.isValid ? appendedTimestamp : nil)
  }
}

nonisolated struct RecordingStreamFailureObservation: Sendable, Equatable {
  let wasFirstVideoFrameReady: Bool
  let wasCapturing: Bool
}

/// A thread-safe class that holds the AVAssetWriter components.
/// This allows safe access from any thread without crossing @MainActor boundaries.
/// Implements lazy start: session begins when first sample buffer arrives to sync timestamps.
final nonisolated class RecordingSession: @unchecked Sendable {
  struct VideoWriteStats {
    let receivedFrames: Int
    let appendedFrames: Int
    let droppedFramesDueToBackpressure: Int
    let failedAppendFrames: Int
    let microphoneSamplesReceived: Int
    let microphoneSamplesAppended: Int
  }

  private let lock = NSLock()

  private var _assetWriter: AVAssetWriter?
  private var _videoInput: AVAssetWriterInput?
  private var _pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var _audioInput: AVAssetWriterInput?
  private var _microphoneInput: AVAssetWriterInput?
  private enum TimelineState {
    case notStarted
    /// `startSession` has been issued, but the first video append has not yet
    /// succeeded.  This state is deliberately not visible to audio writers.
    case starting
    case ready
    case failed
  }

  private struct VideoDimensionMismatch {
    let expectedWidth: Int
    let expectedHeight: Int
    let actualWidth: Int
    let actualHeight: Int
  }

  private struct VideoAppendPlan {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let shouldStartSession: Bool
    let adjustedTimestamp: CMTime
    let onFirstVideoFrame: (() -> Void)?
    let generation: UInt64?
  }

  private var _sessionStarted = false
  private var _timelineState: TimelineState = .notStarted
  private var _timelineStartTimestamp: CMTime?
  private var _timelineAppendInFlight = false
  private var _streamFailure = false
  private var _isCapturing = false
  private var _firstTimestamp: CMTime? // Track first video timestamp for timeline alignment
  private var _generation: UInt64?
  private var _firstVideoFrameReady = false
  private var _firstVideoFrameWaitCancelled = false
  private var _firstVideoFrameWaiter: CheckedContinuation<Bool, Never>?
  private var _pauseOffsetAccumulator: CMTime = .zero
  private var _onFirstVideoFrame: (() -> Void)?
  private var _videoFramesReceived = 0
  private var _videoFramesAppended = 0
  private var _videoFramesDroppedBackpressure = 0
  private var _videoFramesFailedAppend = 0
  private var _microphoneSamplesReceived = 0
  private var _microphoneSamplesAppended = 0
  private var _expectedVideoWidth: Int?
  private var _expectedVideoHeight: Int?
  private var _requiresExactVideoDimensions = false
  private var _didLogMissingPixelBuffer = false
  private var _didLogFrameDimensionMismatch = false
  private var _didLogVideoAppendFailure = false
  private var _didLogAudioAppendFailure = false
  private var _didLogMicrophoneAppendFailure = false
  private var _didLogSystemAudioSampleFormat = false
  private var _didLogMicrophoneAudioSampleFormat = false

  init() {}

  var assetWriter: AVAssetWriter? {
    get { lock.withLock { _assetWriter } }
    set { lock.withLock { _assetWriter = newValue } }
  }

  var videoInput: AVAssetWriterInput? {
    get { lock.withLock { _videoInput } }
    set { lock.withLock { _videoInput = newValue } }
  }

  var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor? {
    get { lock.withLock { _pixelBufferAdaptor } }
    set { lock.withLock { _pixelBufferAdaptor = newValue } }
  }

  var audioInput: AVAssetWriterInput? {
    get { lock.withLock { _audioInput } }
    set { lock.withLock { _audioInput = newValue } }
  }

  var microphoneInput: AVAssetWriterInput? {
    get { lock.withLock { _microphoneInput } }
    set { lock.withLock { _microphoneInput = newValue } }
  }

  var sessionStarted: Bool {
    get { lock.withLock { _sessionStarted } }
    set {
      lock.withLock {
        _sessionStarted = newValue
        if !newValue {
          _timelineState = .notStarted
          _timelineStartTimestamp = nil
          _timelineAppendInFlight = false
          _firstTimestamp = nil
        }
      }
    }
  }

  var isCapturing: Bool {
    get { lock.withLock { _isCapturing } }
    set { lock.withLock { _isCapturing = newValue } }
  }

  /// Whether a complete video sample has reached the writer session.
  ///
  /// This is intentionally separate from `sessionStarted`: the latter is the
  /// AVAssetWriter timeline state, while this flag is the synchronization point
  /// used by the audio-adapter start handshake.
  var firstVideoFrameReady: Bool {
    lock.withLock { _firstVideoFrameReady }
  }

  /// Begin a new capture generation.  A generation is never reused: late
  /// callbacks from an old stream/capturer are rejected before they can read
  /// or mutate the new writer state.
  func beginGeneration(_ generation: UInt64) {
    let waiter = lock.withLock {
      let waiter = resetLocked(waitCancelled: false)
      _generation = generation
      return waiter
    }
    waiter?.resume(returning: false)
  }

  /// Exposed for deterministic state-machine tests and manager-side guards.
  func isCurrentGeneration(_ generation: UInt64) -> Bool {
    lock.withLock { _generation == generation }
  }

  /// Whether the current generation's stream has reported a terminal failure.
  /// This is checked by the manager immediately before it enables user-visible
  /// recording and microphone state.
  func hasStreamFailure(generation: UInt64) -> Bool {
    lock.withLock { _generation == generation && _streamFailure }
  }

  /// Record an SCStream failure exactly once for a generation and wake any
  /// first-frame waiter with a failed result.  Readiness is deliberately
  /// invalidated even when it was already published: a waiter that won the
  /// ready race must not let an adapter start after its stream has stopped.
  @discardableResult
  func markStreamFailure(generation: UInt64) -> RecordingStreamFailureObservation? {
    let result: (RecordingStreamFailureObservation?, CheckedContinuation<Bool, Never>?) = lock.withLock {
      guard _generation == generation, !_streamFailure else {
        return (nil, nil)
      }

      let observation = RecordingStreamFailureObservation(
        wasFirstVideoFrameReady: _firstVideoFrameReady,
        wasCapturing: _isCapturing
      )
      _streamFailure = true
      _timelineState = .failed
      _timelineAppendInFlight = false
      _firstVideoFrameReady = false
      _firstVideoFrameWaitCancelled = true
      _onFirstVideoFrame = nil
      let waiter = _firstVideoFrameWaiter
      _firstVideoFrameWaiter = nil
      return (observation, waiter)
    }

    result.1?.resume(returning: false)
    return result.0
  }

  /// Reset the one-shot first-frame handshake before starting a new capture.
  /// The manager owns the lifecycle; this method is also useful for deterministic
  /// state-machine tests without constructing an SCStream.
  func resetFirstVideoFrameReadiness() {
    let waiter = lock.withLock {
      let waiter = _firstVideoFrameWaiter
      _firstVideoFrameWaiter = nil
      _firstVideoFrameReady = false
      _firstVideoFrameWaitCancelled = false
      return waiter
    }
    // A reset must never leave an already-registered continuation suspended.
    waiter?.resume(returning: false)
  }

  /// Wait until a complete video sample arrives.
  ///
  /// The result is `false` when the wait is cancelled (for example by the
  /// audio-adapter first-frame timeout). The continuation is stored under the
  /// same lock as the readiness bit, so a frame racing with timeout/cancellation
  /// can resume it exactly once.
  func waitForFirstVideoFrame(generation: UInt64? = nil) async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let immediateResult: Bool? = lock.withLock {
          guard readinessGenerationMatchesLocked(generation) else {
            return false
          }
          // Failure/cancellation has precedence over an already-published
          // ready bit.  didStopWithError can race this immediate-result path.
          if _streamFailure || _firstVideoFrameWaitCancelled || Task.isCancelled {
            return false
          }
          if _firstVideoFrameReady {
            return true
          }
          // A recording has one owner of the readiness handshake. Never replace
          // an existing continuation and strand the first waiter.
          if _firstVideoFrameWaiter != nil {
            return false
          }
          _firstVideoFrameWaiter = continuation
          return nil
        }

        if let immediateResult {
          continuation.resume(returning: immediateResult)
        }
      }
    } onCancel: {
      cancelFirstVideoFrameWait(generation: generation)
    }
  }

  /// Fulfil the first-frame handshake. Repeated calls are harmless.
  func markFirstVideoFrameReady(generation: UInt64? = nil) {
    let waiter: CheckedContinuation<Bool, Never>? = lock.withLock {
      guard readinessGenerationMatchesLocked(generation) else { return nil }
      guard !_firstVideoFrameReady, !_firstVideoFrameWaitCancelled, !_streamFailure else { return nil }
      _firstVideoFrameReady = true
      let waiter = _firstVideoFrameWaiter
      _firstVideoFrameWaiter = nil
      return waiter
    }
    waiter?.resume(returning: true)
  }

  /// End a pending first-frame wait without exposing why it ended to callers.
  /// Repeated calls are harmless and never resume a continuation twice.
  func cancelFirstVideoFrameWait(generation: UInt64? = nil) {
    let waiter: CheckedContinuation<Bool, Never>? = lock.withLock {
      guard readinessGenerationMatchesLocked(generation) else { return nil }
      _firstVideoFrameWaitCancelled = true
      let waiter = _firstVideoFrameWaiter
      _firstVideoFrameWaiter = nil
      return waiter
    }
    waiter?.resume(returning: false)
  }

  func setOnFirstVideoFrame(_ callback: (() -> Void)?) {
    lock.withLock {
      _onFirstVideoFrame = callback
    }
  }

  func setOnFirstVideoFrame(generation: UInt64, _ callback: (() -> Void)?) {
    lock.withLock {
      guard _generation == generation else { return }
      _onFirstVideoFrame = callback
    }
  }

  func configureExpectedVideoDimensions(width: Int, height: Int, requiresExact: Bool = false) {
    lock.withLock {
      _expectedVideoWidth = width
      _expectedVideoHeight = height
      _requiresExactVideoDimensions = requiresExact
      _didLogFrameDimensionMismatch = false
    }
  }

  func videoWriteStats() -> VideoWriteStats {
    lock.withLock {
      VideoWriteStats(
        receivedFrames: _videoFramesReceived,
        appendedFrames: _videoFramesAppended,
        droppedFramesDueToBackpressure: _videoFramesDroppedBackpressure,
        failedAppendFrames: _videoFramesFailedAppend,
        microphoneSamplesReceived: _microphoneSamplesReceived,
        microphoneSamplesAppended: _microphoneSamplesAppended
      )
    }
  }

  /// Set the total accumulated pause duration for PTS adjustment.
  /// Called by ScreenRecordingManager on each resume.
  func setAccumulatedPauseOffset(_ offset: CMTime) {
    lock.withLock {
      _pauseOffsetAccumulator = offset
    }
  }

  /// Create a copy of the audio sample buffer with PTS adjusted for pause offset.
  /// Returns nil if the copy fails or if the adjustment is invalid.
  private func adjustedAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
    guard offset.isNumeric, offset > .zero else { return sampleBuffer }

    var timingInfo = CMSampleTimingInfo()
    let status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)
    guard status == noErr else { return nil }

    timingInfo.presentationTimeStamp = CMTimeSubtract(timingInfo.presentationTimeStamp, offset)
    if timingInfo.decodeTimeStamp.isValid {
      timingInfo.decodeTimeStamp = CMTimeSubtract(timingInfo.decodeTimeStamp, offset)
    }

    var adjustedBuffer: CMSampleBuffer?
    let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timingInfo,
      sampleBufferOut: &adjustedBuffer
    )
    return copyStatus == noErr ? adjustedBuffer : nil
  }

  /// Thread-safe video frame write with lazy session start.
  ///
  /// `startSession` is issued at most once per generation, but readiness is
  /// published only after the pixel-buffer adaptor reports a successful append.
  /// A first-frame backpressure/append failure therefore leaves the timeline in
  /// `starting` so a later frame can retry without calling `startSession` again.
  func appendVideoSample(_ sampleBuffer: CMSampleBuffer, generation: UInt64? = nil) {
    // Check if this is a valid frame from ScreenCaptureKit. SCStream sends
    // status updates as sample buffers without image data.
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                    createIfNecessary: false) as? [
      [SCStreamFrameInfo: Any]
    ],
      let statusRawValue = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: statusRawValue),
      status == .complete else {
      return
    }

    guard (lock.withLock {
      appendGenerationMatchesLocked(generation) && _isCapturing && !_streamFailure
    }) else { return }

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      let shouldLog = lock.withLock {
        if _didLogMissingPixelBuffer {
          return false
        }
        _didLogMissingPixelBuffer = true
        return true
      }
      if shouldLog {
        DiagnosticLogger.shared.log(
          .warning,
          .recording,
          "Complete recording frame missing pixel buffer"
        )
      }
      return
    }

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard timestamp.isValid else { return }

    let (plan, mismatch): (VideoAppendPlan?, VideoDimensionMismatch?) = lock.withLock {
      guard appendGenerationMatchesLocked(generation),
            _isCapturing,
            !_streamFailure,
            let writer = _assetWriter,
            writer.status == .writing,
            let videoInput = _videoInput,
            let adaptor = _pixelBufferAdaptor
      else {
        return (nil, nil)
      }

      let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
      let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
      var mismatch: VideoDimensionMismatch?
      if let expectedWidth = _expectedVideoWidth,
         let expectedHeight = _expectedVideoHeight,
         (pixelWidth != expectedWidth || pixelHeight != expectedHeight) {
        if !_didLogFrameDimensionMismatch {
          _didLogFrameDimensionMismatch = true
          mismatch = VideoDimensionMismatch(
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            actualWidth: pixelWidth,
            actualHeight: pixelHeight
          )
        }
        // Adapter frames are a hard contract. Do not reserve the writer
        // timeline for an invalid physical buffer; wait for a compliant frame.
        if _requiresExactVideoDimensions {
          _videoFramesReceived += 1
          return (nil, mismatch)
        }
      }

      let offset = _pauseOffsetAccumulator
      let adjustedTimestamp = offset.isNumeric && offset > .zero
        ? CMTimeSubtract(timestamp, offset)
        : timestamp

      _videoFramesReceived += 1

      let shouldStartSession: Bool
      switch _timelineState {
      case .failed:
        return (nil, mismatch)
      case .ready:
        shouldStartSession = false
      case .notStarted:
        _timelineState = .starting
        _timelineStartTimestamp = adjustedTimestamp
        _timelineAppendInFlight = true
        shouldStartSession = true
      case .starting:
        // Video callbacks are normally serialized by the video queue, but this
        // guard also keeps test/concurrent callbacks from appending two first
        // frames at once while `startSession` is outside the lock.
        guard !_timelineAppendInFlight else { return (nil, mismatch) }
        _timelineAppendInFlight = true
        shouldStartSession = false
      }

      return (
        VideoAppendPlan(
          writer: writer,
          videoInput: videoInput,
          adaptor: adaptor,
          shouldStartSession: shouldStartSession,
          adjustedTimestamp: adjustedTimestamp,
          onFirstVideoFrame: _onFirstVideoFrame,
          generation: generation
        ),
        mismatch
      )
    }

    if let mismatch {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording frame dimension mismatch", context: [
        "expected": "\(mismatch.expectedWidth)x\(mismatch.expectedHeight)",
        "actual": "\(mismatch.actualWidth)x\(mismatch.actualHeight)",
      ])
    }

    guard let plan else { return }

    // A stream-stop callback may arrive after the plan leaves the lock but
    // before startSession/append is issued.  Do not let that stale plan touch
    // the writer or publish readiness.
    guard (lock.withLock {
      appendGenerationMatchesLocked(plan.generation) && _isCapturing && !_streamFailure
    }) else { return }

    if plan.shouldStartSession {
      plan.writer.startSession(atSourceTime: plan.adjustedTimestamp)
      guard plan.writer.status == .writing else {
        finishVideoAppendAttempt(
          plan,
          success: false,
          writerFailed: true
        )
        return
      }
      DiagnosticLogger.shared.log(.debug, .recording, "Recording writer session started", context: [
        "firstFrameTimestampSeconds": String(format: "%.3f", plan.adjustedTimestamp.seconds),
      ])
    }

    guard plan.videoInput.isReadyForMoreMediaData else {
      lock.withLock {
        guard appendGenerationMatchesLocked(plan.generation) else { return }
        _timelineAppendInFlight = false
        _videoFramesDroppedBackpressure += 1
      }
      return
    }

    let success = plan.adaptor.append(pixelBuffer, withPresentationTime: plan.adjustedTimestamp)
    finishVideoAppendAttempt(
      plan,
      success: success,
      writerFailed: plan.writer.status == .failed || plan.writer.status == .cancelled
    )
  }

  private func finishVideoAppendAttempt(
    _ plan: VideoAppendPlan,
    success: Bool,
    writerFailed: Bool
  ) {
    var waiter: CheckedContinuation<Bool, Never>?
    var firstFrameCallback: (() -> Void)?
    let shouldLogFailure = lock.withLock {
      guard appendGenerationMatchesLocked(plan.generation), !_streamFailure else { return false }
      _timelineAppendInFlight = false
      guard success else {
        _videoFramesFailedAppend += 1
        if writerFailed {
          _timelineState = .failed
        }
        if _didLogVideoAppendFailure {
          return false
        }
        _didLogVideoAppendFailure = true
        return true
      }

      _videoFramesAppended += 1
      guard _timelineState == .starting,
            RecordingTimelineReadinessPolicy.canPublishReady(
              startSessionIssued: true,
              appendSucceeded: success,
              dimensionsMatch: true
            )
      else { return false }
      _timelineState = .ready
      _sessionStarted = true
      // `_timelineStartTimestamp` is the writer anchor (T0).  The audio gate
      // must use the actual first successful append (T1 after backpressure).
      _firstTimestamp = RecordingTimelineReadinessPolicy.firstAppendedTimestamp(
        existing: _firstTimestamp,
        appendedTimestamp: plan.adjustedTimestamp
      )
      guard !_firstVideoFrameReady, !_firstVideoFrameWaitCancelled else { return false }
      _firstVideoFrameReady = true
      waiter = _firstVideoFrameWaiter
      _firstVideoFrameWaiter = nil
      firstFrameCallback = plan.onFirstVideoFrame
      return false
    }

    if let waiter {
      waiter.resume(returning: true)
    }
    firstFrameCallback?()

    if shouldLogFailure {
      logWriterIssue(
        "Failed to append recording video frame",
        writer: plan.writer,
        context: ["timestampSeconds": String(format: "%.3f", plan.adjustedTimestamp.seconds)]
      )
    }
  }

  /// Thread-safe audio sample write. System audio is accepted only after the
  /// writer timeline has become ready through a successful video append.
  func appendAudioSample(_ sampleBuffer: CMSampleBuffer, generation: UInt64? = nil) {
    // Get audio timestamp
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard timestamp.isValid else { return }
    logAudioSampleFormatIfNeeded(sampleBuffer, role: .systemAudio, generation: generation)

    let (writer, audioInput, firstTs, offset): (AVAssetWriter?, AVAssetWriterInput?, CMTime?, CMTime) = lock.withLock {
      guard appendGenerationMatchesLocked(generation),
            _isCapturing,
            _timelineState == .ready,
            let writer = _assetWriter,
            writer.status == .writing else {
        return (nil, nil, nil, .zero)
      }
      return (writer, _audioInput, _firstTimestamp, _pauseOffsetAccumulator)
    }

    guard let writer, writer.status == .writing else { return }
    guard let audioInput else { return }
    // Skip audio until video has started the session
    guard let firstTs else { return }

    let adjustedTimestamp = offset.isNumeric && offset > .zero ? CMTimeSubtract(timestamp, offset) : timestamp

    // Skip audio samples that arrived before video start
    guard CMTimeCompare(adjustedTimestamp, firstTs) >= 0 else { return }

    if audioInput.isReadyForMoreMediaData {
      guard (lock.withLock {
        appendGenerationMatchesLocked(generation) && _isCapturing && _timelineState == .ready
      }) else { return }
      guard let bufferToAppend = adjustedAudioSampleBuffer(sampleBuffer, offset: offset) else { return }
      let success = audioInput.append(bufferToAppend)
      if !success {
        let shouldLog = lock.withLock {
          guard appendGenerationMatchesLocked(generation) else { return false }
          if _didLogAudioAppendFailure {
            return false
          }
          _didLogAudioAppendFailure = true
          return true
        }
        if shouldLog {
          logWriterIssue(
            "Failed to append recording system audio sample",
            writer: writer,
            context: ["timestampSeconds": String(format: "%.3f", adjustedTimestamp.seconds)]
          )
        }
      }
    }
  }

  /// Thread-safe microphone sample write. The same timeline gate prevents
  /// microphone data from racing ahead of the first video append.
  func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer, generation: UInt64? = nil) {
    // Get mic timestamp
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard timestamp.isValid else { return }
    logAudioSampleFormatIfNeeded(sampleBuffer, role: .microphone, generation: generation)

    let (writer, microphoneInput, firstTs, offset): (AVAssetWriter?, AVAssetWriterInput?, CMTime?, CMTime) = lock
      .withLock {
        guard appendGenerationMatchesLocked(generation),
              _isCapturing,
              _timelineState == .ready,
              let writer = _assetWriter,
              writer.status == .writing else {
          return (nil, nil, nil, .zero)
        }
        return (writer, _microphoneInput, _firstTimestamp, _pauseOffsetAccumulator)
      }

    guard let writer, writer.status == .writing else { return }
    guard let microphoneInput else { return }
    // Skip mic audio until video has started the session
    guard let firstTs else { return }

    let adjustedTimestamp = offset.isNumeric && offset > .zero ? CMTimeSubtract(timestamp, offset) : timestamp

    // Skip mic samples that arrived before video start
    guard CMTimeCompare(adjustedTimestamp, firstTs) >= 0 else { return }

    guard (lock.withLock {
      appendGenerationMatchesLocked(generation) && _isCapturing && _timelineState == .ready
    }) else { return }
    lock.withLock { _microphoneSamplesReceived += 1 }

    if microphoneInput.isReadyForMoreMediaData {
      guard (lock.withLock {
        appendGenerationMatchesLocked(generation) && _isCapturing && _timelineState == .ready
      }) else { return }
      guard let bufferToAppend = adjustedAudioSampleBuffer(sampleBuffer, offset: offset) else { return }
      let success = microphoneInput.append(bufferToAppend)
      if success {
        lock.withLock {
          guard appendGenerationMatchesLocked(generation) else { return }
          _microphoneSamplesAppended += 1
        }
      } else {
        let shouldLog = lock.withLock {
          guard appendGenerationMatchesLocked(generation) else { return false }
          if _didLogMicrophoneAppendFailure {
            return false
          }
          _didLogMicrophoneAppendFailure = true
          return true
        }
        if shouldLog {
          logWriterIssue(
            "Failed to append recording microphone sample",
            writer: writer,
            context: ["timestampSeconds": String(format: "%.3f", adjustedTimestamp.seconds)]
          )
        }
      }
    }
  }

  /// Mark inputs as finished
  func finishInputs() {
    let inputs = lock.withLock {
      (_videoInput, _audioInput, _microphoneInput)
    }
    inputs.0?.markAsFinished()
    inputs.1?.markAsFinished()
    inputs.2?.markAsFinished()
  }

  /// Cancel writing
  func cancelWriting() {
    let writer = lock.withLock { _assetWriter }
    writer?.cancelWriting()
  }

  /// Finish writing asynchronously
  func finishWriting() async {
    let writer = lock.withLock { _assetWriter }
    guard let writer else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording finish requested without asset writer")
      return
    }

    DiagnosticLogger.shared.log(.debug, .recording, "Finishing recording writer", context: [
      "writerStatus": writerStatusLabel(writer.status),
    ])

    if writer.status == .writing {
      await writer.finishWriting()
      if writer.error != nil {
        logWriterIssue("Recording writer finished with error", writer: writer)
      } else {
        DiagnosticLogger.shared.log(.debug, .recording, "Recording writer finished", context: [
          "writerStatus": writerStatusLabel(writer.status),
        ])
      }
    } else {
      logWriterIssue("Recording writer not in writing state during finish", writer: writer)
    }
  }

  /// Reset all state
  func reset() {
    let waiter = lock.withLock { resetLocked(waitCancelled: true) }
    waiter?.resume(returning: false)
  }

  private func resetLocked(waitCancelled: Bool) -> CheckedContinuation<Bool, Never>? {
    let waiter = _firstVideoFrameWaiter
    _assetWriter = nil
    _videoInput = nil
    _pixelBufferAdaptor = nil
    _audioInput = nil
    _microphoneInput = nil
    _sessionStarted = false
    _timelineState = .notStarted
    _timelineStartTimestamp = nil
    _timelineAppendInFlight = false
    _streamFailure = false
    _isCapturing = false
    _firstTimestamp = nil
    _generation = nil
    _firstVideoFrameReady = false
    _firstVideoFrameWaitCancelled = waitCancelled
    _firstVideoFrameWaiter = nil
    _pauseOffsetAccumulator = .zero
    _onFirstVideoFrame = nil
    _videoFramesReceived = 0
    _videoFramesAppended = 0
    _videoFramesDroppedBackpressure = 0
    _videoFramesFailedAppend = 0
    _microphoneSamplesReceived = 0
    _microphoneSamplesAppended = 0
    _expectedVideoWidth = nil
    _expectedVideoHeight = nil
    _requiresExactVideoDimensions = false
    _didLogMissingPixelBuffer = false
    _didLogFrameDimensionMismatch = false
    _didLogVideoAppendFailure = false
    _didLogAudioAppendFailure = false
    _didLogMicrophoneAppendFailure = false
    _didLogSystemAudioSampleFormat = false
    _didLogMicrophoneAudioSampleFormat = false
    return waiter
  }

  private func readinessGenerationMatchesLocked(_ generation: UInt64?) -> Bool {
    guard let generation else { return true }
    return _generation == generation
  }

  private func appendGenerationMatchesLocked(_ generation: UInt64?) -> Bool {
    guard let activeGeneration = _generation else {
      return generation == nil
    }
    return generation == activeGeneration
  }

  private enum AudioSampleRole {
    case systemAudio
    case microphone

    var logValue: String {
      switch self {
      case .systemAudio: "systemAudio"
      case .microphone: "microphone"
      }
    }
  }

  private func logAudioSampleFormatIfNeeded(
    _ sampleBuffer: CMSampleBuffer,
    role: AudioSampleRole,
    generation: UInt64?
  ) {
    let shouldLog = lock.withLock {
      guard appendGenerationMatchesLocked(generation) else { return false }
      switch role {
      case .systemAudio:
        if _didLogSystemAudioSampleFormat {
          return false
        }
        _didLogSystemAudioSampleFormat = true
        return true
      case .microphone:
        if _didLogMicrophoneAudioSampleFormat {
          return false
        }
        _didLogMicrophoneAudioSampleFormat = true
        return true
      }
    }
    guard shouldLog else { return }

    var context: [String: String] = ["role": role.logValue]
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if timestamp.isValid, timestamp.seconds.isFinite {
      context["timestampSeconds"] = String(format: "%.3f", timestamp.seconds)
    }

    let duration = CMSampleBufferGetDuration(sampleBuffer)
    if duration.isValid, duration.seconds.isFinite {
      context["durationMs"] = String(format: "%.2f", duration.seconds * 1000)
    }

    var observedSampleRate: Double?
    if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
      context["mediaSubType"] = fourCC(CMFormatDescriptionGetMediaSubType(formatDescription))
      if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
        observedSampleRate = streamDescription.mSampleRate
        context["sampleRate"] = String(format: "%.0f", streamDescription.mSampleRate)
        context["channels"] = "\(streamDescription.mChannelsPerFrame)"
        context["formatID"] = fourCC(streamDescription.mFormatID)
        context["formatFlags"] = String(format: "0x%X", streamDescription.mFormatFlags)
        context["bitsPerChannel"] = "\(streamDescription.mBitsPerChannel)"
        context["framesPerPacket"] = "\(streamDescription.mFramesPerPacket)"
      }
    }

    DiagnosticLogger.shared.log(
      .info,
      .recording,
      "Recording audio sample format",
      context: context
    )

    // Surface a sample-rate mismatch proactively: a mic captured below the target rate
    // (e.g. a Bluetooth/HFP device at ~16 kHz) resampled to 48 kHz can produce piercing
    // spectral imaging. The capture output pins 48 kHz LPCM, so this should not fire.
    if role == .microphone,
       let observedSampleRate,
       observedSampleRate > 0,
       Int(observedSampleRate.rounded()) != RecordingAudioEncodingSettings.sampleRate {
      DiagnosticLogger.shared.log(
        .warning,
        .recording,
        "Microphone captured at non-target sample rate",
        context: [
          "role": role.logValue,
          "observedSampleRate": String(format: "%.0f", observedSampleRate),
          "expectedSampleRate": "\(RecordingAudioEncodingSettings.sampleRate)",
        ]
      )
    }
  }

  private func fourCC(_ value: FourCharCode) -> String {
    let bytes = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
          let string = String(bytes: bytes, encoding: .ascii)
    else {
      return "\(value)"
    }
    return string
  }

  private func logWriterIssue(
    _ message: String,
    writer: AVAssetWriter?,
    context: [String: String] = [:]
  ) {
    var context = context
    if let writer {
      context["writerStatus"] = writerStatusLabel(writer.status)
    }

    if let error = writer?.error {
      DiagnosticLogger.shared.logError(.recording, error, message, context: context)
    } else {
      DiagnosticLogger.shared.log(.error, .recording, message, context: context)
    }
  }

  private func writerStatusLabel(_ status: AVAssetWriter.Status) -> String {
    switch status {
    case .unknown: return "unknown"
    case .writing: return "writing"
    case .completed: return "completed"
    case .failed: return "failed"
    case .cancelled: return "cancelled"
    @unknown default: return "unknown"
    }
  }
}
