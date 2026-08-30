//
//  TranslationLanguageDetectorTests.swift
//  ShotPasteTests
//

@testable import ShotPaste
import XCTest

final class TranslationLanguageDetectorTests: XCTestCase {
  private let detector = TranslationLanguageDetector()

  func testURLsNumbersPathsAndCodeArePreservedWithoutLanguageGuessing() throws {
    let values: [(String, TranslationTextClassification)] = [
      ("https://shotpaste.app/docs", .url),
      ("42.5%", .number),
      ("~/Documents/ShotPaste.md", .filePath),
      ("let value = 42;", .code),
    ]

    for (text, classification) in values {
      let result = try detector.detect(text, deadline: .distantFuture)
      XCTAssertEqual(result.classification, classification, text)
      XCTAssertTrue(result.preserveOriginal, text)
      XCTAssertNil(result.languageIdentifier, text)
    }
  }

  func testNaturalLanguageDetectionAndManualHintAreLocal() throws {
    let english = try detector.detect("This is a local translation paragraph.", deadline: .distantFuture)
    XCTAssertEqual(english.languageIdentifier, "en")
    XCTAssertFalse(english.preserveOriginal)

    let shortText = try detector.detect(
      "OK",
      sourceLanguageHint: "zh-Hans",
      deadline: .distantFuture
    )
    XCTAssertEqual(shortText.languageIdentifier, "zh-Hans")
    XCTAssertFalse(shortText.preserveOriginal)
  }

  func testManualSourceLanguageHintIsAuthoritativeForTranslatableShortLabels() throws {
    let result = try detector.detect(
      "OK",
      sourceLanguageHint: "zh-Hans",
      recognitionLanguageHints: ["en-US"],
      deadline: .distantFuture
    )

    XCTAssertEqual(result.languageIdentifier, "zh-Hans")
    XCTAssertEqual(result.confidence, 1)
    XCTAssertEqual(result.classification, .translatable)
    XCTAssertFalse(result.preserveOriginal)
  }

  func testExplicitUnknownManualSourceLanguageRemainsUnknown() throws {
    let result = try detector.detect(
      "This is text.",
      sourceLanguageHint: "und",
      recognitionLanguageHints: ["en-US"],
      deadline: .distantFuture
    )

    XCTAssertNil(result.languageIdentifier)
    XCTAssertEqual(result.confidence, 0)
    XCTAssertFalse(result.preserveOriginal)
  }

  func testMixedLanguageSessionDoesNotClaimOneDominantLanguage() throws {
    let language = try detector.detectSessionLanguage(for: [
      "This is English text.",
      "这是中文文本。",
    ], deadline: .distantFuture)

    XCTAssertNil(language)
  }

  func testMixedLanguageSessionRejectsLatinAndKanaOrHangulEvenForShortBlocks() throws {
    XCTAssertNil(try detector.detectSessionLanguage(for: [
      "OK",
      "こんにちは",
    ], deadline: .distantFuture))
    XCTAssertNil(try detector.detectSessionLanguage(for: [
      "OK",
      "안녕하세요",
    ], deadline: .distantFuture))
  }

  func testMixedHanAndKanaAcrossBlocksDoesNotClaimJapanese() throws {
    XCTAssertNil(try detector.detectSessionLanguage(for: [
      "这是中文。",
      "かな",
    ], deadline: .distantFuture))
  }

  func testSingleScriptSessionsRemainEligibleForAutomaticLanguageDetection() throws {
    XCTAssertEqual(
      try detector.detectSessionLanguage(for: [
        "This is English text.",
        "Another English line.",
      ], deadline: .distantFuture),
      "en"
    )
    XCTAssertEqual(
      try detector.detectSessionLanguage(for: [
        "这是中文文本。",
        "还有另一行中文。",
      ], deadline: .distantFuture),
      "zh-Hans"
    )
  }

