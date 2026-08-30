//
//  TranslationOCRPipelineTests.swift
//  ShotPasteTests
//

import CoreGraphics
@testable import ShotPaste
import XCTest

final class TranslationOCRPipelineTests: XCTestCase {
  func testInjectedExecutorProducesLocalBlocksAndSessionLanguage() async throws {
    let executor = StubTranslationOCRExecutor(observations: [
      TranslationOCRObservation(
        text: "Hello world",
        confidence: 0.91,
        visionBounds: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.2)
      ),
    ])
    let pipeline = TranslationOCRPipeline(executor: executor)
    let image = try XCTUnwrap(makeImage(width: 200, height: 100))
    let result = try await pipeline.recognize(
      TranslationOCRRequest(
        image: image,
        screenRect: CGRect(x: -100, y: 50, width: 100, height: 50),
        sourceLanguageIdentifier: nil,
        deadline: Date().addingTimeInterval(2)
      )
    )

    XCTAssertEqual(result.lines.count, 1)
    XCTAssertEqual(result.blocks.map(\.id), ["block-0001"])
    XCTAssertEqual(result.detectedLanguage, "en")
    let block = try XCTUnwrap(result.blocks.first)
    XCTAssertEqual(block.screenBounds.minX, -90, accuracy: 0.001)
    XCTAssertEqual(block.screenBounds.minY, 75, accuracy: 0.001)
  }

  func testExpiredDeadlineStopsBeforeOCRExecutor() async throws {
    let executor = StubTranslationOCRExecutor(observations: [
      TranslationOCRObservation(
        text: "Should not run",
        confidence: 0.9,
        visionBounds: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.2)
      ),
    ])
    let pipeline = TranslationOCRPipeline(executor: executor)
    let image = try XCTUnwrap(makeImage(width: 200, height: 100))

    do {
      _ = try await pipeline.recognize(
        TranslationOCRRequest(
          image: image,
          screenRect: CGRect(x: 0, y: 0, width: 200, height: 100),
          deadline: Date().addingTimeInterval(-0.01)
        )
      )
      XCTFail("Expected deadline failure")
    } catch {
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
    let callCount = await executor.callCount
    XCTAssertEqual(callCount, 0)
  }

  func testCancellationPropagatesToInjectedExecutor() async throws {
    let executor = StubTranslationOCRExecutor(
      observations: [],
      sleepNanoseconds: 500_000_000
    )
    let pipeline = TranslationOCRPipeline(executor: executor)
    let image = try XCTUnwrap(makeImage(width: 200, height: 100))
    let task = Task {
      try await pipeline.recognize(
        TranslationOCRRequest(
          image: image,
          screenRect: CGRect(x: 0, y: 0, width: 200, height: 100),
          deadline: Date().addingTimeInterval(3)
        )
      )
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNonCooperativeExecutorCannotOutliveAbsoluteDeadlineForCaller() async throws {
    let executor = NonCooperativeOCRExecutor(delayNanoseconds: 350_000_000)
    let pipeline = TranslationOCRPipeline(executor: executor)
    let image = try XCTUnwrap(makeImage(width: 200, height: 100))
    let deadline = Date().addingTimeInterval(0.08)
    let started = Date()

    do {
      _ = try await pipeline.recognize(
        TranslationOCRRequest(
          image: image,
          screenRect: CGRect(x: 0, y: 0, width: 200, height: 100),
          deadline: deadline
        )
      )
      XCTFail("A late executor must not recover a result after the deadline")
    } catch let error as TranslationFailure {
      XCTAssertEqual(error, .timedOut)
    }

    XCTAssertLessThan(Date().timeIntervalSince(started), 0.4)
    try await Task.sleep(nanoseconds: 450_000_000)
    let callCount = await executor.callCount
    let returnedCount = await executor.returnedCount
    let cancellationObserved = await executor.cancellationObserved
    XCTAssertEqual(callCount, 1)
    XCTAssertEqual(returnedCount, 1, "The late executor should finish only after the caller has timed out")
    XCTAssertTrue(cancellationObserved, "The deadline race must cancel the executor task")
  }

  func testInjectedExecutorNeverExceedsTwoConcurrentTiles() async throws {
    let executor = ConcurrencyTrackingOCRExecutor()
    let pipeline = TranslationOCRPipeline(executor: executor, maximumConcurrentTiles: 4)
    let image = try XCTUnwrap(makeImage(width: 3_840, height: 2_880))
    _ = try await pipeline.recognize(
      TranslationOCRRequest(
        image: image,
        screenRect: CGRect(x: 0, y: 0, width: 3_840, height: 2_880),
        deadline: Date().addingTimeInterval(3)
      )
    )

    let callCount = await executor.callCount
    let maximumActive = await executor.maximumActive
    XCTAssertEqual(callCount, 4)
    XCTAssertLessThanOrEqual(maximumActive, 2)
  }

  func testBlockIDsStayStableWhenTileCompletionOrderChanges() async throws {
    let image = try XCTUnwrap(makeImage(width: 3_840, height: 1_000))
    let request = TranslationOCRRequest(
      image: image,
      screenRect: CGRect(x: 0, y: 0, width: 3_840, height: 1_000),
      deadline: Date().addingTimeInterval(3)
    )
    let first = try await TranslationOCRPipeline(
      executor: CompletionOrderOCRExecutor(reverse: false)
    ).recognize(request)
    let second = try await TranslationOCRPipeline(
      executor: CompletionOrderOCRExecutor(reverse: true)
    ).recognize(request)

    XCTAssertEqual(first.blocks.map(\.id), second.blocks.map(\.id))
    XCTAssertEqual(first.blocks.map(\.screenBounds), second.blocks.map(\.screenBounds))
  }

  func testCancellationBeforeContinuationIsReplayedAndLateSuccessIsIgnored() async throws {
    let state = VisionOCRRequestState<Int>()
    let task = Task { () throws -> Int in
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
        state.cancel(CancellationError())
        state.setContinuation(continuation)
      }
    }

    do {
      _ = try await task.value
      XCTFail("Expected the cancellation saved before continuation installation")
    } catch is CancellationError {
      // expected
    }
    state.finish(with: .success(42))
    XCTAssertTrue(state.isTerminated)
  }

  func testDeadlineStateResumesOnceWhenContinuationArrivesAfterTimeout() async throws {
    let state = VisionOCRRequestState<Int>()
    let task = Task { () throws -> Int in
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
        state.cancel(TranslationFailure.timedOut)
        state.setContinuation(continuation)
      }
    }

    do {
      _ = try await task.value
      XCTFail("Expected timeout")
    } catch let error as TranslationFailure {
      XCTAssertEqual(error, .timedOut)
    }
    state.finish(with: .success(7))
    XCTAssertTrue(state.isTerminated)
  }


  private func makeImage(width: Int, height: Int) -> CGImage? {
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage()
  }
}

