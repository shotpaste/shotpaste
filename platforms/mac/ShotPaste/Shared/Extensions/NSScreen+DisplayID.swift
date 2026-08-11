//
//  NSScreen+DisplayID.swift
//  ShotPaste
//

import AppKit

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    return CGDirectDisplayID(screenNumber.uint32Value)
  }
}
