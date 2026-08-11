//
//  PreferencesCoreTests.swift
//  LiteScreenTests
//
//  Unit tests for persisted preferences value models.
//

@testable import LiteScreen
import XCTest

final class PreferencesCoreTests: XCTestCase {
  func testHistoryBackgroundStyleStored_readsValidValueAndFallsBackToDefault() throws {
    let defaults = try makeDefaults()
    XCTAssertEqual(HistoryBackgroundStyle.currentStoredStyle(userDefaults: defaults), .hud)

    defaults.set(HistoryBackgroundStyle.solid.rawValue, forKey: PreferencesKeys.historyBackgroundStyle)
    XCTAssertEqual(HistoryBackgroundStyle.currentStoredStyle(userDefaults: defaults), .solid)

    defaults.set("invalid", forKey: PreferencesKeys.historyBackgroundStyle)
    XCTAssertEqual(HistoryBackgroundStyle.currentStoredStyle(userDefaults: defaults), .hud)
  }

  func testPreferencesTabsRemainUniqueAndHashable() {
    let tabs: Set<PreferencesTab> = [
      .general,
      .capture,
      .quickAccess,
      .history,
      .shortcuts,
      .permissions,
      .advanced,
    ]

    XCTAssertEqual(tabs.count, 7)
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "LiteScreenTests.PreferencesCoreTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
