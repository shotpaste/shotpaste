//
//  LiteScreenDeepLinkHandlerTests.swift
//  LiteScreenTests
//
//  Unit tests for litescreen:// automation URL parsing.
//

@testable import LiteScreen
import XCTest

final class LiteScreenDeepLinkHandlerTests: XCTestCase {
  func testCanonicalRoutesParseExpectedActions() throws {
    let cases: [(String, LiteScreenDeepLinkAction)] = [
      ("litescreen://capture/one-shot", .captureOneShot),
      ("litescreen://open/history", .openHistory),
      ("litescreen://settings", .openSettings(nil)),
    ]

    for (urlString, expectedAction) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(LiteScreenDeepLinkAction(url: url), expectedAction, urlString)
    }
  }

  #if DEBUG
    func testDebugSchemeParsesOneShotRoute() throws {
      let url = try XCTUnwrap(URL(string: "litescreen-debug://capture/one-shot"))
      XCTAssertEqual(LiteScreenDeepLinkAction(url: url), .captureOneShot)
    }
  #endif

  func testRemovedCaptureRoutesReturnNil() throws {
    let aliases = [
      "litescreen://capture/area",
      "litescreen://capture/window",
      "litescreen://application-capture",
      "litescreen://window-capture",
      "litescreen://screenshot/window",
      "litescreen://capture/active-window",
      "litescreen://capture/fullscreen",
      "litescreen://capture/area-annotate",
      "litescreen://capture/scrolling",
      "litescreen://capture/ocr",
      "litescreen://record/screen",
      "litescreen://record/window",
      "litescreen://application-recording",
      "litescreen://window-recording",
      "litescreen://recording/window",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(LiteScreenDeepLinkAction(url: url), urlString)
    }
  }

  func testSettingsTabRoutesParseExpectedTabs() throws {
    let cases: [(String, PreferencesTab)] = [
      ("general", .general),
      ("capture", .capture),
      ("quick-access", .quickAccess),
      ("history", .history),
      ("shortcuts", .shortcuts),
      ("permissions", .permissions),
      ("advanced", .advanced),
    ]

    for (tabName, expectedTab) in cases {
      let queryURL = try XCTUnwrap(URL(string: "litescreen://settings?tab=\(tabName)"))
      XCTAssertEqual(LiteScreenDeepLinkAction(url: queryURL), .openSettings(expectedTab), tabName)

      let pathURL = try XCTUnwrap(URL(string: "litescreen://settings/\(tabName)"))
      XCTAssertEqual(LiteScreenDeepLinkAction(url: pathURL), .openSettings(expectedTab), tabName)
    }
  }

  func testUnsupportedRoutesReturnNil() throws {
    let urls = [
      "https://capture/area",
      "litescreen://",
      "litescreen://capture/unknown",
      "litescreen://record/stop",
      "litescreen://open/unknown",
      "litescreen://open/annotate",
      "litescreen://settings/annotate",
      "litescreen://settings?tab=recording",
    ]

    for urlString in urls {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(LiteScreenDeepLinkAction(url: url), urlString)
    }
  }
}
