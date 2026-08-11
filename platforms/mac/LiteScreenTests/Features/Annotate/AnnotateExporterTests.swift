//
//  AnnotateExporterTests.swift
//  LiteScreenTests
//
//  Unit tests for AnnotateExporter image scale and encoding helpers.
//

import AppKit
@testable import LiteScreen
import XCTest

@MainActor
final class AnnotateExporterTests: XCTestCase {
  // MARK: - sourceImageScale / bestCGImage

  func testBestCGImage_extractsFromNSImage() {
    guard let cgImage = TestImageFactory.solidColor(width: 200, height: 100) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 100))
    let extracted = AnnotateExporter.bestCGImage(from: nsImage)
    XCTAssertNotNil(extracted)
    XCTAssertEqual(extracted?.width, 200)
    XCTAssertEqual(extracted?.height, 100)
  }

  func testSourceImageScale_retinaImage() {
    guard let cgImage = TestImageFactory.solidColor(width: 400, height: 400) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
    // sourceImageScale is private; we test indirectly via bestCGImage + size
    XCTAssertEqual(AnnotateExporter.bestCGImage(from: nsImage)?.width, 400)
  }

  // MARK: - imageData

  func testImageData_pngEncoding() {
    guard let cgImage = TestImageFactory.solidColor(width: 10, height: 10) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 10, height: 10))
    let data = AnnotateExporter.imageData(from: nsImage, for: "png")
    XCTAssertNotNil(data)
    XCTAssertGreaterThan(data?.count ?? 0, 0)
  }

  func testImageData_jpegEncoding() {
    guard let cgImage = TestImageFactory.solidColor(width: 10, height: 10) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 10, height: 10))
    let data = AnnotateExporter.imageData(from: nsImage, for: "jpg")
    XCTAssertNotNil(data)
    XCTAssertGreaterThan(data?.count ?? 0, 0)
  }

  func testImageData_unknownExtension_fallsBackToPNG() {
    guard let cgImage = TestImageFactory.solidColor(width: 10, height: 10) else {
      XCTFail("Failed to create test image")
      return
    }
    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 10, height: 10))
    let data = AnnotateExporter.imageData(from: nsImage, for: "xyz")
    XCTAssertNotNil(data)
    XCTAssertGreaterThan(data?.count ?? 0, 0)
  }

  func testImageData_nilImage_returnsNil() {
    let empty = NSImage(size: NSSize(width: 0, height: 0))
    let data = AnnotateExporter.imageData(from: empty, for: "png")
    XCTAssertNil(data)
  }
}
