//
//  HistoryFloatingLayoutTests.swift
//  ShotPasteTests
//
//  Unit tests for HistoryFloatingLayout math and HistoryFloatingTimeFilter.
//

import AppKit
import Carbon.HIToolbox
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

  func testBasePanelSize_compact() {
    let size = HistoryFloatingLayout.basePanelSize(for: .compact)
    XCTAssertEqual(size, CGSize(width: 920, height: 316))
  }

  func testBasePanelSize_expanded() {
    let size = HistoryFloatingLayout.basePanelSize(for: .expanded)
    XCTAssertEqual(size, CGSize(width: 1040, height: 680))
  }

  // MARK: - baseCornerRadius

  func testBaseCornerRadius_compact() {
    XCTAssertEqual(HistoryFloatingLayout.baseCornerRadius(for: .compact), 30)
  }

  func testBaseCornerRadius_expanded() {
    XCTAssertEqual(HistoryFloatingLayout.baseCornerRadius(for: .expanded), 32)
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

  // MARK: - HistoryFloatingPresentationMode

  func testPresentationModeEquality() {
    XCTAssertEqual(HistoryFloatingPresentationMode.compact, HistoryFloatingPresentationMode.compact)
    XCTAssertNotEqual(HistoryFloatingPresentationMode.compact, HistoryFloatingPresentationMode.expanded)
  }

  func testClipboardHistoryEntryOpensExpandedClipboardView() {
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

    XCTAssertEqual(manager.presentationMode, .expanded)
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
  }

  // MARK: - Toggle Mode Shortcut

  func testToggleModeShortcutDefaultAndCustomization() {
    let manager = HistoryFloatingManager.shared

    // Test default shortcut values
    XCTAssertEqual(HistoryFloatingManager.defaultToggleModeShortcut.keyCode, UInt32(kVK_ANSI_E))
    XCTAssertEqual(HistoryFloatingManager.defaultToggleModeShortcut.modifiers, UInt32(cmdKey))
    XCTAssertTrue(manager.isToggleModeShortcutEnabled)

    // Set custom shortcut
    let custom = ShortcutConfig(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | shiftKey))
    manager.toggleModeShortcut = custom
    XCTAssertEqual(manager.toggleModeShortcut, custom)

    // Disable shortcut row (turn off)
    manager.isToggleModeShortcutEnabled = false
    XCTAssertFalse(manager.isToggleModeShortcutEnabled)
    // Custom shortcut config must remain intact when disabled
    XCTAssertEqual(manager.toggleModeShortcut, custom)

    // Check if it persists and can be loaded
    let savedData = UserDefaults.standard.data(forKey: "history.toggleModeShortcut")
    XCTAssertNotNil(savedData)
    if let savedData {
      let config = try? JSONDecoder().decode(ShortcutConfig.self, from: savedData)
      XCTAssertEqual(config, custom)
    }

    let savedEnabled = UserDefaults.standard.object(forKey: "history.isToggleModeShortcutEnabled") as? Bool
    XCTAssertEqual(savedEnabled, false)

    // Reset to default
    manager.resetToggleModeShortcut()
    XCTAssertEqual(manager.toggleModeShortcut, HistoryFloatingManager.defaultToggleModeShortcut)
    XCTAssertTrue(manager.isToggleModeShortcutEnabled)
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
