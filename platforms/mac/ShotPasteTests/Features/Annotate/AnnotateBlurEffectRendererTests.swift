//
//  AnnotateBlurEffectRendererTests.swift
//  ShotPasteTests
//
//  Unit tests for BlurEffectRenderer drawing helpers.
//

import AppKit
import CoreGraphics
@testable import ShotPaste
import XCTest

final class AnnotateBlurEffectRendererTests: XCTestCase {
  private func makeContext(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  }

  func testDrawBlurPreview_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    BlurEffectRenderer.drawBlurPreview(
      in: context,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      strokeColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    )
  }

  func testDrawPixelatedRegion_withValidImage_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawPixelatedRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      pixelSize: 8
    )
  }

  func testDrawPixelatedRegion_emptyRegion_returnsEarly() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawPixelatedRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 0, y: 0, width: 0, height: 0),
      pixelSize: 8
    )
  }

  func testDrawGaussianRegion_withValidImage_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawGaussianRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      radius: 10
    )
  }

  func testDrawHexagonalRegion_withValidImage_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawHexagonalRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      scale: 8
    )
  }

  func testDrawCrystallizedRegion_withValidImage_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawCrystallizedRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      radius: 8
    )
  }

  func testDrawPointillismRegion_withValidImage_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawPointillismRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      radius: 8
    )
  }

  func testDrawHalftoneRegion_withValidImage_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawHalftoneRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      width: 8
    )
  }

  func testDrawTapeRegion_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    BlurEffectRenderer.drawTapeRegion(
      in: context,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      patternSpacing: 10
    )

    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawTapeRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      patternSpacing: 10.0
    )

    BlurEffectRenderer.drawTapeRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: CGSize(width: 100, height: 100),
      sourceRegion: CGRect(x: 10, y: 10, width: 80, height: 80),
      destRegion: CGRect(x: 10, y: 10, width: 80, height: 80),
      patternSpacing: 10.0
    )
  }

  func testDrawWashiRegion_doesNotCrash() {
    guard let context = makeContext(width: 100, height: 100) else {
      XCTFail("Could not create context")
      return
    }
    BlurEffectRenderer.drawWashiRegion(
      in: context,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      patternSpacing: 10
    )

    guard let cgImage = TestImageFactory.solidColor(width: 100, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100))
    BlurEffectRenderer.drawWashiRegion(
      in: context,
      sourceImage: nsImage,
      region: CGRect(x: 10, y: 10, width: 80, height: 80),
      patternSpacing: 10.0
    )

    BlurEffectRenderer.drawWashiRegion(
      in: context,
      sourceCGImage: cgImage,
      sourceSize: CGSize(width: 100, height: 100),
      sourceRegion: CGRect(x: 10, y: 10, width: 80, height: 80),
      destRegion: CGRect(x: 10, y: 10, width: 80, height: 80),
      patternSpacing: 10.0
    )
  }

  func testDefaultPixelSize_isPositive() {
    XCTAssertGreaterThan(BlurEffectRenderer.defaultPixelSize, 0)
  }

  func testDefaultGaussianRadius_isPositive() {
    XCTAssertGreaterThan(BlurEffectRenderer.defaultGaussianRadius, 0)
  }
}
