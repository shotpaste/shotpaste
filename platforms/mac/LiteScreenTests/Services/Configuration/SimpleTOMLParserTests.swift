//
//  SimpleTOMLParserTests.swift
//  LiteScreenTests
//
//  Unit tests for the focused TOML parser used by config import.
//

@testable import LiteScreen
import XCTest

@MainActor
final class SimpleTOMLParserTests: XCTestCase {
  func testParsesNestedTablesArraysAndComments() throws {
    let source = """
    schema_version = 1

    [general]
    language = "system" # comment
    play_sounds = true

    [shortcuts.global.fullscreen]
    key = "3"
    modifiers = ["command", "shift"]
    enabled = true
    """

    let document = try SimpleTOMLParser.parse(source)

    XCTAssertEqual(document.value(at: "schema_version")?.intValue, 1)
    XCTAssertEqual(document.value(at: "general", "language")?.stringValue, "system")
    XCTAssertEqual(document.value(at: "general", "play_sounds")?.boolValue, true)
    XCTAssertEqual(
      document.value(at: "shortcuts", "global", "fullscreen", "modifiers")?.stringArrayValue,
      ["command", "shift"]
    )
  }

  func testTableDeclarationPreservesExistingDottedKeys() throws {
    let source = """
    general.language = "system"

    [general]
    play_sounds = false
    """

    let document = try SimpleTOMLParser.parse(source)

    XCTAssertEqual(document.value(at: "general", "language")?.stringValue, "system")
    XCTAssertEqual(document.value(at: "general", "play_sounds")?.boolValue, false)
  }

  func testInvalidValueReportsLine() {
    XCTAssertThrowsError(try SimpleTOMLParser.parse("schema_version = nope")) { error in
      XCTAssertEqual(error as? SimpleTOMLError, .invalidValue(1, "nope"))
    }
  }
}
