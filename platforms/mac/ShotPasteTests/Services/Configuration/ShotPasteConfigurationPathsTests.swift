//
//  ShotPasteConfigurationPathsTests.swift
//  ShotPasteTests
//
//  Tests for user-managed TOML configuration paths.
//

import Darwin
@testable import ShotPaste
import XCTest

@MainActor
final class ShotPasteConfigurationPathsTests: XCTestCase {
  func testSuggestedConfigURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = ShotPasteConfigurationPaths.suggestedConfigURL(homeDirectory: home)

    XCTAssertEqual(url.path, "/Users/example/.config/shotpaste/config.toml")
  }

  func testSuggestedConfigDirectoryURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = ShotPasteConfigurationPaths.suggestedConfigDirectoryURL(homeDirectory: home)

    XCTAssertEqual(url.path, "/Users/example/.config/shotpaste")
  }

  func testCollapsingHomePathConvertsAbsolutePathToTilde() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      ShotPasteConfigurationPaths.collapsingHomePath("/Users/example/Desktop", homeDirectory: home),
      "~/Desktop"
    )
    XCTAssertEqual(
      ShotPasteConfigurationPaths.collapsingHomePath("/Users/example", homeDirectory: home),
      "~"
    )
    XCTAssertEqual(
      ShotPasteConfigurationPaths.collapsingHomePath("/tmp/shotpaste", homeDirectory: home),
      "/tmp/shotpaste"
    )
  }

  func testExpandedUserPathUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      ShotPasteConfigurationPaths.expandedUserPath("~/Desktop", homeDirectory: home),
      "/Users/example/Desktop"
    )
    XCTAssertEqual(
      ShotPasteConfigurationPaths.expandedUserPath("/tmp/shotpaste", homeDirectory: home),
      "/tmp/shotpaste"
    )
  }

  func testSuggestedConfigURLUsesAccountHomeDirectory() throws {
    guard
      let passwd = getpwuid(getuid()),
      let home = passwd.pointee.pw_dir
    else {
      throw XCTSkip("No POSIX home directory is available for the current user.")
    }

    let expectedHome = URL(fileURLWithPath: String(cString: home), isDirectory: true)
    let expectedURL = ShotPasteConfigurationPaths.suggestedConfigURL(homeDirectory: expectedHome)

    XCTAssertEqual(ShotPasteConfigurationService.shared.suggestedConfigURL.path, expectedURL.path)
  }
}
