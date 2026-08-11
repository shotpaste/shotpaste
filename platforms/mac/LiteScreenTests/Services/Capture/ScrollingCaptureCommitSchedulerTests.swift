//
//  ScrollingCaptureCommitSchedulerTests.swift
//  LiteScreenTests
//
//  Unit tests for scrolling capture refresh coalescing.
//

@testable import LiteScreen
import XCTest

@MainActor
final class ScrollingCaptureCommitSchedulerTests: XCTestCase {
  func testScheduleCoalescesPendingRequestsBeforeRunnerStarts() async {
    var coalescedCount = 0
    var executed: [ScrollingCaptureCommitScheduler.Request] = []

    let scheduler = ScrollingCaptureCommitScheduler(
      onRequestCoalesced: { coalescedCount += 1 },
      operation: { request in executed.append(request) }
    )

    let first = scheduler.schedule(reason: "first", expectedSignedDeltaPixels: nil)
    let second = scheduler.schedule(reason: "second", expectedSignedDeltaPixels: 42)

    XCTAssertEqual(first.sequenceNumber, 1)
    XCTAssertEqual(second.sequenceNumber, 2)
    XCTAssertEqual(coalescedCount, 1)

    await scheduler.waitForIdle()

    XCTAssertEqual(executed.map(\.sequenceNumber), [2])
    XCTAssertEqual(executed.first?.reason, "second")
    XCTAssertEqual(executed.first?.expectedSignedDeltaPixels, 42)
  }

  func testDiscardPendingRequestPreventsQueuedOperation() async {
    var executed: [Int] = []
    let scheduler = ScrollingCaptureCommitScheduler(operation: { request in
      executed.append(request.sequenceNumber)
    })

    scheduler.schedule(reason: "discard", expectedSignedDeltaPixels: nil)
    scheduler.discardPendingRequest()

    await scheduler.waitForIdle()

    XCTAssertTrue(executed.isEmpty)
    XCTAssertFalse(scheduler.hasPendingWork)
  }

  func testScheduleWhileRunningExecutesCurrentThenLatestPending() async {
    var coalescedCount = 0
    var executed: [Int] = []
    var resumeFirstOperation: CheckedContinuation<Void, Never>?

    let scheduler = ScrollingCaptureCommitScheduler(
      onRequestCoalesced: { coalescedCount += 1 },
      operation: { request in
        executed.append(request.sequenceNumber)
        if request.sequenceNumber == 1 {
          await withCheckedContinuation { continuation in
            resumeFirstOperation = continuation
          }
        }
      }
    )

    scheduler.schedule(reason: "current", expectedSignedDeltaPixels: nil)

    while !scheduler.isRunning {
      await Task.yield()
    }

    scheduler.schedule(reason: "pending", expectedSignedDeltaPixels: 1)
    scheduler.schedule(reason: "latest", expectedSignedDeltaPixels: 2)
    XCTAssertEqual(scheduler.activeRequestCount, 2)
    XCTAssertEqual(coalescedCount, 1)

    resumeFirstOperation?.resume()
    await scheduler.waitForIdle()

    XCTAssertEqual(executed, [1, 3])
    XCTAssertFalse(scheduler.hasPendingWork)
  }
}
