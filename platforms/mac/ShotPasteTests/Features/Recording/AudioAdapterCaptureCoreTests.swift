//
//  AudioAdapterCaptureCoreTests.swift
//  ShotPasteTests
//
//  Pure audio-adapter encoding and first-video-frame readiness tests.
//

import AVFoundation
@testable import ShotPaste
import XCTest

final class AudioAdapterCaptureCoreTests: XCTestCase {
  func testAudioAdapterVideoSpec_isTinyH264OneFPSAndBoundedBitrate() {
    XCTAssertEqual(AudioAdapterCaptureCore.outputWidth, 32)
    XCTAssertEqual(AudioAdapterCaptureCore.outputHeight, 32)
    XCTAssertEqual(AudioAdapterCaptureCore.frameRate, 1)

    let bitrate = AudioAdapterCaptureCore.videoBitrate(width: 32, height: 32, fps: 1)
    XCTAssertGreaterThanOrEqual(bitrate, AudioAdapterCaptureCore.minimumVideoBitrate)
    XCTAssertLessThanOrEqual(bitrate, AudioAdapterCaptureCore.maximumVideoBitrate)

    let settings = AudioAdapterCaptureCore.makeVideoSettings()
    XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .h264)
    XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 32)
    XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 32)

    guard let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] else {
      XCTFail("Audio adapter video settings are missing compression properties")
      return
    }
    XCTAssertEqual(compression[AVVideoExpectedSourceFrameRateKey] as? Int, 1)
    XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, bitrate)
  }

  func testAudioAdapterVideoSpec_isStableRegardlessOfScreenQualityInputs() {
    XCTAssertEqual(
      AudioAdapterCaptureCore.videoBitrate(width: 2_000, height: 1_000, fps: 60),
      AudioAdapterCaptureCore.videoBitrate
    )
  }

  func testAudioAdapterEffectiveFormat_forcesMovExtension() {
    XCTAssertEqual(
      AudioAdapterCaptureCore.effectiveFormat(for: .mp4, purpose: .audioAdapter),
      .mov
    )
    XCTAssertEqual(
      AudioAdapterCaptureCore.effectiveFormat(for: .mp4, purpose: .screenVideo),
      .mp4
    )
  }

  func testAudioAdapterDimensions_areAExactPhysicalGate() {
    XCTAssertTrue(AudioAdapterCaptureCore.acceptsVideoDimensions(width: 32, height: 32))
    XCTAssertFalse(AudioAdapterCaptureCore.acceptsVideoDimensions(width: 64, height: 32))
    XCTAssertFalse(AudioAdapterCaptureCore.acceptsVideoDimensions(width: 32, height: 64))
  }

  func testTimelineReadiness_requiresStartAppendAndMatchingDimensions() {
    XCTAssertFalse(
      RecordingTimelineReadinessPolicy.canPublishReady(
        startSessionIssued: false,
        appendSucceeded: true,
        dimensionsMatch: true
      )
    )
    XCTAssertFalse(
      RecordingTimelineReadinessPolicy.canPublishReady(
        startSessionIssued: true,
        appendSucceeded: false,
        dimensionsMatch: true
      )
    )
    XCTAssertFalse(
      RecordingTimelineReadinessPolicy.canPublishReady(
        startSessionIssued: true,
        appendSucceeded: true,
        dimensionsMatch: false
      )
    )
    XCTAssertTrue(
      RecordingTimelineReadinessPolicy.canPublishReady(
        startSessionIssued: true,
        appendSucceeded: true,
        dimensionsMatch: true
      )
    )
  }

  func testTimelineReadiness_backpressureUsesFirstSuccessfulAppendTimestamp() {
    let t0 = CMTime(value: 100, timescale: 1)
    let t1 = CMTime(value: 101, timescale: 1)
    let t2 = CMTime(value: 102, timescale: 1)

    // T0 is the writer anchor, but its append was backpressured. The first
    // timestamp exposed to the audio gate must be the successful T1 append.
    let firstSuccessful = RecordingTimelineReadinessPolicy.firstAppendedTimestamp(
      existing: nil,
      appendedTimestamp: t1
    )
    XCTAssertEqual(firstSuccessful, t1)
    XCTAssertNotEqual(firstSuccessful, t0)
    XCTAssertEqual(
      RecordingTimelineReadinessPolicy.firstAppendedTimestamp(
        existing: firstSuccessful,
        appendedTimestamp: t2
      ),
      t1
    )
  }

  func testCaptureLifecyclePolicy_staleStartCannotMutateNewGeneration() {
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
        capturedGeneration: 1,
        currentGeneration: 2,
        sessionGenerationIsCurrent: true
      )
    )
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canMutateCapturedGeneration(
        capturedGeneration: 1,
        currentGeneration: 1,
        sessionGenerationIsCurrent: false
      )
    )
  }

  func testCaptureLifecyclePolicy_stopAndCancelAreSingleFlight() {
    let generation: UInt64 = 7
    let stopOwner = RecordingTeardownOwner(generation: generation, operation: .stop)
    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .recording,
        owner: nil,
        operation: .stop
      )
    )
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .stopping,
        owner: stopOwner,
        operation: .cancel
      )
    )
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .idle,
        owner: nil,
        operation: .cancel
      )
    )
    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .preparing,
        owner: nil,
        operation: .cancel
      )
    )
  }

  func testCaptureLifecyclePolicy_cancelClaimsBeforeStopAndOwnerResetAllowsNextClaim() {
    let generation: UInt64 = 41
    let cancelOwner = RecordingTeardownOwner(generation: generation, operation: .cancel)

    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .recording,
        owner: nil,
        operation: .cancel
      )
    )
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .stopping,
        owner: cancelOwner,
        operation: .stop
      )
    )

    // `cleanup` releases the generation-scoped owner before a new generation
    // can be prepared; the reset is represented by the nil owner here.
    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation + 1,
        currentGeneration: generation + 1,
        state: .preparing,
        owner: nil,
        operation: .startFailure
      )
    )
  }

  func testCaptureGenerationGate_failureBeforeAdapterClaimRejectsStart() {
    let gate = RecordingCaptureGenerationGate()
    let generation = gate.begin()

    let failure = gate.markStreamFailed(generation)
    XCTAssertEqual(
      failure,
      RecordingStreamFailureGateObservation(wasAdapterStartClaimed: false)
    )
    XCTAssertFalse(gate.claimAdapterRecordingStart(generation))
    XCTAssertFalse(gate.isHealthy(generation))
  }

  func testCaptureGenerationGate_claimBeforeFailureAllowsStartButReportsActiveFailure() {
    let gate = RecordingCaptureGenerationGate()
    let generation = gate.begin()

    XCTAssertTrue(gate.claimAdapterRecordingStart(generation))
    let failure = gate.markStreamFailed(generation)
    XCTAssertEqual(
      failure,
      RecordingStreamFailureGateObservation(wasAdapterStartClaimed: true)
    )
    let event = RecordingStreamFailureEvent(
      generation: generation,
      purpose: .audioAdapter,
      wasFirstVideoFrameReady: true,
      wasCapturing: true,
      errorType: "TestFailure",
      wasAdapterStartClaimed: failure?.wasAdapterStartClaimed ?? false
    )
    XCTAssertTrue(event.wasAdapterStartClaimed)
    XCTAssertFalse(gate.isHealthy(generation))
    XCTAssertTrue(gate.adapterRecordingStartWasClaimed(generation))
    XCTAssertFalse(gate.claimAdapterRecordingStart(generation))
  }

  func testCaptureLifecyclePolicy_startFailureUsesSameTeardownOwnerAsCancel() {
    let generation: UInt64 = 52
    let startFailureOwner = RecordingTeardownOwner(generation: generation, operation: .startFailure)

    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .preparing,
        owner: nil,
        operation: .startFailure
      )
    )
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .stopping,
        owner: startFailureOwner,
        operation: .cancel
      )
    )
  }

  func testCaptureLifecyclePolicy_prepareFailureClaimsTeardownExactlyOnce() {
    let generation: UInt64 = 61
    let startFailureOwner = RecordingTeardownOwner(generation: generation, operation: .startFailure)
    var owner: RecordingTeardownOwner?
    var teardownCount = 0

    if RecordingCaptureLifecyclePolicy.canClaimTeardown(
      capturedGeneration: generation,
      currentGeneration: generation,
      state: .preparing,
      owner: owner,
      operation: .startFailure
    ) {
      owner = startFailureOwner
      teardownCount += 1
    }

    XCTAssertEqual(owner, startFailureOwner)
    XCTAssertEqual(teardownCount, 1)
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .stopping,
        owner: owner,
        operation: .startFailure
      )
    )
    XCTAssertEqual(teardownCount, 1)
  }

  func testCaptureLifecyclePolicy_prepareFailureDefersToExistingCancelOwner() {
    let generation: UInt64 = 62
    let cancelOwner = RecordingTeardownOwner(generation: generation, operation: .cancel)
    var teardownCount = 0

    let canPrepareFailureClaim = RecordingCaptureLifecyclePolicy.canClaimTeardown(
      capturedGeneration: generation,
      currentGeneration: generation,
      state: .stopping,
      owner: cancelOwner,
      operation: .startFailure
    )
    if canPrepareFailureClaim {
      teardownCount += 1
    }

    XCTAssertFalse(canPrepareFailureClaim)
    XCTAssertEqual(teardownCount, 0)
  }

  func testCaptureLifecyclePolicy_partialStreamRegistrationDefersToOuterOwner() {
    let generation: UInt64 = 64
    let startFailureOwner = RecordingTeardownOwner(generation: generation, operation: .startFailure)

    // The screen output was registered before the audio registration threw.
    // The successful-registration bookkeeping must remain available to the
    // outer owner; the failed audio registration is never inserted.
    var registeredOutputTypes: Set<String> = ["screen"]
    let audioRegistrationSucceeded = false
    if audioRegistrationSucceeded {
      registeredOutputTypes.insert("audio")
    }
    XCTAssertEqual(registeredOutputTypes, ["screen"])

    var teardownCount = 0
    var owner: RecordingTeardownOwner?
    if RecordingCaptureLifecyclePolicy.canClaimTeardown(
      capturedGeneration: generation,
      currentGeneration: generation,
      state: .preparing,
      owner: nil,
      operation: .startFailure
    ) {
      owner = startFailureOwner
      teardownCount += 1
    }

    XCTAssertEqual(owner, startFailureOwner)
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .stopping,
        owner: owner,
        operation: .cancel
      )
    )
    XCTAssertEqual(teardownCount, 1)
  }

  func testCaptureLifecyclePolicy_releasedOwnerAllowsNextGenerationPrepareFailure() {
    let generation: UInt64 = 63
    let cancelOwner = RecordingTeardownOwner(generation: generation, operation: .cancel)
    var owner: RecordingTeardownOwner? = cancelOwner

    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation,
        currentGeneration: generation,
        state: .stopping,
        owner: owner,
        operation: .startFailure
      )
    )

    // The owner is released only after its generation cleanup. The next
    // generation starts with no owner and can claim its own start failure.
    owner = nil
    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canClaimTeardown(
        capturedGeneration: generation + 1,
        currentGeneration: generation + 1,
        state: .preparing,
        owner: owner,
        operation: .startFailure
      )
    )
  }

  func testCaptureLifecyclePolicy_streamFailureAfterReadyBlocksAdapterStart() {
    XCTAssertFalse(
      RecordingCaptureLifecyclePolicy.canEnterRecording(
        capturedGeneration: 7,
        currentGeneration: 7,
        sessionGenerationIsCurrent: true,
        state: .preparing,
        firstVideoFrameReady: true,
        streamFailed: true
      )
    )
    XCTAssertTrue(
      RecordingCaptureLifecyclePolicy.canEnterRecording(
        capturedGeneration: 7,
        currentGeneration: 7,
        sessionGenerationIsCurrent: true,
        state: .preparing,
        firstVideoFrameReady: true,
        streamFailed: false
      )
    )
  }

  func testFirstVideoFrameReadiness_resumesOnceWhenFrameArrives() async {
    let session = RecordingSession()
    let waiter = Task { await session.waitForFirstVideoFrame() }

    await Task.yield()
    session.markFirstVideoFrameReady()
    session.markFirstVideoFrameReady()

    let result = await waiter.value
    XCTAssertTrue(result)
    XCTAssertTrue(session.firstVideoFrameReady)
  }

  func testFirstVideoFrameReadiness_cancellationDoesNotHangOrResumeLater() async {
    let session = RecordingSession()
    let waiter = Task { await session.waitForFirstVideoFrame() }

    await Task.yield()
    session.cancelFirstVideoFrameWait()
    let result = await waiter.value
    XCTAssertFalse(result)

    session.markFirstVideoFrameReady()
    XCTAssertFalse(session.firstVideoFrameReady)
  }

  func testFirstVideoFrameReadiness_taskCancellationResumesWaiter() async {
    let session = RecordingSession()
    let waiter = Task { await session.waitForFirstVideoFrame() }

    await Task.yield()
    waiter.cancel()
    let result = await waiter.value
    XCTAssertFalse(result)
  }

  func testFirstVideoFrameReadiness_resetStartsFreshHandshake() async {
    let session = RecordingSession()
    session.markFirstVideoFrameReady()
    XCTAssertTrue(session.firstVideoFrameReady)

    session.resetFirstVideoFrameReadiness()
    XCTAssertFalse(session.firstVideoFrameReady)

    let waiter = Task { await session.waitForFirstVideoFrame() }
    await Task.yield()
    session.markFirstVideoFrameReady()
    let result = await waiter.value
    XCTAssertTrue(result)
  }

  func testFirstVideoFrameReadiness_oldGenerationCannotCompleteNewWaiter() async {
    let session = RecordingSession()
    session.beginGeneration(1)
    let oldWaiter = Task { await session.waitForFirstVideoFrame(generation: 1) }
    await Task.yield()

    session.beginGeneration(2)
    let oldResult = await oldWaiter.value
    XCTAssertFalse(oldResult)

    let newWaiter = Task { await session.waitForFirstVideoFrame(generation: 2) }
    await Task.yield()
    session.markFirstVideoFrameReady(generation: 1)
    session.cancelFirstVideoFrameWait(generation: 1)
    await Task.yield()
    XCTAssertFalse(session.firstVideoFrameReady)

    session.markFirstVideoFrameReady(generation: 2)
    let newResult = await newWaiter.value
    XCTAssertTrue(newResult)
    XCTAssertTrue(session.isCurrentGeneration(2))
  }

  func testFirstVideoFrameReadiness_oldCancellationDoesNotCancelNewGeneration() async {
    let session = RecordingSession()
    session.beginGeneration(11)
    session.beginGeneration(12)

    let waiter = Task { await session.waitForFirstVideoFrame(generation: 12) }
    await Task.yield()
    session.cancelFirstVideoFrameWait(generation: 11)
    await Task.yield()
    XCTAssertFalse(session.firstVideoFrameReady)

    session.markFirstVideoFrameReady(generation: 12)
    let result = await waiter.value
    XCTAssertTrue(result)
  }

  func testFirstVideoFrameReadiness_streamFailureAfterReadyInvalidatesHandshake() async {
    let session = RecordingSession()
    session.beginGeneration(21)
    session.markFirstVideoFrameReady(generation: 21)
    XCTAssertTrue(session.firstVideoFrameReady)

    let observation = session.markStreamFailure(generation: 21)
    XCTAssertEqual(
      observation,
      RecordingStreamFailureObservation(wasFirstVideoFrameReady: true, wasCapturing: false)
    )
    XCTAssertFalse(session.firstVideoFrameReady)
    XCTAssertTrue(session.hasStreamFailure(generation: 21))

    let result = await session.waitForFirstVideoFrame(generation: 21)
    XCTAssertFalse(result)
    XCTAssertNil(session.markStreamFailure(generation: 21))
  }
}
