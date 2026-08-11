//
//  AnnotateCoreTests.swift
//  ShotPasteTests
//
//  Unit tests for annotation creation and geometry helpers.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import SwiftUI
import XCTest

final class AnnotateCoreTests: XCTestCase {
  // Keep AnnotateState alive for the test process; XCTest scope cleanup can
  // crash while deinitializing this MainActor app-level ObservableObject.
  @MainActor private static var retainedAnnotateStates: [AnnotateState] = []
  @MainActor private static var retainedCanvasPresetStores: [AnnotateCanvasPresetStore] = []
  @MainActor private static var retainedUserDefaults: [UserDefaults] = []

  @MainActor
  private func makeAnnotateState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedAnnotateStates.append(state)
    return state
  }

  @MainActor
  private func makeAnnotateState(defaults: UserDefaults) -> AnnotateState {
    let state = AnnotateState(defaults: defaults)
    Self.retainedUserDefaults.append(defaults)
    Self.retainedAnnotateStates.append(state)
    return state
  }

  @MainActor
  private func makeCanvasPresetStore() -> (AnnotateCanvasPresetStore, UserDefaults) {
    let defaults = UserDefaultsFactory.make()
    let store = AnnotateCanvasPresetStore(defaults: defaults)
    Self.retainedUserDefaults.append(defaults)
    Self.retainedCanvasPresetStores.append(store)
    return (store, defaults)
  }

  func testAnnotateCanvasDefaultsUseNoCornerRadius() {
    XCTAssertEqual(AnnotateCanvasDefaults.cornerRadius, 0)
    XCTAssertEqual(AnnotationCanvasEffects().cornerRadius, 0)
    XCTAssertFalse(AnnotationCanvasEffects().isBlurredBackgroundEnabled)
    XCTAssertEqual(AnnotationCanvasEffects().blurredBackgroundEffect, .soft)
  }

  @MainActor
  func testAnnotateStateToggleSidebarVisibilitySkipsPreviewMode() {
    let state = makeAnnotateState()

    state.toggleSidebarVisibility()
    XCTAssertTrue(state.showSidebar)

    state.editorMode = .preview
    state.toggleSidebarVisibility()
    XCTAssertTrue(state.showSidebar)

    state.editorMode = .annotate
    state.toggleSidebarVisibility()
    XCTAssertFalse(state.showSidebar)
  }

  func testInlineAreaControls_nearFullscreenSelectionUsesBottomInnerPlacement() {
    let containerSize = CGSize(width: 1512, height: 982)
    let rect = CGRect(origin: .zero, size: containerSize)

    let placement = InlineAreaControlGeometry.placement(
      for: rect,
      containerSize: containerSize,
      showsProperties: true,
      propertiesContentWidth: 0,
      controlInsets: .zero
    )

    let reservedHeight = InlineAreaLayout.reservedControlHeight(showsProperties: true)
    let expectedGroupTop = containerSize.height - InlineAreaLayout.screenPadding - reservedHeight
    XCTAssertEqual(
      placement.toolbarCenter.y,
      expectedGroupTop + InlineAreaLayout.toolbarHeight / 2,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      placement.propertiesCenter.y + InlineAreaLayout.propertiesHeight / 2,
      containerSize.height - InlineAreaLayout.screenPadding,
      accuracy: 0.0001
    )
    XCTAssertGreaterThan(placement.toolbarCenter.y, containerSize.height / 2)
  }

  func testInlineAreaControls_respectsTopInsetWhenClampedAboveSelection() {
    let containerSize = CGSize(width: 1512, height: 982)
    let rect = CGRect(x: 80, y: 120, width: 1200, height: 862)
    let controlInsets = InlineAreaControlInsets(top: 60)

    let placement = InlineAreaControlGeometry.placement(
      for: rect,
      containerSize: containerSize,
      showsProperties: false,
      propertiesContentWidth: 0,
      controlInsets: controlInsets
    )

    XCTAssertEqual(
      placement.toolbarCenter.y - InlineAreaLayout.toolbarHeight / 2,
      controlInsets.controlTopPadding,
      accuracy: 0.0001
    )
    XCTAssertLessThanOrEqual(
      placement.toolbarCenter.y + InlineAreaLayout.toolbarHeight / 2,
      rect.minY + 0.0001
    )
  }

  func testInlineAreaControls_keepsAbovePlacementWhenThereIsEnoughRoom() {
    let containerSize = CGSize(width: 1512, height: 982)
    let rect = CGRect(x: 120, y: 200, width: 900, height: 300)

    let placement = InlineAreaControlGeometry.placement(
      for: rect,
      containerSize: containerSize,
      showsProperties: false,
      propertiesContentWidth: 0,
      controlInsets: .zero
    )

    XCTAssertEqual(
      placement.toolbarCenter.y,
      rect.minY - InlineAreaLayout.selectionGap - InlineAreaLayout.toolbarHeight / 2,
      accuracy: 0.0001
    )
  }

  func testInlineAreaControlInsetsPreferVisibleFrameAndSafeArea() {
    let insets = InlineAreaControlInsets(
      screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 40, y: 50, width: 1432, height: 900),
      safeAreaInsets: NSEdgeInsets(top: 70, left: 12, bottom: 10, right: 24)
    )

    XCTAssertEqual(insets.top, 70)
    XCTAssertEqual(insets.leading, 40)
    XCTAssertEqual(insets.bottom, 50)
    XCTAssertEqual(insets.trailing, 40)
  }

  func testInlineAreaDesktopFrameUsesUnionOfDisplayFrames() {
    let desktopFrame = InlineAreaAnnotateSession.desktopFrame(for: [
      CGRect(x: 0, y: 0, width: 300, height: 200),
      CGRect(x: 300, y: -100, width: 200, height: 160),
    ])

    XCTAssertEqual(desktopFrame, CGRect(x: 0, y: -100, width: 500, height: 300))
  }

  func testInlineAreaLocalFrameMapsScreenFrameIntoTopLeftDesktopCoordinates() {
    let desktopFrame = CGRect(x: -200, y: -100, width: 700, height: 300)
    let screenFrame = CGRect(x: 300, y: -100, width: 200, height: 160)

    let localFrame = InlineAreaAnnotateSession.localFrame(for: screenFrame, in: desktopFrame)

    XCTAssertEqual(localFrame, CGRect(x: 500, y: 140, width: 200, height: 160))
  }

  func testInlineAreaScreenRectConvertsDesktopLocalSelectionToScreenCoordinates() {
    let desktopFrame = CGRect(x: -200, y: -100, width: 700, height: 300)
    let localRect = CGRect(x: 250, y: 40, width: 120, height: 80)

    let screenRect = InlineAreaAnnotateSession.screenRect(for: localRect, in: desktopFrame)

    XCTAssertEqual(screenRect, CGRect(x: 50, y: 80, width: 120, height: 80))
  }

  func testInlineAreaLocalRectConvertsAlignedScreenRectToDesktopLocalCoordinates() {
    let desktopFrame = CGRect(x: -200, y: -100, width: 700, height: 300)
    let screenRect = CGRect(x: 50, y: 80, width: 120.5, height: 80.5)

    let localRect = InlineAreaAnnotateSession.localRect(for: screenRect, in: desktopFrame)

    XCTAssertEqual(localRect.origin.x, 250.0, accuracy: 0.0001)
    XCTAssertEqual(localRect.origin.y, 39.5, accuracy: 0.0001)
    XCTAssertEqual(localRect.width, 120.5, accuracy: 0.0001)
    XCTAssertEqual(localRect.height, 80.5, accuracy: 0.0001)
  }

  func testInlineAreaDisplayIDsIntersectingSpanningSelectionReturnsAllTouchedDisplays() {
    let screenFramesByDisplayID: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 200, height: 200),
      2: CGRect(x: 200, y: 0, width: 200, height: 200),
      3: CGRect(x: 0, y: 200, width: 200, height: 200),
    ]
    let selection = CGRect(x: 150, y: 40, width: 120, height: 80)

    let displayIDs = InlineAreaAnnotateSession.displayIDsIntersecting(
      selection,
      screenFramesByDisplayID: screenFramesByDisplayID
    )

    XCTAssertEqual(displayIDs, [1, 2])
  }

  func testInlineAreaPrimaryDisplayIDUsesLargestIntersection() {
    let screenFramesByDisplayID: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 200, height: 200),
      2: CGRect(x: 200, y: 0, width: 200, height: 200),
    ]
    let selection = CGRect(x: 170, y: 40, width: 160, height: 80)

    let displayID = InlineAreaAnnotateSession.primaryDisplayID(
      for: selection,
      screenFramesByDisplayID: screenFramesByDisplayID,
      fallback: 1
    )

    XCTAssertEqual(displayID, 2)
  }

  @MainActor
  func testAnnotateState_undoAfterNewTextCreationRemovesTextAnnotation() {
    let state = makeAnnotateState()

    state.saveState()
    let annotation = AnnotationItem(
      type: .text("Hello"),
      bounds: CGRect(x: 20, y: 20, width: 120, height: 32),
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations.append(annotation)
    state.selectedAnnotationId = annotation.id
    state.beginTextEditing(id: annotation.id, recordsUndo: false)
    state.commitTextEditing()

    state.undo()

    XCTAssertTrue(state.annotations.isEmpty)
  }

  @MainActor
  func testAnnotateState_undoRedoExistingTextEditRestoresText() throws {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .text("Original"),
      bounds: CGRect(x: 20, y: 20, width: 140, height: 32),
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.beginTextEditing(id: annotation.id)
    state.updateAnnotationText(id: annotation.id, text: "Changed")
    state.commitTextEditing()
    state.undo()

    let undone = try XCTUnwrap(state.annotations.first)
    guard case .text(let undoneText) = undone.type else {
      return XCTFail("Expected text annotation after undo")
    }
    XCTAssertEqual(undoneText, "Original")

    state.redo()

    let redone = try XCTUnwrap(state.annotations.first)
    guard case .text(let redoneText) = redone.type else {
      return XCTFail("Expected text annotation after redo")
    }
    XCTAssertEqual(redoneText, "Changed")
  }

  @MainActor
  func testAnnotateState_undoRedoTextFontSizeRestoresPropertiesAndBounds() throws {
    let state = makeAnnotateState()
    let originalBounds = CGRect(x: 20, y: 20, width: 180, height: 32)
    let annotation = AnnotationItem(
      type: .text("Resizable text"),
      bounds: originalBounds,
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.updateAnnotationProperties(id: annotation.id, fontSize: 36, recordsUndo: true)

    let resized = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(resized.properties.fontSize, 36)
    XCTAssertNotEqual(resized.bounds, originalBounds)

    state.undo()

    let undone = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(undone.properties.fontSize, 18)
    XCTAssertEqual(undone.bounds, originalBounds)

    state.redo()

    let redone = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(redone.properties.fontSize, 36)
  }

  @MainActor
  func testAnnotateState_replaceSourceImagePreservingAnnotationsAppliesOffset() throws {
    let state = makeAnnotateState()
    let rectangle = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 20, y: 30, width: 80, height: 44),
      properties: AnnotationProperties()
    )
    let line = AnnotationItem(
      type: .line(start: CGPoint(x: 12, y: 18), end: CGPoint(x: 48, y: 52)),
      bounds: CGRect(x: 12, y: 18, width: 36, height: 34),
      properties: AnnotationProperties()
    )
    state.annotations = [rectangle, line]

    state.replaceSourceImagePreservingAnnotations(
      NSImage(size: CGSize(width: 320, height: 220)),
      annotationOffset: CGPoint(x: 14, y: -6)
    )

    XCTAssertEqual(state.sourceImage?.size.width ?? 0, 320, accuracy: 0.0001)
    XCTAssertEqual(state.sourceImage?.size.height ?? 0, 220, accuracy: 0.0001)

    let shiftedRectangle = try XCTUnwrap(state.annotations.first(where: { $0.id == rectangle.id }))
    XCTAssertEqual(shiftedRectangle.bounds, rectangle.bounds.offsetBy(dx: 14, dy: -6))

    let shiftedLine = try XCTUnwrap(state.annotations.first(where: { $0.id == line.id }))
    guard case .line(let start, let end) = shiftedLine.type else {
      return XCTFail("Expected shifted line annotation")
    }
    XCTAssertEqual(start, CGPoint(x: 26, y: 12))
    XCTAssertEqual(end, CGPoint(x: 62, y: 46))
    XCTAssertEqual(shiftedLine.bounds, line.bounds.offsetBy(dx: 14, dy: -6))
  }

  @MainActor
  func testAnnotateState_updateTextKeepsWidthAndTopLeftAnchor() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 300, height: 200))
    let originalBounds = CGRect(x: 20, y: 140, width: 80, height: 28)
    let annotation = AnnotationItem(
      type: .text(""),
      bounds: originalBounds,
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]

    state.updateAnnotationText(
      id: annotation.id,
      text: "A much longer textbox value"
    )

    let resized = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(resized.bounds.minX, originalBounds.minX, accuracy: 0.0001)
    XCTAssertEqual(resized.bounds.maxY, originalBounds.maxY, accuracy: 0.0001)
    XCTAssertEqual(resized.bounds.width, originalBounds.width, accuracy: 0.0001)
    XCTAssertGreaterThan(resized.bounds.height, originalBounds.height)
  }

  @MainActor
  func testAnnotateState_updateTextExpandsTooShortInitialHeight() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 300, height: 200))
    let originalBounds = CGRect(x: 20, y: 160, width: 200, height: 8)
    let annotation = AnnotationItem(
      type: .text(""),
      bounds: originalBounds,
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]

    state.updateAnnotationText(id: annotation.id, text: "asdasdsad")

    let resized = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(resized.bounds.minX, originalBounds.minX, accuracy: 0.0001)
    XCTAssertEqual(resized.bounds.maxY, originalBounds.maxY, accuracy: 0.0001)
    XCTAssertGreaterThan(resized.bounds.height, originalBounds.height)
    XCTAssertGreaterThanOrEqual(
      resized.bounds.height,
      AnnotateTextLayout.minimumHeight(for: AnnotateTextLayout.font(size: 18))
    )
  }

  @MainActor
  func testAnnotateState_updateTextWrapsAtActiveCanvasRightEdge() throws {
    let state = makeAnnotateState()
    state.sourceImage = NSImage(size: CGSize(width: 120, height: 120))
    let originalBounds = CGRect(x: 80, y: 80, width: 30, height: 28)
    let annotation = AnnotationItem(
      type: .text(""),
      bounds: originalBounds,
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]

    state.updateAnnotationText(
      id: annotation.id,
      text: "asdasdasdaasdasdasdaasdasdasdaasdasdasda"
    )

    let resized = try XCTUnwrap(state.annotations.first)
    XCTAssertLessThanOrEqual(resized.bounds.maxX, state.activeAnnotationBounds.maxX + 0.0001)
    XCTAssertEqual(resized.bounds.minX, originalBounds.minX, accuracy: 0.0001)
    XCTAssertEqual(resized.bounds.maxY, originalBounds.maxY, accuracy: 0.0001)
    XCTAssertGreaterThan(resized.bounds.height, originalBounds.height)
  }

  func testAnnotateTextLayout_textEditorInsetScalesWithCanvasZoom() {
    let halfScaleInset = AnnotateTextLayout.textEditorInset(scale: 0.5)
    XCTAssertEqual(halfScaleInset.width, AnnotateTextLayout.horizontalPadding * 0.5, accuracy: 0.0001)
    XCTAssertEqual(halfScaleInset.height, AnnotateTextLayout.verticalPadding * 0.5, accuracy: 0.0001)

    let doubleScaleInset = AnnotateTextLayout.textEditorInset(scale: 2)
    XCTAssertEqual(doubleScaleInset.width, AnnotateTextLayout.horizontalPadding * 2, accuracy: 0.0001)
    XCTAssertEqual(doubleScaleInset.height, AnnotateTextLayout.verticalPadding * 2, accuracy: 0.0001)
  }

  func testAnnotationFactory_createsCounterCenteredAtStart() {
    let annotation = AnnotationFactory.createAnnotation(
      tool: .counter,
      from: CGPoint(x: 50, y: 60),
      to: CGPoint(x: 50, y: 60),
      path: [],
      context: makeContext(counterValue: 5)
    )

    guard case .counter(5) = annotation?.type else {
      return XCTFail("Expected counter value 5, got \(String(describing: annotation?.type))")
    }
    XCTAssertEqual(annotation?.bounds, CGRect(x: 38, y: 48, width: 24, height: 24))
  }

  func testAnnotationFactory_rejectsNonDrawingToolsAndSinglePointPaths() {
    let context = makeContext()
    let start = CGPoint(x: 10, y: 20)

    XCTAssertNil(AnnotationFactory.createAnnotation(
      tool: .selection,
      from: start,
      to: start,
      path: [],
      context: context
    ))
    XCTAssertNil(AnnotationFactory.createAnnotation(tool: .crop, from: start, to: start, path: [], context: context))
    XCTAssertNil(AnnotationFactory.createAnnotation(tool: .text, from: start, to: start, path: [], context: context))
    XCTAssertNil(AnnotationFactory.createAnnotation(tool: .mockup, from: start, to: start, path: [], context: context))
    XCTAssertNil(AnnotationFactory.createAnnotation(
      tool: .pencil,
      from: start,
      to: start,
      path: [start],
      context: context
    ))
    XCTAssertNil(AnnotationFactory.createAnnotation(
      tool: .highlighter,
      from: start,
      to: start,
      path: [start],
      context: context
    ))
  }

  func testAnnotationToolCreationPolicy_requiresDragExceptClickPlacementTools() {
    for tool in [AnnotationToolType.rectangle, .filledRectangle, .oval, .arrow, .line, .blur, .watermark] {
      XCTAssertTrue(tool.requiresDragToCreateAnnotation, "\(tool) should not create a new item from an empty click.")
    }

    for tool in [AnnotationToolType.selection, .crop, .text, .highlighter, .counter, .pencil, .mockup] {
      XCTAssertFalse(tool.requiresDragToCreateAnnotation, "\(tool) keeps its existing non-drag behavior.")
    }
  }

  @MainActor
  func testCanvasBlankClickWithActiveShapeToolDeselectsItemButKeepsTool() {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
      properties: AnnotationProperties()
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id
    state.selectedTool = .rectangle

    let canvas = DrawingCanvasNSView(state: state)
    canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    canvas.displayScale = 1
    canvas.canvasBounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    let clickPoint = CGPoint(x: 220, y: 180)
    let mouseDown = makeMouseEvent(type: .leftMouseDown, location: clickPoint)
    let mouseUp = makeMouseEvent(type: .leftMouseUp, location: clickPoint)

    canvas.mouseDown(with: mouseDown)
    canvas.mouseUp(with: mouseUp)

    XCTAssertNil(state.selectedAnnotationId)
    XCTAssertFalse(state.hasSelectedAnnotations)
    XCTAssertEqual(state.selectedTool, .rectangle)
    XCTAssertEqual(state.annotations.count, 1)
  }

  func testAnnotationFactory_normalizesNearlyHorizontalHighlighterStroke() throws {
    let path = [
      CGPoint(x: 10, y: 100),
      CGPoint(x: 30, y: 102),
      CGPoint(x: 60, y: 98),
      CGPoint(x: 90, y: 101),
    ]

    let annotation = try XCTUnwrap(try AnnotationFactory.createAnnotation(
      tool: .highlighter,
      from: path[0],
      to: XCTUnwrap(path.last),
      path: path,
      context: makeContext()
    ))

    guard case .highlight(let points) = annotation.type else {
      return XCTFail("Expected highlighter annotation, got \(annotation.type)")
    }
    XCTAssertEqual(points.count, 2)
    XCTAssertEqual(points[0].x, 10, accuracy: 0.0001)
    XCTAssertEqual(points[1].x, 90, accuracy: 0.0001)
    XCTAssertEqual(points[0].y, 100.5, accuracy: 0.0001)
    XCTAssertEqual(points[1].y, 100.5, accuracy: 0.0001)
    XCTAssertEqual(annotation.bounds, CGRect(x: 10, y: 100, width: 80, height: 1))
  }

  func testAnnotationFactory_smallWatermarkDragUsesCanvasSizedDefaultBounds() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .watermark,
      from: CGPoint(x: 500, y: 250),
      to: CGPoint(x: 504, y: 254),
      path: [],
      context: makeContext(watermarkText: "   ", bounds: CGRect(x: 0, y: 0, width: 1000, height: 500))
    ))

    guard case .watermark(let text) = annotation.type else {
      return XCTFail("Expected watermark annotation, got \(annotation.type)")
    }
    XCTAssertEqual(text, "ShotPaste")
    XCTAssertEqual(annotation.bounds, CGRect(x: 290, y: 205, width: 420, height: 90))
  }

  func testAnnotationFactory_usesArrowStyleAndBoundsFromGeometry() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .arrow,
      from: CGPoint(x: 10, y: 20),
      to: CGPoint(x: 90, y: 80),
      path: [],
      context: makeContext(arrowStyle: .curvedRight)
    ))

    guard case .arrow(let geometry) = annotation.type else {
      return XCTFail("Expected arrow annotation, got \(annotation.type)")
    }
    XCTAssertEqual(geometry.style, .curvedRight)
    XCTAssertEqual(annotation.bounds, geometry.bounds())
    XCTAssertGreaterThan(annotation.bounds.width, 0)
    XCTAssertGreaterThan(annotation.bounds.height, 0)
  }

  func testAnnotationFactory_usesArrowBendDirectionFromContext() throws {
    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .arrow,
      from: CGPoint(x: 10, y: 20),
      to: CGPoint(x: 90, y: 80),
      path: [],
      context: makeContext(arrowStyle: .curvedLeft, arrowBendDirection: .alternate)
    ))

    guard case .arrow(let geometry) = annotation.type else {
      return XCTFail("Expected arrow annotation, got \(annotation.type)")
    }
    XCTAssertEqual(geometry.style, .curvedRight) // alternating curvedLeft style flips it to curvedRight
    XCTAssertEqual(geometry.bendDirection, .alternate)
  }

  @MainActor
  func testAnnotateStateArrowBendDirectionUpdatesNextCreatedArrow() throws {
    let state = makeAnnotateState()
    state.arrowStyle = .curvedLeft
    state.setActiveArrowBendDirection(.alternate)

    let annotation = try XCTUnwrap(AnnotationFactory.createAnnotation(
      tool: .arrow,
      from: CGPoint(x: 10, y: 20),
      to: CGPoint(x: 90, y: 80),
      path: [],
      state: state
    ))

    guard case .arrow(let geometry) = annotation.type else {
      return XCTFail("Expected arrow annotation, got \(annotation.type)")
    }
    XCTAssertEqual(geometry.bendDirection, .alternate)
  }

  @MainActor
  func testAnnotateStateArrowBendDirectionUpdatesSelectedArrow() throws {
    let state = makeAnnotateState()
    let geometry = ArrowGeometry(
      start: CGPoint(x: 10, y: 20),
      end: CGPoint(x: 90, y: 80),
      style: .curvedLeft
    )
    let annotation = AnnotationItem(
      type: .arrow(geometry),
      bounds: geometry.bounds(),
      properties: AnnotationProperties()
    )
    state.annotations.append(annotation)
    state.selectedAnnotationId = annotation.id

    state.setActiveArrowBendDirection(.alternate)

    let updated = try XCTUnwrap(state.annotations.first)
    guard case .arrow(let updatedGeometry) = updated.type else {
      return XCTFail("Expected arrow annotation, got \(updated.type)")
    }
    XCTAssertEqual(updatedGeometry.bendDirection, .alternate)
    XCTAssertEqual(updated.bounds, updatedGeometry.bounds())
  }

  @MainActor
  func testAnnotateStateArrowBendDirectionRecordsUndoAndDirtyState() throws {
    let state = makeAnnotateState()
    let geometry = ArrowGeometry(
      start: CGPoint(x: 10, y: 20),
      end: CGPoint(x: 90, y: 80),
      style: .curvedLeft
    )
    let annotation = AnnotationItem(
      type: .arrow(geometry),
      bounds: geometry.bounds(),
      properties: AnnotationProperties()
    )
    state.annotations.append(annotation)
    state.selectedAnnotationId = annotation.id

    state.hasUnsavedChanges = false
    state.setActiveArrowBendDirection(.alternate)

    XCTAssertTrue(state.hasUnsavedChanges)
    XCTAssertTrue(state.canUndo)

    state.undo()

    let restored = try XCTUnwrap(state.annotations.first)
    guard case .arrow(let restoredGeometry) = restored.type else {
      return XCTFail("Expected arrow annotation, got \(restored.type)")
    }
    XCTAssertEqual(restoredGeometry.bendDirection, .primary)
    XCTAssertTrue(state.canRedo)
  }

  func testAnnotationProperties_clampControlValueAndDerivedSizes() {
    XCTAssertEqual(AnnotationProperties.clampedControlValue(-10), 1)
    XCTAssertEqual(AnnotationProperties.clampedControlValue(30), 20)
    XCTAssertEqual(AnnotationProperties.counterDiameter(for: 3), 24)
    XCTAssertEqual(AnnotationProperties.pixelatedBlurSize(for: 2), 10)
    XCTAssertEqual(AnnotationProperties.gaussianBlurRadius(for: 2), 16)
  }

  @MainActor
  func testAnnotateExporter_renderFinalImagePreservesRetinaPixelDetail() throws {
    let state = makeAnnotateState()
    let sourceImage = try makeRetinaPixelPatternImage(pixelWidth: 96, pixelHeight: 48, scale: 2)
    state.loadImage(sourceImage)

    let renderedImage = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let sourceCGImage = try XCTUnwrap(sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let renderedCGImage = try XCTUnwrap(AnnotateExporter.bestCGImage(from: renderedImage))

    XCTAssertEqual(renderedImage.size.width, sourceImage.size.width, accuracy: 0.0001)
    XCTAssertEqual(renderedImage.size.height, sourceImage.size.height, accuracy: 0.0001)
    XCTAssertEqual(renderedCGImage.width, sourceCGImage.width)
    XCTAssertEqual(renderedCGImage.height, sourceCGImage.height)
    guard renderedCGImage.width == sourceCGImage.width, renderedCGImage.height == sourceCGImage.height else {
      return
    }

    let sourceBytes = try rgbaBytes(from: sourceCGImage)
    let renderedBytes = try rgbaBytes(from: renderedCGImage)
    XCTAssertEqual(renderedBytes.count, sourceBytes.count)
    guard renderedBytes.count == sourceBytes.count else { return }
    var mismatchedPixels = 0
    for index in stride(from: 0, to: sourceBytes.count, by: 4) {
      let pixelMatches = (0 ..< 4).allSatisfy { channel in
        abs(Int(sourceBytes[index + channel]) - Int(renderedBytes[index + channel])) <= 2
      }
      if !pixelMatches {
        mismatchedPixels += 1
      }
    }
    XCTAssertEqual(mismatchedPixels, 0)

    var softenedStripePixels = 0
    let centerY = renderedCGImage.height / 2
    for x in 0 ..< renderedCGImage.width {
      let red = renderedBytes[rgbaIndex(x: x, y: centerY, width: renderedCGImage.width)]
      if red > 2, red < 253 {
        softenedStripePixels += 1
      }
    }
    XCTAssertEqual(softenedStripePixels, 0)
  }

  @MainActor
  func testAnnotateExporter_renderFinalImageCropsRetinaSourceInImageCoordinates() throws {
    let scale: CGFloat = 2
    let state = makeAnnotateState()
    let sourceImage = try makeRetinaPixelPatternImage(pixelWidth: 96, pixelHeight: 48, scale: scale)
    let cropRect = CGRect(x: 4, y: 3, width: 20, height: 8)
    state.loadImage(sourceImage)
    state.cropRect = cropRect

    let renderedImage = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let sourceCGImage = try XCTUnwrap(sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let renderedCGImage = try XCTUnwrap(AnnotateExporter.bestCGImage(from: renderedImage))

    XCTAssertEqual(renderedCGImage.width, Int(cropRect.width * scale))
    XCTAssertEqual(renderedCGImage.height, Int(cropRect.height * scale))
    guard renderedCGImage.width == Int(cropRect.width * scale),
          renderedCGImage.height == Int(cropRect.height * scale) else {
      return
    }

    let sourceBytes = try rgbaBytes(from: sourceCGImage)
    let renderedBytes = try rgbaBytes(from: renderedCGImage)
    let sourceStartX = Int(cropRect.minX * scale)
    let sourceStartY = Int((sourceImage.size.height - cropRect.maxY) * scale)
    var mismatchedPixels = 0
    for y in 0 ..< renderedCGImage.height {
      for x in 0 ..< renderedCGImage.width {
        let sourceIndex = rgbaIndex(x: sourceStartX + x, y: sourceStartY + y, width: sourceCGImage.width)
        let renderedIndex = rgbaIndex(x: x, y: y, width: renderedCGImage.width)
        let pixelMatches = (0 ..< 4).allSatisfy { channel in
          abs(Int(sourceBytes[sourceIndex + channel]) - Int(renderedBytes[renderedIndex + channel])) <= 2
        }
        if !pixelMatches {
          mismatchedPixels += 1
        }
      }
    }
    XCTAssertEqual(mismatchedPixels, 0)
  }

  func testAspectRatioOptionOriginalKeepsForegroundRatioWithMinimumPadding() {
    let foregroundSize = CGSize(width: 1000, height: 600)

    let canvasSize = AspectRatioOption.auto.canvasSize(
      for: foregroundSize,
      padding: 100,
      alignmentSpace: 0
    )

    XCTAssertEqual(canvasSize.height, 800, accuracy: 0.0001)
    XCTAssertEqual(canvasSize.width, 800 * (1000.0 / 600.0), accuracy: 0.0001)
    XCTAssertEqual(canvasSize.width / canvasSize.height, 1000.0 / 600.0, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual((canvasSize.width - foregroundSize.width) / 2, 100)
    XCTAssertGreaterThanOrEqual((canvasSize.height - foregroundSize.height) / 2, 100)
  }

  func testAspectRatioOptionFreeKeepsPaddingOnlyCanvasSize() {
    let canvasSize = AspectRatioOption.free.canvasSize(
      for: CGSize(width: 1000, height: 600),
      padding: 100,
      alignmentSpace: 0
    )

    XCTAssertEqual(canvasSize, CGSize(width: 1200, height: 800))
  }

  func testAspectRatioOptionVerticalOrientationInvertsFixedRatio() {
    let foregroundSize = CGSize(width: 1000, height: 600)

    let canvasSize = AspectRatioOption.ratio16x9.canvasSize(
      for: foregroundSize,
      padding: 100,
      alignmentSpace: 0,
      orientation: .vertical
    )

    XCTAssertEqual(canvasSize.width, 1200, accuracy: 0.0001)
    XCTAssertEqual(canvasSize.width / canvasSize.height, 9.0 / 16.0, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual((canvasSize.width - foregroundSize.width) / 2, 100)
    XCTAssertGreaterThanOrEqual((canvasSize.height - foregroundSize.height) / 2, 100)
  }

  @MainActor
  func testAnnotateExporter_renderFinalImageUsesSelectedBackgroundAspectRatio() throws {
    let state = makeAnnotateState()
    let sourceImage = try makeRetinaPixelPatternImage(pixelWidth: 1000, pixelHeight: 600, scale: 1)
    state.loadImage(sourceImage)
    state.backgroundStyle = .solidColor(.white)
    state.padding = 100
    state.aspectRatio = .ratio16x9

    let renderedImage = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))

    XCTAssertEqual(renderedImage.size.width / renderedImage.size.height, 16.0 / 9.0, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual((renderedImage.size.width - sourceImage.size.width) / 2, 100)
    XCTAssertGreaterThanOrEqual((renderedImage.size.height - sourceImage.size.height) / 2, 100)
  }

  @MainActor
  func testAnnotateExporter_renderFinalImageUsesVerticalBackgroundAspectRatio() throws {
    let state = makeAnnotateState()
    let sourceImage = try makeRetinaPixelPatternImage(pixelWidth: 1000, pixelHeight: 600, scale: 1)
    state.loadImage(sourceImage)
    state.backgroundStyle = .solidColor(.white)
    state.padding = 100
    state.aspectRatio = .ratio16x9
    state.aspectRatioOrientation = .vertical

    let renderedImage = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))

    XCTAssertEqual(renderedImage.size.width / renderedImage.size.height, 9.0 / 16.0, accuracy: 0.0001)
    XCTAssertGreaterThanOrEqual((renderedImage.size.width - sourceImage.size.width) / 2, 100)
    XCTAssertGreaterThanOrEqual((renderedImage.size.height - sourceImage.size.height) / 2, 100)
  }

  func testCodableBackgroundStyle_roundTripsSupportedStyles() throws {
    XCTAssertEqual(try XCTUnwrap(CodableBackgroundStyle(from: BackgroundStyle.none)).toBackgroundStyle(), .none)
    XCTAssertEqual(
      try XCTUnwrap(CodableBackgroundStyle(from: .gradient(.cyanBlue))).toBackgroundStyle(),
      .gradient(.cyanBlue)
    )

    let solid = try XCTUnwrap(CodableBackgroundStyle(from: .solidColor(.red)))
    XCTAssertEqual(solid.kind, .solidColor)
    XCTAssertNotNil(solid.solidColorRGBA)
  }

  func testRGBAColorClampsComponents() {
    let color = RGBAColor(red: -1, green: 0.25, blue: 2, alpha: 1.5)

    XCTAssertEqual(color.red, 0)
    XCTAssertEqual(color.green, 0.25)
    XCTAssertEqual(color.blue, 1)
    XCTAssertEqual(color.alpha, 1)
  }

  func testAnnotateCanvasPresetPayloadApproximatelyEqualsHonorsTolerance() throws {
    let first = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )
    let close = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      padding: 40.00005,
      shadowIntensity: 0.30005,
      cornerRadius: 12.00005
    )
    let different = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.orangeRed))),
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )

    XCTAssertTrue(first.approximatelyEquals(close))
    XCTAssertFalse(first.approximatelyEquals(different))
  }

  func testAnnotateCanvasPresetPayloadDefaultsMissingAspectRatioToOriginal() throws {
    let data = Data("""
    {
      "backgroundStyle": {
        "kind": "gradient",
        "gradientPresetRawValue": "bluePurple"
      },
      "padding": 40,
      "shadowIntensity": 0.3,
      "cornerRadius": 12
    }
    """.utf8)

    let payload = try JSONDecoder().decode(AnnotateCanvasPresetPayload.self, from: data)

    XCTAssertEqual(payload.aspectRatio, .auto)
    XCTAssertEqual(payload.aspectRatioOrientation, .horizontal)
    XCTAssertFalse(payload.isBlurredBackgroundEnabled)
    XCTAssertEqual(payload.blurredBackgroundEffect, .soft)
  }

  func testAnnotateCanvasPresetPayloadApproximatelyEqualsIncludesBlurredBackgroundEffect() throws {
    let soft = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .solidColor(.blue))),
      isBlurredBackgroundEnabled: true,
      blurredBackgroundEffect: .soft,
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )
    let vivid = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .solidColor(.blue))),
      isBlurredBackgroundEnabled: true,
      blurredBackgroundEffect: .vivid,
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )

    XCTAssertFalse(soft.approximatelyEquals(vivid))
  }

  func testAnnotateCanvasPresetPayloadApproximatelyEqualsIncludesBlurredBackgroundEnabled() throws {
    let disabled = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .solidColor(.blue))),
      isBlurredBackgroundEnabled: false,
      blurredBackgroundEffect: .soft,
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )
    let enabled = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .solidColor(.blue))),
      isBlurredBackgroundEnabled: true,
      blurredBackgroundEffect: .soft,
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )

    XCTAssertFalse(disabled.approximatelyEquals(enabled))
  }

  func testAnnotateCanvasPresetPayloadApproximatelyEqualsIgnoresBlurredEffectForNonBlurredBackgrounds() throws {
    let soft = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      isBlurredBackgroundEnabled: false,
      blurredBackgroundEffect: .soft,
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )
    let vivid = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      isBlurredBackgroundEnabled: false,
      blurredBackgroundEffect: .vivid,
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12
    )

    XCTAssertTrue(soft.approximatelyEquals(vivid))
  }

  func testAnnotateCanvasPresetPayloadApproximatelyEqualsIncludesAspectRatio() throws {
    let originalRatio = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12,
      aspectRatio: .auto
    )
    let fixedRatio = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12,
      aspectRatio: .ratio16x9
    )

    XCTAssertFalse(originalRatio.approximatelyEquals(fixedRatio))
  }

  func testAnnotateCanvasPresetPayloadApproximatelyEqualsIncludesAspectRatioOrientation() throws {
    let horizontalRatio = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12,
      aspectRatio: .ratio16x9,
      aspectRatioOrientation: .horizontal
    )
    let verticalRatio = try AnnotateCanvasPresetPayload(
      backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
      padding: 40,
      shadowIntensity: 0.3,
      cornerRadius: 12,
      aspectRatio: .ratio16x9,
      aspectRatioOrientation: .vertical
    )

    XCTAssertFalse(horizontalRatio.approximatelyEquals(verticalRatio))
  }

  @MainActor
  func testAnnotateCanvasPresetStoreClearsInvalidDefaultPreset() throws {
    let (store, defaults) = makeCanvasPresetStore()
    let preset = try AnnotateCanvasPreset(
      name: "Share",
      payload: AnnotateCanvasPresetPayload(
        backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.bluePurple))),
        padding: 40,
        shadowIntensity: 0.3,
        cornerRadius: 12
      )
    )

    store.savePresets([preset])
    store.saveDefaultPresetId(preset.id)
    XCTAssertEqual(store.loadDefaultPresetId(validating: [preset]), preset.id)

    store.savePresets([])

    XCTAssertNil(store.loadDefaultPresetId(validating: []))
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.annotateDefaultCanvasPresetId))
  }

  @MainActor
  func testAnnotateCanvasPresetStoreClearsMalformedDefaultPresetId() {
    let (store, defaults) = makeCanvasPresetStore()
    defaults.set("not-a-uuid", forKey: PreferencesKeys.annotateDefaultCanvasPresetId)

    XCTAssertNil(store.loadDefaultPresetId(validating: []))
    XCTAssertNil(defaults.string(forKey: PreferencesKeys.annotateDefaultCanvasPresetId))
  }

  @MainActor
  func testAnnotateStateAppliesDefaultCanvasPresetToNewImageWithoutDirtyFlag() throws {
    let (store, _) = makeCanvasPresetStore()
    let preset = try AnnotateCanvasPreset(
      name: "Default Share",
      payload: AnnotateCanvasPresetPayload(
        backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.orangeRed))),
        padding: 48,
        shadowIntensity: 0.35,
        cornerRadius: 16
      )
    )
    store.savePresets([preset])
    store.saveDefaultPresetId(preset.id)

    let state = AnnotateState(
      image: NSImage(size: NSSize(width: 20, height: 20)),
      url: URL(fileURLWithPath: "/tmp/shotpaste-default-preset.png"),
      canvasPresetStore: store
    )
    Self.retainedAnnotateStates.append(state)

    XCTAssertEqual(state.defaultCanvasPresetId, preset.id)
    XCTAssertEqual(state.selectedCanvasPresetId, preset.id)
    XCTAssertEqual(state.backgroundStyle, .gradient(.orangeRed))
    XCTAssertEqual(state.padding, 48)
    XCTAssertEqual(state.shadowIntensity, 0.35)
    XCTAssertEqual(state.cornerRadius, 16)
    XCTAssertFalse(state.hasUnsavedChanges)
    XCTAssertTrue(state.isDefaultCanvasPresetAutoApplied)
    XCTAssertTrue(state.requiresRenderedOutputForSharing)

    state.applyCanvasPreset(preset)

    XCTAssertFalse(state.hasUnsavedChanges)
    XCTAssertTrue(state.isDefaultCanvasPresetAutoApplied)
    XCTAssertTrue(state.requiresRenderedOutputForSharing)
  }

  @MainActor
  func testAnnotateStateCanOptOutOfDefaultCanvasPresetApplication() throws {
    let (store, _) = makeCanvasPresetStore()
    let preset = try AnnotateCanvasPreset(
      name: "Default Share",
      payload: AnnotateCanvasPresetPayload(
        backgroundStyle: XCTUnwrap(CodableBackgroundStyle(from: .gradient(.orangeRed))),
        padding: 48,
        shadowIntensity: 0.35,
        cornerRadius: 16
      )
    )
    store.savePresets([preset])
    store.saveDefaultPresetId(preset.id)

    let state = AnnotateState(
      image: NSImage(size: NSSize(width: 20, height: 20)),
      url: URL(fileURLWithPath: "/tmp/shotpaste-default-preset.png"),
      canvasPresetStore: store,
      appliesDefaultCanvasPresetOnNewImages: false
    )
    Self.retainedAnnotateStates.append(state)

    XCTAssertEqual(state.defaultCanvasPresetId, preset.id)
    XCTAssertNil(state.selectedCanvasPresetId)
    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.isDefaultCanvasPresetAutoApplied)
    XCTAssertFalse(state.requiresRenderedOutputForSharing)
  }

  func testCropAspectRatioNumericValues() {
    XCTAssertEqual(CropAspectRatio.free.ratio, 0)
    XCTAssertEqual(CropAspectRatio.square.ratio, 1)
    XCTAssertEqual(CropAspectRatio.ratio4x3.ratio, 4.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(CropAspectRatio.ratio16x9.ratio, 16.0 / 9.0, accuracy: 0.0001)
    XCTAssertEqual(CropAspectRatio.ratio21x9.ratio, 21.0 / 9.0, accuracy: 0.0001)
  }

  func testAnnotationToolTypeQuickPropertiesAreScoped() {
    XCTAssertFalse(AnnotationToolType.selection.supportsQuickPropertiesBar)
    XCTAssertFalse(AnnotationToolType.crop.supportsQuickPropertiesBar)
    XCTAssertFalse(AnnotationToolType.mockup.supportsQuickPropertiesBar)
    XCTAssertTrue(AnnotationToolType.rectangle.supportsQuickPropertiesBar)
    XCTAssertTrue(AnnotationToolType.watermark.supportsQuickPropertiesBar)
    XCTAssertTrue(AnnotationToolType.filledRectangle.supportsQuickStrokeColor)
    XCTAssertFalse(AnnotationToolType.filledRectangle.supportsQuickFillColor)
    XCTAssertFalse(AnnotationToolType.rectangle.supportsQuickFillColor)
    XCTAssertTrue(AnnotationToolType.rectangle.supportsQuickCornerRadius)
    XCTAssertFalse(AnnotationToolType.oval.supportsQuickCornerRadius)
  }

  @MainActor
  func testFilledRectangleQuickColorUpdatesStrokeAndFill() throws {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .filledRectangle,
      bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
      properties: AnnotationProperties(strokeColor: .red, fillColor: .green)
    )
    state.annotations = [annotation]
    state.setSelectedAnnotationIds([annotation.id])

    XCTAssertFalse(state.quickPropertiesSupportsFill)

    state.quickStrokeColorBinding.wrappedValue = .blue

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.properties.strokeColor, .blue)
    XCTAssertEqual(updated.properties.fillColor, .blue)
  }

  @MainActor
  func testFilledRectangleDefaultColorAppliesToStrokeAndFill() {
    let state = makeAnnotateState()
    state.activateTool(.filledRectangle)

    XCTAssertFalse(state.quickPropertiesSupportsFill)

    state.quickStrokeColorBinding.wrappedValue = .purple

    let properties = state.annotationCreationProperties(for: .filledRectangle)
    XCTAssertEqual(properties.strokeColor, .purple)
    XCTAssertEqual(properties.fillColor, .purple)
  }

  @MainActor
  func testPrimaryAnnotationColorAppliesAcrossToolDefaults() {
    let state = makeAnnotateState()
    state.activateTool(.rectangle)

    state.quickStrokeColorBinding.wrappedValue = .blue

    assertColorsMatch(state.annotationCreationProperties(for: .rectangle).strokeColor, .blue)
    assertColorsMatch(state.annotationCreationProperties(for: .arrow).strokeColor, .blue)
    assertColorsMatch(state.annotationCreationProperties(for: .text).strokeColor, .blue)
    assertColorsMatch(state.annotationCreationProperties(for: .filledRectangle).strokeColor, .blue)
    assertColorsMatch(state.annotationCreationProperties(for: .filledRectangle).fillColor, .blue)

    state.activateTool(.arrow)
    assertColorsMatch(state.quickStrokeColorBinding.wrappedValue, .blue)
  }

  @MainActor
  func testPrimaryAnnotationColorPersistsAcrossAnnotateStateInstances() {
    let defaults = UserDefaultsFactory.make()
    let firstState = makeAnnotateState(defaults: defaults)
    firstState.activateTool(.arrow)

    firstState.quickStrokeColorBinding.wrappedValue = .purple

    let reloadedState = makeAnnotateState(defaults: defaults)
    reloadedState.activateTool(.rectangle)

    assertColorsMatch(reloadedState.quickStrokeColorBinding.wrappedValue, .purple)
    assertColorsMatch(reloadedState.annotationCreationProperties(for: .filledRectangle).strokeColor, .purple)
    assertColorsMatch(reloadedState.annotationCreationProperties(for: .filledRectangle).fillColor, .purple)
  }

  @MainActor
  func testSelectedItemPrimaryColorAlsoUpdatesFutureToolDefaults() throws {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
      properties: AnnotationProperties(strokeColor: .red, fillColor: .clear)
    )
    state.annotations = [annotation]
    state.setSelectedAnnotationIds([annotation.id])

    state.quickStrokeColorBinding.wrappedValue = .green

    let updated = try XCTUnwrap(state.annotations.first)
    assertColorsMatch(updated.properties.strokeColor, .green)
    assertColorsMatch(state.annotationCreationProperties(for: .line).strokeColor, .green)
    assertColorsMatch(state.annotationCreationProperties(for: .filledRectangle).fillColor, .green)
  }

  @MainActor
  func testStrokeWidthDefaultAppliesAcrossStrokeWidthTools() {
    let state = makeAnnotateState(defaults: UserDefaultsFactory.make())
    state.activateTool(.rectangle)

    state.quickStrokeWidthBinding.wrappedValue = 9

    XCTAssertEqual(state.annotationCreationProperties(for: .rectangle).strokeWidth, 9)
    XCTAssertEqual(state.annotationCreationProperties(for: .filledRectangle).strokeWidth, 9)
    XCTAssertEqual(state.annotationCreationProperties(for: .arrow).strokeWidth, 9)
    XCTAssertEqual(state.annotationCreationProperties(for: .blur).strokeWidth, 9)
    XCTAssertEqual(state.annotationCreationProperties(for: .pencil).strokeWidth, 9)

    state.activateTool(.arrow)
    XCTAssertEqual(state.quickStrokeWidthBinding.wrappedValue, 9)
  }

  @MainActor
  func testCornerRadiusDefaultAppliesAcrossRectangleTools() {
    let state = makeAnnotateState(defaults: UserDefaultsFactory.make())
    state.activateTool(.rectangle)

    state.quickCornerRadiusBinding.wrappedValue = 12

    XCTAssertEqual(state.annotationCreationProperties(for: .rectangle).cornerRadius, 12)
    XCTAssertEqual(state.annotationCreationProperties(for: .filledRectangle).cornerRadius, 12)

    state.activateTool(.filledRectangle)
    XCTAssertEqual(state.quickCornerRadiusBinding.wrappedValue, 12)
  }

  @MainActor
  func testFontSizeDefaultAppliesAcrossTextAndWatermarkTools() {
    let state = makeAnnotateState(defaults: UserDefaultsFactory.make())
    state.activateTool(.text)

    state.quickTextFontSizeBinding.wrappedValue = 30

    XCTAssertEqual(state.annotationCreationProperties(for: .text).fontSize, 30)
    XCTAssertEqual(state.annotationCreationProperties(for: .watermark).fontSize, 30)

    state.activateTool(.watermark)
    XCTAssertEqual(state.quickTextFontSizeBinding.wrappedValue, 30)
  }

  @MainActor
  func testSelectedItemNumericControlsDoNotUpdateFutureToolDefaults() throws {
    let state = makeAnnotateState(defaults: UserDefaultsFactory.make())
    let annotation = AnnotationItem(
      type: .rectangle,
      bounds: CGRect(x: 0, y: 0, width: 80, height: 40),
      properties: AnnotationProperties(strokeWidth: 3)
    )
    state.annotations = [annotation]
    state.setSelectedAnnotationIds([annotation.id])

    state.quickStrokeWidthBinding.wrappedValue = 12

    let updated = try XCTUnwrap(state.annotations.first)
    XCTAssertEqual(updated.properties.strokeWidth, 12)
    XCTAssertEqual(state.annotationCreationProperties(for: .arrow).strokeWidth, 3)
    XCTAssertEqual(state.annotationCreationProperties(for: .rectangle).strokeWidth, 3)
  }

  @MainActor
  func testQuickPropertiesSliderGestureRecordsSingleUndoCheckpoint() throws {
    let state = makeAnnotateState(defaults: UserDefaultsFactory.make())
    let annotation = AnnotationItem(
      type: .blur(.pixelated),
      bounds: CGRect(x: 0, y: 0, width: 120, height: 80),
      properties: AnnotationProperties(strokeWidth: 3)
    )
    state.annotations = [annotation]
    state.setSelectedAnnotationIds([annotation.id])

    state.setQuickPropertiesControlEditing(true)
    state.quickStrokeWidthBinding.wrappedValue = 8
    state.quickStrokeWidthBinding.wrappedValue = 12
    state.setQuickPropertiesControlEditing(false)

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.strokeWidth, 12)

    state.undo()

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.strokeWidth, 3)
    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testPropertySliderGestureRecordsSingleUndoCheckpoint() throws {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .text("Sized text"),
      bounds: CGRect(x: 20, y: 20, width: 180, height: 32),
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.setPropertySliderGestureEditing(true)
    state.updateAnnotationProperties(id: annotation.id, fontSize: 24, recordsUndo: true)
    state.updateAnnotationProperties(id: annotation.id, fontSize: 36, recordsUndo: true)
    state.updateAnnotationProperties(id: annotation.id, fontSize: 48, recordsUndo: true)
    state.setPropertySliderGestureEditing(false)

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.fontSize, 48)

    state.undo()

    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.fontSize, 18)
    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testPropertySliderGestureWithoutChangeRecordsNoUndo() {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .text("Sized text"),
      bounds: CGRect(x: 20, y: 20, width: 180, height: 32),
      properties: AnnotationProperties(fontSize: 18)
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    state.setPropertySliderGestureEditing(true)
    state.setPropertySliderGestureEditing(false)

    XCTAssertFalse(state.canUndo)
  }

  @MainActor
  func testUndoStackIsCappedDuringRapidPropertyEdits() throws {
    let state = makeAnnotateState()
    let annotation = AnnotationItem(
      type: .text("Sized text"),
      bounds: CGRect(x: 20, y: 20, width: 180, height: 32),
      properties: AnnotationProperties(fontSize: 12)
    )
    state.annotations = [annotation]
    state.selectedAnnotationId = annotation.id

    // 60 individual (non-gesture) property edits push 60 undo checkpoints.
    for size in 13 ... 72 {
      state.updateAnnotationProperties(id: annotation.id, fontSize: CGFloat(size), recordsUndo: true)
    }

    var undoCount = 0
    while state.canUndo {
      state.undo()
      undoCount += 1
    }
    XCTAssertEqual(undoCount, 50)
    XCTAssertEqual(try XCTUnwrap(state.annotations.first).properties.fontSize, 22)
  }

  @MainActor
  func testSharedParameterDefaultsPersistAcrossAnnotateStateInstances() {
    let defaults = UserDefaultsFactory.make()
    let firstState = makeAnnotateState(defaults: defaults)

    firstState.activateTool(.rectangle)
    firstState.quickStrokeWidthBinding.wrappedValue = 11
    firstState.quickCornerRadiusBinding.wrappedValue = 7
    firstState.activateTool(.text)
    firstState.quickTextFontSizeBinding.wrappedValue = 32
    firstState.activateTool(.watermark)
    firstState.quickWatermarkOpacityBinding.wrappedValue = 0.4
    firstState.quickWatermarkRotationBinding.wrappedValue = -12

    let reloadedState = makeAnnotateState(defaults: defaults)

    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .line).strokeWidth, 11)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .blur).strokeWidth, 11)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .filledRectangle).cornerRadius, 7)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .text).fontSize, 32)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .watermark).fontSize, 32)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .watermark).opacity, 0.4)
    XCTAssertEqual(reloadedState.annotationCreationProperties(for: .watermark).rotationDegrees, -12)
  }

  @MainActor
  func testArrowPreferencesPersistAcrossAnnotateStateInstances() {
    let defaults = UserDefaultsFactory.make()
    let firstState = makeAnnotateState(defaults: defaults)

    firstState.activateTool(.arrow)
    firstState.quickArrowStyleBinding.wrappedValue = .curvedRight
    firstState.quickArrowTypeBinding.wrappedValue = .outlined
    firstState.quickArrowBendDirectionBinding.wrappedValue = .alternate

    let reloadedState = makeAnnotateState(defaults: defaults)

    XCTAssertEqual(reloadedState.arrowStyle, .curvedRight)
    XCTAssertEqual(reloadedState.arrowType, .outlined)
    XCTAssertEqual(reloadedState.arrowBendDirection, .alternate)
  }

  func testMockupPresetCatalogContainsUniqueBuiltInPresets() {
    let presets = MockupPreset.allPresets

    XCTAssertEqual(presets.count, 8)
    XCTAssertEqual(Set(presets.map(\.id)).count, presets.count)
    XCTAssertEqual(DefaultPresets.all, presets)
    XCTAssertEqual(DefaultPresets.preset(named: "Hero Shot"), .heroShot)
    XCTAssertNil(DefaultPresets.preset(named: "Missing"))
  }

  private func makeContext(
    properties: AnnotationProperties = AnnotationProperties(),
    arrowStyle: ArrowStyle = .straight,
    arrowBendDirection: ArrowBendDirection = .primary,
    blurType: BlurType = .pixelated,
    counterValue: Int = 1,
    watermarkText: String = "ShotPaste",
    bounds: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300)
  ) -> AnnotationFactory.CreationContext {
    AnnotationFactory.CreationContext(
      properties: properties,
      arrowStyle: arrowStyle,
      arrowBendDirection: arrowBendDirection,
      blurType: blurType,
      counterValue: counterValue,
      watermarkText: watermarkText,
      activeAnnotationBounds: bounds
    )
  }

  private func makeMouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: location,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )!
  }

  private func makeRetinaPixelPatternImage(
    pixelWidth: Int,
    pixelHeight: Int,
    scale: CGFloat
  ) throws -> NSImage {
    var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    for y in 0 ..< pixelHeight {
      for x in 0 ..< pixelWidth {
        let index = rgbaIndex(x: x, y: y, width: pixelWidth)
        let whiteStripe = x.isMultiple(of: 2)
        let topBand = y < pixelHeight / 2
        pixels[index] = whiteStripe ? 255 : 0
        pixels[index + 1] = topBand ? 48 : 208
        pixels[index + 2] = topBand ? 32 : 192
        pixels[index + 3] = 255
      }
    }

    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let cgImage = try XCTUnwrap(CGImage(
      width: pixelWidth,
      height: pixelHeight,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: pixelWidth * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: rgbaBitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))

    return NSImage(
      cgImage: cgImage,
      size: CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    )
  }

  private func rgbaBytes(from image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: rgbaBitmapInfo.rawValue
      ))
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private func assertColorsMatch(
    _ lhs: Color,
    _ rhs: Color,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(RGBAColor(color: lhs), RGBAColor(color: rhs), file: file, line: line)
  }

  private var rgbaBitmapInfo: CGBitmapInfo {
    CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
  }

  private func rgbaIndex(x: Int, y: Int, width: Int) -> Int {
    (y * width + x) * 4
  }

  @MainActor
  func testSpotlightAnnotationCreation() {
    let defaults = UserDefaultsFactory.make()
    let state = makeAnnotateState(defaults: defaults)
    let start = CGPoint(x: 10, y: 10)
    let end = CGPoint(x: 100, y: 100)
    let item = AnnotationFactory.createAnnotation(
      tool: .spotlight,
      from: start,
      to: end,
      path: [],
      state: state
    )
    XCTAssertNotNil(item)
    XCTAssertEqual(item?.type, .spotlight)
    XCTAssertEqual(item?.bounds, CGRect(x: 10, y: 10, width: 90, height: 90))
    XCTAssertEqual(item?.properties.spotlightOpacity, 0.5)
    XCTAssertEqual(item?.properties.cornerRadius, 14)
  }

  @MainActor
  func testSpotlightAnnotationCreationDegenerateDrag() {
    let defaults = UserDefaultsFactory.make()
    let state = makeAnnotateState(defaults: defaults)
    let start = CGPoint(x: 10, y: 10)
    let end = CGPoint(x: 15, y: 15) // less than 8px drag
    let item = AnnotationFactory.createAnnotation(
      tool: .spotlight,
      from: start,
      to: end,
      path: [],
      state: state
    )
    XCTAssertNil(item)
  }

  @MainActor
  func testSpotlightCornerRadiusIsolation() {
    let defaults = UserDefaultsFactory.make()
    let state = makeAnnotateState(defaults: defaults)

    // Set rectangle corner radius default to 0
    state.selectedTool = .rectangle
    state.quickCornerRadiusBinding.wrappedValue = 0

    // Creating a spotlight annotation should still default to 14 corner radius
    let start = CGPoint(x: 10, y: 10)
    let end = CGPoint(x: 100, y: 100)
    let item = AnnotationFactory.createAnnotation(
      tool: .spotlight,
      from: start,
      to: end,
      path: [],
      state: state
    )
    XCTAssertEqual(item?.properties.cornerRadius, 14)
  }

  @MainActor
  func testSpotlightOpacityStoredPerItem() throws {
    // Verifies the opacity-source fix: per-item spotlightOpacity is what gets persisted
    // and read by the compositor, not the global state.spotlightOpacity.
    let defaults = UserDefaultsFactory.make()
    let state = makeAnnotateState(defaults: defaults)

    // Change global opacity before creating the item
    state.spotlightOpacity = 0.8

    let item = AnnotationFactory.createAnnotation(
      tool: .spotlight,
      from: CGPoint(x: 0, y: 0),
      to: CGPoint(x: 100, y: 100),
      path: [],
      state: state
    )
    let unwrapped = try XCTUnwrap(item)
    // Item must carry the opacity at creation time, not the default 0.5
    XCTAssertEqual(unwrapped.properties.spotlightOpacity, 0.8, accuracy: 0.001)
  }

  @MainActor
  func testSpotlightOpacityClamp() {
    XCTAssertEqual(AnnotationProperties.clampedSpotlightOpacity(0.0), 0.1, accuracy: 0.001)
    XCTAssertEqual(AnnotationProperties.clampedSpotlightOpacity(1.0), 0.9, accuracy: 0.001)
    XCTAssertEqual(AnnotationProperties.clampedSpotlightOpacity(0.5), 0.5, accuracy: 0.001)
  }

  @MainActor
  func testSpotlightRegionCarriesOpacity() {
    // SpotlightRegion must carry opacity so the compositor can source it per-item.
    let region = SpotlightRegion(rect: CGRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 14, opacity: 0.75)
    XCTAssertEqual(region.opacity, 0.75, accuracy: 0.001)
  }

  @MainActor
  func testSpotlightOpacityPersistence() {
    let defaults = UserDefaultsFactory.make()
    let firstState = makeAnnotateState(defaults: defaults)
    firstState.activateTool(.spotlight)

    // Change the spotlight opacity (darkness) tool default property
    firstState.quickSpotlightOpacityBinding.wrappedValue = 0.75

    // Re-initialize state with the same defaults to simulate reload/reopen
    let reloadedState = makeAnnotateState(defaults: defaults)

    // Assert that the default spotlight opacity for the spotlight tool has persisted
    let spotlightProperties = reloadedState.annotationCreationProperties(for: .spotlight)
    XCTAssertEqual(spotlightProperties.spotlightOpacity, 0.75, accuracy: 0.001)
  }
}
