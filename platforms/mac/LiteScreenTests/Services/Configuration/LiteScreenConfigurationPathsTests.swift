//
//  LiteScreenConfigurationPathsTests.swift
//  LiteScreenTests
//
//  Tests for user-managed TOML configuration paths.
//

import Darwin
@testable import LiteScreen
import XCTest

@MainActor
final class LiteScreenConfigurationPathsTests: XCTestCase {
  func testSuggestedConfigURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = LiteScreenConfigurationPaths.suggestedConfigURL(homeDirectory: home)

    XCTAssertEqual(url.path, "/Users/example/.config/lite-screen/config.toml")
  }

  func testSuggestedConfigDirectoryURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = LiteScreenConfigurationPaths.suggestedConfigDirectoryURL(homeDirectory: home)

    XCTAssertEqual(url.path, "/Users/example/.config/lite-screen")
  }

  func testCollapsingHomePathConvertsAbsolutePathToTilde() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      LiteScreenConfigurationPaths.collapsingHomePath("/Users/example/Desktop", homeDirectory: home),
      "~/Desktop"
    )
    XCTAssertEqual(
      LiteScreenConfigurationPaths.collapsingHomePath("/Users/example", homeDirectory: home),
      "~"
    )
    XCTAssertEqual(
      LiteScreenConfigurationPaths.collapsingHomePath("/tmp/litescreen", homeDirectory: home),
      "/tmp/litescreen"
    )
  }

  func testExpandedUserPathUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      LiteScreenConfigurationPaths.expandedUserPath("~/Desktop", homeDirectory: home),
      "/Users/example/Desktop"
    )
    XCTAssertEqual(
      LiteScreenConfigurationPaths.expandedUserPath("/tmp/litescreen", homeDirectory: home),
      "/tmp/litescreen"
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
    let expectedURL = LiteScreenConfigurationPaths.suggestedConfigURL(homeDirectory: expectedHome)

    XCTAssertEqual(LiteScreenConfigurationService.shared.suggestedConfigURL.path, expectedURL.path)
  }
}
