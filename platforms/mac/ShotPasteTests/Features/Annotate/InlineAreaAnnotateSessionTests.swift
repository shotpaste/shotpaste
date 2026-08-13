//
//  InlineAreaAnnotateSessionTests.swift
//  ShotPasteTests
//
//  Unit tests for InlineAreaAnnotateSession coordinate conversion helpers.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import XCTest

final class InlineAreaAnnotateSessionTests: XCTestCase {
  // MARK: - desktopFrame

  func testDesktopFrame_unionsScreenFrames() {
    let frames = [
      CGRect(x: 0, y: 0, width: 1000, height: 600),
      CGRect(x: 1000, y: 100, width: 800, height: 500),
    ]
    let desktop = InlineAreaAnnotateSession.desktopFrame(for: frames)
    XCTAssertEqual(desktop.minX, 0)
    XCTAssertEqual(desktop.maxX, 1800)
    XCTAssertEqual(desktop.minY, 0)
    XCTAssertEqual(desktop.maxY, 600)
  }

  // MARK: - localFrame / screenRect / localRect

  func testLocalFrame_convertsScreenToLocal() {
    let desktop = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let screen = CGRect(x: 1000, y: 100, width: 800, height: 500)
    let local = InlineAreaAnnotateSession.localFrame(for: screen, in: desktop)
    XCTAssertEqual(local.minX, 1000)
    XCTAssertEqual(local.minY, 600) // desktop.maxY - screen.maxY = 1200 - 600
    XCTAssertEqual(local.width, 800)
    XCTAssertEqual(local.height, 500)
  }

  func testScreenRect_convertsLocalToScreen() {
    let desktop = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let local = CGRect(x: 1000, y: 600, width: 800, height: 500)
    let screen = InlineAreaAnnotateSession.screenRect(for: local, in: desktop)
    XCTAssertEqual(screen.minX, 1000)
    XCTAssertEqual(screen.minY, 100) // desktop.maxY - local.maxY = 1200 - 1100
    XCTAssertEqual(screen.width, 800)
    XCTAssertEqual(screen.height, 500)
  }

  func testLocalRect_roundTrips() {
    let desktop = CGRect(x: 0, y: 0, width: 2000, height: 1200)
    let screen = CGRect(x: 500, y: 200, width: 400, height: 300)
    let local = InlineAreaAnnotateSession.localFrame(for: screen, in: desktop)
    let back = InlineAreaAnnotateSession.screenRect(for: local, in: desktop)
    XCTAssertEqual(back.minX, screen.minX, accuracy: 0.001)
    XCTAssertEqual(back.minY, screen.minY, accuracy: 0.001)
    XCTAssertEqual(back.width, screen.width, accuracy: 0.001)
    XCTAssertEqual(back.height, screen.height, accuracy: 0.001)
  }

  // MARK: - displayIDsIntersecting

