//
//  AnnotateExportSaveTests.swift
//  LiteScreenTests
//
//  Characterization tests for the inline annotation renderer.
//  ALWAYS-RUN: renderFinalImage non-nil + dims (NO pixel equality — retina
//  pixel fidelity is already covered in AnnotateCoreTests).
//

import AppKit
import CoreGraphics
@testable import LiteScreen
import XCTest

@MainActor
final class AnnotateExportSaveTests: XCTestCase {
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

  // MARK: - renderFinalImage (dims only)

  func testRenderFinalImageReturnsNonNilImageMatchingSourceDimensions() throws {
    let state = makeAnnotateState()
    try state.loadImage(makeImage(width: 200, height: 120))

    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))

    // Default state: no crop, backgroundStyle == .none (padding 0), 1x image.
    // Point-size equals source point-size; pixel dims equal source pixel dims.
    XCTAssertEqual(rendered.size.width, 200, accuracy: 0.0001)
    XCTAssertEqual(rendered.size.height, 120, accuracy: 0.0001)

    let renderedCG = try XCTUnwrap(AnnotateExporter.bestCGImage(from: rendered))
    XCTAssertEqual(renderedCG.width, 200)
    XCTAssertEqual(renderedCG.height, 120)
  }

  func testRenderFinalImageReturnsNilWhenNoSourceImage() {
    let state = makeAnnotateState()
    XCTAssertNil(AnnotateExporter.renderFinalImage(state: state))
  }

  func testRenderFinalImageWithAnnotationsKeepsSourceDimensions() throws {
    let state = makeAnnotateState()
    try state.loadImage(makeImage(width: 160, height: 160))
    state.annotations = [
      AnnotationItem(
        type: .rectangle,
        bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
        properties: AnnotationProperties()
      ),
    ]

    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    XCTAssertEqual(rendered.size.width, 160, accuracy: 0.0001)
    XCTAssertEqual(rendered.size.height, 160, accuracy: 0.0001)
  }

  func testRenderFinalImageUsesCombinedBoundsGapAndPadding() throws {
    let state = makeAnnotateState()
    try state.loadImage(makeImage(width: 200, height: 100))
    try state.importImage(makeImage(width: 100, height: 100))
    state.setCombineDirection(.horizontal)
    state.setCombineGap(10)
    state.padding = 24

    let rendered = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))

    XCTAssertEqual(rendered.size.width, 358, accuracy: 0.001)
    XCTAssertEqual(rendered.size.height, 148, accuracy: 0.001)
  }
}
