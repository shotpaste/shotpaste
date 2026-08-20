//
//  ScrollingCapturePreviewView.swift
//  ShotPaste
//
//  Geometry for the lightweight scrolling-capture preview rail.
//

import CoreGraphics

enum ScrollingCapturePreviewLayout {
  static let maximumPreviewWidth: CGFloat = 320
  static let maximumPreviewHeight: CGFloat = 760
  static let minimumAvailableHeight: CGFloat = 160
  static let anchorGap: CGFloat = 12
  static let screenInset: CGFloat = 12

  // Preserve the current branch's proven preview workload while the window
  // adopts the taller scroll-rebuild rail geometry.
  static let renderPixelWidth = 440
  static let renderPixelHeight = 840

  static func previewSize(
    for image: CGImage,
    anchorRect: CGRect,
    visibleFrame: CGRect
  ) -> CGSize {
    guard image.width > 0, image.height > 0 else { return .zero }

    let preferredWidth = min(
      maximumPreviewWidth,
      max(1, anchorRect.width * 0.56)
    )
    let heightAboveAnchorBottom = visibleFrame.maxY - anchorRect.minY - screenInset
    let heightLimit = min(
      maximumPreviewHeight,
      max(
        minimumAvailableHeight,
        min(visibleFrame.height - screenInset * 2, heightAboveAnchorBottom)
      )
    )
    let scale = min(
      preferredWidth / CGFloat(image.width),
      heightLimit / CGFloat(image.height)
    )

    return CGSize(
      width: max(1, (CGFloat(image.width) * scale).rounded(.up)),
      height: max(1, (CGFloat(image.height) * scale).rounded(.up))
    )
  }
}
