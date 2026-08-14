//
//  AppVariantTests.swift
//  ShotPasteTests
//

import AppKit
import Foundation
@testable import ShotPaste
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AppVariantTests: XCTestCase {
  func testBuiltAppDeclaresCurrentVariant() throws {
    let configuredValue = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "ShotPasteVariant") as? String
    )

    XCTAssertEqual(AppVariant.current.rawValue, configuredValue)
  }

  func testConfiguredVariantMatchesCompilerConfiguration() {
    #if DEBUG
      let compiledVariant = AppVariant.debug
    #else
      let compiledVariant = AppVariant.release
    #endif

    XCTAssertEqual(AppVariant.current, compiledVariant)
  }

  func testBuiltAppIdentityMatchesCurrentVariant() throws {
    let variant = AppVariant.current
    let info = try XCTUnwrap(Bundle.main.infoDictionary)
    let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
    let urlType = try XCTUnwrap(urlTypes.first)
    let schemes = try XCTUnwrap(urlType["CFBundleURLSchemes"] as? [String])

    XCTAssertEqual(Bundle.main.bundleIdentifier, variant.bundleIdentifier)
    XCTAssertEqual(info["CFBundleDisplayName"] as? String, variant.displayName)
    XCTAssertEqual(info["CFBundleName"] as? String, variant.displayName)
    XCTAssertEqual(info["CFBundleExecutable"] as? String, variant.executableName)
    XCTAssertEqual(urlType["CFBundleURLName"] as? String, variant.bundleIdentifier)
    XCTAssertEqual(schemes, [variant.urlScheme])
  }

  func testReleaseIdentityAndStorageNamesRemainUnchanged() {
    let release = AppVariant.release

    XCTAssertEqual(release.bundleIdentifier, "com.ahtcfg24.shotpaste")
    XCTAssertEqual(release.displayName, "ShotPaste")
    XCTAssertEqual(release.executableName, "ShotPaste")
    XCTAssertEqual(release.urlScheme, "shotpaste")
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
    XCTAssertEqual(
      release.internalPasteboardWriteMarkerIdentifier,
      "com.ahtcfg24.shotpaste.internal-media-write"
    )
    XCTAssertEqual(
      release.quickAccessActionTypeIdentifier,
      "com.ahtcfg24.shotpaste.quick-access-action"
    )
    XCTAssertEqual(
      release.quickAccessReorderTypeIdentifier,
      "com.ahtcfg24.shotpaste.quick-access-reorder"
    )
    XCTAssertFalse(release.erasesDatabaseOnSchemaChange)
    XCTAssertTrue(release.performsAutomaticUpdateChecks)
  }

  func testDebugIdentityAndStorageNamesAreDistinctFromRelease() {
    let debug = AppVariant.debug
    let release = AppVariant.release

    XCTAssertNotEqual(debug.bundleIdentifier, release.bundleIdentifier)
    XCTAssertNotEqual(debug.displayName, release.displayName)
    XCTAssertNotEqual(debug.executableName, release.executableName)
    XCTAssertNotEqual(debug.urlScheme, release.urlScheme)
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
    XCTAssertNotEqual(
      debug.internalPasteboardWriteMarkerIdentifier,
      release.internalPasteboardWriteMarkerIdentifier
    )
    XCTAssertNotEqual(debug.quickAccessActionTypeIdentifier, release.quickAccessActionTypeIdentifier)
    XCTAssertNotEqual(debug.quickAccessReorderTypeIdentifier, release.quickAccessReorderTypeIdentifier)
    XCTAssertTrue(debug.erasesDatabaseOnSchemaChange)
    XCTAssertFalse(debug.performsAutomaticUpdateChecks)
  }

  func testCurrentGlobalResourceTypesComeFromAppVariant() {
    let variant = AppVariant.current

    XCTAssertEqual(
      MediaClipboardMonitor.internalWriteMarker.rawValue,
      variant.internalPasteboardWriteMarkerIdentifier
    )
    XCTAssertEqual(UTType.quickAccessAction.identifier, variant.quickAccessActionTypeIdentifier)
    XCTAssertEqual(UTType.quickAccessReorder.identifier, variant.quickAccessReorderTypeIdentifier)
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
