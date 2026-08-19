import CoreVideo
@testable import ShotPaste
import XCTest

final class ScrollingCaptureFrameSourceTests: XCTestCase {
  func testSampledSignatureIsStableAndChangesWithPixels() throws {
    let buffer = try makePixelBuffer(width: 8, height: 8)
    fill(buffer, value: 12)
    let first = try XCTUnwrap(ScrollingCaptureFrameSource.sampledSignature(of: buffer))
    XCTAssertEqual(first, ScrollingCaptureFrameSource.sampledSignature(of: buffer))

    try mutatePixel(buffer, x: 4, y: 4, blue: 220)
    let changed = try XCTUnwrap(ScrollingCaptureFrameSource.sampledSignature(of: buffer))
    XCTAssertNotEqual(first, changed)
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      nil,
      &buffer
    )
    XCTAssertEqual(status, kCVReturnSuccess)
    return try XCTUnwrap(buffer)
  }

  private func fill(_ buffer: CVPixelBuffer, value: UInt8) {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
      XCTFail("Missing pixel-buffer base address")
      return
    }
    memset(base, Int32(value), CVPixelBufferGetDataSize(buffer))
  }

  private func mutatePixel(
    _ buffer: CVPixelBuffer,
    x: Int,
    y: Int,
    blue: UInt8
  ) throws {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
      .assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    base[offset] = blue
  }
}
