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
  func testCurrentSuggestedConfigURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = ShotPasteConfigurationPaths.suggestedConfigURL(homeDirectory: home)
    let expected = AppDataLocations.configurationDirectory(
      in: home,
      variant: .current
    ).appendingPathComponent("config.toml")

    XCTAssertEqual(url.path, expected.path)
  }

  func testCurrentSuggestedConfigDirectoryURLUsesProvidedHomeDirectory() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    let url = ShotPasteConfigurationPaths.suggestedConfigDirectoryURL(homeDirectory: home)

    XCTAssertEqual(
      url.path,
      AppDataLocations.configurationDirectory(in: home, variant: .current).path
    )
  }

  func testReleaseSuggestedConfigPathRemainsUnchanged() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      ShotPasteConfigurationPaths.suggestedConfigURL(
        homeDirectory: home,
        variant: .release
      ).path,
      "/Users/example/.config/shotpaste/config.toml"
    )
  }

  func testDebugSuggestedConfigPathIsIndependent() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    XCTAssertEqual(
      ShotPasteConfigurationPaths.suggestedConfigURL(
        homeDirectory: home,
        variant: .debug
      ).path,
      "/Users/example/.config/shotpaste-debug/config.toml"
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

    XCTAssertEqual(ShotPasteConfigurationPaths.suggestedConfigURL.path, expectedURL.path)
  }
}
