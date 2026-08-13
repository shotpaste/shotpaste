//
//  AnnotateImageOpsTests.swift
//  ShotPasteTests
//
//  Characterization tests for image loading behavior on
//  AnnotateState. Pure/state-only assertions — ALWAYS-RUN.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class AnnotateImageOpsTests: XCTestCase {
  /// Keep AnnotateState alive for the test process; XCTest scope cleanup can
  /// crash while deinitializing this MainActor app-level ObservableObject.
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

  // MARK: - loadImage

  func testLoadImageSetsSourceAndSizesCanvasToImage() throws {
    let state = makeAnnotateState()
    let image = try makeImage(width: 240, height: 160)

    state.loadImage(image)

    XCTAssertTrue(state.hasImage)
    XCTAssertEqual(state.sourceImage?.size.width ?? 0, 240, accuracy: 0.0001)
    XCTAssertEqual(state.sourceImage?.size.height ?? 0, 160, accuracy: 0.0001)
    XCTAssertEqual(state.imageWidth, 240, accuracy: 0.0001)
    XCTAssertEqual(state.imageHeight, 160, accuracy: 0.0001)
    XCTAssertFalse(state.hasUnsavedChanges)
  }

  func testLoadImageResetsExistingAnnotations() throws {
    let state = makeAnnotateState()
    state.annotations = [
      AnnotationItem(
        type: .rectangle,
        bounds: CGRect(x: 5, y: 5, width: 20, height: 20),
        properties: AnnotationProperties()
      ),
    ]

    try state.loadImage(makeImage(width: 120, height: 80))

    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertNil(state.selectedAnnotationId)
    XCTAssertFalse(state.canUndo)
    XCTAssertFalse(state.canRedo)
  }
}
