//
//  AnnotationItemHitTests.swift
//  LiteScreenTests
//
//  Unit tests for AnnotationItem.containsPoint and geometry helpers.
//

import CoreGraphics
@testable import LiteScreen
import XCTest

final class AnnotationItemHitTests: XCTestCase {
  func testRectangle_containsPoint_inside() {
    let item = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties()
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 25)))
  }

  func testRectangle_containsPoint_outside() {
    let item = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties()
    )
    XCTAssertFalse(item.containsPoint(CGPoint(x: 150, y: 25)))
  }

  func testOval_containsPoint_inside() {
    let item = AnnotationItem(
      type: .oval,
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties()
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 25)))
  }

  func testOval_containsPoint_outside() {
    let item = AnnotationItem(
      type: .oval,
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties()
    )
    XCTAssertFalse(item.containsPoint(CGPoint(x: 90, y: 45)))
  }

  func testArrow_containsPoint_nearLine() {
    let geo = ArrowGeometry(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), style: .straight)
    let item = AnnotationItem(
      type: .arrow(geo),
      bounds: CGRect(x: 0, y: 0, width: 100, height: 10),
      properties: AnnotationProperties(strokeWidth: 4)
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 2)))
  }

  func testArrow_containsPoint_farAway() {
    let geo = ArrowGeometry(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), style: .straight)
    let item = AnnotationItem(
      type: .arrow(geo),
      bounds: CGRect(x: 0, y: 0, width: 100, height: 10),
      properties: AnnotationProperties(strokeWidth: 4)
    )
    XCTAssertFalse(item.containsPoint(CGPoint(x: 50, y: 50)))
  }

  func testLine_containsPoint_nearSegment() {
    let item = AnnotationItem(
      type: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100)),
      bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      properties: AnnotationProperties(strokeWidth: 2)
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 52)))
  }

  func testLine_containsPoint_outsideTolerance() {
    let item = AnnotationItem(
      type: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100)),
      bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
      properties: AnnotationProperties(strokeWidth: 2)
    )
    XCTAssertFalse(item.containsPoint(CGPoint(x: 50, y: 70)))
  }

  func testPath_containsPoint_nearPolyline() {
    let item = AnnotationItem(
      type: .path([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]),
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties(strokeWidth: 4)
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 48)))
  }

  func testHighlight_containsPoint_withWiderTolerance() {
    let item = AnnotationItem(
      type: .highlight([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]),
      bounds: CGRect(x: 0, y: 0, width: 100, height: 10),
      properties: AnnotationProperties(strokeWidth: 4)
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 18)))
  }

  func testText_containsPoint_insideBounds() {
    let item = AnnotationItem(
      type: .text("Hello"),
      bounds: CGRect(x: 10, y: 10, width: 80, height: 20),
      properties: AnnotationProperties()
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 20)))
  }

  func testCounter_containsPoint_insideEllipse() {
    let item = AnnotationItem(
      type: .counter(1),
      bounds: CGRect(x: 40, y: 40, width: 20, height: 20),
      properties: AnnotationProperties()
    )
    XCTAssertTrue(item.containsPoint(CGPoint(x: 50, y: 50)))
  }

  func testCounter_containsPoint_outside() {
    let item = AnnotationItem(
      type: .counter(1),
      bounds: CGRect(x: 40, y: 40, width: 20, height: 20),
      properties: AnnotationProperties()
    )
    XCTAssertFalse(item.containsPoint(CGPoint(x: 100, y: 100)))
  }

  // MARK: - selectionBounds / resizeBounds

  func testResizeBounds_straightArrow_returnsGeometryBounds() {
    let geo = ArrowGeometry(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 50), style: .straight)
    let item = AnnotationItem(type: .arrow(geo), bounds: CGRect.zero, properties: AnnotationProperties())
    let rb = item.resizeBounds
    XCTAssertGreaterThanOrEqual(rb.width, 1)
    XCTAssertGreaterThanOrEqual(rb.height, 1)
  }

  func testResizeBounds_path_returnsNormalizedBounds() {
    let item = AnnotationItem(
      type: .path([CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 10)]),
      bounds: CGRect(x: 10, y: 10, width: 0, height: 0),
      properties: AnnotationProperties()
    )
    let rb = item.resizeBounds
    XCTAssertGreaterThanOrEqual(rb.width, 1)
    XCTAssertGreaterThanOrEqual(rb.height, 1)
  }

  func testSelectionBounds_addsPadding() {
    let item = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties(strokeWidth: 4)
    )
    let sb = item.selectionBounds
    XCTAssertGreaterThan(sb.width, item.resizeBounds.width)
    XCTAssertGreaterThan(sb.height, item.resizeBounds.height)
  }

  // MARK: - supportsResize

  func testPath_doesNotSupportResize() {
    let item = AnnotationItem(
      type: .path([CGPoint(x: 0, y: 0)]),
      bounds: CGRect.zero,
      properties: AnnotationProperties()
    )
    XCTAssertFalse(item.supportsResize)
  }

  func testRectangle_supportsResize() {
    let item = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
      properties: AnnotationProperties()
    )
    XCTAssertTrue(item.supportsResize)
  }
}
