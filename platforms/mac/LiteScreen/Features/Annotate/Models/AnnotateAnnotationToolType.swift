//
//  AnnotateAnnotationToolType.swift
//  LiteScreen
//
//  Enum defining all available annotation tools
//

import Foundation

/// Tool types available in annotation editor
nonisolated enum AnnotationToolType: String, CaseIterable, Identifiable {
  case selection
  case crop
  case rectangle
  case filledRectangle
  case oval
  case arrow
  case line
  case text
  case highlighter
  case blur
  case spotlight
  case counter
  case watermark
  case pencil
  case mockup

  var id: String {
    rawValue
  }

  /// The only capture annotation surface is One Shot. Keep this fixed order in
  /// sync with Windows.
  static let oneShotToolGroups: [[AnnotationToolType]] = [
    [.selection],
    [.rectangle, .filledRectangle, .oval, .arrow, .line],
    [.text, .highlighter, .blur, .spotlight, .counter, .pencil],
  ]

  var icon: String {
    switch self {
    case .selection: "cursorarrow"
    case .crop: "crop"
    case .rectangle: "rectangle"
    case .filledRectangle: "rectangle.fill"
    case .oval: "circle"
    case .arrow: "arrow.up.right"
    case .line: "line.diagonal"
    case .text: "t.square"
    case .highlighter: "highlighter"
    case .blur: "square.grid.3x3.fill"
    case .spotlight: "viewfinder"
    case .counter: "list.number"
    case .watermark: "seal"
    case .pencil: "pencil"
    case .mockup: "cube.transparent"
    }
  }

  /// Display name for the tool
  var displayName: String {
    switch self {
    case .selection: L10n.Annotate.selectionTool
    case .crop: L10n.Annotate.cropTool
    case .rectangle: L10n.Annotate.rectangleTool
    case .filledRectangle: L10n.Annotate.filledRectangleTool
    case .oval: L10n.Annotate.ovalTool
    case .arrow: L10n.Annotate.arrowTool
    case .line: L10n.Annotate.lineTool
    case .text: L10n.Annotate.textTool
    case .highlighter: L10n.Annotate.highlighterTool
    case .blur: L10n.Annotate.blurTool
    case .spotlight: L10n.Annotate.spotlightTool
    case .counter: L10n.Annotate.counterTool
    case .watermark: L10n.Annotate.watermarkTool
    case .pencil: L10n.Annotate.pencilTool
    case .mockup: L10n.Annotate.mockupTool
    }
  }

  var supportsQuickPropertiesBar: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .text, .highlighter, .blur, .spotlight, .counter,
         .watermark, .pencil:
      true
    case .selection, .crop, .mockup:
      false
    }
  }

  /// Drawable tools that should only commit a new blank-canvas item after a
  /// drag intent. Counter stays click-to-place, text keeps its click-to-edit
  /// flow, and freehand tools keep their existing path-count behavior.
  var requiresDragToCreateAnnotation: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .blur, .spotlight, .watermark:
      true
    case .selection, .crop, .text, .highlighter, .counter, .pencil, .mockup:
      false
    }
  }

  var supportsQuickStrokeColor: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .text, .highlighter, .counter, .watermark, .pencil:
      true
    case .selection, .crop, .blur, .spotlight, .mockup:
      false
    }
  }

  var supportsQuickFillColor: Bool {
    false
  }

  var supportsQuickStrokeWidth: Bool {
    switch self {
    case .rectangle, .filledRectangle, .oval, .arrow, .line, .highlighter, .blur, .counter, .pencil:
      true
    case .selection, .crop, .text, .watermark, .spotlight, .mockup:
      false
    }
  }

  var supportsQuickCornerRadius: Bool {
    switch self {
    case .rectangle, .filledRectangle, .text, .spotlight:
      true
    case .selection, .crop, .oval, .arrow, .line, .highlighter, .blur, .counter, .watermark, .pencil, .mockup:
      false
    }
  }
}
