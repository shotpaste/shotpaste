//
//  ShotPasteDeepLinkHandlerTests.swift
//  ShotPasteTests
//
//  Unit tests for shotpaste:// automation URL parsing.
//

@testable import ShotPaste
import XCTest

final class ShotPasteDeepLinkHandlerTests: XCTestCase {
  func testCanonicalRoutesParseExpectedActions() throws {
    let cases: [(String, ShotPasteDeepLinkAction)] = [
      ("shotpaste://capture/one-shot", .captureOneShot),
      ("shotpaste://open/history", .openHistory),
      ("shotpaste://settings", .openSettings(nil)),
    ]

    for (urlString, expectedAction) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteDeepLinkAction(url: url), expectedAction, urlString)
    }
  }

  #if DEBUG
    func testDebugSchemeParsesOneShotRoute() throws {
      let url = try XCTUnwrap(URL(string: "shotpaste-debug://capture/one-shot"))
      XCTAssertEqual(ShotPasteDeepLinkAction(url: url), .captureOneShot)
    }
  #endif

  func testRemovedCaptureRoutesReturnNil() throws {
    let aliases = [
      "shotpaste://capture/area",
      "shotpaste://capture/window",
      "shotpaste://application-capture",
      "shotpaste://window-capture",
      "shotpaste://screenshot/window",
      "shotpaste://capture/active-window",
      "shotpaste://capture/fullscreen",
      "shotpaste://capture/area-annotate",
      "shotpaste://capture/scrolling",
      "shotpaste://capture/ocr",
      "shotpaste://record/screen",
      "shotpaste://record/window",
      "shotpaste://application-recording",
      "shotpaste://window-recording",
      "shotpaste://recording/window",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(ShotPasteDeepLinkAction(url: url), urlString)
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
      let queryURL = try XCTUnwrap(URL(string: "shotpaste://settings?tab=\(tabName)"))
      XCTAssertEqual(ShotPasteDeepLinkAction(url: queryURL), .openSettings(expectedTab), tabName)

      let pathURL = try XCTUnwrap(URL(string: "shotpaste://settings/\(tabName)"))
      XCTAssertEqual(ShotPasteDeepLinkAction(url: pathURL), .openSettings(expectedTab), tabName)
    }
  }

  func testUnsupportedRoutesReturnNil() throws {
    let urls = [
      "https://capture/area",
      "shotpaste://",
      "shotpaste://capture/unknown",
      "shotpaste://record/stop",
      "shotpaste://open/unknown",
      "shotpaste://open/annotate",
      "shotpaste://settings/annotate",
      "shotpaste://settings?tab=recording",
    ]

    for urlString in urls {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(ShotPasteDeepLinkAction(url: url), urlString)
    }
  }
}
