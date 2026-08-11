//
//  FrozenAreaCaptureSessionTests.swift
//  ShotPasteTests
//
//  Unit tests for FrozenAreaCaptureSession crop math and pixel alignment.
//

import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class FrozenAreaCaptureSessionTests: XCTestCase {
  // MARK: - Helpers

  /// Create a test session with a single display snapshot.
  private func makeSession(
    displayID: CGDirectDisplayID = 1,
    width: Int = 200,
    height: Int = 200,
    scaleFactor: CGFloat = 2.0,
    screenOriginX: CGFloat = 0,
    screenOriginY: CGFloat = 0
  ) -> FrozenAreaCaptureSession? {
    guard let image = TestImageFactory.solidColor(
      width: Int(CGFloat(width) * scaleFactor),
      height: Int(CGFloat(height) * scaleFactor),
      red: 100, green: 150, blue: 200
    ) else {
      return nil
    }

    let snapshot = FrozenDisplaySnapshot(
      displayID: displayID,
      screenFrame: CGRect(
        x: screenOriginX,
        y: screenOriginY,
        width: CGFloat(width),
        height: CGFloat(height)
      ),
      scaleFactor: scaleFactor,
      colorSpaceName: nil,
      image: image
    )

    return FrozenAreaCaptureSession.fromSnapshot(snapshot)
  }

  /// Create an AreaSelectionResult for testing.
  private func makeSelection(
    rect: CGRect,
    displayID: CGDirectDisplayID = 1
  ) -> AreaSelectionResult {
    AreaSelectionResult(
      rect: rect,
      displayID: displayID
    )
  }

  private func makeSnapshot(
    displayID: CGDirectDisplayID,
    width: Int = 200,
    height: Int = 200,
    scaleFactor: CGFloat = 2.0,
    imageScaleFactor: CGFloat? = nil,
    screenOriginX: CGFloat = 0,
    screenOriginY: CGFloat = 0,
    red: UInt8 = 80,
    green: UInt8 = 120,
    blue: UInt8 = 180
  ) -> FrozenDisplaySnapshot? {
    let bitmapScaleFactor = imageScaleFactor ?? scaleFactor
    guard let image = TestImageFactory.solidColor(
      width: Int(CGFloat(width) * bitmapScaleFactor),
      height: Int(CGFloat(height) * bitmapScaleFactor),
      red: red,
      green: green,
      blue: blue
    ) else {
      return nil
    }

    return FrozenDisplaySnapshot(
      displayID: displayID,
      screenFrame: CGRect(
        x: screenOriginX,
        y: screenOriginY,
        width: CGFloat(width),
        height: CGFloat(height)
      ),
      scaleFactor: scaleFactor,
      colorSpaceName: nil,
      image: image
    )
  }

  private func makeGradientSnapshot(
    displayID: CGDirectDisplayID,
    width: Int = 100,
    height: Int = 100,
    scaleFactor: CGFloat = 1.0,
    screenOriginX: CGFloat = 0,
    screenOriginY: CGFloat = 0,
    topGray: UInt8 = 20,
    bottomGray: UInt8 = 220
  ) -> FrozenDisplaySnapshot? {
    guard let image = TestImageFactory.verticalGradient(
      width: Int(CGFloat(width) * scaleFactor),
      height: Int(CGFloat(height) * scaleFactor),
      topGray: topGray,
      bottomGray: bottomGray
    ) else {
      return nil
    }

    return FrozenDisplaySnapshot(
      displayID: displayID,
      screenFrame: CGRect(
        x: screenOriginX,
        y: screenOriginY,
        width: CGFloat(width),
        height: CGFloat(height)
      ),
      scaleFactor: scaleFactor,
      colorSpaceName: nil,
      image: image
    )
  }

  private func makeVerticalEdgeSnapshot(
    displayID: CGDirectDisplayID,
    width: Int = 100,
    height: Int = 40,
    scaleFactor: CGFloat = 1.0,
    screenOriginX: CGFloat = 0,
    screenOriginY: CGFloat = 0,
    edgeX: Int? = nil
  ) -> FrozenDisplaySnapshot? {
    guard let image = TestImageFactory.verticalEdge(
      width: Int(CGFloat(width) * scaleFactor),
      height: Int(CGFloat(height) * scaleFactor),
      edgeX: edgeX
    ) else {
      return nil
    }

    return FrozenDisplaySnapshot(
      displayID: displayID,
      screenFrame: CGRect(
        x: screenOriginX,
        y: screenOriginY,
        width: CGFloat(width),
        height: CGFloat(height)
      ),
      scaleFactor: scaleFactor,
      colorSpaceName: nil,
      image: image
    )
  }

  private func redValue(in image: CGImage, x: Int, y: Int) throws -> UInt8 {
    let bytes = try rgbaBytes(from: image)
    return bytes[rgbaIndex(x: x, y: y, width: image.width)]
  }

  private func rgbaBytes(from image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: rgbaBitmapInfo.rawValue
      ))
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  private var rgbaBitmapInfo: CGBitmapInfo {
    CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
  }

  private func rgbaIndex(x: Int, y: Int, width: Int) -> Int {
    (y * width + x) * 4
  }

  // MARK: - Valid Crop

  func testCropImage_validSelectionInsideBounds_returnsCroppedImage() throws {
    guard let session = makeSession() else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 10, y: 10, width: 50, height: 50))
    let result = try session.cropImage(for: selection)

    // At 2x scale, a 50x50 pt selection → ~100x100 px image
    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertGreaterThan(result.image.width, 0)
    XCTAssertGreaterThan(result.image.height, 0)
    // Pixel dimensions should be approximately 100x100
    XCTAssertEqual(result.image.width, 100)
    XCTAssertEqual(result.image.height, 100)
  }

  func testCropImage_fractionalSelectionReturnsPixelAlignedScreenRect() throws {
    guard let session = makeSession(scaleFactor: 2.0) else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 10.2, y: 10.3, width: 50.2, height: 49.6))
    let result = try session.cropImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.screenRect.origin.x, 10.0, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.origin.y, 10.0, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.width, 50.5, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.height, 50.0, accuracy: 0.0001)
    XCTAssertEqual(result.image.width, 101)
    XCTAssertEqual(result.image.height, 100)
    XCTAssertEqual(CGFloat(result.image.width) / result.scaleFactor, result.screenRect.width, accuracy: 0.0001)
    XCTAssertEqual(CGFloat(result.image.height) / result.scaleFactor, result.screenRect.height, accuracy: 0.0001)
  }

  func testCropImage_fullScreenSelection_returnsFullImage() throws {
    guard let session = makeSession() else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 0, y: 0, width: 200, height: 200))
    let result = try session.cropImage(for: selection)

    XCTAssertEqual(result.image.width, 400) // 200 * 2
    XCTAssertEqual(result.image.height, 400)
  }

  // MARK: - Partial Overlap

  func testCropImage_selectionPartiallyOutsideBounds_returnsClamped() throws {
    guard let session = makeSession() else {
      XCTFail("Failed to create test session")
      return
    }

    // Selection extends beyond right and bottom edges (200pt screen, 160+100=260pt)
    let selection = makeSelection(rect: CGRect(x: 160, y: 160, width: 100, height: 100))
    let result = try session.cropImage(for: selection)

    // Clamped region should be smaller than the requested 100x100 pt
    // At 2x scale, 40pt → 80px, but pixel alignment may adjust slightly
    XCTAssertLessThanOrEqual(result.image.width, 80)
    XCTAssertLessThanOrEqual(result.image.height, 80)
    XCTAssertGreaterThan(result.image.width, 0)
    XCTAssertGreaterThan(result.image.height, 0)
  }

  // MARK: - Completely Outside

  func testCropImage_selectionCompletelyOutsideBounds_throws() {
    guard let session = makeSession() else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 500, y: 500, width: 50, height: 50))

    XCTAssertThrowsError(try session.cropImage(for: selection)) { error in
      XCTAssertTrue(error is CaptureError)
    }
  }

  // MARK: - Unknown Display

  func testCropImage_unknownDisplayID_throws() {
    guard let session = makeSession(displayID: 1) else {
      XCTFail("Failed to create test session")
      return
    }

    // Use a different displayID that doesn't exist in the session
    let selection = makeSelection(rect: CGRect(x: 0, y: 0, width: 50, height: 50), displayID: 999)

    XCTAssertThrowsError(try session.cropImage(for: selection)) { error in
      XCTAssertTrue(error is CaptureError)
    }
  }

  // MARK: - Scale Factors

  func testCropImage_at1xScaleFactor() throws {
    guard let session = makeSession(width: 100, height: 100, scaleFactor: 1.0) else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 10, y: 10, width: 30, height: 30))
    let result = try session.cropImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 1.0)
    XCTAssertEqual(result.image.width, 30)
    XCTAssertEqual(result.image.height, 30)
  }

  func testCropImage_usesBitmapScaleWhenReportedScaleFactorDiffers() throws {
    guard let snapshot = makeSnapshot(
      displayID: 2,
      width: 200,
      height: 100,
      scaleFactor: 1.0,
      imageScaleFactor: 1.5,
      screenOriginX: 400
    ) else {
      XCTFail("Failed to create display snapshot")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
    let selection = makeSelection(
      rect: CGRect(x: 410, y: 10, width: 40, height: 20),
      displayID: 2
    )

    let result = try session.cropImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 1.5)
    XCTAssertEqual(result.screenRect.width, 40, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.height, 20, accuracy: 0.0001)
    XCTAssertEqual(result.image.width, 60)
    XCTAssertEqual(result.image.height, 30)
  }

  func testCropImage_promotesOutputScaleForLowDensityDisplay() throws {
    guard let session = makeSession(width: 200, height: 100, scaleFactor: 1.0) else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 10, y: 10, width: 40, height: 20))
    let result = try session.cropImage(
      for: selection,
      minimumOutputScaleFactor: 2.0
    )

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.screenRect.width, 40, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.height, 20, accuracy: 0.0001)
    XCTAssertEqual(result.image.width, 80)
    XCTAssertEqual(result.image.height, 40)
  }

  func testCropImage_keepsNativeScaleWhenAlreadyHigherThanMinimumOutputScale() throws {
    guard let session = makeSession(width: 200, height: 100, scaleFactor: 2.0) else {
      XCTFail("Failed to create test session")
      return
    }

    let selection = makeSelection(rect: CGRect(x: 10, y: 10, width: 40, height: 20))
    let result = try session.cropImage(
      for: selection,
      minimumOutputScaleFactor: 2.0
    )

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.image.width, 80)
    XCTAssertEqual(result.image.height, 40)
  }

  func testImageByPromotingScaleIfNeeded_promotesWholeImageForLowDensityDisplay() throws {
    let logicalSize = CGSize(width: 100, height: 50)
    let image = try XCTUnwrap(TestImageFactory.solidColor(width: 100, height: 50))

    let result = FrozenAreaCaptureSession.imageByPromotingScaleIfNeeded(
      image,
      logicalSize: logicalSize,
      sourceScaleFactor: 1.0,
      minimumOutputScaleFactor: 2.0,
      colorSpaceName: nil
    )

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.image.width, 200)
    XCTAssertEqual(result.image.height, 100)
  }

  // MARK: - Very Small Selection

  func testCropImage_verySmallSelection_returnsMinimalImage() throws {
    guard let session = makeSession(scaleFactor: 2.0) else {
      XCTFail("Failed to create test session")
      return
    }

    // 1x1 pt selection at 2x → should produce at least 2x2 px
    let selection = makeSelection(rect: CGRect(x: 50, y: 50, width: 1, height: 1))
    let result = try session.cropImage(for: selection)

    XCTAssertGreaterThanOrEqual(result.image.width, 1)
    XCTAssertGreaterThanOrEqual(result.image.height, 1)
  }

  // MARK: - Invalidate

  func testInvalidate_thenCrop_throws() {
    guard let session = makeSession() else {
      XCTFail("Failed to create test session")
      return
    }

    session.invalidate()

    let selection = makeSelection(rect: CGRect(x: 0, y: 0, width: 50, height: 50))
    XCTAssertThrowsError(try session.cropImage(for: selection))
  }

  // MARK: - Backdrops

  func testBackdrops_returnsBackdropForEachDisplay() {
    guard let session = makeSession(displayID: 42) else {
      XCTFail("Failed to create test session")
      return
    }

    let backdrops = session.backdrops
    XCTAssertEqual(backdrops.count, 1)
    XCTAssertNotNil(backdrops[42])
    XCTAssertEqual(backdrops[42]?.displayID, 42)
    XCTAssertEqual(backdrops[42]?.scaleFactor, 2.0)
  }

  func testBackdrops_useBitmapScaleWhenReportedScaleFactorDiffers() {
    guard let snapshot = makeSnapshot(
      displayID: 42,
      width: 200,
      height: 100,
      scaleFactor: 1.0,
      imageScaleFactor: 1.5
    ) else {
      XCTFail("Failed to create display snapshot")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshot(snapshot)
    let backdrop = session.backdrops[42]

    XCTAssertEqual(backdrop?.scaleFactor, 1.5)
    XCTAssertEqual(backdrop?.image.width, 300)
    XCTAssertEqual(backdrop?.image.height, 150)
  }

  func testAddSnapshot_addsBackdropAndDisplayID() {
    guard let session = makeSession(displayID: 1),
          let secondSnapshot = makeSnapshot(displayID: 2, screenOriginX: 300) else {
      XCTFail("Failed to create test session")
      return
    }

    session.addSnapshot(secondSnapshot)

    XCTAssertTrue(session.containsSnapshot(for: 1))
    XCTAssertTrue(session.containsSnapshot(for: 2))
    XCTAssertEqual(session.displayIDs, Set([1, 2]))
    XCTAssertNotNil(session.backdrop(for: 2))
    XCTAssertEqual(session.backdrops.count, 2)
  }

  func testFromSnapshots_buildsSessionWithEverySnapshot() {
    guard let firstSnapshot = makeSnapshot(displayID: 1),
          let secondSnapshot = makeSnapshot(displayID: 2, screenOriginX: 200) else {
      XCTFail("Failed to create snapshots")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshots([firstSnapshot, secondSnapshot])

    XCTAssertEqual(session.displayIDs, [1, 2])
    XCTAssertNotNil(session.backdrop(for: 1))
    XCTAssertNotNil(session.backdrop(for: 2))
  }

  func testCropImage_afterAddingSecondDisplay_usesSecondDisplayOrigin() throws {
    guard let session = makeSession(displayID: 1),
          let secondSnapshot = makeSnapshot(
            displayID: 2,
            width: 120,
            height: 90,
            scaleFactor: 2.0,
            screenOriginX: 300,
            screenOriginY: -100
          ) else {
      XCTFail("Failed to create test session")
      return
    }

    session.addSnapshot(secondSnapshot)
    let selection = makeSelection(
      rect: CGRect(x: 310, y: -90, width: 40, height: 30),
      displayID: 2
    )

    let result = try session.cropImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.image.width, 80)
    XCTAssertEqual(result.image.height, 60)
  }

  func testCropCompositeImage_spanningTwoDisplays_returnsUnionSize() throws {
    guard let session = makeSession(displayID: 1),
          let secondSnapshot = makeSnapshot(
            displayID: 2,
            width: 200,
            height: 200,
            scaleFactor: 2.0,
            screenOriginX: 200,
            screenOriginY: 0
          ) else {
      XCTFail("Failed to create test session")
      return
    }

    session.addSnapshot(secondSnapshot)
    let selection = AreaSelectionResult(
      rect: CGRect(x: 150, y: 50, width: 100, height: 60),
      displayID: 1,
      displayIDs: [1, 2]
    )

    let result = try session.cropCompositeImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.image.width, 200)
    XCTAssertEqual(result.image.height, 120)
  }

  func testCropCompositeImage_fractionalSelectionReturnsPixelAlignedScreenRect() throws {
    guard let session = makeSession(displayID: 1),
          let secondSnapshot = makeSnapshot(
            displayID: 2,
            width: 200,
            height: 200,
            scaleFactor: 2.0,
            screenOriginX: 200,
            screenOriginY: 0
          ) else {
      XCTFail("Failed to create test session")
      return
    }

    session.addSnapshot(secondSnapshot)
    let selection = AreaSelectionResult(
      rect: CGRect(x: 150.2, y: 20.3, width: 99.2, height: 40.2),
      displayID: 1,
      displayIDs: [1, 2]
    )

    let result = try session.cropCompositeImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.screenRect.origin.x, 150.0, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.origin.y, 20.0, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.width, 99.5, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.height, 40.5, accuracy: 0.0001)
    XCTAssertEqual(result.image.width, 199)
    XCTAssertEqual(result.image.height, 81)
    XCTAssertEqual(CGFloat(result.image.width) / result.scaleFactor, result.screenRect.width, accuracy: 0.0001)
    XCTAssertEqual(CGFloat(result.image.height) / result.scaleFactor, result.screenRect.height, accuracy: 0.0001)
  }

  func testCropCompositeImage_usesBitmapScaleWhenReportedScaleFactorDiffers() throws {
    guard let firstSnapshot = makeSnapshot(displayID: 1, scaleFactor: 1.0),
          let secondSnapshot = makeSnapshot(
            displayID: 2,
            width: 200,
            height: 100,
            scaleFactor: 1.0,
            imageScaleFactor: 1.5,
            screenOriginX: 200
          ) else {
      XCTFail("Failed to create display snapshots")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshots([firstSnapshot, secondSnapshot])
    let selection = AreaSelectionResult(
      rect: CGRect(x: 210, y: 10, width: 40, height: 20),
      displayID: 2,
      displayIDs: [2]
    )

    let result = try session.cropCompositeImage(for: selection)

    XCTAssertEqual(result.scaleFactor, 1.5)
    XCTAssertEqual(result.screenRect.width, 40, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.height, 20, accuracy: 0.0001)
    XCTAssertEqual(result.image.width, 60)
    XCTAssertEqual(result.image.height, 30)
  }

  func testCropCompositeImage_promotesOutputScaleForLowDensityDisplay() throws {
    guard let firstSnapshot = makeSnapshot(displayID: 1, scaleFactor: 1.0),
          let secondSnapshot = makeSnapshot(
            displayID: 2,
            width: 200,
            height: 100,
            scaleFactor: 1.0,
            screenOriginX: 200
          ) else {
      XCTFail("Failed to create display snapshots")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshots([firstSnapshot, secondSnapshot])
    let selection = AreaSelectionResult(
      rect: CGRect(x: 210, y: 10, width: 40, height: 20),
      displayID: 2,
      displayIDs: [2]
    )

    let result = try session.cropCompositeImage(
      for: selection,
      minimumOutputScaleFactor: 2.0
    )

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.screenRect.width, 40, accuracy: 0.0001)
    XCTAssertEqual(result.screenRect.height, 20, accuracy: 0.0001)
    XCTAssertEqual(result.image.width, 80)
    XCTAssertEqual(result.image.height, 40)
  }

  func testCropCompositeImage_promotesLowDensitySliceWhenMixedWithRetinaDisplay() throws {
    guard let retinaSnapshot = makeSnapshot(
      displayID: 1,
      width: 100,
      height: 40,
      scaleFactor: 2.0,
      screenOriginX: 0
    ),
      let lowDensitySnapshot = makeVerticalEdgeSnapshot(
        displayID: 2,
        width: 100,
        height: 40,
        scaleFactor: 1.0,
        screenOriginX: 100,
        edgeX: 50
      ) else {
      XCTFail("Failed to create display snapshots")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshots([retinaSnapshot, lowDensitySnapshot])
    let selection = AreaSelectionResult(
      rect: CGRect(x: 90, y: 0, width: 70, height: 20),
      displayID: 1,
      displayIDs: [1, 2]
    )

    let result = try session.cropCompositeImage(
      for: selection,
      minimumOutputScaleFactor: 2.0
    )
    let lowDensitySourceCrop = try XCTUnwrap(lowDensitySnapshot.image.cropping(to: CGRect(
      x: 0,
      y: 20,
      width: 60,
      height: 20
    )))
    let expectedLowDensitySlice = FrozenAreaCaptureSession.imageByPromotingScaleIfNeeded(
      lowDensitySourceCrop,
      logicalSize: CGSize(width: 60, height: 20),
      sourceScaleFactor: 1.0,
      minimumOutputScaleFactor: 2.0,
      colorSpaceName: nil
    ).image
    let actualLowDensitySlice = try XCTUnwrap(result.image.cropping(to: CGRect(
      x: 20,
      y: 0,
      width: 120,
      height: 40
    )))

    XCTAssertEqual(result.scaleFactor, 2.0)
    XCTAssertEqual(result.image.width, 140)
    XCTAssertEqual(result.image.height, 40)
    XCTAssertEqual(try rgbaBytes(from: actualLowDensitySlice), try rgbaBytes(from: expectedLowDensitySlice))
  }

  func testCropCompositeImage_preservesVerticalScreenOrientation() throws {
    guard let firstSnapshot = makeGradientSnapshot(displayID: 1),
          let secondSnapshot = makeGradientSnapshot(displayID: 2, screenOriginX: 100) else {
      XCTFail("Failed to create gradient snapshots")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshot(firstSnapshot)
    session.addSnapshot(secondSnapshot)
    let selection = AreaSelectionResult(
      rect: CGRect(x: 75, y: 25, width: 50, height: 50),
      displayID: 1,
      displayIDs: [1, 2]
    )

    let result = try session.cropCompositeImage(for: selection)
    let topRed = try redValue(in: result.image, x: result.image.width / 2, y: 0)
    let bottomRed = try redValue(in: result.image, x: result.image.width / 2, y: result.image.height - 1)

    XCTAssertLessThan(topRed, bottomRed)
  }

  func testCropCompositeImage_stackedDisplaysKeepsTopDisplayOnTop() throws {
    guard let bottomSnapshot = makeSnapshot(
      displayID: 1,
      width: 100,
      height: 100,
      scaleFactor: 1.0,
      screenOriginY: 0,
      red: 10,
      green: 20,
      blue: 220
    ),
      let topSnapshot = makeSnapshot(
        displayID: 2,
        width: 100,
        height: 100,
        scaleFactor: 1.0,
        screenOriginY: 100,
        red: 240,
        green: 40,
        blue: 40
      ) else {
      XCTFail("Failed to create stacked display snapshots")
      return
    }

    let session = FrozenAreaCaptureSession.fromSnapshot(bottomSnapshot)
    session.addSnapshot(topSnapshot)
    let selection = AreaSelectionResult(
      rect: CGRect(x: 0, y: 50, width: 100, height: 100),
      displayID: 2,
      displayIDs: [1, 2]
    )

    let result = try session.cropCompositeImage(for: selection)
    let topRed = try redValue(in: result.image, x: 50, y: 0)
    let bottomRed = try redValue(in: result.image, x: 50, y: result.image.height - 1)

    XCTAssertGreaterThan(topRed, bottomRed)
  }

  func testMissingSnapshotDisplayIDs_returnsOnlyMissingDisplays() {
    guard let session = makeSession(displayID: 1),
          let secondSnapshot = makeSnapshot(displayID: 2, screenOriginX: 200) else {
      XCTFail("Failed to create test session")
      return
    }

    session.addSnapshot(secondSnapshot)

    XCTAssertEqual(session.missingSnapshotDisplayIDs(for: [1, 2, 3]), [3])
  }

  func testInvalidate_afterAddingSnapshot_clearsAllSnapshots() {
    guard let session = makeSession(displayID: 1),
          let secondSnapshot = makeSnapshot(displayID: 2, screenOriginX: 300) else {
      XCTFail("Failed to create test session")
      return
    }

    session.addSnapshot(secondSnapshot)
    session.invalidate()

    XCTAssertFalse(session.containsSnapshot(for: 1))
    XCTAssertFalse(session.containsSnapshot(for: 2))
    XCTAssertTrue(session.displayIDs.isEmpty)
  }

  // MARK: - Non-zero Screen Origin

  func testCropImage_withNonZeroScreenOrigin_adjustsCorrectly() throws {
    // Simulate a secondary display with origin at (1920, 0)
    guard let session = makeSession(
      displayID: 2,
      width: 100,
      height: 100,
      scaleFactor: 2.0,
      screenOriginX: 1920,
      screenOriginY: 0
    ) else {
      XCTFail("Failed to create test session")
      return
    }

    // Selection in global coordinates on the second display
    let selection = makeSelection(
      rect: CGRect(x: 1930, y: 10, width: 50, height: 50),
      displayID: 2
    )
    let result = try session.cropImage(for: selection)

    // 50x50 pt at 2x → 100x100 px
    XCTAssertEqual(result.image.width, 100)
    XCTAssertEqual(result.image.height, 100)
  }

  // MARK: - Transition re-freeze (snapshot replacement updates crop source)

  /// Read the RGB of the top-left pixel of a CGImage (for solid-color crop assertions).
  private func topLeftRGB(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
    var pixel = [UInt8](repeating: 0, count: 4)
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let ctx = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    ) else { return nil }
    // Draw the image's top-left region into the 1x1 context.
    ctx.draw(
      image,
      in: CGRect(x: 0, y: 1 - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height))
    )
    return (pixel[0], pixel[1], pixel[2])
  }

  func testAddSnapshot_replacesBackdropAndCropSource() throws {
    // GIVEN: a frozen session with an initial RED snapshot on display 1.
    guard let redImage = TestImageFactory.solidColor(width: 400, height: 400, red: 255, green: 0, blue: 0) else {
      XCTFail("Failed to create red image")
      return
    }
    let redSnapshot = FrozenDisplaySnapshot(
      displayID: 1,
      screenFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
      scaleFactor: 2.0,
      colorSpaceName: nil,
      image: redImage
    )
    let session = FrozenAreaCaptureSession.fromSnapshot(redSnapshot)
    XCTAssertTrue((session.backdrop(for: 1)?.image as AnyObject) === (redImage as AnyObject),
                  "Initial backdrop must reference the red snapshot image")

    // WHEN: a transition re-freeze replaces display 1 with a BLUE snapshot (same display).
    guard let blueImage = TestImageFactory.solidColor(width: 400, height: 400, red: 0, green: 0, blue: 255) else {
      XCTFail("Failed to create blue image")
      return
    }
    let blueSnapshot = FrozenDisplaySnapshot(
      displayID: 1,
      screenFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
      scaleFactor: 2.0,
      colorSpaceName: nil,
      image: blueImage
    )
    session.addSnapshot(blueSnapshot)

    // THEN: the visible backdrop now references the blue image (preview reflects new state)...
    XCTAssertTrue((session.backdrop(for: 1)?.image as AnyObject) === (blueImage as AnyObject),
                  "After re-freeze, backdrop must reference the new blue snapshot image")

    // ...and the FINAL crop source samples blue, not the stale red (capture reflects new state).
    let selection = makeSelection(rect: CGRect(x: 10, y: 10, width: 50, height: 50), displayID: 1)
    let cropped = try session.cropImage(for: selection)
    guard let rgb = topLeftRGB(of: cropped.image) else {
      XCTFail("Failed to sample cropped image")
      return
    }
    XCTAssertEqual(rgb.b, 255, "Crop must contain the new (blue) content after re-freeze")
    XCTAssertEqual(rgb.r, 0, "Crop must NOT contain the stale (red) content after re-freeze")
  }

  func testAddSnapshot_doesNotAffectOtherDisplays() {
    // GIVEN: two displays with distinct snapshots.
    guard let redImage = TestImageFactory.solidColor(width: 200, height: 200, red: 255, green: 0, blue: 0),
          let greenImage = TestImageFactory.solidColor(width: 200, height: 200, red: 0, green: 255, blue: 0) else {
      XCTFail("Failed to create images")
      return
    }
    let session = FrozenAreaCaptureSession.fromSnapshots([
      FrozenDisplaySnapshot(
        displayID: 1,
        screenFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
        scaleFactor: 1.0,
        colorSpaceName: nil,
        image: redImage
      ),
      FrozenDisplaySnapshot(
        displayID: 2,
        screenFrame: CGRect(x: 200, y: 0, width: 200, height: 200),
        scaleFactor: 1.0,
        colorSpaceName: nil,
        image: greenImage
      ),
    ])

    // WHEN: re-freezing only display 1.
    guard let blueImage = TestImageFactory.solidColor(width: 200, height: 200, red: 0, green: 0, blue: 255) else {
      XCTFail("Failed to create blue image")
      return
    }
    session.addSnapshot(FrozenDisplaySnapshot(
      displayID: 1,
      screenFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
      scaleFactor: 1.0,
      colorSpaceName: nil,
      image: blueImage
    ))

    // THEN: display 2 is untouched.
    XCTAssertTrue((session.backdrop(for: 2)?.image as AnyObject) === (greenImage as AnyObject),
                  "Re-freezing display 1 must not affect display 2's snapshot")
    XCTAssertTrue((session.backdrop(for: 1)?.image as AnyObject) === (blueImage as AnyObject),
                  "Display 1 must reflect the re-frozen blue snapshot")
  }
}
