import Foundation
@testable import ShotPaste
import XCTest

final class ErrorPermissionDeniedTests: XCTestCase {
  func testCocoaReadPermissionError() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    XCTAssertTrue(error.isPermissionDenied)
  }

  func testCocoaWritePermissionError() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    XCTAssertTrue(error.isPermissionDenied)
  }

  func testPosixEacces() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
    XCTAssertTrue(error.isPermissionDenied)
  }

  func testPosixEperm() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    XCTAssertTrue(error.isPermissionDenied)
  }

  func testNonPermissionError() {
    let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    XCTAssertFalse(error.isPermissionDenied)
  }

  func testUnrelatedDomain() {
    let error = NSError(domain: "com.example.custom", code: 42)
    XCTAssertFalse(error.isPermissionDenied)
  }
}
