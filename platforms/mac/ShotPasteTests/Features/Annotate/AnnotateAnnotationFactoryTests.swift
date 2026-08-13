//
//  AnnotateAnnotationFactoryTests.swift
//  ShotPasteTests
//
//  Characterization tests for `AnnotationFactory.createAnnotation` successful
//  creation paths (shape/line/pencil/blur). Counter, spotlight, highlighter,
//  and arrow creation are already covered in AnnotateCoreTests, so
//  this file only fills the remaining tool gaps.
//

import CoreGraphics
@testable import ShotPaste
import SwiftUI
import XCTest

final class AnnotateAnnotationFactoryTests: XCTestCase {
  private func makeContext(
    properties: AnnotationProperties = AnnotationProperties(),
    blurType: BlurType = .pixelated
  ) -> AnnotationFactory.CreationContext {
    AnnotationFactory.CreationContext(
      properties: properties,
      arrowStyle: .straight,
      arrowBendDirection: .primary,
      blurType: blurType,
      counterValue: 1
    )
  }

  func testCreateRectangleUsesNormalizedDragBounds() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .rectangle,
      from: CGPoint(x: 10, y: 20),
      to: CGPoint(x: 90, y: 80),
      path: [],
      context: makeContext()
    ))

    XCTAssertEqual(annotation.type, .rectangle)
    XCTAssertEqual(annotation.bounds, CGRect(x: 10, y: 20, width: 80, height: 60))
  }

  func testCreateRectangleNormalizesReversedDrag() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .rectangle,
      from: CGPoint(x: 90, y: 80),
      to: CGPoint(x: 10, y: 20),
      path: [],
      context: makeContext()
    ))

    XCTAssertEqual(annotation.type, .rectangle)
    XCTAssertEqual(annotation.bounds, CGRect(x: 10, y: 20, width: 80, height: 60))
  }

  func testCreateFilledRectangleCarriesTypeAndProperties() throws {
    let properties = AnnotationProperties(strokeColor: .blue, fillColor: .green, strokeWidth: 5)
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .filledRectangle,
      from: CGPoint(x: 0, y: 0),
      to: CGPoint(x: 40, y: 30),
      path: [],
      context: makeContext(properties: properties)
    ))

    XCTAssertEqual(annotation.type, .filledRectangle)
    XCTAssertEqual(annotation.bounds, CGRect(x: 0, y: 0, width: 40, height: 30))
    XCTAssertEqual(annotation.properties.strokeWidth, 5)
  }

  func testCreateOvalUsesNormalizedDragBounds() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .oval,
      from: CGPoint(x: 5, y: 5),
      to: CGPoint(x: 55, y: 35),
      path: [],
      context: makeContext()
    ))

    XCTAssertEqual(annotation.type, .oval)
    XCTAssertEqual(annotation.bounds, CGRect(x: 5, y: 5, width: 50, height: 30))
  }

  func testCreateLinePreservesEndpoints() throws {
    let start = CGPoint(x: 12, y: 18)
    let end = CGPoint(x: 48, y: 52)
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .line,
      from: start,
      to: end,
      path: [],
      context: makeContext()
    ))

    guard case .line(let lineStart, let lineEnd) = annotation.type else {
      return XCTFail("Expected line annotation, got \(annotation.type)")
    }
    XCTAssertEqual(lineStart, start)
    XCTAssertEqual(lineEnd, end)
    XCTAssertEqual(annotation.bounds, CGRect(x: 12, y: 18, width: 36, height: 34))
  }

  func testCreatePencilPreservesPathPointsInOrder() throws {
    let path = [
      CGPoint(x: 10, y: 10),
      CGPoint(x: 20, y: 40),
      CGPoint(x: 35, y: 25),
    ]
    let annotation = try XCTUnwrap(try AnnotationFactory.createAnnotation(
      tool: .pencil,
      from: path[0],
      to: XCTUnwrap(path.last),
      path: path,
      context: makeContext()
    ))

    guard case .path(let points) = annotation.type else {
      return XCTFail("Expected pencil path annotation, got \(annotation.type)")
    }
    XCTAssertEqual(points, path)
  }

  func testCreatePencilRejectsSinglePointPath() {
    let point = CGPoint(x: 10, y: 10)
    XCTAssertNil(AnnotationFactory.createAnnotation(
      tool: .pencil,
      from: point,
      to: point,
      path: [point],
      context: makeContext()
    ))
  }

  func testCreateBlurUsesContextBlurTypeAndDragBounds() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .blur,
      from: CGPoint(x: 20, y: 20),
      to: CGPoint(x: 120, y: 100),
      path: [],
      context: makeContext(blurType: .gaussian)
    ))

    guard case .blur(let blurType) = annotation.type else {
      return XCTFail("Expected blur annotation, got \(annotation.type)")
    }
    XCTAssertEqual(blurType, .gaussian)
    XCTAssertEqual(annotation.bounds, CGRect(x: 20, y: 20, width: 100, height: 80))
  }
}
