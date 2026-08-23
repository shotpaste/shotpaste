//
//  TranslationResultRendererTests.swift
//  ShotPasteTests
//

import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class TranslationResultRendererTests: XCTestCase {
  func testRendererKeepsFrozenInputLogicalSizeAndProducesBitmap() throws {
    let input = TranslationInput(
      image: try XCTUnwrap(TestImageFactory.solidColor(width: 400, height: 200)),
      screenRect: CGRect(x: -200, y: 100, width: 200, height: 100)
    )
    let block = TranslationRenderBlock(
      id: "result",
      sourceText: "Hello",
      translatedText: "你好",
      screenBounds: CGRect(x: -160, y: 130, width: 80, height: 28),
      alignment: .leading,
      rotationDegrees: 0,
      confidence: 0.9,
      usesLightBackground: true
    )

    let image = try XCTUnwrap(TranslationResultRenderer.render(input: input, blocks: [block]))

    XCTAssertEqual(image.size, CGSize(width: 200, height: 100))
    let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    XCTAssertEqual(bitmap.pixelsWide, 400)
    XCTAssertEqual(bitmap.pixelsHigh, 200)
    XCTAssertNotNil(image.tiffRepresentation)
  }

  func testRendererRejectsZeroSizedInput() throws {
    let input = TranslationInput(
      image: try XCTUnwrap(TestImageFactory.solidColor(width: 1, height: 1)),
      screenRect: .zero
    )

    XCTAssertNil(TranslationResultRenderer.render(input: input, blocks: []))
  }

  func testRendererUsesWordWrappingAndStoredFontSizeForLongText() throws {
    let block = TranslationRenderBlock(
      id: "wrapped",
      sourceText: "Source",
      translatedText: "This is a deliberately long translated sentence that should wrap.",
      screenBounds: CGRect(x: 10, y: 10, width: 80, height: 48),
      alignment: .leading,
      fontSize: 13,
      confidence: 0.95,
      usesLightBackground: true
    )
    let attributed = TranslationResultRenderer.attributedText(
      for: block,
      in: block.screenBounds
    )
    let paragraph = try XCTUnwrap(
      attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    )
    let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

    XCTAssertEqual(paragraph.lineBreakMode, .byWordWrapping)
    XCTAssertEqual(font.pointSize, block.fontSize, accuracy: 0.001)
    let measured = attributed.boundingRect(
      with: CGSize(width: 70, height: 200),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    XCTAssertGreaterThan(measured.height, block.fontSize)
  }

  func testRendererClipsToFrozenSelectionAndRotatesVerticalBlocks() throws {
    let input = TranslationInput(
      image: try XCTUnwrap(TestImageFactory.solidColor(width: 200, height: 100)),
      screenRect: CGRect(x: -100, y: 40, width: 100, height: 50)
    )
    let partiallyOutside = TranslationRenderBlock(
      id: "clipped",
      sourceText: "Source",
      translatedText: "Translated",
      screenBounds: CGRect(x: -120, y: 60, width: 40, height: 24),
      alignment: .leading,
      confidence: 0.9
    )
    let clipped = try XCTUnwrap(
      TranslationResultRenderer.clippedDrawingRect(for: partiallyOutside, input: input)
    )

    XCTAssertEqual(clipped.minX, 0, accuracy: 0.001)
    XCTAssertEqual(clipped.maxX, 20, accuracy: 0.001)
    XCTAssertTrue(clipped.minY >= 0)
    XCTAssertTrue(clipped.maxY <= input.screenRect.height)

    let vertical = TranslationRenderBlock(
      id: "vertical",
      sourceText: "竖排",
      translatedText: "Vertical",
      screenBounds: CGRect(x: -80, y: 50, width: 16, height: 60),
      alignment: .center,
      direction: .vertical,
      rotationDegrees: 0,
      fontSize: 12
    )
    XCTAssertEqual(
      TranslationResultRenderer.effectiveRotationDegrees(for: vertical),
      90,
      accuracy: 0.001
    )

    let image = try XCTUnwrap(TranslationResultRenderer.render(input: input, blocks: [vertical]))
    XCTAssertEqual(image.size, input.screenRect.size)
  }

  func testRendererTinyBlockClampsTextInsetToPositiveRect() throws {
    let tiny = CGRect(x: 1, y: 2, width: 4, height: 3)
    let textRect = try XCTUnwrap(TranslationResultRenderer.textDrawingRect(for: tiny))
    XCTAssertGreaterThan(textRect.width, 0)
    XCTAssertGreaterThan(textRect.height, 0)
    XCTAssertGreaterThanOrEqual(textRect.minX, tiny.minX)
    XCTAssertGreaterThanOrEqual(textRect.minY, tiny.minY)
    XCTAssertLessThanOrEqual(textRect.maxX, tiny.maxX)
    XCTAssertLessThanOrEqual(textRect.maxY, tiny.maxY)

    let input = TranslationInput(
      image: try XCTUnwrap(TestImageFactory.solidColor(width: 32, height: 24)),
      screenRect: CGRect(x: 0, y: 0, width: 32, height: 24)
    )
    let block = TranslationRenderBlock(
      id: "tiny",
      sourceText: "x",
      translatedText: "y",
      screenBounds: tiny,
      alignment: .leading,
      confidence: 0.9
    )
    XCTAssertNoThrow(try XCTUnwrap(TranslationResultRenderer.render(input: input, blocks: [block])))
  }
}
