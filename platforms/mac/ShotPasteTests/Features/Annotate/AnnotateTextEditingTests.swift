//
//  AnnotateTextEditingTests.swift
//  ShotPasteTests
//
//  Characterization tests for the text-editing lifecycle state machine:
//  begin -> update -> commit / finish. Undo/redo of text edits and text
//  bounds resizing are covered in AnnotateCoreTests and are not duplicated
//  here; this file locks down the editing-target id transitions and the
//  empty-commit deletion behavior.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import SwiftUI
import XCTest

@MainActor
final class AnnotateTextEditingTests: XCTestCase {
  /// Keep AnnotateState alive for the test process; XCTest scope cleanup can
  /// crash while deinitializing this MainActor app-level ObservableObject.
  private static var retainedAnnotateStates: [AnnotateState] = []

  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makeTextAnnotation(_ text: String) -> AnnotationItem {
    AnnotationItem(
      type: .text(text),
      bounds: CGRect(x: 20, y: 20, width: 140, height: 32),
      properties: AnnotationProperties(fontSize: 18)
    )
  }

  func testBeginTextEditingSetsEditingTargetId() {
    let state = makeAnnotateState()
    let annotation = makeTextAnnotation("Hello")
    state.annotations = [annotation]

    XCTAssertNil(state.editingTextAnnotationId)

    state.beginTextEditing(id: annotation.id)

    XCTAssertEqual(state.editingTextAnnotationId, annotation.id)
  }

  func testFinishTextEditingClearsEditingTargetId() {
    let state = makeAnnotateState()
    let annotation = makeTextAnnotation("Hello")
    state.annotations = [annotation]

    state.beginTextEditing(id: annotation.id)
    state.finishTextEditing()

    XCTAssertNil(state.editingTextAnnotationId)
  }

  func testBeginUpdateCommitPersistsTextAndClearsEditingState() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 300, height: 200))
    let annotation = makeTextAnnotation("Original")
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.beginTextEditing(id: annotation.id)
    state.updateAnnotationText(id: annotation.id, text: "Updated text")
    state.commitTextEditing()

    let committed = try XCTUnwrap(state.annotations.first)
    guard case .text(let text) = committed.type else {
      return XCTFail("Expected text annotation, got \(committed.type)")
    }
    XCTAssertEqual(text, "Updated text")
    XCTAssertNil(state.editingTextAnnotationId)
  }

  func testCommitTrimsSurroundingWhitespaceFromText() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 300, height: 200))
    let annotation = makeTextAnnotation("")
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.beginTextEditing(id: annotation.id)
    state.updateAnnotationText(id: annotation.id, text: "   padded value   ")
    state.commitTextEditing()

    let committed = try XCTUnwrap(state.annotations.first)
    guard case .text(let text) = committed.type else {
      return XCTFail("Expected text annotation, got \(committed.type)")
    }
    XCTAssertEqual(text, "padded value")
  }

  func testCommitEmptyTextDeletesAnnotationAndClearsSelection() {
    let state = makeAnnotateState()
    let annotation = makeTextAnnotation("")
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.beginTextEditing(id: annotation.id, recordsUndo: false)
    state.commitTextEditing()

    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertNil(state.selectedAnnotationId)
    XCTAssertNil(state.editingTextAnnotationId)
    XCTAssertTrue(state.hasUnsavedChanges)
  }

  func testCommitWhitespaceOnlyTextIsTreatedAsEmptyAndDeletes() {
    let state = makeAnnotateState()
    let annotation = makeTextAnnotation("   \n  ")
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.beginTextEditing(id: annotation.id, recordsUndo: false)
    state.commitTextEditing()

    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertNil(state.editingTextAnnotationId)
  }

  func testFinishTextEditingKeepsUncommittedTextAndItem() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 300, height: 200))
    let annotation = makeTextAnnotation("")
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.beginTextEditing(id: annotation.id)
    state.updateAnnotationText(id: annotation.id, text: "not committed")
    // finishTextEditing only clears the editing id; it does not trim/delete.
    state.finishTextEditing()

    XCTAssertNil(state.editingTextAnnotationId)
    let item = try XCTUnwrap(state.annotations.first)
    guard case .text(let text) = item.type else {
      return XCTFail("Expected text annotation, got \(item.type)")
    }
    XCTAssertEqual(text, "not committed")
  }

  func testCommitWithoutActiveEditingTargetIsNoOp() {
    let state = makeAnnotateState()
    let annotation = makeTextAnnotation("Kept")
    state.annotations = [annotation]

    // No beginTextEditing call -> editingTextAnnotationId is nil.
    state.commitTextEditing()

    XCTAssertEqual(state.annotations.count, 1)
    XCTAssertNil(state.editingTextAnnotationId)
  }

  func testAutomaticTextWidthGrowsWithTypedContent() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 600, height: 300))
    let annotation = makeTextAnnotation("")
    state.annotations = [annotation]
    state.useAutomaticTextWidth(for: annotation.id)

    state.updateAnnotationText(id: annotation.id, text: "A natural width text label")

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertGreaterThan(updated.bounds.width, 140)
    XCTAssertLessThan(updated.bounds.width, 300)
  }

  func testManualTextResizeKeepsFixedWidthWhileEditing() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 600, height: 300))
    let annotation = makeTextAnnotation("")
    state.annotations = [annotation]
    state.useAutomaticTextWidth(for: annotation.id)
    state.updateAnnotationBounds(
      id: annotation.id,
      bounds: CGRect(x: 20, y: 20, width: 180, height: 32)
    )

    state.updateAnnotationText(id: annotation.id, text: "This text should wrap in the width chosen by the user")

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.bounds.width, 180, accuracy: 0.5)
  }

  func testRecommendedTextFontSizeTracksCurrentCanvasShortSide() {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 1600, height: 900))

    XCTAssertEqual(state.recommendedTextFontSize(), 24)

    state.sourceImage = NSImage(size: CGSize(width: 480, height: 1200))
    XCTAssertEqual(state.recommendedTextFontSize(), 16)
  }

  func testBeginTextEditingOnDifferentItemCommitsPreviousEdit() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 400, height: 300))
    let first = makeTextAnnotation("first")
    let second = AnnotationItem(
      type: .text("second"),
      bounds: CGRect(x: 200, y: 20, width: 140, height: 32),
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [first, second]

    state.beginTextEditing(id: first.id)
    state.updateAnnotationText(id: first.id, text: "first edited")
    // Switching editing target to another item commits the first.
    state.beginTextEditing(id: second.id)

    XCTAssertEqual(state.editingTextAnnotationId, second.id)
    let firstItem = try XCTUnwrap(state.annotations.first(where: { $0.id == first.id }))
    guard case .text(let firstText) = firstItem.type else {
      return XCTFail("Expected text annotation, got \(firstItem.type)")
    }
    XCTAssertEqual(firstText, "first edited")
  }
}
