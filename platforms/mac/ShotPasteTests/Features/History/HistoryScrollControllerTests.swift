import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class HistoryScrollControllerTests: XCTestCase {
  // Keep these synchronous: an async XCTest task masks the Swift 6.2
  // isolated-deinit back-deployment crash seen during SwiftUI teardown.
  func testControllerCanBeReleasedSynchronously() {
    weak var released: HistoryScrollController?
    autoreleasepool {
      var controller: HistoryScrollController? = HistoryScrollController()
      released = controller
      XCTAssertNotNil(released)
      controller = nil
    }
    XCTAssertNil(released)
  }

  func testReaderCoordinatorCanBeReleasedSynchronously() {
    let controller = HistoryScrollController()
    weak var released: HistoryScrollViewReader.Coordinator?
    autoreleasepool {
      var coordinator: HistoryScrollViewReader.Coordinator? = HistoryScrollViewReader(
        controller: controller
      ).makeCoordinator()
      released = coordinator
      XCTAssertNotNil(released)
      coordinator = nil
    }
    XCTAssertNil(released)
  }

  func testSearchModelCanBeReleasedSynchronously() {
    weak var released: HistorySearchViewModel?
    autoreleasepool {
      var model: HistorySearchViewModel? = HistorySearchViewModel()
      released = model
      XCTAssertNotNil(released)
      model = nil
    }
    XCTAssertNil(released)
  }
}