  func testDisplayIDsIntersecting_findsIntersecting() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 1000, height: 600),
      2: CGRect(x: 1000, y: 0, width: 800, height: 600),
    ]
    let rect = CGRect(x: 1100, y: 100, width: 200, height: 200)
    let ids = InlineAreaAnnotateSession.displayIDsIntersecting(rect, screenFramesByDisplayID: frames)
    XCTAssertEqual(ids.count, 1)
    XCTAssertTrue(ids.contains(2))
  }

  func testDisplayIDsIntersecting_emptyWhenNoOverlap() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 100, height: 100),
    ]
    let rect = CGRect(x: 200, y: 200, width: 50, height: 50)
    let ids = InlineAreaAnnotateSession.displayIDsIntersecting(rect, screenFramesByDisplayID: frames)
    XCTAssertTrue(ids.isEmpty)
  }

  // MARK: - primaryDisplayID

  func testPrimaryDisplayID_returnsLargestOverlap() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 1000, height: 600),
      2: CGRect(x: 1000, y: 0, width: 800, height: 600),
    ]
    let rect = CGRect(x: 1050, y: 100, width: 400, height: 400)
    let id = InlineAreaAnnotateSession.primaryDisplayID(
      for: rect,
      screenFramesByDisplayID: frames,
      fallback: 99
    )
    XCTAssertEqual(id, 2)
  }

  func testPrimaryDisplayID_usesFallbackWhenNoOverlap() {
    let frames: [CGDirectDisplayID: CGRect] = [
      1: CGRect(x: 0, y: 0, width: 100, height: 100),
    ]
    let rect = CGRect(x: 200, y: 200, width: 50, height: 50)
    let id = InlineAreaAnnotateSession.primaryDisplayID(
      for: rect,
      screenFramesByDisplayID: frames,
      fallback: 99
    )
    XCTAssertEqual(id, 99)
  }

  // MARK: - Shortcut matching

  func testInlineShortcutMatchersRecognizeCommandSaveAndCopy() throws {
    let save = try makeKeyEvent(keyCode: 1, characters: "s", flags: .command)
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertTrue(InlineAreaAnnotateSession.matchesCommandSaveShortcut(save))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesCommandCopyShortcut(copy))
  }

  func testInlineCopyShortcutRequiresPlainCommandModifier() throws {
    let shiftCopy = try makeKeyEvent(keyCode: 8, characters: "C", flags: [.command, .shift])
    let optionCopy = try makeKeyEvent(keyCode: 8, characters: "c", flags: [.command, .option])
    let capsLockCopy = try makeKeyEvent(keyCode: 8, characters: "c", flags: [.command, .capsLock])

    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandCopyShortcut(shiftCopy))
    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandCopyShortcut(optionCopy))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesCommandCopyShortcut(capsLockCopy))
  }

  func testInlineCopyShortcutRequiresLocalEventOrKeyWindow() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertTrue(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: true,
      hasTextResponder: false,
      hasKeyWindow: false
    ))
    XCTAssertTrue(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: false,
      hasTextResponder: false,
      hasKeyWindow: true
    ))
    XCTAssertFalse(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: false,
      hasTextResponder: false,
      hasKeyWindow: false
    ))
    XCTAssertFalse(InlineAreaAnnotateSession.shouldHandleCommandCopyShortcut(
      copy,
      isLocalEvent: true,
      hasTextResponder: true,
      hasKeyWindow: true
    ))
  }

  func testInlineKeyActionKeepsTextCopyNative() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .local,
        phase: .annotating,
        hasTextResponder: true,
        hasKeyWindow: true
      ),
      .passThrough
    )
  }

  func testInlineKeyActionGatesGlobalCopyByKeyWindow() throws {
    let copy = try makeKeyEvent(keyCode: 8, characters: "c", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .global,
        phase: .annotating,
        hasTextResponder: false,
        hasKeyWindow: false
      ),
      .passThrough
    )
    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: copy,
        source: .global,
        phase: .annotating,
        hasTextResponder: false,
        hasKeyWindow: true
      ),
      .copyCurrentImage
    )
  }

  func testInlineKeyActionKeepsSaveWhileTextEditing() throws {
    let save = try makeKeyEvent(keyCode: 1, characters: "s", flags: .command)

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: save,
        source: .local,
        phase: .annotating,
        hasTextResponder: true,
        hasKeyWindow: true
      ),
      .finish
    )
  }

  func testInlineKeyActionResetsMoveModifierWhileTextEditing() throws {
    let spaceUp = try makeKeyEvent(type: .keyUp, keyCode: 49, characters: " ", flags: [])

    XCTAssertEqual(
      InlineAreaAnnotateSession.keyAction(
        for: spaceUp,
        source: .local,
        phase: .annotating,
        hasTextResponder: true,
        hasKeyWindow: true
      ),
      .resetMoveModifierAndPassThrough
    )
  }

  func testInlineShortcutMatchersIgnoreKeyUpEvents() throws {
    let saveKeyUp = try makeKeyEvent(type: .keyUp, keyCode: 1, characters: "s", flags: .command)
    let copyKeyUp = try makeKeyEvent(type: .keyUp, keyCode: 8, characters: "c", flags: .command)

    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandSaveShortcut(saveKeyUp))
    XCTAssertFalse(InlineAreaAnnotateSession.matchesCommandCopyShortcut(copyKeyUp))
  }

  func testInlineShortcutMatchersPreserveFinishCancelAndMoveKeys() throws {
    let returnKey = try makeKeyEvent(keyCode: 36, characters: "\r", flags: [])
    let escapeKey = try makeKeyEvent(keyCode: 53, characters: "\u{1b}", flags: [])
    let spaceDown = try makeKeyEvent(keyCode: 49, characters: " ", flags: [])
    let spaceUp = try makeKeyEvent(type: .keyUp, keyCode: 49, characters: " ", flags: [])

    XCTAssertTrue(InlineAreaAnnotateSession.matchesFinishShortcut(returnKey))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesCancelShortcut(escapeKey))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesMoveModifierKey(spaceDown))
    XCTAssertTrue(InlineAreaAnnotateSession.matchesMoveModifierKey(spaceUp))
  }

  @MainActor
  func testDiagonalResizeCursorsHaveLightHaloAndDarkCore() throws {
    for nwse in [true, false] {
      let cursor = InlineAreaResizeCursor.diagonal(nwse: nwse)
      let tiff = try XCTUnwrap(cursor.image.tiffRepresentation)
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
      var hasLightPixel = false
      var hasDarkPixel = false

      for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                color.alphaComponent > 0.5 else { continue }
          let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
          hasLightPixel = hasLightPixel || luminance > 0.85
          hasDarkPixel = hasDarkPixel || luminance < 0.15
        }
      }

      XCTAssertTrue(hasLightPixel, "Diagonal resize cursor needs a light halo for dark captures.")
      XCTAssertTrue(hasDarkPixel, "Diagonal resize cursor needs a dark core for light captures.")
      XCTAssertFalse(cursor.image.isTemplate)
    }
  }

  func testResizePreviewUsesFixedDisplayCanvasWithoutMovingAnnotations() {
    let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let stableSelection = CGRect(x: 100, y: 120, width: 400, height: 300)
    let annotation = CGRect(x: 30, y: 45, width: 80, height: 50)
    let resizedSelections = [
      CGRect(x: 40, y: 120, width: 460, height: 300),
      CGRect(x: 100, y: 120, width: 460, height: 300),
      CGRect(x: 100, y: 80, width: 400, height: 340),
      CGRect(x: 100, y: 120, width: 400, height: 340),
      CGRect(x: 130, y: 120, width: 370, height: 300),
      CGRect(x: 100, y: 120, width: 370, height: 300),
      CGRect(x: 100, y: 150, width: 400, height: 270),
      CGRect(x: 100, y: 120, width: 400, height: 270),
    ]

    let layout = InlineAreaAnnotationPreviewLayout.resolve(
      stableSelectionRect: stableSelection,
      displayFrame: displayFrame,
      imageSize: stableSelection.size
    )
    XCTAssertEqual(layout.displayScale, 1, accuracy: 0.0001)
    XCTAssertEqual(
      layout.canvasBounds,
      CGRect(x: -100, y: -480, width: 1440, height: 900)
    )

    let previewGlobalBounds = CGRect(
      x: displayFrame.minX + (annotation.minX - layout.canvasBounds.minX) * layout.displayScale,
      y: displayFrame.minY + (layout.canvasBounds.maxY - annotation.maxY) * layout.displayScale,
      width: annotation.width * layout.displayScale,
      height: annotation.height * layout.displayScale
    )
    XCTAssertEqual(previewGlobalBounds.minX, stableSelection.minX + annotation.minX)
    XCTAssertEqual(previewGlobalBounds.minY, stableSelection.maxY - annotation.maxY)
    XCTAssertEqual(previewGlobalBounds.size, annotation.size)

    for resizedSelection in resizedSelections {
      let resizedLayout = InlineAreaAnnotationPreviewLayout.resolve(
        stableSelectionRect: stableSelection,
        displayFrame: displayFrame,
        imageSize: stableSelection.size
      )

      XCTAssertEqual(resizedLayout, layout)

      let annotationOffset = InlineAreaSelectionAnnotationGeometry.annotationOffset(
        from: stableSelection,
        to: resizedSelection
      )
      let committedAnnotation = annotation.offsetBy(
        dx: annotationOffset.x,
        dy: annotationOffset.y
      )
      XCTAssertEqual(
        resizedSelection.minX + committedAnnotation.minX,
        stableSelection.minX + annotation.minX
      )
      XCTAssertEqual(
        resizedSelection.maxY - committedAnnotation.maxY,
        stableSelection.maxY - annotation.maxY
      )
      XCTAssertEqual(committedAnnotation.size, annotation.size)
    }
  }

  func testExpandedSelectionRevealsRetainedOverflowingAnnotation() {
    let stableSelection = CGRect(x: 100, y: 120, width: 400, height: 300)
    let cases = [
      (
        annotation: CGRect(x: -80, y: 80, width: 40, height: 40),
        selection: CGRect(x: 0, y: 120, width: 500, height: 300)
      ),
      (
        annotation: CGRect(x: 440, y: 80, width: 40, height: 40),
        selection: CGRect(x: 100, y: 120, width: 500, height: 300)
      ),
      (
        annotation: CGRect(x: 80, y: 330, width: 40, height: 40),
        selection: CGRect(x: 100, y: 40, width: 400, height: 380)
      ),
      (
        annotation: CGRect(x: 80, y: -70, width: 40, height: 40),
        selection: CGRect(x: 100, y: 120, width: 400, height: 400)
      ),
    ]

    for testCase in cases {
      let overflowingAnnotation = testCase.annotation
      let expandedSelection = testCase.selection
      let globalAnnotation = CGRect(
        x: stableSelection.minX + overflowingAnnotation.minX,
        y: stableSelection.maxY - overflowingAnnotation.maxY,
        width: overflowingAnnotation.width,
        height: overflowingAnnotation.height
      )

      XCTAssertFalse(stableSelection.intersects(globalAnnotation))
      XCTAssertTrue(expandedSelection.contains(globalAnnotation))

      let annotationOffset = InlineAreaSelectionAnnotationGeometry.annotationOffset(
        from: stableSelection,
        to: expandedSelection
      )
      let committedAnnotation = overflowingAnnotation.offsetBy(
        dx: annotationOffset.x,
        dy: annotationOffset.y
      )

      XCTAssertEqual(expandedSelection.minX + committedAnnotation.minX, globalAnnotation.minX)
      XCTAssertEqual(expandedSelection.maxY - committedAnnotation.maxY, globalAnnotation.minY)
      XCTAssertEqual(committedAnnotation.size, overflowingAnnotation.size)
      XCTAssertTrue(CGRect(origin: .zero, size: expandedSelection.size).contains(committedAnnotation))
    }
  }

  private func makeKeyEvent(
    type: NSEvent.EventType = .keyDown,
    keyCode: UInt16,
    characters: String,
    flags: NSEvent.ModifierFlags
  ) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: type,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters.lowercased(),
      isARepeat: false,
      keyCode: keyCode
    ))
  }
}
