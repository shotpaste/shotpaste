//
//  SingleFrameStreamCaptureSessionTests.swift
//  LiteScreenTests
//
//  Regression tests for GitHub issue #286: the macOS 13 single-frame SCStream
//  fallback must always terminate (first frame, stream error, timeout or
//  cancellation) and resume its continuation exactly once — it must never hang
//  forever. Tests drive the session's state machine directly so no Screen
//  Recording permission is required.
//
//  Note: `arm` and `finish`/`cancel` are invoked inside the synchronous
//  continuation closure so the arming always happens before any outcome is
//  delivered — an unstructured `Task` would race and deliver outcomes before
//  the continuation is installed.
//

import CoreGraphics
@testable import LiteScreen
import XCTest

@MainActor
final class SingleFrameStreamCaptureSessionTests: XCTestCase {
  private func makeTestImage() -> CGImage {
    let context = CGContext(
      data: nil,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
  }

  func testFinish_firstResultWins_secondFinishIgnored() async throws {
    let session = SingleFrameStreamCaptureSession()

    let result: CGImage = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<CGImage, Error>) in
      session.arm(continuation: continuation, timeout: 60)
      session.finish(.success(makeTestImage()))
      // Second resume attempt must be ignored (a double resume would trap).
      session.finish(.failure(CaptureError.cancelled))
    }

    XCTAssertEqual(result.width, 1)
    XCTAssertEqual(result.height, 1)
  }

  func testTimeout_noFrameArriving_throwsWithinBoundedTime() async {
    let session = SingleFrameStreamCaptureSession()
    let startedAt = Date()

    do {
      let _: CGImage = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<CGImage, Error>) in
        session.arm(continuation: continuation, timeout: 0.2)
      }
      XCTFail("Expected a timeout error, got a frame")
    } catch {
      // The wait must terminate promptly — before the fix it hung forever.
      XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
      guard case CaptureError.captureFailed = error else {
        XCTFail("Expected CaptureError.captureFailed, got \(error)")
        return
      }
    }
    _ = session // keep the session alive across the await
  }

  func testCancel_pendingWait_throwsCancelledPromptly() async {
    let session = SingleFrameStreamCaptureSession()
    let startedAt = Date()

    do {
      let _: CGImage = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<CGImage, Error>) in
        session.arm(continuation: continuation, timeout: 60)
        session.cancel()
      }
      XCTFail("Expected a cancellation error, got a frame")
    } catch {
      XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
      guard case CaptureError.cancelled = error else {
        XCTFail("Expected CaptureError.cancelled, got \(error)")
        return
      }
    }
  }

  func testFinishFailure_propagatesError() async {
    let session = SingleFrameStreamCaptureSession()

    do {
      let _: CGImage = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<CGImage, Error>) in
        session.arm(continuation: continuation, timeout: 60)
        session.finish(.failure(CaptureError.noDisplayFound))
      }
      XCTFail("Expected an error, got a frame")
    } catch {
      guard case CaptureError.noDisplayFound = error else {
        XCTFail("Expected CaptureError.noDisplayFound, got \(error)")
        return
      }
    }
  }

  func testTimeout_afterSuccessfulFinish_doesNotResumeAgain() async throws {
    let session = SingleFrameStreamCaptureSession()

    let _: CGImage = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<CGImage, Error>) in
      session.arm(continuation: continuation, timeout: 0.1)
      session.finish(.success(makeTestImage()))
    }

    // Let the (cancelled) timeout lapse; a late fire or finish must not resume twice.
    try await Task.sleep(nanoseconds: 300_000_000)
    session.finish(.failure(CaptureError.cancelled))
  }
}
