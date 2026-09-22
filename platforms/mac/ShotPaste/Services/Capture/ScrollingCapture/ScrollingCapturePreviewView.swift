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

  /// Bound the canvas viewport at the same aspect ratio as the available rail.
  /// The canvas already follows the newest growth edge; clipping there avoids
  /// fitting an ever-taller thumbnail into a shorter window and shrinking its
  /// text as the capture grows.
  static func renderPixelBounds(
    imagePixelWidth: Int,
    anchorRect: CGRect,
    visibleFrame: CGRect
  ) -> (width: Int, height: Int) {
    let availableSize = availableSize(anchorRect: anchorRect, visibleFrame: visibleFrame)
    let width = min(renderPixelWidth, max(1, imagePixelWidth))
    let height = Int((availableSize.height * CGFloat(width) / availableSize.width).rounded(.down))
    return (width, min(renderPixelHeight, max(1, height)))
  }

  static func previewSize(
    for image: CGImage,
    anchorRect: CGRect,
    visibleFrame: CGRect
  ) -> CGSize {
    guard image.width > 0, image.height > 0 else { return .zero }

    let availableSize = availableSize(anchorRect: anchorRect, visibleFrame: visibleFrame)
    let scale = min(
      availableSize.width / CGFloat(image.width),
      availableSize.height / CGFloat(image.height)
    )

    return CGSize(
      width: max(1, (CGFloat(image.width) * scale).rounded(.up)),
      height: max(1, (CGFloat(image.height) * scale).rounded(.up))
    )
  }

  private static func availableSize(anchorRect: CGRect, visibleFrame: CGRect) -> CGSize {
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
    return CGSize(width: preferredWidth, height: heightLimit)
  }
}
