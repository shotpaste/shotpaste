//
//  TranslationViewsTests.swift
//  ShotPasteTests
//

@testable import ShotPaste
import XCTest

@MainActor
final class TranslationViewsTests: XCTestCase {
  func testProgressPresentationMapsAllLocalStages() {
    XCTAssertEqual(
      TranslationViewPresentation.progressTitle(for: .recognizingText),
      L10n.OneShot.translationRecognizingText
    )
    XCTAssertEqual(
      TranslationViewPresentation.progressTitle(for: .detectingLanguage),
      L10n.OneShot.translationDetectingLanguage
    )
    XCTAssertEqual(
      TranslationViewPresentation.progressTitle(for: .translatingText),
      L10n.OneShot.translationTranslatingText
    )
    XCTAssertEqual(
      TranslationViewPresentation.progressTitle(for: .layingOut),
      L10n.OneShot.translationLayingOut
    )
    XCTAssertEqual(
      TranslationViewPresentation.progressTitle(for: nil),
      L10n.OneShot.translationInProgress
    )
  }

  func testFailurePresentationUsesTextPrivacyCase() {
    XCTAssertEqual(
      TranslationViewPresentation.failureMessage(for: .recognizedTextSharingDisabled),
      L10n.OneShot.translationRecognizedTextSharingDisabled
    )
    XCTAssertFalse(
      TranslationViewPresentation.failureMessage(for: .recognizedTextSharingDisabled)
        .isEmpty
    )
  }

  func testLowConfidenceNoticeOnlyAppearsOnSuccessfulResult() {
    XCTAssertFalse(
      TranslationViewPresentation.showsLowConfidence(
        phase: .translating,
        lowConfidenceLineCount: 2
      )
    )
    XCTAssertFalse(
      TranslationViewPresentation.showsLowConfidence(
        phase: .showingResult,
        lowConfidenceLineCount: 0
      )
    )
    XCTAssertTrue(
      TranslationViewPresentation.showsLowConfidence(
        phase: .showingResult,
        lowConfidenceLineCount: 1
      )
    )
  }
}
