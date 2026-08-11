//
//  AnnotateSpotlightCompositor.swift
//  LiteScreen
//
//  Composits spotlight overlay using CGContext and even-odd fill.
//

import AppKit
import CoreGraphics

struct SpotlightRegion {
  let rect: CGRect
  let cornerRadius: CGFloat
  let opacity: CGFloat // darkness strength, clamped 0.1...0.9
}

nonisolated enum SpotlightCompositor {
  /// Darken canvasRect except the union of spotlight regions. Opacity is sourced from regions themselves,
  /// so per-item slider changes reflect immediately without a global state sync cycle.
  static func drawOverlay(
    regions: [SpotlightRegion], // committed spotlight items (canvas coord space)
    previewRegion: SpotlightRegion?, // in-progress drag rect; nil for export
    canvasRect: CGRect, // effective/cropped visible bounds, same coord space
    in context: CGContext
  ) {
    let holes = regions + (previewRegion.map { [$0] } ?? [])
    guard !holes.isEmpty else { return }

    // All regions share a single global opacity (per design). Source from first committed region;
    // fall back to preview region when no committed regions exist yet (first drag).
    let opacity = (regions.first ?? previewRegion)?.opacity ?? 0.5
    guard opacity > 0 else { return }

    context.saveGState()
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    context.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
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
