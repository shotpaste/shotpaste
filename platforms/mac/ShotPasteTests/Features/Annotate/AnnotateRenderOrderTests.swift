//
//  AnnotateRenderOrderTests.swift
//  ShotPasteTests
//
//  Unit tests for the renderOrdered z-order tiering used by canvas and export.
//

import CoreGraphics
@testable import ShotPaste
import XCTest

final class AnnotateRenderOrderTests: XCTestCase {
  private func makeItem(_ type: AnnotationType) -> AnnotationItem {
    AnnotationItem(
      type: type,
      bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
      properties: AnnotationProperties()
    )
  }

  func testRenderOrdered_placesBlurBelowMarkup() {
    let rectangle = makeItem(.rectangle)
    let blur = makeItem(.blur(.pixelated))
    let arrow = makeItem(.arrow(ArrowGeometry(
      start: .zero,
      end: CGPoint(x: 10, y: 10),
      style: .straight,
      arrowType: .tapered,
      startHead: .none,
      endHead: .arrow
    )))

    // Model order has the blur on top (created last); render order puts it underneath.
    let ordered = [rectangle, arrow, blur].renderOrdered

    XCTAssertEqual(ordered.map(\.id), [blur.id, rectangle.id, arrow.id])
  }

  func testRenderOrdered_placesEmbeddedImagesBelowBlur() {
    let blur = makeItem(.blur(.gaussian))
    let embedded = makeItem(.embeddedImage(UUID()))
    let text = makeItem(.text("hello"))

    let ordered = [text, blur, embedded].renderOrdered

    XCTAssertEqual(ordered.map(\.id), [embedded.id, blur.id, text.id])
  }

  func testRenderOrdered_isStableWithinTiers() {
    let blurA = makeItem(.blur(.pixelated))
    let rectA = makeItem(.rectangle)
    let blurB = makeItem(.blur(.gaussian))
    let rectB = makeItem(.oval)

    let ordered = [blurA, rectA, blurB, rectB].renderOrdered

    XCTAssertEqual(ordered.map(\.id), [blurA.id, blurB.id, rectA.id, rectB.id])
  }

  func testRenderOrdered_preservesAllItems() {
    let items = [
      makeItem(.rectangle),
      makeItem(.blur(.pixelated)),
      makeItem(.counter(1)),
      makeItem(.embeddedImage(UUID())),
      makeItem(.watermark("wm")),
      makeItem(.spotlight),
    ]

    let ordered = items.renderOrdered

    XCTAssertEqual(ordered.count, items.count)
    XCTAssertEqual(Set(ordered.map(\.id)), Set(items.map(\.id)))
  }

  func testRenderOrdered_withoutSpecialTiers_matchesInputOrder() {
    let items = [
      makeItem(.rectangle),
      makeItem(.counter(2)),
      makeItem(.text("note")),
    ]

    XCTAssertEqual(items.renderOrdered.map(\.id), items.map(\.id))
  }
}
