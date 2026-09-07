import AppKit
import XCTest
@testable import ShotPaste

@MainActor
final class InlineEditableSettingFieldTests: XCTestCase {
  func testFinishingEditingImmediatelyDisplaysSavedValue() {
    assertFinishingEditing(displays: "new-model")
  }

  func testCancellingEditingImmediatelyRestoresStoredValue() {
    assertFinishingEditing(displays: "old-model")
  }

  private func assertFinishingEditing(displays value: String) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 32))
    window.contentView?.addSubview(field)
    field.stringValue = "old-model"
    field.isEditable = true
    XCTAssertTrue(window.makeFirstResponder(field))
    guard let editor = field.currentEditor() else {
      XCTFail("Expected an active AppKit field editor")
      return
    }
    editor.string = "new-model"

    LeftAlignedAppKitField.update(field, text: value, isEditing: false)

    XCTAssertNil(field.currentEditor())
    XCTAssertFalse(field.isEditable)
    XCTAssertEqual(field.stringValue, value)
    window.makeFirstResponder(nil)
  }
}
