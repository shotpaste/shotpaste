//
//  MediaCoreTests.swift
//  LiteScreenTests
//
//  Unit tests for OCR benchmark math and QR clipboard payload logic.
//

import CoreGraphics
@testable import LiteScreen
import XCTest

final class MediaCoreTests: XCTestCase {
  func testQRPayloadClassifier_trimsAndClassifiesWebURLs() {
    let classification = QRPayloadClassifier.classify("  HTTPS://Example.COM/path?q=1  ")

    XCTAssertEqual(classification, .webURL(scheme: "https", host: "example.com"))
    XCTAssertEqual(classification.diagnosticName, "web-url-https")
  }

  func testQRPayloadClassifier_distinguishesPlainTextAndCustomSchemes() {
    XCTAssertEqual(QRPayloadClassifier.classify("hello world"), .plainText)
    XCTAssertEqual(QRPayloadClassifier.classify("mailto:hello@example.com"), .urlScheme("mailto"))
    XCTAssertEqual(QRPayloadClassifier.classify("litescreen://capture/area"), .urlScheme("litescreen"))
  }

  func testQRCodeDetectionResult_hasCopyablePayloadsOnlyWhenDetectionsExist() {
    XCTAssertFalse(QRCodeDetectionResult.empty.hasCopyablePayloads)

    let result = QRCodeDetectionResult(
      detections: [makeDetection("https://example.com")],
      unsupportedPayloadCount: 2
    )

    XCTAssertTrue(result.hasCopyablePayloads)
    XCTAssertEqual(result.unsupportedPayloadCount, 2)
  }

  func testOCRQRPayloadComposer_returnsNilForEmptyInputs() {
    XCTAssertNil(OCRQRPayloadComposer.compose(
      recognizedText: " \n ",
      qrDetections: [],
      qrSectionTitle: "QR Codes"
    ))
  }

  func testOCRQRPayloadComposer_deduplicatesAndFiltersPayloadsAlreadyInText() {
    let text = "Open https://example.com for details"
    let output = OCRQRPayloadComposer.compose(
      recognizedText: text,
      qrDetections: [
        makeDetection("https://example.com"),
        makeDetection("WIFI:T:WPA;S:Office;P:secret;;"),
        makeDetection("WIFI:T:WPA;S:Office;P:secret;;"),
        makeDetection("   "),
        makeDetection("mailto:team@example.com"),
      ],
      qrSectionTitle: "QR Codes"
    )

    XCTAssertEqual(
      output,
      """
      Open https://example.com for details

      QR Codes:
      WIFI:T:WPA;S:Office;P:secret;;
      mailto:team@example.com
      """
    )
  }

  func testOCRQRPayloadComposer_returnsSingleQRPayloadWithoutSectionWhenNoOCRText() {
    let output = OCRQRPayloadComposer.compose(
      recognizedText: nil,
      qrDetections: [makeDetection("https://example.com")],
      qrSectionTitle: "QR Codes"
    )

    XCTAssertEqual(output, "https://example.com")
  }

  func testOCRBenchmarkMetrics_normalizesLineEndingsAndWhitespace() {
    XCTAssertEqual(
      OCRBenchmarkMetrics.normalized(" \r\nHello\rWorld\n "),
      "Hello\nWorld"
    )
  }

  func testOCRBenchmarkMetrics_accuracyHandlesEmptyExpectedText() {
    XCTAssertEqual(OCRBenchmarkMetrics.normalizedAccuracy(expected: "", recognized: ""), 1)
    XCTAssertEqual(OCRBenchmarkMetrics.normalizedAccuracy(expected: "", recognized: "extra"), 0)
  }

  func testOCRBenchmarkMetrics_summarizeGroupsLanguagesAndComputesRates() throws {
    let summaries = OCRBenchmarkMetrics.summarize([
      OCRBenchmarkSample(
        languageIdentifier: "vi",
        expectedText: "Xin chao",
        recognizedText: "Xin chao",
        confidence: 0.9,
        latencyMs: 20
      ),
      OCRBenchmarkSample(
        languageIdentifier: "en",
        expectedText: "Hello",
        recognizedText: "Hella",
        confidence: 0.8,
        latencyMs: 10
      ),
      OCRBenchmarkSample(
        languageIdentifier: "en",
        expectedText: "World",
        recognizedText: "",
        confidence: 0.2,
        latencyMs: 30
      ),
    ])

    XCTAssertEqual(summaries.map(\.languageIdentifier), ["en", "vi"])

    let english = try XCTUnwrap(summaries.first { $0.languageIdentifier == "en" })
    XCTAssertEqual(english.sampleCount, 2)
    XCTAssertEqual(english.exactMatchRate, 0)
    XCTAssertEqual(english.noOutputRate, 0.5)
    XCTAssertEqual(english.averageConfidence, 0.5, accuracy: 0.0001)
    XCTAssertEqual(english.averageLatencyMs, 20, accuracy: 0.0001)
    XCTAssertEqual(english.averageCharacterAccuracy, 0.4, accuracy: 0.0001)

    let vietnamese = try XCTUnwrap(summaries.first { $0.languageIdentifier == "vi" })
    XCTAssertEqual(vietnamese.exactMatchRate, 1)
    XCTAssertEqual(vietnamese.noOutputRate, 0)
    XCTAssertEqual(vietnamese.averageCharacterAccuracy, 1, accuracy: 0.0001)
  }

  private func makeDetection(_ payload: String) -> QRCodeDetection {
    QRCodeDetection(
      payload: payload,
      boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
      classification: QRPayloadClassifier.classify(payload)
    )
  }
}
