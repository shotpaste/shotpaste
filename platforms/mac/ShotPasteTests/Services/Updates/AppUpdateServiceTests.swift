//
//  AppUpdateServiceTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

final class AppUpdateServiceTests: XCTestCase {
  func testReleaseVersionParsesAndComparesStableSemanticVersions() throws {
    let version = try XCTUnwrap(AppReleaseVersion("v1.12.3"))
    let olderVersion = try XCTUnwrap(AppReleaseVersion("1.11.99"))
    let newerVersion = try XCTUnwrap(AppReleaseVersion("2.0.0"))
    XCTAssertEqual(version.description, "1.12.3")
    XCTAssertTrue(version > olderVersion)
    XCTAssertTrue(version < newerVersion)
  }

  func testReleaseVersionRejectsNonStableOrNonCanonicalValues() {
    XCTAssertNil(AppReleaseVersion("1.2"))
    XCTAssertNil(AppReleaseVersion("1.2.3-beta.1"))
    XCTAssertNil(AppReleaseVersion("1.02.3"))
    XCTAssertNil(AppReleaseVersion("1.2.3.0"))
  }

  func testCheckForUpdatesReturnsAvailableReleaseAndUsesGitHubHeaders() async throws {
    let releaseURL = try XCTUnwrap(
      URL(string: "https://github.com/shotpaste/shotpaste/releases/tag/v1.13.0")
    )
    let session = MockURLSession { request in
      XCTAssertEqual(request.url, AppUpdateService.latestReleaseAPIURL)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ShotPaste/1.12.2")
      let data = Data(
        """
        {"tag_name":"v1.13.0","html_url":"\(releaseURL.absoluteString)","draft":false,"prerelease":false}
        """.utf8
      )
      return MockURLSession.makeResponse(statusCode: 200, data: data, url: request.url!)
    }
    let service = AppUpdateService(session: session) { "1.12.2" }

    let result = try await service.checkForUpdates()

    XCTAssertEqual(
      result,
      .updateAvailable(
        currentVersion: try XCTUnwrap(AppReleaseVersion("1.12.2")),
        latestRelease: AppRelease(
          version: try XCTUnwrap(AppReleaseVersion("1.13.0")),
          pageURL: releaseURL
        )
      )
    )
  }

  func testCheckForUpdatesTreatsSameOrOlderReleaseAsUpToDate() async throws {
    let releaseURL = try XCTUnwrap(
      URL(string: "https://github.com/shotpaste/shotpaste/releases/tag/v1.12.2")
    )
    let session = MockURLSession { request in
      let data = Data(
        """
        {"tag_name":"v1.12.2","html_url":"\(releaseURL.absoluteString)","draft":false,"prerelease":false}
        """.utf8
      )
      return MockURLSession.makeResponse(statusCode: 200, data: data, url: request.url!)
    }
    let service = AppUpdateService(session: session) { "1.12.2" }

    guard case let .upToDate(currentVersion, latestRelease) = try await service.checkForUpdates() else {
      return XCTFail("Expected the installed version to be current")
    }
    XCTAssertEqual(currentVersion.description, "1.12.2")
    XCTAssertEqual(latestRelease.version.description, "1.12.2")
  }

  func testCheckForUpdatesTreatsNewerInstalledVersionAsUpToDate() async throws {
    let releaseURL = try XCTUnwrap(
      URL(string: "https://github.com/shotpaste/shotpaste/releases/tag/v1.12.2")
    )
    let session = MockURLSession { request in
      let data = Data(
        """
        {"tag_name":"v1.12.2","html_url":"\(releaseURL.absoluteString)","draft":false,"prerelease":false}
        """.utf8
      )
      return MockURLSession.makeResponse(statusCode: 200, data: data, url: request.url!)
    }
    let service = AppUpdateService(session: session) { "2.0.0" }

    guard case let .upToDate(currentVersion, latestRelease) = try await service.checkForUpdates() else {
      return XCTFail("Expected a newer installed build to remain current")
    }
    XCTAssertEqual(currentVersion.description, "2.0.0")
    XCTAssertEqual(latestRelease.version.description, "1.12.2")
  }

  func testCheckForUpdatesRejectsUntrustedReleaseURL() async throws {
    let session = MockURLSession { request in
      let data = Data(
        """
        {"tag_name":"v9.0.0","html_url":"https://example.com/download","draft":false,"prerelease":false}
        """.utf8
      )
      return MockURLSession.makeResponse(statusCode: 200, data: data, url: request.url!)
    }
    let service = AppUpdateService(session: session) { "1.12.2" }

    do {
      _ = try await service.checkForUpdates()
      XCTFail("Expected an invalid release error")
    } catch let error as AppUpdateCheckError {
      XCTAssertEqual(error, .invalidRelease)
    }
  }

  func testCheckForUpdatesSurfacesHTTPStatus() async throws {
    let session = MockURLSession { request in
      MockURLSession.makeResponse(statusCode: 403, url: request.url!)
    }
    let service = AppUpdateService(session: session) { "1.12.2" }

    do {
      _ = try await service.checkForUpdates()
      XCTFail("Expected an HTTP status error")
    } catch let error as AppUpdateCheckError {
      XCTAssertEqual(error, .unsuccessfulStatusCode(403))
    }
  }
}
