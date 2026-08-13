//
//  OneShotSessionStateTests.swift
//  ShotPasteTests
//
//  Acceptance coverage for the shared One Shot state machine.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class OneShotSessionStateTests: XCTestCase {
  private let displayA: CGDirectDisplayID = 11
  private let displayB: CGDirectDisplayID = 22

  private var recordingOptions: OneShotRecordingOptions {
    OneShotRecordingOptions(
      outputMode: .video,
      showsCursor: true,
      capturesSystemAudio: true,
      capturesMicrophone: false
    )
  }

  private func makeArmedState() -> OneShotSessionState {
    let state = OneShotSessionState(recordingOptions: recordingOptions)
    state.beginPreparing(switcherDisplayID: displayA, switcherX: 500)
    state.arm(frozenDisplayIDs: [displayA, displayB])
    return state
  }

  @discardableResult
  private func makeSelectedState(
    rect: CGRect = CGRect(x: 120, y: 160, width: 640, height: 360)
  ) -> OneShotSessionState {
    let state = makeArmedState()
    state.beginSelection()
    XCTAssertTrue(state.finishSelection(rect, displayIDs: [displayA, displayB]))
    return state
  }

  func testOS010ArmingDefaultsToScreenshotWithFrozenDisplays() {
    let state = makeArmedState()

    XCTAssertEqual(state.phase, .armed)
    XCTAssertEqual(state.activeTab, .screenshot)
    XCTAssertEqual(state.frozenDisplayIDs, [displayA, displayB])
    XCTAssertTrue(state.isPristine)
    XCTAssertTrue(state.showsTopSwitcher)
  }

  func testAutomationCanPreselectScrollingOrRecordingWhenArming() {
    for initialTab in [OneShotTab.scrolling, .recording] {
      let state = OneShotSessionState(
        initialTab: initialTab,
        recordingOptions: recordingOptions
      )
      state.beginPreparing(switcherDisplayID: displayA, switcherX: 500)
      state.arm(frozenDisplayIDs: [displayA])

      XCTAssertEqual(state.activeTab, initialTab)
      XCTAssertEqual(state.phase, .armed)
      XCTAssertTrue(state.isPristine)
    }
  }

  func testOS011MovingSwitcherIsHorizontalClampedAndDoesNotCommit() {
    let state = makeArmedState()

    state.moveSwitcher(to: 920, within: 200 ... 800)

    XCTAssertEqual(state.switcherX, 800)
    XCTAssertEqual(state.phase, .armed)
    XCTAssertTrue(state.isPristine)
    XCTAssertNil(state.commitReason)
  }

  func testOS012AndOS013SelectionBeginsWithoutSwitcherOrOldSelection() {
    let state = makeSelectedState()

    state.beginSelection()

    XCTAssertEqual(state.phase, .selecting)
    XCTAssertFalse(state.canSwitchTab)
    XCTAssertFalse(state.showsTopSwitcher)
    XCTAssertNil(state.selectionRectGlobal)
    XCTAssertTrue(state.selectionDisplayIDs.isEmpty)
  }

  func testTopSwitcherReturnsAfterSelectionAndHidesWhenModeCommits() {
    let state = makeArmedState()

    state.beginSelection()
    XCTAssertFalse(state.showsTopSwitcher)

    XCTAssertTrue(
      state.finishSelection(
        CGRect(x: 120, y: 160, width: 640, height: 360),
        displayIDs: [displayA]
      )
    )
    XCTAssertTrue(state.canSwitchTab)
    XCTAssertTrue(state.showsTopSwitcher)

    XCTAssertTrue(state.commitModeInteraction(.screenshotTool))
    XCTAssertFalse(state.canSwitchTab)
    XCTAssertFalse(state.showsTopSwitcher)
    XCTAssertEqual(state.requestTab(.scrolling), .rejected)
  }

  func testOS015AndOS018TabsPreserveIdenticalGlobalSelectionAcrossDisplays() {
    let rect = CGRect(x: -320, y: 80, width: 1_200, height: 720)
    let state = makeSelectedState(rect: rect)

    for tab in [OneShotTab.scrolling, .recording, .screenshot] {
      XCTAssertEqual(state.requestTab(tab), .switched)
      XCTAssertEqual(state.selectionRectGlobal, rect)
      XCTAssertEqual(state.selectionDisplayIDs, [displayA, displayB])
    }
  }

  func testOS016MovingAndResizingSelectionKeepsTabsSwitchable() {
    let state = makeSelectedState()
    let adjusted = CGRect(x: 240, y: 260, width: 800, height: 450)

    state.updateEditableSelection(adjusted, displayIDs: [displayB])

    XCTAssertEqual(state.selectionRectGlobal, adjusted)
    XCTAssertTrue(state.isPristine)
    XCTAssertEqual(state.requestTab(.recording), .switched)
  }

  func testOS017InvalidReselectionReturnsToArmedAndDiscardsOldSelection() {
    let state = makeSelectedState()

    state.beginSelection()
    XCTAssertFalse(
      state.finishSelection(
        CGRect(x: 10, y: 10, width: 3, height: 3),
        displayIDs: [displayA]
      )
    )

    XCTAssertEqual(state.phase, .armed)
    XCTAssertNil(state.selectionRectGlobal)
    XCTAssertTrue(state.selectionDisplayIDs.isEmpty)
    XCTAssertTrue(state.canSwitchTab)
    XCTAssertTrue(state.showsTopSwitcher)
  }

  func testOS020OS025AndOS026ScreenshotToolCommitsLocksTabsAndSelection() {
    let initialRect = CGRect(x: 120, y: 160, width: 640, height: 360)
    let state = makeSelectedState(rect: initialRect)

    XCTAssertTrue(state.commitModeInteraction(.screenshotTool))
    state.updateEditableSelection(
      CGRect(x: 0, y: 0, width: 100, height: 100),
      displayIDs: [displayA]
    )
    state.beginSelection()

    XCTAssertEqual(state.phase, .committed)
    XCTAssertEqual(state.commitReason, .screenshotTool)
    XCTAssertFalse(state.isPristine)
    XCTAssertFalse(state.selectionIsEditable)
    XCTAssertEqual(state.selectionRectGlobal, initialRect)
    XCTAssertEqual(state.requestTab(.scrolling), .rejected)
    XCTAssertEqual(state.activeTab, .screenshot)
    XCTAssertFalse(state.showsTopSwitcher)
  }

  func testOneShotOCRCommitsScreenshotAndPreservesTheOuterSelection() {
    let initialRect = CGRect(x: 120, y: 160, width: 640, height: 360)
    let state = makeSelectedState(rect: initialRect)

    XCTAssertTrue(state.commitModeInteraction(.screenshotOCR))

    XCTAssertEqual(state.phase, .committed)
    XCTAssertEqual(state.commitReason, .screenshotOCR)
    XCTAssertFalse(state.selectionIsEditable)
    XCTAssertEqual(state.selectionRectGlobal, initialRect)
    XCTAssertEqual(state.requestTab(.recording), .rejected)
    XCTAssertEqual(state.activeTab, .screenshot)
    XCTAssertTrue(state.beginExecuting())
    XCTAssertEqual(state.phase, .executing)
  }

  func testOS022ScrollingHelpDoesNotCommitAndTabsRemainSwitchable() {
    let state = makeSelectedState()
    XCTAssertEqual(state.requestTab(.scrolling), .switched)

    state.toggleScrollingHelp()

    XCTAssertTrue(state.showsScrollingHelp)
    XCTAssertTrue(state.isPristine)
    XCTAssertEqual(state.phase, .selected)
    XCTAssertEqual(state.requestTab(.screenshot), .switched)
  }

  func testOS023ScrollingStartCommitsBeforeExecution() {
    let state = makeSelectedState()
    XCTAssertEqual(state.requestTab(.scrolling), .switched)

    XCTAssertTrue(state.commitModeInteraction(.scrollingStart))
    XCTAssertEqual(state.phase, .committed)
    XCTAssertEqual(state.commitReason, .scrollingStart)
    XCTAssertTrue(state.beginExecuting())
    XCTAssertEqual(state.phase, .executing)
  }

  func testOS024RecordingTabDoesNotCommitUntilAnOptionChanges() {
    let state = makeSelectedState()
    XCTAssertEqual(state.requestTab(.recording), .switched)
    XCTAssertEqual(state.phase, .selected)
    XCTAssertTrue(state.isPristine)

    var options = recordingOptions
    options.outputMode = .gif
    state.updateRecordingOptions(options, reason: .recordingOutputMode)

    XCTAssertEqual(state.phase, .committed)
    XCTAssertEqual(state.commitReason, .recordingOutputMode)
    XCTAssertEqual(state.recordingOptions.outputMode, .gif)
  }

  func testOS040AndOS041ClipboardRequestClearsAnySelection() {
    let armed = makeArmedState()
    XCTAssertEqual(armed.requestTab(.clipboard), .openClipboard)
    XCTAssertNil(armed.selectionRectGlobal)

    let selected = makeSelectedState()
    XCTAssertNotNil(selected.selectionRectGlobal)
    XCTAssertEqual(selected.requestTab(.clipboard), .openClipboard)
    XCTAssertNil(selected.selectionRectGlobal)
    XCTAssertTrue(selected.selectionDisplayIDs.isEmpty)
  }

  func testOS044TeardownIsIdempotentAndOS045NewSessionCanStartImmediately() {
    let state = makeSelectedState()
    state.beginTerminating(clearSelection: true)

    XCTAssertTrue(state.performTeardown())
    XCTAssertFalse(state.performTeardown())
    XCTAssertEqual(state.phase, .idle)
    XCTAssertTrue(state.teardownPerformed)
    XCTAssertNil(state.selectionRectGlobal)
    XCTAssertTrue(state.frozenDisplayIDs.isEmpty)

    let restarted = makeArmedState()
    XCTAssertEqual(restarted.phase, .armed)
    XCTAssertFalse(restarted.teardownPerformed)
  }

  func testArmedMagnifierColorCanToggleBetweenHexAndRGB() {
    let state = makeArmedState()

    state.updateCurrentColor(hex: "#12ABEF", rgb: "RGB(18, 171, 239)")
    XCTAssertEqual(state.currentColorValue, "#12ABEF")

    state.toggleColorFormat()
    XCTAssertEqual(state.colorFormat, .rgb)
    XCTAssertEqual(state.currentColorValue, "RGB(18, 171, 239)")
  }

  func testOS010MagnifierSamplerReturnsFrozenPixelColorAndGlobalCoordinates() throws {
    var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = 255
      pixels[index + 3] = 255
    }
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels,
        width: 4,
        height: 4,
        bitsPerComponent: 8,
        bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue
      )
    )
    let image = try XCTUnwrap(context.makeImage())

    let sample = try XCTUnwrap(
      OneShotMagnifierSampler.sample(
        image: image,
        localPoint: CGPoint(x: 2, y: 2),
        displaySize: CGSize(width: 4, height: 4),
        globalPoint: CGPoint(x: 420, y: 240),
        sampleRadius: 1
      )
    )

    XCTAssertEqual(sample.globalPoint, CGPoint(x: 420, y: 240))
    XCTAssertEqual(sample.hex, "#FF0000")
    XCTAssertEqual(sample.rgb, "RGB(255, 0, 0)")
  }
}
