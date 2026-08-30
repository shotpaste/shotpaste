//
//  TranslationTextBlockBuilderTests.swift
//  ShotPasteTests
//

import CoreGraphics
@testable import ShotPaste
import XCTest

final class TranslationTextBlockBuilderTests: XCTestCase {
  private let builder = TranslationTextBlockBuilder()

  func testNearbyCompatibleLinesBecomeOneStableParagraphBlock() throws {
    let lines = [
      line("Welcome to", x: 20, y: 20),
      line("the translation app", x: 20, y: 48),
    ]

    let blocks = try builder.buildBlocks(
      from: lines,
      imagePixelSize: CGSize(width: 400, height: 200),
      screenRect: CGRect(x: -100, y: 50, width: 200, height: 100),
      sourceLanguageHint: "en",
      deadline: .distantFuture
    )

    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks.first?.id, "block-0001")
    XCTAssertEqual(blocks.first?.sourceText, "Welcome to the translation app")
    XCTAssertEqual(blocks.first?.detectedLanguage, "en")
    XCTAssertEqual(blocks.first?.screenBounds, CGRect(x: -90, y: 116, width: 90, height: 24))
  }

  func testDifferentLanguagesAndStructuralTextRemainIndependent() throws {
    let lines = [
      line("Hello world", x: 20, y: 20),
      line("你好世界", x: 20, y: 48),
      line("https://shotpaste.app", x: 20, y: 76),
    ]

    let blocks = try builder.buildBlocks(
      from: lines,
      imagePixelSize: CGSize(width: 400, height: 200),
      screenRect: CGRect(x: 0, y: 0, width: 400, height: 200),
      sourceLanguageHint: nil,
      deadline: .distantFuture
    )

    XCTAssertEqual(blocks.count, 3)
    XCTAssertTrue(blocks[2].preserveOriginal)
    XCTAssertEqual(blocks[2].detectedLanguage, nil)
  }

  func testMenuLikeRowsAreNotMergedAndVerticalTextGetsRotationDirection() throws {
    let menuRows = [
      line("File", x: 20, y: 20),
      line("Edit", x: 20, y: 42),
      line("View", x: 20, y: 64),
    ]
    let menuBlocks = try builder.buildBlocks(
      from: menuRows,
      imagePixelSize: CGSize(width: 300, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 300, height: 160),
      sourceLanguageHint: "en",
      deadline: .distantFuture
    )
    XCTAssertEqual(menuBlocks.map(\.sourceText), ["File", "Edit", "View"])

    let vertical = TranslationOCRLine(
      text: "縦書き",
      pixelBounds: CGRect(x: 220, y: 20, width: 14, height: 90),
      confidence: 0.88,
      direction: .vertical
    )
    let verticalBlocks = try builder.buildBlocks(
      from: [vertical],
      imagePixelSize: CGSize(width: 300, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 300, height: 160),
      deadline: .distantFuture
    )
    XCTAssertEqual(verticalBlocks.first?.direction, .vertical)
  }

  func testThreeLineShortParagraphIsNotSeparatedOnlyBecauseItHasThreeRows() throws {
    let paragraphRows = [
      line("One short sentence", x: 20, y: 20),
      line("continues on the next line", x: 20, y: 48),
      line("and finishes here", x: 20, y: 76),
    ]

    let blocks = try builder.buildBlocks(
      from: paragraphRows,
      imagePixelSize: CGSize(width: 300, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 300, height: 160),
      sourceLanguageHint: "en",
      deadline: .distantFuture
    )

    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(
      blocks.first?.sourceText,
      "One short sentence continues on the next line and finishes here"
    )
  }

  func testCompactOrdinaryParagraphWithSmallLeadingIsNotAMenu() throws {
    let rows = [
      line("The quick note", x: 20, y: 20),
      line("contains a small idea", x: 20, y: 44),
      line("for readers today", x: 20, y: 68),
    ]

    let blocks = try builder.buildBlocks(
      from: rows,
      imagePixelSize: CGSize(width: 300, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 300, height: 160),
      sourceLanguageHint: "en",
      deadline: .distantFuture
    )

    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(
      blocks.first?.sourceText,
      "The quick note contains a small idea for readers today"
    )
  }

  func testCompactTwoWordProseIsNotMistakenForTitleCaseMenuRows() throws {
    let proseRows = [
      line("read this", x: 20, y: 20),
      line("next line", x: 20, y: 42),
      line("keep going", x: 20, y: 64),
    ]
    let menuRows = [
      line("File", x: 160, y: 20),
      line("Edit", x: 160, y: 42),
      line("Save As", x: 160, y: 64),
    ]

    let proseBlocks = try builder.buildBlocks(
      from: proseRows,
      imagePixelSize: CGSize(width: 400, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 400, height: 160),
      sourceLanguageHint: "en",
      deadline: .distantFuture
    )
    let menuBlocks = try builder.buildBlocks(
      from: menuRows,
      imagePixelSize: CGSize(width: 400, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 400, height: 160),
      sourceLanguageHint: "en",
      deadline: .distantFuture
    )

    XCTAssertEqual(proseBlocks.count, 1)
    XCTAssertEqual(menuBlocks.map(\.sourceText), ["File", "Edit", "Save As"])
  }

  func testUnknownLanguageDoesNotJoinKnownOrAnotherUnknownLine() throws {
    let lines = [
      TranslationOCRLine(
        text: "---",
        pixelBounds: CGRect(x: 20, y: 20, width: 80, height: 20),
        confidence: 0.9
      ),
      TranslationOCRLine(
        text: "***",
        pixelBounds: CGRect(x: 20, y: 48, width: 80, height: 20),
        confidence: 0.9
      ),
    ]

    let blocks = try builder.buildBlocks(
      from: lines,
      imagePixelSize: CGSize(width: 300, height: 160),
      screenRect: CGRect(x: 0, y: 0, width: 300, height: 160),
      deadline: .distantFuture
    )

    XCTAssertEqual(blocks.count, 2)
  }

  func testInvalidGeometryIsRejectedBeforeStableKeyConversion() {
    let invalid = line("outside", x: -500, y: -500)
    let valid = line("inside", x: 20, y: 20)
    for malformed in [
      invalid,
      TranslationOCRLine(
        text: "nan",
        pixelBounds: CGRect(x: CGFloat.nan, y: 20, width: 80, height: 20),
        confidence: 0.9
      ),
      TranslationOCRLine(
        text: "infinite",
        pixelBounds: CGRect(x: CGFloat.infinity, y: 20, width: 80, height: 20),
        confidence: 0.9
      ),
      TranslationOCRLine(
        text: "huge",
        pixelBounds: CGRect(x: CGFloat(Int.max), y: 20, width: 80, height: 20),
        confidence: 0.9
      ),
      TranslationOCRLine(
        text: "bad confidence",
        pixelBounds: CGRect(x: 20, y: 20, width: 80, height: 20),
        confidence: Float.infinity
      ),
      TranslationOCRLine(
        text: "high confidence",
        pixelBounds: CGRect(x: 20, y: 20, width: 80, height: 20),
        confidence: 1.01
      ),
      TranslationOCRLine(
        text: "negative confidence",
        pixelBounds: CGRect(x: 20, y: 20, width: 80, height: 20),
        confidence: -0.01
      ),
    ] {
      XCTAssertThrowsError(
        try builder.buildBlocks(
          from: [malformed, valid],
          imagePixelSize: CGSize(width: 300, height: 160),
          screenRect: CGRect(x: 0, y: 0, width: 300, height: 160),
          sourceLanguageHint: "en",
          deadline: .distantFuture
        )
      ) { error in
        XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
      }
    }
  }

  func testExpiredParagraphDeadlineStopsBeforeReturningBlocks() {
    XCTAssertThrowsError(
      try builder.buildBlocks(
        from: [line("expired", x: 10, y: 10)],
        imagePixelSize: CGSize(width: 100, height: 100),
        screenRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        deadline: Date(timeIntervalSince1970: 0)
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
  }

  func testOCRLineBudgetRejectsPathologicalInput() {
    let lines = Array(
      repeating: line("noise", x: 10, y: 10),
      count: TranslationOCRLimits.maximumOCRLines + 1
    )
    XCTAssertThrowsError(
      try builder.buildBlocks(
        from: lines,
        imagePixelSize: CGSize(width: 100, height: 100),
        screenRect: CGRect(x: 0, y: 0, width: 100, height: 100),
        deadline: .distantFuture
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
    }
  }

  func testExactlyMaximumOCRLinesAndBlocksAreAccepted() throws {
    let lineCount = TranslationOCRLimits.maximumOCRLines
    // Repeated observations still exercise the exact line-count gate while
    // allowing the deduplicator to collapse them immediately; this boundary
    // test should not become an accidental quadratic performance test.
    let lines = Array(repeating: line("hello world", x: 10, y: 10), count: lineCount)
    XCTAssertNoThrow(
      try builder.buildBlocks(
        from: lines,
        imagePixelSize: CGSize(width: 220, height: 100),
        screenRect: CGRect(x: 0, y: 0, width: 220, height: 100),
        sourceLanguageHint: "en",
        deadline: .distantFuture
      )
    )

    let blockCount = TranslationOCRLimits.maximumTextBlocks
    let independentLines = (0 ..< blockCount).map { index in
      line("https://example.com/(index)", x: 10, y: CGFloat(index * 22))
    }
    let blocks = try builder.buildBlocks(
      from: independentLines,
      imagePixelSize: CGSize(width: 300, height: CGFloat(blockCount * 22 + 20)),
      screenRect: CGRect(x: 0, y: 0, width: 300, height: CGFloat(blockCount * 22 + 20)),
      deadline: .distantFuture
    )
    XCTAssertEqual(blocks.count, blockCount)
  }

  func testGroupLinesOwnsTheExactCharacterBudgetAndHonorsDeadlineForLargeSiblingSets() {
    let exact = line(
      String(repeating: "-", count: TranslationOCRLimits.maximumTextCharacters),
      x: 10,
      y: 10
    )
    let over = line(
      String(repeating: "-", count: TranslationOCRLimits.maximumTextCharacters + 1),
      x: 10,
      y: 10
    )
    XCTAssertNoThrow(try TranslationTextBlockBuilder.groupLines([exact], deadline: .distantFuture))
    XCTAssertThrowsError(try TranslationTextBlockBuilder.groupLines([over], deadline: .distantFuture)) { error in
      XCTAssertEqual(error as? TranslationFailure, .inputTooLarge)
    }

    let candidates = (0 ..< TranslationOCRLimits.maximumOCRLines).map { index in
      line("File", x: 10, y: CGFloat(index * 20))
    }
    XCTAssertThrowsError(
      try TranslationTextBlockBuilder.groupLines(
        candidates,
        deadline: Date(timeIntervalSince1970: 0)
      )
    ) { error in
      XCTAssertEqual(error as? TranslationFailure, .timedOut)
    }
  }

  private func line(_ text: String, x: CGFloat, y: CGFloat) -> TranslationOCRLine {
    TranslationOCRLine(
      text: text,
      pixelBounds: CGRect(x: x, y: y, width: 180, height: 20),
      confidence: 0.9
    )
  }
}
