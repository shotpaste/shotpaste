//
//  HistoryFloatingLayoutTests.swift
//  ShotPasteTests
//
//  Unit tests for HistoryFloatingLayout math and HistoryFloatingTimeFilter.
//

import AppKit
@testable import ShotPaste
import XCTest

final class HistoryFloatingLayoutTests: XCTestCase {
  // MARK: - clampedScale

  func testClampedScale_clampsBelowMinimum() {
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(0.1), 0.8)
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(-5), 0.8)
  }

  func testClampedScale_clampsAboveMaximum() {
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(2.0), 1.4)
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(99), 1.4)
  }

  func testClampedScale_passesThroughValidRange() {
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(0.8), 0.8)
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(1.0), 1.0)
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(1.25), 1.25)
    XCTAssertEqual(HistoryFloatingLayout.clampedScale(1.4), 1.4)
  }

  // MARK: - storedScale

  func testStoredScale_readsPersistedValue() throws {
    let defaults = try makeDefaults()
    defaults.set(1.25, forKey: PreferencesKeys.historyFloatingScale)

    XCTAssertEqual(HistoryFloatingLayout.storedScale(userDefaults: defaults), 1.25, accuracy: 0.0001)
  }

  func testStoredScale_clampsPersistedValue() throws {
    let defaults = try makeDefaults()
    defaults.set(5.0, forKey: PreferencesKeys.historyFloatingScale)

    XCTAssertEqual(HistoryFloatingLayout.storedScale(userDefaults: defaults), 1.4, accuracy: 0.0001)
  }

  func testStoredScale_defaultsToOneWhenMissing() throws {
    let defaults = try makeDefaults()
    XCTAssertEqual(HistoryFloatingLayout.storedScale(userDefaults: defaults), 1.0, accuracy: 0.0001)
  }

  // MARK: - basePanelSize

  func testBasePanelSizeUsesFullHistorySurface() {
    XCTAssertEqual(HistoryFloatingLayout.basePanelSize, CGSize(width: 1040, height: 680))
  }

  // MARK: - baseCornerRadius

  func testBaseCornerRadiusUsesFullHistorySurface() {
    XCTAssertEqual(HistoryFloatingLayout.baseCornerRadius, 32)
  }

  // MARK: - HistoryFloatingTimeFilter

  func testTimeFilterAllIncludesAnyDate() {
    let now = Date()
    XCTAssertTrue(HistoryFloatingTimeFilter.all.includes(now.addingTimeInterval(-1_000_000), relativeTo: now))
    XCTAssertTrue(HistoryFloatingTimeFilter.all.includes(now.addingTimeInterval(100), relativeTo: now))
  }

  func testTimeFilterLast24HoursExcludesOlder() {
    let now = Date()
    XCTAssertTrue(HistoryFloatingTimeFilter.last24Hours.includes(now.addingTimeInterval(-3600), relativeTo: now))
    XCTAssertFalse(HistoryFloatingTimeFilter.last24Hours.includes(now.addingTimeInterval(-100_000), relativeTo: now))
  }

  func testTimeFilterLast7DaysExcludesOlder() {
    let now = Date()
    XCTAssertTrue(HistoryFloatingTimeFilter.last7Days.includes(now.addingTimeInterval(-100_000), relativeTo: now))
    XCTAssertFalse(HistoryFloatingTimeFilter.last7Days.includes(now.addingTimeInterval(-1_000_000), relativeTo: now))
  }

  func testTimeFilterLast30DaysExcludesOlder() {
    let now = Date()
    XCTAssertTrue(HistoryFloatingTimeFilter.last30Days.includes(now.addingTimeInterval(-1_000_000), relativeTo: now))
    XCTAssertFalse(HistoryFloatingTimeFilter.last30Days.includes(now.addingTimeInterval(-10_000_000), relativeTo: now))
  }

  func testTimeFilterAllCasesAreUnique() {
    let all = HistoryFloatingTimeFilter.allCases
    XCTAssertEqual(Set(all).count, all.count)
  }

  func testClipboardHistoryEntryOpensClipboardView() {
    let manager = HistoryFloatingManager.shared
    let originalFilter = manager.expandedFilter
    let originalTimeFilter = manager.expandedTimeFilter
    let originalSearchText = manager.searchText
    defer {
      manager.hide()
      manager.expandedFilter = originalFilter
      manager.expandedTimeFilter = originalTimeFilter
      manager.searchText = originalSearchText
    }

    manager.expandedFilter = .screenshot
    manager.expandedTimeFilter = .last7Days
    manager.searchText = "previous search"
    manager.showClipboardHistory()

    XCTAssertEqual(manager.expandedFilter, .clipboard)
    XCTAssertEqual(manager.expandedTimeFilter, .all)
    XCTAssertTrue(manager.searchText.isEmpty)
  }

  func testDefaultConfigurationUsesClipboardHistoryFilter() throws {
    let parsed = try SimpleTOMLParser.parse(ShotPasteConfigurationDefaultDocument.toml())

    XCTAssertEqual(
      parsed.value(at: "history", "floating", "default_filter")?.stringValue,
      CaptureHistoryCategory.clipboard.rawValue
    )
    XCTAssertNil(parsed.value(at: "history", "floating", "enabled"))
    XCTAssertNil(parsed.value(at: "history", "floating", "max_displayed_items"))
  }

  func testPanelResignDuringPresentationDoesNotDismiss() {
    XCTAssertFalse(
      HistoryFloatingManager.shouldDismissPanelAfterResigningKey(
        isShowing: true,
        isModalInteractionActive: false
      )
    )
    XCTAssertFalse(
      HistoryFloatingManager.shouldDismissPanelAfterResigningKey(
        isShowing: false,
        isModalInteractionActive: true
      )
    )
    XCTAssertTrue(
      HistoryFloatingManager.shouldDismissPanelAfterResigningKey(
        isShowing: false,
        isModalInteractionActive: false
      )
    )
    XCTAssertFalse(
      HistoryFloatingManager.shouldDismissPanelAfterResigningKey(
        isShowing: false,
        isModalInteractionActive: false,
        keepsOpen: true
      )
    )
  }

  @MainActor
  func testHistoryPanelIsCapturableAndExceptedFromOwnAppExclusion() {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    defer { panel.close() }

    XCTAssertEqual(panel.sharingType, .readOnly)
    XCTAssertTrue(
      ScreenshotCaptureWindowPolicy.exceptedOwnWindowIDs(from: [panel])
        .contains(CGWindowID(panel.windowNumber))
    )

    panel.sharingType = .none
    XCTAssertTrue(ScreenshotCaptureWindowPolicy.exceptedOwnWindowIDs(from: [panel]).isEmpty)
  }

  func testHistoryFloatingPanelCmdAPostNotification() {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    let expectation = expectation(forNotification: .historySelectAll, object: panel, handler: nil)

    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "a",
      charactersIgnoringModifiers: "a",
      isARepeat: false,
      keyCode: 0
    )

    guard let event else {
      XCTFail("Failed to create Cmd+A event")
      return
    }

    let handled = panel.performKeyEquivalent(with: event)
    XCTAssertTrue(handled)

    wait(for: [expectation], timeout: 1.0)
  }

  func testHistoryFloatingPanelCmdANoNotificationWhenTextInputActive() {
    let panel = HistoryFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
    panel.contentView?.addSubview(textView)
    let madeFirstResponder = panel.makeFirstResponder(textView)
    XCTAssertTrue(madeFirstResponder)

    let observer = NotificationCenter.default.addObserver(
      forName: .historySelectAll,
      object: panel,
      queue: nil
    ) { _ in
      XCTFail("Notification should not be posted when text input is active")
    }
    defer {
      NotificationCenter.default.removeObserver(observer)
    }

    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: .command,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "a",
      charactersIgnoringModifiers: "a",
      isARepeat: false,
      keyCode: 0
    )

    guard let event else {
      XCTFail("Failed to create Cmd+A event")
      return
    }

    let handled = panel.performKeyEquivalent(with: event)
    XCTAssertFalse(handled)
  }

  func testHistorySelectionNavigationMovesByGridColumnsAndClampsAtEdges() {
    XCTAssertEqual(
      HistorySelectionNavigation.destinationIndex(
        from: 5,
        move: .up,
        itemCount: 10,
        columnCount: 4
      ),
      1
    )
    XCTAssertEqual(
      HistorySelectionNavigation.destinationIndex(
        from: 5,
        move: .down,
        itemCount: 10,
        columnCount: 4
      ),
      9
    )
    XCTAssertEqual(
      HistorySelectionNavigation.destinationIndex(
        from: 0,
        move: .left,
        itemCount: 10,
        columnCount: 4
      ),
      0
    )
    XCTAssertNil(
      HistorySelectionNavigation.destinationIndex(
        from: 0,
        move: .right,
        itemCount: 0,
        columnCount: 4
      )
    )
  }

  // MARK: - Helpers

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "ShotPasteTests.HistoryFloatingLayoutTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
