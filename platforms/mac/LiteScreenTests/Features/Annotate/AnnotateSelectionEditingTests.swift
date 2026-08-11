//
//  AnnotateSelectionEditingTests.swift
//  LiteScreenTests
//
//  Phase-03 characterization tests for selection + editing STATE wiring:
//  hit selection, marquee selection, delete + undo, direct bounds mutation,
//  nudge, line-endpoint edits, arrow-style switching, and remembered shared
//  spotlight/color/opacity/corner-radius props applied to the next create.
//
//  Hit-test math itself lives in AnnotationItemHitTests / ArrowGeometryTests;
//  here we only assert the resulting selection set and mutated model state.
//

import CoreGraphics
@testable import LiteScreen
import SwiftUI
import XCTest

final class AnnotateSelectionEditingTests: XCTestCase {
  /// Keep AnnotateState alive for the test process; XCTest scope cleanup can
  /// crash while deinitializing this MainActor app-level ObservableObject.
  @MainActor private static var retainedAnnotateStates: [AnnotateState] = []

  @MainActor
  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState(defaults: UserDefaultsFactory.make())
    Self.retainedAnnotateStates.append(state)
    return state
  }

  @MainActor
  private func makeRectangle(_ bounds: CGRect) -> AnnotationItem {
    AnnotationItem(type: .rectangle, bounds: bounds, properties: AnnotationProperties())
  }

  @MainActor
  private func makeLine(start: CGPoint, end: CGPoint) -> AnnotationItem {
    AnnotationItem(
      type: .line(start: start, end: end),
      bounds: CGRect(
        x: min(start.x, end.x),
        y: min(start.y, end.y),
        width: abs(end.x - start.x),
        height: abs(end.y - start.y)
      ),
      properties: AnnotationProperties()
    )
  }

  @MainActor
  private func makeArrow(start: CGPoint, end: CGPoint, style: ArrowStyle) -> AnnotationItem {
    let geometry = ArrowGeometry(start: start, end: end, style: style)
    return AnnotationItem(type: .arrow(geometry), bounds: geometry.bounds(), properties: AnnotationProperties())
  }

  // MARK: - Hit selection

  @MainActor
  func testSelectAnnotationAtPointSelectsTopmostOverlappingItem() throws {
    let state = makeAnnotateState()
    let lower = makeRectangle(CGRect(x: 0, y: 0, width: 100, height: 100))
    let upper = makeRectangle(CGRect(x: 20, y: 20, width: 100, height: 100))
    // Later index draws on top; overlap region belongs to `upper`.
    state.annotations = [lower, upper]

    let hit = try XCTUnwrap(state.selectAnnotation(at: CGPoint(x: 50, y: 50)))

    XCTAssertEqual(hit.id, upper.id)
    XCTAssertEqual(state.selectedAnnotationIds, [upper.id])
    XCTAssertEqual(state.selectedAnnotationId, upper.id)
  }

  @MainActor
  func testSelectAnnotationAtPointInEmptyAreaClearsSelection() {
    let state = makeAnnotateState()
    let rectangle = makeRectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
    state.annotations = [rectangle]
    state.setSelectedAnnotationIds([rectangle.id])

    let hit = state.selectAnnotation(at: CGPoint(x: 500, y: 500))

    XCTAssertNil(hit)
    XCTAssertTrue(state.selectedAnnotationIds.isEmpty)
    XCTAssertNil(state.selectedAnnotationId)
    XCTAssertFalse(state.hasSelectedAnnotations)
  }

  // MARK: - Marquee selection

  @MainActor
  func testSelectAnnotationsInRectSelectsIntersectingSubset() {
    let state = makeAnnotateState()
    let inside = makeRectangle(CGRect(x: 10, y: 10, width: 30, height: 30))
    let overlapping = makeRectangle(CGRect(x: 90, y: 90, width: 40, height: 40))
    let outside = makeRectangle(CGRect(x: 400, y: 400, width: 20, height: 20))
    state.annotations = [inside, overlapping, outside]

    let selected = state.selectAnnotations(in: CGRect(x: 0, y: 0, width: 100, height: 100))

    let selectedIds = Set(selected.map(\.id))
    XCTAssertEqual(selectedIds, [inside.id, overlapping.id])
    XCTAssertEqual(state.selectedAnnotationIds, [inside.id, overlapping.id])
    // Multi-selection leaves no single primary id.
    XCTAssertNil(state.selectedAnnotationId)
  }

  @MainActor
  func testSelectAnnotationsInZeroSizeRectClearsSelection() {
    let state = makeAnnotateState()
    let rectangle = makeRectangle(CGRect(x: 10, y: 10, width: 30, height: 30))
    state.annotations = [rectangle]
    state.setSelectedAnnotationIds([rectangle.id])

    let selected = state.selectAnnotations(in: CGRect(x: 5, y: 5, width: 0, height: 0))

    XCTAssertTrue(selected.isEmpty)
    XCTAssertTrue(state.selectedAnnotationIds.isEmpty)
  }

  // MARK: - Delete + undo

  @MainActor
  func testDeleteSelectedAnnotationRemovesOnlySelectedAndIsUndoable() {
    let state = makeAnnotateState()
    let keep = makeRectangle(CGRect(x: 0, y: 0, width: 20, height: 20))
    let removeA = makeRectangle(CGRect(x: 30, y: 30, width: 20, height: 20))
    let removeB = makeRectangle(CGRect(x: 60, y: 60, width: 20, height: 20))
    state.annotations = [keep, removeA, removeB]
    state.setSelectedAnnotationIds([removeA.id, removeB.id])

    state.deleteSelectedAnnotation()

    XCTAssertEqual(state.annotations.map(\.id), [keep.id])
    XCTAssertFalse(state.hasSelectedAnnotations)
    XCTAssertTrue(state.canUndo)

    state.undo()

    XCTAssertEqual(Set(state.annotations.map(\.id)), [keep.id, removeA.id, removeB.id])
  }

  @MainActor
  func testDeleteSelectedAnnotationIsNoOpWithoutSelection() {
    let state = makeAnnotateState()
    let rectangle = makeRectangle(CGRect(x: 0, y: 0, width: 20, height: 20))
    state.annotations = [rectangle]

    state.deleteSelectedAnnotation()

    XCTAssertEqual(state.annotations.map(\.id), [rectangle.id])
  }

  // MARK: - Direct bounds mutation

  @MainActor
  func testUpdateAnnotationBoundsMutatesTargetOnlyAndNormalizes() {
    let state = makeAnnotateState()
    let target = makeRectangle(CGRect(x: 10, y: 10, width: 40, height: 40))
    let other = makeRectangle(CGRect(x: 100, y: 100, width: 40, height: 40))
    state.annotations = [target, other]

    // Negative width/height should standardize to a positive-extent rect.
    state.updateAnnotationBounds(id: target.id, bounds: CGRect(x: 60, y: 60, width: -20, height: -20))

    let updated = state.annotations.first { $0.id == target.id }
    XCTAssertEqual(updated?.bounds, CGRect(x: 40, y: 40, width: 20, height: 20))
    let unchanged = state.annotations.first { $0.id == other.id }
    XCTAssertEqual(unchanged?.bounds, CGRect(x: 100, y: 100, width: 40, height: 40))
  }

  // MARK: - Nudge

  @MainActor
  func testNudgeSelectedAnnotationShiftsSelectedOriginOnly() {
    let state = makeAnnotateState()
    let selected = makeRectangle(CGRect(x: 10, y: 20, width: 30, height: 30))
    let untouched = makeRectangle(CGRect(x: 200, y: 200, width: 30, height: 30))
    state.annotations = [selected, untouched]
    state.setSelectedAnnotationIds([selected.id])

    state.nudgeSelectedAnnotation(dx: 5, dy: -3)

    let moved = state.annotations.first { $0.id == selected.id }
    XCTAssertEqual(moved?.bounds.origin, CGPoint(x: 15, y: 17))
    XCTAssertEqual(moved?.bounds.size, CGSize(width: 30, height: 30))
    let still = state.annotations.first { $0.id == untouched.id }
    XCTAssertEqual(still?.bounds.origin, CGPoint(x: 200, y: 200))
    XCTAssertTrue(state.canUndo)
  }

  // MARK: - Line endpoint editing

  @MainActor
  func testUpdateLineEndpointUpdatesStartAndEndIndependently() throws {
    let state = makeAnnotateState()
    let line = makeLine(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 40, y: 40))
    state.annotations = [line]

    // Move only the start; end stays put.
    state.updateLineEndpoint(id: line.id, start: CGPoint(x: 10, y: 10))
    var updated = try XCTUnwrap(state.annotations.first)
    guard case .line(let start1, let end1) = updated.type else {
      return XCTFail("Expected line annotation")
    }
    XCTAssertEqual(start1, CGPoint(x: 10, y: 10))
    XCTAssertEqual(end1, CGPoint(x: 40, y: 40))

    // Move only the end; start stays at its previously-set value.
    state.updateLineEndpoint(id: line.id, end: CGPoint(x: 60, y: 20))
    updated = try XCTUnwrap(state.annotations.first)
    guard case .line(let start2, let end2) = updated.type else {
      return XCTFail("Expected line annotation")
    }
    XCTAssertEqual(start2, CGPoint(x: 10, y: 10))
    XCTAssertEqual(end2, CGPoint(x: 60, y: 20))
    XCTAssertEqual(updated.bounds, CGRect(x: 10, y: 10, width: 50, height: 10))
  }

  // MARK: - Arrow style switching

  @MainActor
  func testUpdateArrowStyleSwitchesAcrossStraightCurvedRightCurvedLeft() throws {
    let state = makeAnnotateState()
    let arrow = makeArrow(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 90, y: 80), style: .straight)
    state.annotations = [arrow]

    for style in [ArrowStyle.curvedRight, .curvedLeft, .straight] {
      state.updateArrowStyle(id: arrow.id, style: style)
      let updated = try XCTUnwrap(state.annotations.first)
      guard case .arrow(let geometry) = updated.type else {
        return XCTFail("Expected arrow annotation")
      }
      XCTAssertEqual(geometry.style, style)
      XCTAssertEqual(updated.bounds, geometry.bounds())
    }
    XCTAssertTrue(state.hasUnsavedChanges)
  }

  @MainActor
  func testUpdateArrowStyleIsNoOpForNonArrowAndUnknownId() {
    let state = makeAnnotateState()
    let rectangle = makeRectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
    state.annotations = [rectangle]

    state.updateArrowStyle(id: rectangle.id, style: .curvedRight)
    state.updateArrowStyle(id: UUID(), style: .curvedLeft)

    XCTAssertEqual(state.annotations.first?.type, .rectangle)
  }

  // MARK: - Primary color + remembered shared color

  @MainActor
  func testUpdatePrimaryColorSetsItemColorAndInheritsOnNextCreate() throws {
    let state = makeAnnotateState()
    state.activateTool(.rectangle)
    let rectangle = makeRectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
    state.annotations = [rectangle]
    state.selectedAnnotationId = rectangle.id

    state.updateAnnotationPrimaryColor(id: rectangle.id, color: .green)

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.properties.strokeColor, .green)

    // Remembered shared color feeds a freshly-created annotation's defaults.
    let nextCreateProperties = state.annotationCreationProperties(for: .rectangle)
    XCTAssertEqual(nextCreateProperties.strokeColor, .green)
  }

  // MARK: - Spotlight opacity remembered on next create

  @MainActor
  func testSpotlightOpacityBindingPersistsAndInheritsOnNextCreate() {
    let state = makeAnnotateState()
    state.activateTool(.spotlight)

    state.quickSpotlightOpacityBinding.wrappedValue = 0.8

    XCTAssertEqual(state.spotlightOpacity, 0.8, accuracy: 0.0001)
    let nextCreateProperties = state.annotationCreationProperties(for: .spotlight)
    XCTAssertEqual(nextCreateProperties.spotlightOpacity, 0.8, accuracy: 0.0001)
  }

  @MainActor
  func testSpotlightOpacityBindingUpdatesSelectedSpotlightWithSingleUndo() throws {
    let state = makeAnnotateState()
    let spotlight = AnnotationItem(
      type: .spotlight,
      bounds: CGRect(x: 0, y: 0, width: 80, height: 80),
      properties: AnnotationProperties(spotlightOpacity: 0.5)
    )
    state.annotations = [spotlight]
    state.activateTool(.selection)
    state.setSelectedAnnotationIds([spotlight.id])
    state.hasUnsavedChanges = false

    state.quickSpotlightOpacityBinding.wrappedValue = 0.9

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.properties.spotlightOpacity, 0.9, accuracy: 0.0001)
    XCTAssertTrue(state.canUndo)

    state.undo()

    let restored = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(restored.properties.spotlightOpacity, 0.5, accuracy: 0.0001)
  }

  // MARK: - Spotlight corner radius remembered on next create

  @MainActor
  func testSpotlightCornerRadiusBindingInheritsOnNextCreate() {
    let state = makeAnnotateState()
    state.activateTool(.spotlight)

    state.quickCornerRadiusBinding.wrappedValue = 24

    let nextCreateProperties = state.annotationCreationProperties(for: .spotlight)
    XCTAssertEqual(nextCreateProperties.cornerRadius, 24, accuracy: 0.0001)
  }
}
