//
//  ShotPasteDeepLinkHandlerTests.swift
//  ShotPasteTests
//
//  Unit tests for shotpaste:// automation URL parsing.
//

@testable import ShotPaste
import XCTest

final class ShotPasteDeepLinkHandlerTests: XCTestCase {
  private func urlString(_ route: String, variant: AppVariant = .current) -> String {
    "\(variant.urlScheme)://\(route)"
  }

  func testCanonicalRoutesParseExpectedCommands() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      (urlString("capture/one-shot"), .startCapture(.screenshot)),
      (urlString("open/history"), .openHistory(nil)),
      (urlString("settings"), .openSettings(nil)),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testEachVariantAcceptsOnlyItsOwnScheme() throws {
    for variant in AppVariant.allCases {
      let ownURL = try XCTUnwrap(URL(string: urlString("capture/one-shot", variant: variant)))
      XCTAssertEqual(
        ShotPasteAutomationCommand(url: ownURL, variant: variant),
        .startCapture(.screenshot)
      )

      for otherVariant in AppVariant.allCases where otherVariant != variant {
        XCTAssertNil(ShotPasteAutomationCommand(url: ownURL, variant: otherVariant))
      }
    }
  }

  func testCurrentVariantRejectsOtherVariantScheme() throws {
    let otherVariant = try XCTUnwrap(AppVariant.allCases.first { $0 != .current })
    let url = try XCTUnwrap(URL(string: urlString("capture/one-shot", variant: otherVariant)))

    XCTAssertNil(ShotPasteAutomationCommand(url: url))
  }

  func testCaptureModeRoutesAndQueryParseExpectedCommands() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      (urlString("capture/screenshot"), .startCapture(.screenshot)),
      (urlString("capture/scrolling"), .startCapture(.scrolling)),
      (urlString("record/screen"), .startCapture(.recording)),
      (urlString("capture/one-shot?mode=recording"), .startCapture(.recording)),
      (urlString("capture?mode=scrolling"), .startCapture(.scrolling)),
      (urlString("capture/cancel"), .cancelCapture),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testHistoryRoutesParseFilters() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      (urlString("open/history?filter=all"), .openHistory(.all)),
      (urlString("open/history?filter=screenshots"), .openHistory(.screenshot)),
      (urlString("open/history?filter=scrolling-screenshot"), .openHistory(.scrolling)),
      (urlString("open/history?filter=video"), .openHistory(.recording)),
      (urlString("open/clipboard"), .openHistory(.clipboard)),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testRecordingControlRoutesParseExpectedCommands() throws {
    let cases: [(String, ShotPasteAutomationCommand)] = [
      (urlString("recording/pause"), .controlRecording(.pause)),
      (urlString("recording/resume"), .controlRecording(.resume)),
      (urlString("recording/stop"), .controlRecording(.stop)),
    ]

    for (urlString, expectedCommand) in cases {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertEqual(ShotPasteAutomationCommand(url: url), expectedCommand, urlString)
    }
  }

  func testUnsupportedDirectCaptureRoutesReturnNil() throws {
    let aliases = [
      urlString("capture/area"),
      urlString("capture/window"),
      urlString("application-capture"),
      urlString("window-capture"),
      urlString("screenshot/window"),
      urlString("capture/active-window"),
      urlString("capture/fullscreen"),
      urlString("capture/area-annotate"),
      urlString("capture/ocr"),
      urlString("record/window"),
      urlString("application-recording"),
      urlString("window-recording"),
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
      ("agent", .agent),
      ("shortcuts", .shortcuts),
      ("permissions", .permissions),
      ("advanced", .advanced),
    ]

    for (tabName, expectedTab) in cases {
      let queryURL = try XCTUnwrap(URL(string: urlString("settings?tab=\(tabName)")))
      XCTAssertEqual(ShotPasteAutomationCommand(url: queryURL), .openSettings(expectedTab), tabName)

      let pathURL = try XCTUnwrap(URL(string: urlString("settings/\(tabName)")))
      XCTAssertEqual(ShotPasteAutomationCommand(url: pathURL), .openSettings(expectedTab), tabName)
    }
  }

  func testUnsupportedRoutesAndInvalidParametersReturnNil() throws {
    let urls = [
      "https://capture/area",
      urlString(""),
      urlString("capture/unknown"),
      urlString("capture?mode=window"),
      urlString("open/history?filter=secret"),
      urlString("open/unknown"),
      urlString("settings/annotate"),
      urlString("settings?tab=recording"),
    ]

    for urlString in urls {
      let url = try XCTUnwrap(URL(string: urlString))
      XCTAssertNil(ShotPasteAutomationCommand(url: url), urlString)
    }
  }
}
