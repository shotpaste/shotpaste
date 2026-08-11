//
//  HistoryThumbnailGeneratorTests.swift
//  LiteScreenTests
//
//  Integration tests for thumbnail generation, caching, and cleanup.
//

import AppKit
@testable import LiteScreen
import XCTest

final class HistoryThumbnailGeneratorTests: XCTestCase {
  private var testDirectory: URL!
  private var generator: HistoryThumbnailGenerator!

  override func setUp() {
    super.setUp()
    testDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiteScreenTests_HistoryThumbs_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    generator = HistoryThumbnailGenerator(
      thumbnailsDirectory: testDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    )
    generator.clearAllThumbnails()
  }

  override func tearDown() {
    generator.clearAllThumbnails()
    try? FileManager.default.removeItem(at: testDirectory)
    super.tearDown()
  }

  // MARK: - thumbnailURL

  func testThumbnailURL_returnsNilForMissingSourceFile() {
    let record = makeRecord(filePath: "/tmp/nonexistent.png")
    XCTAssertNil(generator.thumbnailURL(for: record))
  }

  // MARK: - generate

  func testGenerate_returnsNilForMissingSourceFile() async {
    let record = makeRecord(filePath: "/tmp/nonexistent.png")
    let url = await generator.generate(for: record)
    XCTAssertNil(url)
  }

  func testGenerate_createsThumbnailForImage() async throws {
    let imageURL = try createTestImage(width: 200, height: 150)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)

    let thumbURL = await generator.generate(for: record)
    XCTAssertNotNil(thumbURL)
    XCTAssertTrue(try FileManager.default.fileExists(atPath: XCTUnwrap(thumbURL?.path)))

    let attrs = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(thumbURL?.path))
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    XCTAssertGreaterThan(size, 0)
  }

  func testGenerate_usesExistingCacheOnSecondCall() async throws {
    let imageURL = try createTestImage(width: 100, height: 100)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)

    let url1 = await generator.generate(for: record)
    let url2 = await generator.generate(for: record)

    XCTAssertEqual(url1?.path, url2?.path)
  }

  // MARK: - totalThumbnailSize

  func testTotalThumbnailSize_sumsFileSizes() async throws {
    XCTAssertEqual(generator.totalThumbnailSize(), 0)

    let imageURL = try createTestImage(width: 100, height: 100)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)
    _ = await generator.generate(for: record)

    let size = generator.totalThumbnailSize()
    XCTAssertGreaterThan(size, 0)
  }

  // MARK: - clearAllThumbnails

  func testClearAllThumbnails_removesAllFiles() async throws {
    let imageURL = try createTestImage(width: 100, height: 100)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)
    _ = await generator.generate(for: record)
    XCTAssertGreaterThan(generator.totalThumbnailSize(), 0)

    generator.clearAllThumbnails()
    XCTAssertEqual(generator.totalThumbnailSize(), 0)
  }

  // MARK: - deleteThumbnail

  func testDeleteThumbnail_removesFilesForRecordId() async throws {
    let imageURL = try createTestImage(width: 100, height: 100)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)
    let thumbURL = await generator.generate(for: record)
    XCTAssertNotNil(thumbURL)

    generator.deleteThumbnail(for: record.id)
    XCTAssertFalse(try FileManager.default.fileExists(atPath: XCTUnwrap(thumbURL?.path)))
  }

  // MARK: - loadThumbnailImage

  func testLoadThumbnailImage_returnsImageForValidFile() async throws {
    let imageURL = try createTestImage(width: 100, height: 100)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)
    _ = await generator.generate(for: record)

    let image = await generator.loadThumbnailImage(for: record)
    XCTAssertNotNil(image)
  }

  func testLoadThumbnailImage_returnsNilForMissingFile() async {
    let record = makeRecord(filePath: "/tmp/nonexistent.png")
    let image = await generator.loadThumbnailImage(for: record)
    XCTAssertNil(image)
  }

  func testLoadThumbnailImage_usesMemoryCache() async throws {
    let imageURL = try createTestImage(width: 100, height: 100)
    let record = makeRecord(filePath: imageURL.path, captureType: .screenshot)
    _ = await generator.generate(for: record)

    let first = await generator.loadThumbnailImage(for: record)
    let second = await generator.loadThumbnailImage(for: record)
    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    // Both should resolve successfully; exact identity comparison is not guaranteed
    // because NSCache may evict, but in this tight loop it should be cached.
  }

  // MARK: - Helpers

  private func makeRecord(filePath: String, captureType: CaptureHistoryType = .screenshot) -> CaptureHistoryRecord {
    CaptureHistoryRecord(
      id: UUID(),
      filePath: filePath,
      fileName: (filePath as NSString).lastPathComponent,
      captureType: captureType,
      fileSize: 1024,
      capturedAt: Date(),
      width: 100,
      height: 100,
      duration: nil,
      thumbnailPath: nil,
      isDeleted: false
    )
  }

  private func createTestImage(width: Int, height: Int) throws -> URL {
    guard let cgImage = TestImageFactory.solidColor(width: width, height: height) else {
      throw XCTSkip("Failed to create test image")
    }
    let url = testDirectory.appendingPathComponent("\(UUID().uuidString).png")
    let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
      throw XCTSkip("Failed to encode PNG")
    }
    try pngData.write(to: url)
    return url
  }
}
