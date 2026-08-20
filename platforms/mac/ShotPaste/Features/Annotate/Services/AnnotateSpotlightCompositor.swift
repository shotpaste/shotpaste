//
//  AnnotateSpotlightCompositor.swift
//  ShotPaste
//
//  Composits spotlight overlay using CGContext and even-odd fill.
//

import AppKit
import CoreGraphics

struct SpotlightRegion {
  let rect: CGRect
  let cornerRadius: CGFloat
}

nonisolated enum SpotlightCompositor {
  /// Darken canvasRect except the union of spotlight regions.
  static func drawOverlay(
    regions: [SpotlightRegion], // committed spotlight items (canvas coord space)
    previewRegion: SpotlightRegion?, // in-progress drag rect; nil for export
    canvasRect: CGRect, // effective/cropped visible bounds, same coord space
    in context: CGContext
  ) {
    let holes = regions + (previewRegion.map { [$0] } ?? [])
    guard !holes.isEmpty else { return }

    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    context.setFillColor(NSColor.black.withAlphaComponent(AnnotationProperties.spotlightOverlayOpacity).cgColor)
    context.fill(canvasRect)

    context.setBlendMode(.clear)
    for h in holes {
      let rr = h.rect.standardized
      let radius = min(h.cornerRadius, min(rr.width, rr.height) / 2)
      let path = CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil)
      context.addPath(path)
      context.fillPath()
    }

    context.endTransparencyLayer()
    context.restoreGState()
  }
}
