//
//  QuickAccessCardShadowViewTests.swift
//  LiteScreenTests
//
//  Unit tests for the layer-backed Quick Access card shadow host.
//

import AppKit
@testable import LiteScreen
import XCTest

@MainActor
final class QuickAccessCardShadowViewTests: XCTestCase {
  private func makeView(cornerRadius: CGFloat = 16) -> ShadowHostView {
    let view = ShadowHostView()
    view.wantsLayer = true
    view.cornerRadius = cornerRadius
    return view
  }

  func testLayout_buildsShadowPathMatchingBounds() {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 180, height: 112)
    view.layout()

    let path = try? XCTUnwrap(view.layer?.shadowPath)
    XCTAssertNotNil(path)
    // Path spans the full bounds (rounded-rect bounding box == view bounds).
    XCTAssertEqual(view.layer?.shadowPath?.boundingBoxOfPath, view.bounds)
  }

  func testRefresh_isSkippedWhenBoundsUnchanged() {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 180, height: 112)
    view.layout()

    let firstPath = view.layer?.shadowPath
    XCTAssertNotNil(firstPath)

    // Second refresh with identical bounds must NOT reallocate the path (per-frame guard).
    view.refreshShadowPath()
    XCTAssertTrue(firstPath === view.layer?.shadowPath, "shadowPath rebuilt despite unchanged bounds")
  }

  func testRefresh_rebuildsWhenBoundsChange() {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 180, height: 112)
    view.layout()
    let firstPath = view.layer?.shadowPath

    view.frame = NSRect(x: 0, y: 0, width: 200, height: 140)
    view.layout()
    let secondPath = view.layer?.shadowPath

    XCTAssertFalse(firstPath === secondPath, "shadowPath not rebuilt after bounds change")
    XCTAssertEqual(secondPath?.boundingBoxOfPath, view.bounds)
  }

  func testIsNotFlipped_soShadowOffsetRendersDownward() {
    // Shadow offset direction (height:-4 == downward) depends on the non-flipped,
    // bottom-left-origin backing layer. Lock it so a later flip can't invert the shadow.
    XCTAssertFalse(makeView().isFlipped)
  }

  func testHitTest_isClickThrough() {
    let view = makeView()
    view.frame = NSRect(x: 0, y: 0, width: 180, height: 112)
    // Shadow host must never intercept clicks intended for the card content above it.
    XCTAssertNil(view.hitTest(NSPoint(x: 90, y: 56)))
  }
}