private actor StubTranslationOCRExecutor: TranslationOCRExecutor {
  let observations: [TranslationOCRObservation]
  let sleepNanoseconds: UInt64
  private(set) var callCount = 0

  init(observations: [TranslationOCRObservation], sleepNanoseconds: UInt64 = 0) {
    self.observations = observations
    self.sleepNanoseconds = sleepNanoseconds
  }

  func recognize(
    tile _: LocalOCRTile,
    sourceLanguageIdentifier _: String?,
    deadline: Date
  ) async throws -> [TranslationOCRObservation] {
    callCount += 1
    if sleepNanoseconds > 0 {
      try await Task.sleep(nanoseconds: sleepNanoseconds)
    }
    guard Date() < deadline else { throw TranslationFailure.timedOut }
    return observations
  }
}

private actor NonCooperativeOCRExecutor: TranslationOCRExecutor {
  let delayNanoseconds: UInt64
  private(set) var callCount = 0
  private(set) var returnedCount = 0
  private(set) var cancellationObserved = false

  init(delayNanoseconds: UInt64) {
    self.delayNanoseconds = delayNanoseconds
  }

  func recognize(
    tile _: LocalOCRTile,
    sourceLanguageIdentifier _: String?,
    deadline _: Date
  ) async throws -> [TranslationOCRObservation] {
    callCount += 1
    let end = Date().addingTimeInterval(Double(delayNanoseconds) / 1_000_000_000)
    while Date() < end {
      // Deliberately ignore cancellation. The pipeline's race must detach and
      // cancel this task without waiting for this executor to cooperate.
      if Task.isCancelled { cancellationObserved = true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    returnedCount += 1
    return [
      TranslationOCRObservation(
        text: "late result",
        confidence: 0.9,
        visionBounds: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.2)
      ),
    ]
  }
}

private actor ConcurrencyTrackingOCRExecutor: TranslationOCRExecutor {
  private(set) var callCount = 0
  private(set) var active = 0
  private(set) var maximumActive = 0

  func recognize(
    tile _: LocalOCRTile,
    sourceLanguageIdentifier _: String?,
    deadline: Date
  ) async throws -> [TranslationOCRObservation] {
    callCount += 1
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    try await Task.sleep(nanoseconds: 30_000_000)
    guard Date() < deadline else { throw TranslationFailure.timedOut }
    return [
      TranslationOCRObservation(
        text: "Hello world",
        confidence: 0.9,
        visionBounds: CGRect(x: 0.05, y: 0.55, width: 0.15, height: 0.1)
      ),
    ]
  }
}

private actor CompletionOrderOCRExecutor: TranslationOCRExecutor {
  let reverse: Bool

  init(reverse: Bool) {
    self.reverse = reverse
  }

  func recognize(
    tile: LocalOCRTile,
    sourceLanguageIdentifier _: String?,
    deadline: Date
  ) async throws -> [TranslationOCRObservation] {
    let isFirstTile = tile.pixelRect.minX == 0
    let delay: UInt64 = (isFirstTile == reverse) ? 40_000_000 : 1_000_000
    try await Task.sleep(nanoseconds: delay)
    guard Date() < deadline else { throw TranslationFailure.timedOut }
    return [
      TranslationOCRObservation(
        text: "Hello world",
        confidence: 0.9,
        visionBounds: CGRect(x: 0.05, y: 0.55, width: 0.15, height: 0.1)
      ),
    ]
  }
}
