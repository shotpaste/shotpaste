//
//  AppVariantTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class AppVariantTests: XCTestCase {
  func testDebugBuildUsesDebugVariant() {
    XCTAssertEqual(AppVariant.current, .debug)
  }

  func testReleaseIdentityAndStorageNamesRemainUnchanged() {
    let release = AppVariant.release

    XCTAssertEqual(release.bundleIdentifier, "com.ahtcfg24.shotpaste")
    XCTAssertEqual(release.displayName, "ShotPaste")
    XCTAssertEqual(release.executableName, "ShotPaste")
    XCTAssertEqual(release.applicationSupportDirectoryName, "ShotPaste")
    XCTAssertEqual(release.diagnosticLogDirectoryName, "ShotPaste")
    XCTAssertEqual(release.defaultExportDirectoryName, "ShotPaste")
    XCTAssertEqual(release.configurationDirectoryName, "shotpaste")
    XCTAssertEqual(release.fallbackCaptureDirectoryName, "ShotPaste_Captures")
    XCTAssertEqual(release.problemReportsDirectoryName, "ShotPasteProblemReports")
    XCTAssertEqual(release.problemReportFilePrefix, "shotpaste-problem-report-")
    XCTAssertEqual(release.defaultMCPPort, 48_123)
    XCTAssertEqual(release.mcpClientName, "shotpaste")
    XCTAssertEqual(release.menuBarIconAssetName, "MenubarIcon")
  }

  func testDebugIdentityAndStorageNamesAreDistinctFromRelease() {
    let debug = AppVariant.debug
    let release = AppVariant.release

    XCTAssertNotEqual(debug.bundleIdentifier, release.bundleIdentifier)
    XCTAssertNotEqual(debug.displayName, release.displayName)
    XCTAssertNotEqual(debug.executableName, release.executableName)
    XCTAssertNotEqual(debug.applicationSupportDirectoryName, release.applicationSupportDirectoryName)
    XCTAssertNotEqual(debug.diagnosticLogDirectoryName, release.diagnosticLogDirectoryName)
    XCTAssertNotEqual(debug.defaultExportDirectoryName, release.defaultExportDirectoryName)
    XCTAssertNotEqual(debug.configurationDirectoryName, release.configurationDirectoryName)
    XCTAssertNotEqual(debug.fallbackCaptureDirectoryName, release.fallbackCaptureDirectoryName)
    XCTAssertNotEqual(debug.problemReportsDirectoryName, release.problemReportsDirectoryName)
    XCTAssertNotEqual(debug.problemReportFilePrefix, release.problemReportFilePrefix)
    XCTAssertNotEqual(debug.defaultMCPPort, release.defaultMCPPort)
    XCTAssertNotEqual(debug.mcpClientName, release.mcpClientName)
    XCTAssertEqual(debug.menuBarIconAssetName, "MenubarIconDebug")
    XCTAssertNotEqual(debug.menuBarIconAssetName, release.menuBarIconAssetName)
  }

  func testVariantDataLocationsUseIndependentRoots() {
    let appSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support", isDirectory: true)
    let library = URL(fileURLWithPath: "/Users/example/Library", isDirectory: true)
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let desktop = home.appendingPathComponent("Desktop", isDirectory: true)

    XCTAssertEqual(
      AppDataLocations.applicationSupportRoot(in: appSupport, variant: .release).path,
      "/Users/example/Library/Application Support/ShotPaste"
    )
    XCTAssertEqual(
      AppDataLocations.applicationSupportRoot(in: appSupport, variant: .debug).path,
      "/Users/example/Library/Application Support/ShotPaste Debug"
    )
    XCTAssertEqual(
      AppDataLocations.diagnosticLogDirectory(in: library, variant: .release).path,
      "/Users/example/Library/Logs/ShotPaste"
    )
    XCTAssertEqual(
      AppDataLocations.diagnosticLogDirectory(in: library, variant: .debug).path,
      "/Users/example/Library/Logs/ShotPaste Debug"
    )
    XCTAssertEqual(
      AppDataLocations.configurationDirectory(in: home, variant: .debug).path,
      "/Users/example/.config/shotpaste-debug"
    )
    XCTAssertEqual(
      AppDataLocations.defaultExportDirectory(in: desktop, variant: .debug).path,
      "/Users/example/Desktop/ShotPaste Debug"
    )
  }

  func testDebugCopiedMCPConfigurationUsesDistinctClientKey() throws {
    let json = ShotPasteMCPServer.connectionConfigurationJSON(
      clientName: AppVariant.debug.mcpClientName,
      endpointURLString: "http://127.0.0.1:48124/mcp",
      authorizationToken: "test-token"
    )
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])

    XCTAssertNotNil(servers[AppVariant.debug.mcpClientName])
    XCTAssertNil(servers[AppVariant.release.mcpClientName])
  }
}
