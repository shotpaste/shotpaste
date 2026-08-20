//
//  DiagnosticCoreTests.swift
//  ShotPasteTests
//
//  Unit tests for diagnostic log value formatting and parsing.
//

@testable import ShotPaste
import XCTest

final class DiagnosticCoreTests: XCTestCase {
  func testDiagnosticLogEntryToLogLine_usesShortFileNameAndSortedContext() {
    let entry = DiagnosticLogEntry(
      level: .info,
      category: .capture,
      message: "Capture complete",
      context: ["z": "last", "a": "first"],
      file: "ShotPaste/Services/Capture/ScreenCaptureManager.swift",
      function: "capturePreparedArea(_:)",
      line: 42,
      timestamp: Date(timeIntervalSince1970: 0)
    )

    let line = entry.toLogLine()

    XCTAssertTrue(line
      .contains("[INF][CAPTURE][ScreenCaptureManager.swift:42:capturePreparedArea(_:)] Capture complete"))
    XCTAssertTrue(line.contains(" {a=first, z=last}"))
    XCTAssertTrue(line.hasSuffix("\n"))
  }
}
