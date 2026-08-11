//
//  AnnotateBackgroundCutoutTests.swift
//  ShotPasteTests
//
//  Characterization tests for background cutout state transitions.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class AnnotateBackgroundCutoutTests: XCTestCase {
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeImage(width: Int, height: Int) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }

  func testToggleBackgroundCutoutWithoutSourceImageDoesNotProcess() {
    let state = makeAnnotateState()
    XCTAssertFalse(state.isCutoutApplied)

    state.toggleBackgroundCutout()

    XCTAssertFalse(state.isCutoutApplied)
    XCTAssertFalse(state.isCutoutProcessing)
  }

  /// Foreground segmentation timing and ML output are nondeterministic. This local-only
  /// smoke test verifies that processing starts on a supported OS.
  func testApplyBackgroundCutoutStartsProcessingOnSupportedOS() throws {
    try skipIfRunningInCI("applyBackgroundCutout runs async Vision ML")
    let state = makeAnnotateState()
    try state.loadImage(makeImage(width: 64, height: 64))
    guard state.canUseBackgroundCutout else {
      throw XCTSkip("Background cutout unsupported on this OS")
    }

    state.applyBackgroundCutout()

    XCTAssertTrue(state.isCutoutProcessing)
  }
}
