//
//  TranslationLayoutResolverTests.swift
//  ShotPasteTests
//

import CoreGraphics
@testable import ShotPaste
import XCTest

final class TranslationLayoutResolverTests: XCTestCase {
  private let resolver = TranslationLayoutResolver()

  func testLayoutUsesOCRBoundsAndClipsToSelection() throws {
    let block = makeBlock(
      id: "block-0001",
      bounds: CGRect(x: -20, y: 20, width: 90, height: 30)
    )

    let items = try resolver.resolve(
      [TranslationLayoutInput(block: block, translatedText: "欢迎使用 ShotPaste")],
      inside: CGRect(x: 0, y: 0, width: 100, height: 100),
      deadline: .distantFuture
    )

    let item = XCTAssertNotNilAndReturn(items.first)
    XCTAssertEqual(item.screenBounds, CGRect(x: 0, y: 20, width: 70, height: 30))
    XCTAssertTrue(CGRect(x: 0, y: 0, width: 100, height: 100).contains(item.screenBounds))
    XCTAssertEqual(item.rotationDegrees, 0)
  }

  func testAdjacentBlocksAreMovedLocallyAndVerticalBlocksRotate() throws {
    let first = makeBlock(id: "block-0001", bounds: CGRect(x: 10, y: 10, width: 70, height: 20))
    let second = makeBlock(id: "block-0002", bounds: CGRect(x: 10, y: 12, width: 70, height: 20))
    let vertical = TranslationTextBlock(
      id: "block-0003",
      sourceText: "縦書き",
      pixelBounds: CGRect(x: 90, y: 10, width: 12, height: 60),
      screenBounds: CGRect(x: 90, y: 10, width: 12, height: 60),
      direction: .vertical,
      alignment: .leading,
      confidence: 0.8,
      detectedLanguage: "ja"
    )

    let items = try resolver.resolve(
      blocks: [first, second, vertical],
      translations: [
        first.id: "第一段",
        second.id: "第二段",
        vertical.id: "縦書き",
      ],
      inside: CGRect(x: 0, y: 0, width: 120, height: 100),
      deadline: .distantFuture
    )

    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items.last?.rotationDegrees, 90)
    XCTAssertTrue(items.allSatisfy { CGRect(x: 0, y: 0, width: 120, height: 100).contains($0.screenBounds) })
    XCTAssertFalse(items[0].screenBounds.intersects(items[1].screenBounds))
  }

  func testPreserveOriginalBlockCanLayoutWithoutProviderTranslation() throws {
    let block = TranslationTextBlock(
      id: "block-0001",
      sourceText: "https://shotpaste.app",
      pixelBounds: CGRect(x: 5, y: 5, width: 90, height: 15),
      screenBounds: CGRect(x: 5, y: 5, width: 90, height: 15),
      direction: .horizontal,
      alignment: .leading,
      confidence: 1,
      detectedLanguage: nil,
      preserveOriginal: true
    )

    let items = try resolver.resolve(
      blocks: [block],
      translations: [:],
      inside: CGRect(x: 0, y: 0, width: 100, height: 100),
      deadline: .distantFuture
    )

    XCTAssertEqual(items.first?.translatedText, block.sourceText)
  }

  func testPreserveOriginalAlwaysIgnoresAProviderValueForTheSameID() throws {
    let block = TranslationTextBlock(
      id: "block-preserve",
      sourceText: "~/Documents/ShotPaste.md",
      pixelBounds: CGRect(x: 5, y: 5, width: 90, height: 15),
      screenBounds: CGRect(x: 5, y: 5, width: 90, height: 15),
      direction: .horizontal,
      alignment: .leading,
      confidence: 1,
      detectedLanguage: nil,
      preserveOriginal: true
    )

    let items = try resolver.resolve(
      blocks: [block],
      translations: [block.id: "malicious provider replacement"],
      inside: CGRect(x: 0, y: 0, width: 100, height: 100),
      deadline: .distantFuture
    )

    XCTAssertEqual(items.first?.translatedText, block.sourceText)
  }

  func testDirectLayoutInputAlsoForcesPreserveOriginalSourceText() throws {
    let block = TranslationTextBlock(
      id: "block-direct-preserve",
      sourceText: "42.5%",
      pixelBounds: CGRect(x: 5, y: 5, width: 90, height: 15),
      screenBounds: CGRect(x: 5, y: 5, width: 90, height: 15),
      direction: .horizontal,
      alignment: .leading,
      confidence: 1,
      detectedLanguage: nil,
      preserveOriginal: true
    )

    let items = try resolver.resolve(
      [TranslationLayoutInput(block: block, translatedText: "ignore this injection")],
      inside: CGRect(x: 0, y: 0, width: 100, height: 100),
      deadline: .distantFuture
    )

    XCTAssertEqual(items.first?.translatedText, block.sourceText)
  }

  func testVerticalFrameUsesRotatedTextMeasureAndStaysInsideClip() throws {
    let block = TranslationTextBlock(
      id: "vertical",
      sourceText: "縦書き",
      pixelBounds: CGRect(x: 90, y: 10, width: 12, height: 60),
      screenBounds: CGRect(x: 90, y: 10, width: 12, height: 60),
      direction: .vertical,
      alignment: .leading,
      confidence: 0.9,
      detectedLanguage: "ja"
    )

    let clip = CGRect(x: 0, y: 0, width: 120, height: 100)
    let item = XCTAssertNotNilAndReturn(
      try resolver.resolve(
        [TranslationLayoutInput(block: block, translatedText: "縦書き")],
        inside: clip,
        deadline: .distantFuture
      ).first
    )

    XCTAssertEqual(item.rotationDegrees, 90)
    XCTAssertEqual(item.screenBounds.width, block.screenBounds.height, accuracy: 0.001)
    XCTAssertEqual(item.screenBounds.height, block.screenBounds.width, accuracy: 0.001)
    XCTAssertTrue(clip.contains(item.screenBounds))
    XCTAssertGreaterThanOrEqual(item.fontSize, TranslationLayoutResolver.minimumFontSize)
  }

  func testExpiredLayoutDeadlineStopsBeforePlacement() {
    let block = makeBlock(id: "expired", bounds: CGRect(x: 5, y: 5, width: 50, height: 20))
    XCTAssertThrowsError(
      try resolver.resolve(
        [TranslationLayoutInput(block: block, translatedText: "expired")],
        inside: CGRect(x: 0, y: 0, width: 100, height: 100),
        deadline: Date(timeIntervalSince1970: 0)
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
  }

  func testLayoutBlockBudgetRejectsPathologicalInput() {
    let block = makeBlock(id: "too-many", bounds: CGRect(x: 5, y: 5, width: 50, height: 20))
    let inputs = Array(
      repeating: TranslationLayoutInput(block: block, translatedText: "text"),
      count: TranslationOCRLimits.maximumTextBlocks + 1
    )
    XCTAssertThrowsError(
      try resolver.resolve(
        inputs,
        inside: CGRect(x: 0, y: 0, width: 100, height: 100),
        deadline: .distantFuture
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
    }
  }

  private func makeBlock(id: String, bounds: CGRect) -> TranslationTextBlock {
    TranslationTextBlock(
      id: id,
      sourceText: id,
      pixelBounds: bounds,
      screenBounds: bounds,
      direction: .horizontal,
      alignment: .leading,
      confidence: 0.9,
      detectedLanguage: "en"
    )
  }

  private func XCTAssertNotNilAndReturn<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
    XCTAssertNotNil(value, file: file, line: line)
    return value!
  }
}
