//
//  InlineAreaTranslationTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class InlineAreaTranslationTests: XCTestCase {
  func testFrozenCropDeadlineChecksBeforeStartingCrop() {
    var didRun = false

    XCTAssertThrowsError(
      try InlineAreaAnnotateSession.withTranslationCropDeadline(
        deadline: Date(timeIntervalSinceNow: -1),
        crop: {
          didRun = true
          return 1
        }
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
    XCTAssertFalse(didRun)
  }

  func testFrozenCropDeadlineChecksAfterSingleOrCompositeCrop() {
    XCTAssertThrowsError(
      try InlineAreaAnnotateSession.withTranslationCropDeadline(
        deadline: Date(timeIntervalSinceNow: 0.001),
        crop: {
          Thread.sleep(forTimeInterval: 0.01)
          return "frozen-crop"
        }
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
  }

  func testFrozenCropDeadlinePreservesSuccessfulFrozenValue() throws {
    let value = try InlineAreaAnnotateSession.withTranslationCropDeadline(
      deadline: Date(timeIntervalSinceNow: 1),
      crop: { "from-frozen-snapshot" }
    )
    XCTAssertEqual(value, "from-frozen-snapshot")
  }
}
