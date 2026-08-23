//
//  TranslationResponseValidatorTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

final class TranslationResponseValidatorTests: XCTestCase {
  func testGenerationMismatchIsRejected() {
    assertInvalid(
      TranslationTextResponse(
        generationID: "late-generation",
        translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "欢迎")]
      )
    )
  }

  func testUnknownDuplicateAndMissingIDsAreRejected() {
    assertInvalid(
      TranslationTextResponse(
        generationID: "generation-1",
        translations: [TranslationTextResultBlock(id: "unknown", translatedText: "未知")]
      )
    )
    assertInvalid(
      TranslationTextResponse(
        generationID: "generation-1",
        translations: [
          TranslationTextResultBlock(id: "block-0001", translatedText: "一"),
          TranslationTextResultBlock(id: "block-0001", translatedText: "二"),
        ]
      )
    )
    assertInvalid(
      TranslationTextResponse(generationID: "generation-1", translations: [])
    )
  }

  func testEmptyOrOversizedTranslationIsRejectedAndTrimmedTextIsNormalized() throws {
    assertInvalid(
      TranslationTextResponse(
        generationID: "generation-1",
        translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "   ")]
      )
    )
    let normalized = try TranslationTextResponseValidator.validate(
      TranslationTextResponse(
        generationID: "generation-1",
        translations: [TranslationTextResultBlock(id: "block-0001", translatedText: "  欢迎  ")]
      ),
      against: request()
    )
    XCTAssertEqual(normalized.translations.first?.translatedText, "欢迎")

    assertInvalid(
      TranslationTextResponse(
        generationID: "generation-1",
        translations: [
          TranslationTextResultBlock(
            id: "block-0001",
            translatedText: String(repeating: "x", count: TranslationTextLimits.maximumTranslatedCharactersPerBlock + 1)
          ),
        ]
      )
    )
  }

  func testCoordinatesAndExtraFieldsNeverEnterResult() throws {
    let object: [String: Any] = [
      "generation_id": "generation-1",
      "translations": [[
        "id": "block-0001",
        "translated_text": "欢迎",
        "bounds": ["x": 0, "y": 0, "width": 1, "height": 1],
      ]],
    ]
    XCTAssertThrowsError(
      try TranslationTextResponseValidator.decodeObject(object, against: request())
    ) { error in
      XCTAssertEqual(error as? TranslationTextProviderError, .invalidResponse)
    }
  }

  func testStrictJSONRejectsProseAndMarkdown() {
    for response in [
      "note {\"generation_id\":\"generation-1\",\"translations\":[]}",
      "```json\n{\"generation_id\":\"generation-1\",\"translations\":[]}\n```",
      "[ {\"generation_id\":\"generation-1\"} ]",
    ] {
      XCTAssertThrowsError(
        try TranslationTextResponseValidator.decodeStrictJSON(response, against: request())
      ) { error in
        XCTAssertEqual(error as? TranslationTextProviderError, .invalidResponse)
      }
    }
  }

  private func request() -> TranslationTextRequest {
    TranslationTextRequest(
      generationID: "generation-1",
      sourceLanguage: "auto",
      targetLanguage: "zh-Hans",
      blocks: [TranslationTextRequestBlock(id: "block-0001", text: "Welcome")]
    )
  }

  private func assertInvalid(
    _ response: TranslationTextResponse,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try TranslationTextResponseValidator.validate(response, against: request()),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? TranslationTextProviderError, .invalidResponse, file: file, line: line)
    }
  }
}
