//
//  ShotPasteDeepLinkHandlerTests.swift
//  ShotPasteTests
//
//  Unit tests for shotpaste:// automation URL parsing.
//

@testable import ShotPaste
import XCTest

final class ShotPasteDeepLinkHandlerTests: XCTestCase {
  func testCanonicalRoutesParseExpectedCommands() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      ("shotpaste://capture/one-shot", .startCapture(.screenshot)),
      ("shotpaste://open/history", .openHistory(nil)),
      ("shotpaste://settings", .openSettings(nil)),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  #if DEBUG
    func testDebugSchemeParsesOneShotRoute() throws {
      let url = try XCTUnwrap(URL(string: "shotpaste-debug://capture/one-shot"))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), .startCapture(.screenshot))
    }
  #endif

  func testCaptureModeRoutesAndQueryParseExpectedCommands() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      ("shotpaste://capture/screenshot", .startCapture(.screenshot)),
      ("shotpaste://capture/scrolling", .startCapture(.scrolling)),
      ("shotpaste://record/screen", .startCapture(.recording)),
      ("shotpaste://capture/one-shot?mode=recording", .startCapture(.recording)),
      ("shotpaste://capture?mode=scrolling", .startCapture(.scrolling)),
      ("shotpaste://capture/cancel", .cancelCapture),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testHistoryRoutesParseFilters() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      ("shotpaste://open/history?filter=all", .openHistory(.all)),
      ("shotpaste://open/history?filter=screenshots", .openHistory(.screenshot)),
      ("shotpaste://open/history?filter=scrolling-screenshot", .openHistory(.scrolling)),
      ("shotpaste://open/history?filter=video", .openHistory(.recording)),
      ("shotpaste://open/clipboard", .openHistory(.clipboard)),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testRecordingControlRoutesParseExpectedCommands() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      ("shotpaste://recording/pause", .controlRecording(.pause)),
      ("shotpaste://recording/resume", .controlRecording(.resume)),
      ("shotpaste://recording/stop", .controlRecording(.stop)),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testUnsupportedDirectCaptureRoutesReturnNil() throws {
    let aliases = [
      "shotpaste://capture/area",
      "shotpaste://capture/window",
      "shotpaste://application-capture",
      "shotpaste://window-capture",
      "shotpaste://screenshot/window",
      "shotpaste://capture/active-window",
      "shotpaste://capture/fullscreen",
      "shotpaste://capture/area-annotate",
      "shotpaste://capture/ocr",
      "shotpaste://record/window",
      "shotpaste://application-recording",
      "shotpaste://window-recording",
    ]

    for urlString in aliases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(ShotPasteAutomationCommand(url: url), urlString)
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
      XCTAssertEqual(ShotPasteAutomationCommand(url: queryURL), .openSettings(expectedTab), tabName)

      let pathURL = try XCTUnwrap(URL(string: "shotpaste://settings/\(tabName)"))
      XCTAssertEqual(ShotPasteAutomationCommand(url: pathURL), .openSettings(expectedTab), tabName)
    }
  }

  func testUnsupportedRoutesAndInvalidParametersReturnNil() throws {
    let urls = [
      "https://capture/area",
      "shotpaste://",
      "shotpaste://capture/unknown",
      "shotpaste://capture?mode=window",
      "shotpaste://open/history?filter=secret",
      "shotpaste://open/unknown",
      "shotpaste://settings/annotate",
      "shotpaste://settings?tab=recording",
    ]

    for urlString in urls {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(ShotPasteAutomationCommand(url: url), urlString)
    }
  }
}