  func testJapaneseHanAndKanaWithinOneSessionAreNotMarkedMixed() throws {
    XCTAssertEqual(
      try detector.detectSessionLanguage(for: [
        "これは日本語です。",
        "カタカナの行です。",
      ], deadline: .distantFuture),
      "ja"
    )
  }

  func testManualSessionHintStillPrecedesMixedScriptEvidence() throws {
    XCTAssertEqual(
      try detector.detectSessionLanguage(
        for: ["This is English text.", "这是中文文本。"],
        sourceLanguageHint: "en_US",
        deadline: .distantFuture
      ),
      "en"
    )
  }

  func testIdentifierNormalizationAndVisionHintMapping() {
    XCTAssertEqual(TranslationLanguageDetector.normalizedIdentifier("en_US"), "en")
    XCTAssertEqual(TranslationLanguageDetector.normalizedIdentifier("zh-Hant-TW"), "zh-Hant")
    XCTAssertNil(TranslationLanguageDetector.normalizedIdentifier("auto"))
    XCTAssertNil(TranslationLanguageDetector.normalizedIdentifier("und"))
    XCTAssertEqual(
      TranslationLanguageDetector.visionRecognitionIdentifier(
        for: "en",
        supportedLanguages: ["en-US"]
      ),
      "en-US"
    )
  }

  func testTenSupportedAppLanguagesMapToNonBareVisionLocales() {
    let expected: [(String, String)] = [
      ("en", "en-US"),
      ("vi", "vi-VT"),
      ("zh-Hans", "zh-Hans"),
      ("zh-Hant", "zh-Hant"),
      ("es", "es-ES"),
      ("ja", "ja-JP"),
      ("ko", "ko-KR"),
      ("ru", "ru-RU"),
      ("fr", "fr-FR"),
      ("de", "de-DE"),
    ]

    for (appIdentifier, visionIdentifier) in expected {
      XCTAssertEqual(
        TranslationLanguageDetector.visionRecognitionIdentifier(
          for: appIdentifier,
          supportedLanguages: [visionIdentifier]
        ),
        visionIdentifier,
        appIdentifier
      )
      XCTAssertFalse(visionIdentifier == appIdentifier && !visionIdentifier.contains("-"))
    }
  }

  func testUnsupportedVisionLocaleFallsBackToAutomaticOCR() {
    XCTAssertNil(
      TranslationLanguageDetector.visionRecognitionIdentifier(
        for: "vi",
        supportedLanguages: ["en-US"]
      )
    )
    XCTAssertNil(
      TranslationLanguageDetector.visionRecognitionIdentifier(
        for: "en",
        supportedLanguages: ["en"]
      )
    )
  }

  func testExplicitUnknownHintRemainsUnknownForParagraphBoundaries() throws {
    let result = try detector.detect(
      "A short label",
      recognitionLanguageHints: ["und"],
      deadline: .distantFuture
    )
    XCTAssertNil(result.languageIdentifier)
    XCTAssertEqual(result.confidence, 0)
  }

  func testLanguageStagesHonorExpiredAbsoluteDeadline() {
    let deadline = Date(timeIntervalSince1970: 0)
    XCTAssertThrowsError(try detector.detect("local text", deadline: deadline)) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
    XCTAssertThrowsError(try detector.detectSessionLanguage(for: ["local text"], deadline: deadline)) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
  }

  func testEveryLanguageEntryOwnsTheExactTwoHundredThousandCharacterBudget() throws {
    let exact = String(repeating: "-", count: TranslationOCRLimits.maximumTextCharacters)
    let over = exact + "-"

    XCTAssertNoThrow(try detector.detect(exact, deadline: .distantFuture))
    XCTAssertThrowsError(try detector.detect(over, deadline: .distantFuture)) { error in
      XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
    }

    XCTAssertEqual(
      try detector.detectSessionLanguage(
        for: [exact],
        sourceLanguageHint: "en",
        deadline: .distantFuture
      ),
      "en"
    )
    XCTAssertThrowsError(
      try detector.detectSessionLanguage(
        for: [over],
        sourceLanguageHint: "en",
        deadline: .distantFuture
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
    }
  }
}
