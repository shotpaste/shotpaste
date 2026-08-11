//
//  AreaSelectionBackdrop.swift
//  ShotPaste
//
//  Shared models for area selection backdrops and results.
//

import CoreGraphics
import Foundation

nonisolated struct AreaSelectionBackdrop {
  let displayID: CGDirectDisplayID
  let image: CGImage
  let scaleFactor: CGFloat
  let isVisible: Bool

  init(displayID: CGDirectDisplayID, image: CGImage, scaleFactor: CGFloat, isVisible: Bool = true) {
    self.displayID = displayID
    self.image = image
    self.scaleFactor = scaleFactor
    self.isVisible = isVisible
  }
}

nonisolated struct AreaSelectionResult {
  let rect: CGRect
  let displayID: CGDirectDisplayID
  let displayIDs: Set<CGDirectDisplayID>

  init(
    rect: CGRect,
    displayID: CGDirectDisplayID,
    displayIDs: Set<CGDirectDisplayID>? = nil
  ) {
    self.rect = rect
    self.displayID = displayID
    self.displayIDs = displayIDs ?? [displayID]
  }

  var spansMultipleDisplays: Bool {
    displayIDs.count > 1
  }
}
