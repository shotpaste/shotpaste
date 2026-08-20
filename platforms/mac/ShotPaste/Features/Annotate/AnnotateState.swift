//
//  AnnotateState.swift
//  ShotPaste
//
//  Central state management for annotation window
//

import AppKit
import Combine
import SwiftUI

/// Central state for annotation window
@MainActor
final class AnnotateState: ObservableObject {
  private struct AnnotationSnapshot {
    var annotations: [AnnotationItem]
  }

  private struct TextEditingUndoTransaction {
    let annotationId: UUID
    let snapshotBeforeEdit: AnnotationSnapshot
    let originalText: String
    var didRecordUndo: Bool = false
  }

  private struct SharedAnnotationParameterDefaults: Codable {
    var strokeWidth: CGFloat?
    var cornerRadius: CGFloat?
    var fontSize: CGFloat?
    var spotlightCornerRadius: CGFloat?
    var arrowStyle: String?
    var arrowType: String?
    var arrowBendDirection: String?
    var arrowStartHead: String?
    var arrowEndHead: String?
  }

  private let defaults: UserDefaults

  // MARK: - Source Image

  @Published var sourceImage: NSImage?

  // MARK: - Tool State

  @Published var selectedTool: AnnotationToolType = .selection {
    didSet { syncActiveToolProperties() }
  }

  @Published var strokeWidth: CGFloat = 3
  @Published var strokeColor: Color = .red
  @Published var rectangleCornerRadius: CGFloat = 0
  @Published var blurType: BlurType = .pixelated
  @Published var arrowStyle: ArrowStyle = .straight
  @Published var arrowType: ArrowType = .tapered
  @Published var arrowBendDirection: ArrowBendDirection = .primary
  @Published var arrowStartHead: ArrowEndpointStyle = .none
  @Published var arrowEndHead: ArrowEndpointStyle = .arrow
  private var isQuickPropertiesGestureEditing = false
  private var quickPropertiesGestureUndoSnapshot: AnnotationSnapshot?
  private var sharedAnnotationColor: Color?
  private var sharedAnnotationParameterDefaults = SharedAnnotationParameterDefaults()
  /// New text starts as a natural-width line. Resizing it switches that item
  /// to a fixed width so deliberate wrapping is never overwritten while typing.
  private var autoSizingTextAnnotationIDs: Set<UUID> = []

  enum QuickPropertiesMode: Equatable {
    case hidden
    case toolDefaults
    case selectedItem
  }

  // MARK: - UI State

  @Published var zoomLevel: CGFloat = 1.0

  static let minimumZoomLevel: CGFloat = 0.25
  static let defaultMaximumZoomLevel: CGFloat = 4.0
  static let hardMaximumZoomLevel: CGFloat = 16.0
  static let zoomPresetPercents = [25, 50, 75, 100, 125, 150, 200, 300, 400, 600, 800, 1200, 1600]

  /// Base fitted canvas size before zoom is applied.
  @Published private(set) var baseCanvasDisplaySize: CGSize = .zero

  /// Fit scale used to derive a dynamic max zoom for very long captures.
  @Published private(set) var fitScale: CGFloat = 1.0

  var effectiveMaximumZoomLevel: CGFloat {
    guard fitScale > 0 else { return Self.defaultMaximumZoomLevel }
    return min(Self.hardMaximumZoomLevel, max(Self.defaultMaximumZoomLevel, 1.0 / fitScale))
  }

  var effectiveZoomRange: ClosedRange<CGFloat> {
    Self.minimumZoomLevel ... effectiveMaximumZoomLevel
  }

  var currentDisplayedZoomPercent: Int {
    Int((fitScale * zoomLevel * 100).rounded())
  }

  var zoomMenuPresetPercents: [Int] {
    let maxDisplayedPercent = max(
      25,
      Int((effectiveMaximumZoomLevel * fitScale * 100).rounded(.down) / 25) * 25
    )

    var options = Self.zoomPresetPercents.filter {
      $0 <= maxDisplayedPercent
    }

    if maxDisplayedPercent > (options.last ?? 0) {
      options.append(maxDisplayedPercent)
    }

    return options
  }

  func zoomLevel(forDisplayedPercent percent: Int) -> CGFloat {
    let normalizedFitScale = max(fitScale, 0.0001)
    return clampedZoom(CGFloat(percent) / 100 / normalizedFitScale)
  }

  /// Clamp a zoom level to the valid range
  func clampedZoom(_ level: CGFloat) -> CGFloat {
    min(max(level, effectiveZoomRange.lowerBound), effectiveZoomRange.upperBound)
  }

  func setZoomLevel(_ level: CGFloat) {
    zoomLevel = clampedZoom(level)
    resetPanIfNeeded()
  }

  func setDisplayedZoomPercent(_ percent: Int) {
    setZoomLevel(zoomLevel(forDisplayedPercent: percent))
  }

  func zoomIn() {
    let currentPercent = currentDisplayedZoomPercent
    if let nextPercent = zoomMenuPresetPercents.first(where: { $0 > currentPercent }) {
      setDisplayedZoomPercent(nextPercent)
    } else {
      setZoomLevel(zoomLevel * 1.25)
    }
  }

  func zoomOut() {
    let currentPercent = currentDisplayedZoomPercent
    if let previousPercent = zoomMenuPresetPercents.last(where: { $0 < currentPercent }) {
      setDisplayedZoomPercent(previousPercent)
    } else {
      setZoomLevel(zoomLevel / 1.25)
    }
  }

  func fitCanvasToViewport() {
    zoomLevel = 1
    panOffset = .zero
    isCanvasPanningMode = false
    isSpacePanning = false
  }

  // MARK: - Pan State (for zoomed canvas navigation)

  /// Viewport pan offset (points). Applied alongside scaleEffect.
  @Published var panOffset: CGSize = .zero

  /// Keeps the canvas in a direct manipulation mode while the hand button is active.
  @Published var isCanvasPanningMode = false

  /// Whether Space key is currently held (hand tool active)
  @Published var isSpacePanning: Bool = false

  /// Canvas container size for pan bounds calculation (updated by GeometryReader)
  var canvasContainerSize: CGSize = .zero

  var canPanInteractively: Bool {
    let overflow = panOverflow(at: zoomLevel)
    return overflow.width > 0.5 || overflow.height > 0.5
  }

  func updateViewportMetrics(containerSize: CGSize, baseCanvasSize: CGSize, fitScale: CGFloat) {
    let normalizedFitScale = max(fitScale, 0.0001)
    let metricsChanged = canvasContainerSize != containerSize
      || baseCanvasDisplaySize != baseCanvasSize
      || abs(self.fitScale - normalizedFitScale) > 0.0001

    canvasContainerSize = containerSize
    if baseCanvasDisplaySize != baseCanvasSize {
      baseCanvasDisplaySize = baseCanvasSize
    }
    if abs(self.fitScale - normalizedFitScale) > 0.0001 {
      self.fitScale = normalizedFitScale
    }

    guard metricsChanged else { return }

    let clampedLevel = clampedZoom(zoomLevel)
    if abs(clampedLevel - zoomLevel) > 0.0001 {
      zoomLevel = clampedLevel
    } else {
      resetPanIfNeeded()
    }
  }

  func pan(by delta: CGSize) {
    guard canPanInteractively else {
      panOffset = .zero
      return
    }

    panOffset.width += delta.width
    panOffset.height += delta.height
    clampPanOffset()
  }

  /// Reset pan when content no longer overflows.
  func resetPanIfNeeded() {
    if !canPanInteractively {
      panOffset = .zero
      isCanvasPanningMode = false
    } else {
      clampPanOffset()
    }
  }

  /// Clamp pan offset to keep content partially visible.
  /// At least ~40% of the canvas remains in the viewport at all times.
  func clampPanOffset() {
    let overflow = panOverflow(at: zoomLevel)
    guard overflow.width > 0 || overflow.height > 0 else {
      panOffset = .zero
      return
    }

    let marginX = overflow.width > 0 ? canvasContainerSize.width * 0.1 : 0
    let marginY = overflow.height > 0 ? canvasContainerSize.height * 0.1 : 0
    let maxPanX = overflow.width + marginX
    let maxPanY = overflow.height + marginY

    panOffset.width = min(max(panOffset.width, -maxPanX), maxPanX)
    panOffset.height = min(max(panOffset.height, -maxPanY), maxPanY)
  }

  private func panOverflow(at zoomLevel: CGFloat) -> CGSize {
    guard canvasContainerSize.width > 0,
          canvasContainerSize.height > 0,
          baseCanvasDisplaySize.width > 0,
          baseCanvasDisplaySize.height > 0 else {
      return .zero
    }

    let renderedWidth = baseCanvasDisplaySize.width * zoomLevel
    let renderedHeight = baseCanvasDisplaySize.height * zoomLevel

    return CGSize(
      width: max((renderedWidth - canvasContainerSize.width) / 2, 0),
      height: max((renderedHeight - canvasContainerSize.height) / 2, 0)
    )
  }

  // MARK: - Display Metrics

  /// Default canvas size when no image loaded
  private static let defaultCanvasWidth: CGFloat = 400
  private static let defaultCanvasHeight: CGFloat = 300

  /// Original image dimensions (points, not pixels)
  var imageWidth: CGFloat {
    sourceImage?.size.width ?? Self.defaultCanvasWidth
  }

  var imageHeight: CGFloat {
    sourceImage?.size.height ?? Self.defaultCanvasHeight
  }

  var sourceImageBounds: CGRect {
    CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight))
  }

  var activeAnnotationBounds: CGRect {
    sourceImageBounds
  }

  // MARK: - Annotations

  @Published var annotations: [AnnotationItem] = [] {
    didSet {
      // Mutations outside `updateAnnotationProperties` are structural
      // (add/remove/undo/drag-commit) and can't be redrawn via dirty rects.
      if !isApplyingPropertyEdit {
        pendingFullCanvasInvalidation = true
      }
    }
  }

  /// True while `updateAnnotationProperties` applies mutations — lets the
  /// annotations observer tell property-only edits apart from structural ones.
  private var isApplyingPropertyEdit = false
  /// Image-space rects dirtied by property-only edits since the last flush.
  private var pendingPropertyEditRects: [CGRect] = []
  /// Set when a mutation can't be served by dirty rects (structural change, or
  /// a property affecting full-canvas layers such as spotlight dimming).
  private var pendingFullCanvasInvalidation = false

  /// Drains pending invalidation info for the canvas view. Scoped dirty rects
  /// let property slider drags redraw only the edited annotation instead of
  /// every layer in full bounds (see issue #335).
  func consumePendingCanvasInvalidation() -> (rects: [CGRect], needsFullRedraw: Bool) {
    defer {
      pendingPropertyEditRects.removeAll()
      pendingFullCanvasInvalidation = false
    }
    return (pendingPropertyEditRects, pendingFullCanvasInvalidation)
  }

  private var isSynchronizingSelection = false
  @Published var selectedAnnotationId: UUID? {
    didSet {
      guard !isSynchronizingSelection else { return }
      selectedAnnotationIds = selectedAnnotationId.map { Set([$0]) } ?? []
    }
  }

  @Published private(set) var selectedAnnotationIds: Set<UUID> = []
  @Published var editingTextAnnotationId: UUID? {
    didSet {
      if editingTextAnnotationId == nil {
        textEditingUndoTransaction = nil
      }
    }
  }

  // MARK: - Counter Tool State (derived from annotations, not stored)

  // MARK: - Unsaved Changes Tracking

  /// Whether canvas has modifications not yet saved to disk
  @Published var hasUnsavedChanges: Bool = false

  // MARK: - Undo/Redo

  @Published var canUndo: Bool = false
  @Published var canRedo: Bool = false

  private var undoStack: [AnnotationSnapshot] = []
  private var redoStack: [AnnotationSnapshot] = []
  private var textEditingUndoTransaction: TextEditingUndoTransaction?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    sourceImage = nil
    loadSharedAnnotationColor()
    loadSharedAnnotationParameterDefaults()
  }

  // MARK: - Image Loading

  /// Load image directly
  func loadImage(_ image: NSImage) {
    DiagnosticLogger.shared.log(.info, .annotate, "Loading image directly", context: [
      "size": "\(Int(image.size.width))x\(Int(image.size.height))",
    ])
    resetCanvasForNewBaseImage(image: image)
  }

  /// Replace the backing screenshot while keeping editable annotations.
  /// Used by inline area annotate when the selected region moves or resizes.
  func replaceSourceImagePreservingAnnotations(_ image: NSImage, annotationOffset: CGPoint = .zero) {
    sourceImage = image
    if annotationOffset != .zero {
      translateAnnotations(dx: annotationOffset.x, dy: annotationOffset.y)
    }
  }

  /// Freeze every render input into a value-type snapshot so final-image rendering can run
  /// off the main actor.
  func makeRenderSnapshot() -> AnnotateRenderSnapshot? {
    guard let sourceImage else { return nil }
    return AnnotateRenderSnapshot(sourceImage: sourceImage, annotations: annotations)
  }

  private func resetCanvasForNewBaseImage(image: NSImage) {
    sourceImage = image
    // Reset annotations for new image
    annotations.removeAll()
    selectedAnnotationId = nil
    editingTextAnnotationId = nil
    undoStack.removeAll()
    redoStack.removeAll()
    canUndo = false
    canRedo = false

    hasUnsavedChanges = false
  }

  // MARK: - Undo/Redo Methods

  /// Bounds undo memory; per-tick slider snapshots previously grew the stack
  /// without limit during a single drag (see issue #335).
  private static let maxUndoStackSize = 50

  func saveState() {
    pushUndoSnapshot(currentSnapshot(), annotationCount: annotations.count)
  }

  private func pushUndoSnapshot(_ snapshot: AnnotationSnapshot, annotationCount: Int) {
    DiagnosticLogger.shared.log(.debug, .annotate, "Undo checkpoint", context: ["annotations": "\(annotationCount)"])
    undoStack.append(snapshot)
    capUndoStack()
    redoStack.removeAll()
    canUndo = true
    canRedo = false
    hasUnsavedChanges = true
  }

  private func capUndoStack() {
    if undoStack.count > Self.maxUndoStackSize {
      undoStack.removeFirst(undoStack.count - Self.maxUndoStackSize)
    }
  }

  func undo() {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    DiagnosticLogger.shared.log(.debug, .annotate, "Undo", context: ["stackDepth": "\(undoStack.count)"])
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(currentSnapshot())
    applySnapshot(previous)
    canUndo = !undoStack.isEmpty
    canRedo = true
  }

  func redo() {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    DiagnosticLogger.shared.log(.debug, .annotate, "Redo", context: ["stackDepth": "\(redoStack.count)"])
    guard let next = redoStack.popLast() else { return }
    undoStack.append(currentSnapshot())
    applySnapshot(next)
    canUndo = true
    canRedo = !redoStack.isEmpty
  }

  private func currentSnapshot() -> AnnotationSnapshot {
    AnnotationSnapshot(annotations: annotations)
  }

  func beginTextEditing(id: UUID, recordsUndo: Bool = true) {
    if let activeId = editingTextAnnotationId, activeId != id {
      commitTextEditing()
    }

    if recordsUndo,
       let annotation = annotations.first(where: { $0.id == id }),
       case .text(let text) = annotation.type {
      textEditingUndoTransaction = TextEditingUndoTransaction(
        annotationId: id,
        snapshotBeforeEdit: currentSnapshot(),
        originalText: text
      )
    } else {
      textEditingUndoTransaction = nil
    }

    editingTextAnnotationId = id
  }

  func useAutomaticTextWidth(for id: UUID) {
    guard let annotation = annotations.first(where: { $0.id == id }),
          case .text = annotation.type else { return }
    autoSizingTextAnnotationIDs.insert(id)
  }

  func finishTextEditing() {
    editingTextAnnotationId = nil
  }

  private func recordTextEditingUndoIfNeeded(id: UUID, newText: String) {
    guard var transaction = textEditingUndoTransaction,
          transaction.annotationId == id,
          !transaction.didRecordUndo,
          transaction.originalText != newText else { return }

    pushUndoSnapshot(
      transaction.snapshotBeforeEdit,
      annotationCount: transaction.snapshotBeforeEdit.annotations.count
    )
    transaction.didRecordUndo = true
    textEditingUndoTransaction = transaction
  }

  private func applySnapshot(_ snapshot: AnnotationSnapshot) {
    annotations = snapshot.annotations

    let validAnnotationIds = Set(annotations.map(\.id))
    setSelectedAnnotationIds(selectedAnnotationIds.intersection(validAnnotationIds))

    if let editingTextAnnotationId,
       !annotations.contains(where: { $0.id == editingTextAnnotationId }) {
      self.editingTextAnnotationId = nil
    }
  }

  // MARK: - Counter

  /// Derive next counter value from existing annotations.
  /// This ensures undo/redo correctly adjusts future counter values.
  func nextCounterValue() -> Int {
    let maxExisting = annotations.compactMap { annotation -> Int? in
      if case .counter(let v) = annotation.type {
        return v
      }
      return nil
    }.max() ?? 0
    return maxExisting + 1
  }

  /// Reset unsaved changes flag after successful save
  func markAsSaved() {
    hasUnsavedChanges = false
  }

  // MARK: - Annotation Selection

  var selectedAnnotations: [AnnotationItem] {
    annotations.filter { selectedAnnotationIds.contains($0.id) }
  }

  var hasSelectedAnnotations: Bool {
    !selectedAnnotationIds.isEmpty
  }

  func isAnnotationSelected(_ id: UUID) -> Bool {
    selectedAnnotationIds.contains(id)
  }

  func selectAnnotation(at point: CGPoint) -> AnnotationItem? {
    // Find annotation at point (in reverse render order to select topmost)
    for annotation in annotations.renderOrdered.reversed() {
      // Quick bounds check first (optimization)
      let expandedBounds = annotation.selectionBounds.insetBy(dx: -10, dy: -10)
      guard expandedBounds.contains(point) else { continue }

      // Precise hit test
      if annotation.containsPoint(point) {
        setSelectedAnnotationIds([annotation.id])
        return annotation
      }
    }
    deselectAnnotation()
    return nil
  }

  @discardableResult
  func selectAnnotations(in rect: CGRect) -> [AnnotationItem] {
    let selectionRect = rect.standardized
    guard selectionRect.width > 0, selectionRect.height > 0 else {
      deselectAnnotation()
      return []
    }

    let selected = annotations.filter { annotation in
      let annotationBounds = annotation.selectionBounds
      return selectionRect.intersects(annotationBounds)
        || selectionRect.contains(annotationBounds)
    }
    setSelectedAnnotationIds(Set(selected.map(\.id)))
    return selected
  }

  func setSelectedAnnotationIds(_ ids: Set<UUID>) {
    let validIds = Set(annotations.map(\.id))
    let filteredIds = ids.intersection(validIds)
    let primaryId = filteredIds.count == 1 ? filteredIds.first : nil

    isSynchronizingSelection = true
    selectedAnnotationIds = filteredIds
    selectedAnnotationId = primaryId
    isSynchronizingSelection = false
  }

  func updateAnnotationBounds(id: UUID, bounds: CGRect) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }

    let oldBounds = annotations[index].resizeBounds
    let normalizedBounds = bounds.standardized
    annotations[index] = annotations[index].applyingResizeBounds(normalizedBounds)

    if case .text = annotations[index].type,
       abs(oldBounds.width - normalizedBounds.width) > 0.5 {
      autoSizingTextAnnotationIDs.remove(id)
    }
  }

  func updateLineEndpoint(id: UUID, start newStart: CGPoint? = nil, end newEnd: CGPoint? = nil) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .line(let start, let end) = annotations[index].type else { return }

    let updatedStart = newStart ?? start
    let updatedEnd = newEnd ?? end
    annotations[index].type = .line(start: updatedStart, end: updatedEnd)
    annotations[index].bounds = CGRect(
      x: min(updatedStart.x, updatedEnd.x),
      y: min(updatedStart.y, updatedEnd.y),
      width: abs(updatedEnd.x - updatedStart.x),
      height: abs(updatedEnd.y - updatedStart.y)
    ).standardized
  }

  /// Move an arrow's start/end endpoint (Figma-style line editing).
  /// Style, display type, and heads are preserved; the curve control point is
  /// re-derived from the new endpoints so curved arrows follow the drag.
  func updateArrowEndpoint(id: UUID, start newStart: CGPoint? = nil, end newEnd: CGPoint? = nil) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updatedStart = newStart ?? geometry.start
    let updatedEnd = newEnd ?? geometry.end
    let updated = ArrowGeometry(
      start: updatedStart,
      end: updatedEnd,
      style: geometry.style,
      arrowType: geometry.arrowType,
      startHead: geometry.startHead,
      endHead: geometry.endHead
    )
    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateAnnotationText(id: UUID, text: String) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text(let currentText) = annotations[index].type else { return }

    let currentBounds = annotations[index].bounds
    let newBounds = resizedTextBounds(
      id: id,
      text: text,
      properties: annotations[index].properties,
      currentBounds: currentBounds
    )

    let textChanged = currentText != text
    let boundsChanged = annotations[index].bounds != newBounds
    guard textChanged || boundsChanged else { return }

    if textChanged {
      recordTextEditingUndoIfNeeded(id: id, newText: text)
      annotations[index].type = .text(text)
    }
    annotations[index].bounds = newBounds
    hasUnsavedChanges = true
  }

  func updateArrowStyle(id: UUID, style: ArrowStyle) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withStyle(style)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowType(id: UUID, arrowType: ArrowType) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withArrowType(arrowType)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowBendDirection(id: UUID, bendDirection: ArrowBendDirection) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type,
          geometry.style.supportsBendDirection else { return }

    let updated = geometry.withBendDirection(bendDirection)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowStartHead(id: UUID, head: ArrowEndpointStyle) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withStartHead(head)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateArrowEndHead(id: UUID, head: ArrowEndpointStyle) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .arrow(let geometry) = annotations[index].type else { return }

    let updated = geometry.withEndHead(head)
    guard updated != geometry else { return }

    annotations[index].type = .arrow(updated)
    annotations[index].bounds = updated.bounds()
    hasUnsavedChanges = true
  }

  func updateBlurType(id: UUID, blurType: BlurType) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .blur = annotations[index].type else { return }

    annotations[index].type = .blur(blurType)
  }

  /// Update annotation properties (strokeWidth, fontSize, colors)
  func updateAnnotationProperties(
    id: UUID,
    strokeWidth: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    strokeColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    recordsUndo: Bool = false
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }

    guard annotationPropertiesWillChange(
      annotations[index],
      strokeWidth: strokeWidth,
      fontSize: fontSize,
      strokeColor: strokeColor,
      cornerRadius: cornerRadius
    ) else { return }

    if recordsUndo {
      saveState()
    }

    let oldSelectionBounds = annotations[index].selectionBounds
    isApplyingPropertyEdit = true
    defer { isApplyingPropertyEdit = false }

    if let strokeWidth {
      let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
      annotations[index].properties.strokeWidth = clampedWidth
      if case .counter = annotations[index].type {
        let center = CGPoint(x: annotations[index].bounds.midX, y: annotations[index].bounds.midY)
        annotations[index].bounds = counterBounds(center: center, controlValue: clampedWidth)
      }
    }
    if let fontSize {
      annotations[index].properties.fontSize = fontSize
      // Recalculate bounds for new font size
      if case .text(let content) = annotations[index].type {
        let currentBounds = annotations[index].bounds
        let properties = annotations[index].properties
        annotations[index].bounds = resizedTextBounds(
          id: id,
          text: content,
          properties: properties,
          currentBounds: currentBounds
        )
      }
    }
    if let strokeColor {
      annotations[index].properties.strokeColor = strokeColor
    }
    if let cornerRadius {
      annotations[index].properties.cornerRadius = max(0, cornerRadius)
    }
    pendingPropertyEditRects.append(oldSelectionBounds.union(annotations[index].selectionBounds))
    hasUnsavedChanges = true
  }

  private func annotationPropertiesWillChange(
    _ annotation: AnnotationItem,
    strokeWidth: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    strokeColor: Color? = nil,
    cornerRadius: CGFloat? = nil
  ) -> Bool {
    let properties = annotation.properties

    if let strokeWidth,
       properties.strokeWidth != AnnotationProperties.clampedControlValue(strokeWidth) {
      return true
    }
    if let fontSize,
       properties.fontSize != fontSize {
      return true
    }
    if let strokeColor,
       properties.strokeColor != strokeColor {
      return true
    }
    if let cornerRadius,
       properties.cornerRadius != max(0, cornerRadius) {
      return true
    }
    return false
  }

  /// Calculate text bounds based on content and font size with word wrapping
  /// - Parameters:
  ///   - text: The text content
  ///   - fontSize: Desired font size (will be clamped to 8-144pt range)
  ///   - origin: Origin point for the text bounds
  ///   - constrainedWidth: Width to constrain text wrapping to (nil = auto-width from content)
  /// - Returns: Bounded CGRect with enforced maximum dimensions
  private func calculateTextBounds(
    text: String,
    fontSize: CGFloat,
    origin: CGPoint,
    constrainedWidth: CGFloat? = nil,
    maximumHeight: CGFloat = AnnotateTextLayout.maxHeight
  ) -> CGRect {
    AnnotateTextLayout.bounds(
      text: text,
      font: AnnotateTextLayout.font(size: fontSize),
      origin: origin,
      constrainedWidth: constrainedWidth,
      maximumHeight: maximumHeight
    )
  }

  private func resizedTextBounds(
    id: UUID,
    text: String,
    properties: AnnotationProperties,
    currentBounds: CGRect
  ) -> CGRect {
    let font = AnnotateTextLayout.font(size: properties.fontSize)
    let annotationBounds = activeAnnotationBounds.standardized
    let topY = currentBounds.maxY
    let availableWidth = max(annotationBounds.maxX - currentBounds.minX, AnnotateTextLayout.minWidth)
    let availableHeight = max(
      topY - annotationBounds.minY,
      AnnotateTextLayout.minimumHeight(for: font)
    )
    let targetWidth: CGFloat = if autoSizingTextAnnotationIDs.contains(id) {
      AnnotateTextLayout.preferredAutoWidth(
        text: text,
        font: font,
        minimumWidth: AnnotateTextLayout.minWidth,
        maximumWidth: availableWidth
      )
    } else {
      AnnotateTextLayout.clampedWidth(
        currentBounds.width,
        maximumWidth: availableWidth
      )
    }

    var bounds = calculateTextBounds(
      text: text,
      fontSize: properties.fontSize,
      origin: currentBounds.origin,
      constrainedWidth: targetWidth,
      maximumHeight: availableHeight
    )
    bounds.origin.y = topY - bounds.height
    return bounds
  }

  private var selectedArrowAnnotations: [AnnotationItem] {
    selectedAnnotations.filter { annotation in
      if case .arrow = annotation.type {
        return true
      }
      return false
    }
  }

  private var selectedBlurAnnotations: [AnnotationItem] {
    selectedAnnotations.filter { annotation in
      if case .blur = annotation.type {
        return true
      }
      return false
    }
  }

  var activeArrowStyle: ArrowStyle {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.style
    }
    return arrowStyle
  }

  func setActiveArrowStyle(_ style: ArrowStyle) {
    arrowStyle = style
    sharedAnnotationParameterDefaults.arrowStyle = style.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.style != style
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowStyle(id: $0.id, style: style) }
    } else {
      arrowStyle = style
    }
  }

  var activeArrowType: ArrowType {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.arrowType
    }
    return arrowType
  }

  func setActiveArrowType(_ type: ArrowType) {
    arrowType = type
    sharedAnnotationParameterDefaults.arrowType = type.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.arrowType != type
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowType(id: $0.id, arrowType: type) }
    } else {
      arrowType = type
    }
  }

  var activeArrowBendDirection: ArrowBendDirection {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.bendDirection
    }
    return arrowBendDirection
  }

  func setActiveArrowBendDirection(_ bendDirection: ArrowBendDirection) {
    arrowBendDirection = bendDirection
    sharedAnnotationParameterDefaults.arrowBendDirection = bendDirection.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.style.supportsBendDirection && geometry.bendDirection != bendDirection
      }) {
        saveState()
      }
      for arrowAnnotation in arrowAnnotations {
        updateArrowBendDirection(id: arrowAnnotation.id, bendDirection: bendDirection)
      }
    } else {
      arrowBendDirection = bendDirection
    }
  }

  var activeArrowStartHead: ArrowEndpointStyle {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.startHead
    }
    return arrowStartHead
  }

  func setActiveArrowStartHead(_ head: ArrowEndpointStyle) {
    arrowStartHead = head
    sharedAnnotationParameterDefaults.arrowStartHead = head.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.startHead != head
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowStartHead(id: $0.id, head: head) }
    }
  }

  var activeArrowEndHead: ArrowEndpointStyle {
    if let annotation = selectedArrowAnnotations.first,
       case .arrow(let geometry) = annotation.type {
      return geometry.endHead
    }
    return arrowEndHead
  }

  func setActiveArrowEndHead(_ head: ArrowEndpointStyle) {
    arrowEndHead = head
    sharedAnnotationParameterDefaults.arrowEndHead = head.rawValue
    persistSharedAnnotationParameterDefaults()

    let arrowAnnotations = selectedArrowAnnotations
    if !arrowAnnotations.isEmpty {
      if arrowAnnotations.contains(where: {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.endHead != head
      }) {
        saveState()
      }
      arrowAnnotations.forEach { updateArrowEndHead(id: $0.id, head: head) }
    }
  }

  var activeBlurType: BlurType {
    if let annotation = selectedBlurAnnotations.first,
       case .blur(let type) = annotation.type {
      return type
    }
    return blurType
  }

  func setActiveBlurType(_ type: BlurType) {
    let blurAnnotations = selectedBlurAnnotations
    if !blurAnnotations.isEmpty {
      blurAnnotations.forEach { updateBlurType(id: $0.id, blurType: type) }
    } else {
      blurType = type
    }
  }

  private func loadSharedAnnotationColor() {
    guard let data = defaults.data(forKey: PreferencesKeys.annotatePrimaryColor),
          let rgba = try? JSONDecoder().decode(RGBAColor.self, from: data) else {
      return
    }
    sharedAnnotationColor = rgba.color
    strokeColor = rgba.color
  }

  private func rememberSharedAnnotationColor(_ color: Color) {
    guard let rgba = RGBAColor(color: color),
          let data = try? JSONEncoder().encode(rgba) else {
      return
    }

    sharedAnnotationColor = color
    defaults.set(data, forKey: PreferencesKeys.annotatePrimaryColor)
    if selectedTool.supportsQuickPropertiesBar {
      syncActiveToolProperties()
    } else {
      strokeColor = color
    }
  }

  private func loadSharedAnnotationParameterDefaults() {
    guard let data = defaults.data(forKey: PreferencesKeys.annotateParameterDefaults),
          let decoded = try? JSONDecoder().decode(SharedAnnotationParameterDefaults.self, from: data)
    else { return }

    sharedAnnotationParameterDefaults = sanitizedSharedAnnotationParameterDefaults(decoded)

    if let savedStyleRaw = sharedAnnotationParameterDefaults.arrowStyle,
       let savedStyle = ArrowStyle(rawValue: savedStyleRaw) {
      arrowStyle = savedStyle
    }
    if let savedTypeRaw = sharedAnnotationParameterDefaults.arrowType,
       let savedType = ArrowType(rawValue: savedTypeRaw) {
      arrowType = savedType
    }
    if let savedBendRaw = sharedAnnotationParameterDefaults.arrowBendDirection,
       let savedBend = ArrowBendDirection(rawValue: savedBendRaw) {
      arrowBendDirection = savedBend
    }
    if let savedStartHeadRaw = sharedAnnotationParameterDefaults.arrowStartHead,
       let savedStartHead = ArrowEndpointStyle(rawValue: savedStartHeadRaw) {
      arrowStartHead = savedStartHead
    }
    if let savedEndHeadRaw = sharedAnnotationParameterDefaults.arrowEndHead,
       let savedEndHead = ArrowEndpointStyle(rawValue: savedEndHeadRaw) {
      arrowEndHead = savedEndHead
    }
  }

  private func persistSharedAnnotationParameterDefaults() {
    guard let data = try? JSONEncoder().encode(sharedAnnotationParameterDefaults) else { return }
    defaults.set(data, forKey: PreferencesKeys.annotateParameterDefaults)
  }

  private func sanitizedSharedAnnotationParameterDefaults(
    _ defaults: SharedAnnotationParameterDefaults
  ) -> SharedAnnotationParameterDefaults {
    SharedAnnotationParameterDefaults(
      strokeWidth: defaults.strokeWidth.map(AnnotationProperties.clampedControlValue(_:)),
      cornerRadius: defaults.cornerRadius.map { max(0, $0) },
      fontSize: defaults.fontSize.map { min(max($0, 12), 72) },
      spotlightCornerRadius: defaults.spotlightCornerRadius.map { max(0, $0) },
      arrowStyle: defaults.arrowStyle,
      arrowType: defaults.arrowType,
      arrowBendDirection: defaults.arrowBendDirection,
      arrowStartHead: defaults.arrowStartHead,
      arrowEndHead: defaults.arrowEndHead
    )
  }

  private func rememberSharedAnnotationStrokeWidth(_ strokeWidth: CGFloat) {
    let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    sharedAnnotationParameterDefaults.strokeWidth = clampedWidth
    persistSharedAnnotationParameterDefaults()
    syncActiveToolProperties()
  }

  private func rememberSharedAnnotationCornerRadius(_ cornerRadius: CGFloat) {
    let clampedRadius = max(0, cornerRadius)
    sharedAnnotationParameterDefaults.cornerRadius = clampedRadius
    persistSharedAnnotationParameterDefaults()
    syncActiveToolProperties()
  }

  private func rememberSharedSpotlightCornerRadius(_ cornerRadius: CGFloat) {
    let clampedRadius = max(0, cornerRadius)
    sharedAnnotationParameterDefaults.spotlightCornerRadius = clampedRadius
    persistSharedAnnotationParameterDefaults()
    syncActiveToolProperties()
  }

  private func rememberSharedAnnotationFontSize(_ fontSize: CGFloat) {
    let clampedSize = min(max(fontSize, 12), 72)
    sharedAnnotationParameterDefaults.fontSize = clampedSize
    persistSharedAnnotationParameterDefaults()
    syncActiveToolProperties()
  }

  private func rememberAnnotationCornerRadius(_ cornerRadius: CGFloat, for tool: AnnotationToolType?) {
    if tool == .spotlight {
      rememberSharedSpotlightCornerRadius(cornerRadius)
    } else {
      rememberSharedAnnotationCornerRadius(cornerRadius)
    }
  }

  private func defaultAnnotationProperties(for tool: AnnotationToolType?) -> AnnotationProperties {
    guard let tool else {
      var properties = AnnotationProperties(strokeColor: sharedAnnotationColor ?? .red)
      applySharedParameterDefaults(to: &properties, for: nil)
      return properties
    }
    return baseAnnotationProperties(for: tool)
  }

  private func baseAnnotationProperties(for tool: AnnotationToolType) -> AnnotationProperties {
    if tool == .spotlight {
      var properties = AnnotationProperties(
        strokeColor: sharedAnnotationColor ?? .red,
        strokeWidth: 3,
        cornerRadius: 14
      )
      applySharedParameterDefaults(to: &properties, for: tool)
      return properties
    }
    var properties = AnnotationProperties(strokeColor: sharedAnnotationColor ?? .red)
    if tool == .blur {
      properties.strokeWidth = AnnotationProperties.controlValueRange.lowerBound
    }
    applySharedParameterDefaults(to: &properties, for: tool)
    return properties
  }

  private func applySharedParameterDefaults(
    to properties: inout AnnotationProperties,
    for tool: AnnotationToolType?
  ) {
    let defaults = sharedAnnotationParameterDefaults

    if tool == nil || tool?.supportsQuickStrokeWidth == true,
       let strokeWidth = defaults.strokeWidth {
      properties.strokeWidth = strokeWidth
    }

    if tool == .spotlight {
      if let cornerRadius = defaults.spotlightCornerRadius {
        properties.cornerRadius = cornerRadius
      } else {
        properties.cornerRadius = 14
      }
    } else if tool == nil || tool?.supportsQuickCornerRadius == true {
      if let cornerRadius = defaults.cornerRadius {
        properties.cornerRadius = cornerRadius
      }
    }

    if tool == nil || tool == .text,
       let fontSize = defaults.fontSize {
      properties.fontSize = fontSize
    }
  }

  func annotationCreationProperties(for tool: AnnotationToolType) -> AnnotationProperties {
    var properties = defaultAnnotationProperties(for: tool)
    if tool == .text, shouldUseRecommendedTextFontSize {
      properties.fontSize = recommendedTextFontSize()
    }
    return properties
  }

  /// Starts new text at a readable size relative to the current image.
  /// A manually chosen text size is always preserved for subsequent annotations.
  func recommendedTextFontSize() -> CGFloat {
    let canvasSize = sourceImageBounds.size
    let shortSide = max(min(canvasSize.width, canvasSize.height), 1)
    let suggested = shortSide * 0.026
    let stepped = (suggested / 2).rounded() * 2
    return min(max(stepped, 16), 36)
  }

  private var shouldUseRecommendedTextFontSize: Bool {
    sharedAnnotationParameterDefaults.fontSize == nil
  }

  private func counterBounds(center: CGPoint, controlValue: CGFloat) -> CGRect {
    let diameter = AnnotationProperties.counterDiameter(for: controlValue)
    return CGRect(
      x: center.x - diameter / 2,
      y: center.y - diameter / 2,
      width: diameter,
      height: diameter
    )
  }

  private func syncActiveToolProperties() {
    guard selectedTool.supportsQuickPropertiesBar else { return }
    applyToolPropertiesToActiveState(defaultAnnotationProperties(for: selectedTool), for: selectedTool)
  }

  private func applyToolPropertiesToActiveState(
    _ properties: AnnotationProperties,
    for tool: AnnotationToolType
  ) {
    strokeColor = properties.strokeColor
    strokeWidth = properties.strokeWidth
    if tool.supportsQuickCornerRadius {
      rectangleCornerRadius = properties.cornerRadius
    }
  }

  private var quickPropertiesSelectionAnnotations: [AnnotationItem] {
    selectedAnnotations
  }

  private var quickPropertiesSelectionTargets: [AnnotationItem] {
    let selected = quickPropertiesSelectionAnnotations
    guard !selected.isEmpty else { return [] }
    if selected.count == 1 {
      guard selected[0].type.supportsQuickPropertiesBar else { return [] }
    }
    return selected
  }

  private var quickPropertiesCommonSelectedTool: AnnotationToolType? {
    let selected = quickPropertiesSelectionAnnotations
    guard !selected.isEmpty else { return nil }
    let tools = Set(selected.map(\.type.toolType))
    guard tools.count == 1 else { return nil }
    return tools.first
  }

  private func quickSelectionAnySupport(_ predicate: (AnnotationType) -> Bool) -> Bool {
    let selected = quickPropertiesSelectionTargets
    guard !selected.isEmpty else { return false }
    return selected.contains { predicate($0.type) }
  }

  private func quickSelectionTargets(matching predicate: (AnnotationType) -> Bool) -> [AnnotationItem] {
    quickPropertiesSelectionTargets.filter { predicate($0.type) }
  }

  func setQuickPropertiesControlEditing(_ isEditing: Bool) {
    if isEditing {
      beginQuickPropertiesGestureUndoIfNeeded()
    } else {
      isQuickPropertiesGestureEditing = false
      quickPropertiesGestureUndoSnapshot = nil
    }
  }

  private func beginQuickPropertiesGestureUndoIfNeeded() {
    guard !isQuickPropertiesGestureEditing,
          !quickPropertiesSelectionTargets.isEmpty else { return }
    isQuickPropertiesGestureEditing = true
    quickPropertiesGestureUndoSnapshot = currentSnapshot()
  }

  private func updateQuickSelectionProperties(
    strokeWidth: CGFloat? = nil,
    strokeColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    recordsUndo: Bool = false,
    matching predicate: ((AnnotationType) -> Bool)? = nil
  ) -> Bool {
    let selected = quickPropertiesSelectionTargets.filter { annotation in
      predicate?(annotation.type) ?? true
    }
    guard !selected.isEmpty else { return false }

    let shouldRecordUndo = recordsUndo && selected.contains(where: {
      annotationPropertiesWillChange(
        $0,
        strokeWidth: strokeWidth,
        fontSize: fontSize,
        strokeColor: strokeColor,
        cornerRadius: cornerRadius
      )
    })

    if shouldRecordUndo {
      if let snapshot = quickPropertiesGestureUndoSnapshot {
        pushUndoSnapshot(snapshot, annotationCount: snapshot.annotations.count)
        quickPropertiesGestureUndoSnapshot = nil
      } else if !isQuickPropertiesGestureEditing {
        saveState()
      }
    }

    for annotation in selected {
      updateAnnotationProperties(
        id: annotation.id,
        strokeWidth: strokeWidth,
        fontSize: fontSize,
        strokeColor: strokeColor,
        cornerRadius: cornerRadius
      )
    }
    return true
  }

  var quickPropertiesSupportsArrowStyle: Bool {
    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .arrow = $0.type {
          return true
        }
        return false
      }
    }

    return quickPropertiesTool == .arrow
  }

  var quickPropertiesSupportsArrowBendDirection: Bool {
    guard quickPropertiesSupportsArrowStyle else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.style.supportsBendDirection
      }
    }

    return quickPropertiesTool == .arrow && activeArrowStyle.supportsBendDirection
  }

  /// Per-endpoint head styles apply to the classic (stroked line) display type.
  var quickPropertiesSupportsArrowEndpoints: Bool {
    guard quickPropertiesSupportsArrowStyle else {
      return false
    }

    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        guard case .arrow(let geometry) = $0.type else { return false }
        return geometry.arrowType == .classic
      }
    }

    return quickPropertiesTool == .arrow && activeArrowType == .classic
  }

  var quickArrowStyleBinding: Binding<ArrowStyle> {
    Binding(
      get: { [weak self] in
        self?.activeArrowStyle ?? .straight
      },
      set: { [weak self] newStyle in
        self?.setActiveArrowStyle(newStyle)
      }
    )
  }

  var quickArrowTypeBinding: Binding<ArrowType> {
    Binding(
      get: { [weak self] in
        self?.activeArrowType ?? .tapered
      },
      set: { [weak self] newType in
        self?.setActiveArrowType(newType)
      }
    )
  }

  var quickArrowBendDirectionBinding: Binding<ArrowBendDirection> {
    Binding(
      get: { [weak self] in
        self?.activeArrowBendDirection ?? .primary
      },
      set: { [weak self] newDirection in
        self?.setActiveArrowBendDirection(newDirection)
      }
    )
  }

  var quickArrowStartHeadBinding: Binding<ArrowEndpointStyle> {
    Binding(
      get: { [weak self] in
        self?.activeArrowStartHead ?? .none
      },
      set: { [weak self] newHead in
        self?.setActiveArrowStartHead(newHead)
      }
    )
  }

  var quickArrowEndHeadBinding: Binding<ArrowEndpointStyle> {
    Binding(
      get: { [weak self] in
        self?.activeArrowEndHead ?? .arrow
      },
      set: { [weak self] newHead in
        self?.setActiveArrowEndHead(newHead)
      }
    )
  }

  var quickPropertiesSupportsTextFontSize: Bool {
    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .text = $0.type {
          return true
        }
        return false
      }
    }

    return quickPropertiesTool == .text
  }

  var quickTextFontSizeBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 16 }
        return quickSelectionTargets(matching: {
          if case .text = $0 {
            return true
          }
          return false
        }).first?.properties.fontSize
          ?? defaultAnnotationProperties(for: quickPropertiesTool).fontSize
      },
      set: { [weak self] newSize in
        guard let self else { return }
        let clampedSize = min(max(newSize, 12), 72)
        if !updateQuickSelectionProperties(
          fontSize: clampedSize,
          recordsUndo: true,
          matching: {
            if case .text = $0 {
              return true
            }
            return false
          }
        ) {
          rememberSharedAnnotationFontSize(clampedSize)
        }
      }
    )
  }

  var quickPropertiesSupportsBlurType: Bool {
    let selected = quickPropertiesSelectionAnnotations
    if !selected.isEmpty {
      return selected.contains {
        if case .blur = $0.type {
          return true
        }
        return false
      }
    }

    return quickPropertiesTool == .blur
  }

  var quickBlurTypeBinding: Binding<BlurType> {
    Binding(
      get: { [weak self] in
        self?.activeBlurType ?? .pixelated
      },
      set: { [weak self] newType in
        self?.setActiveBlurType(newType)
      }
    )
  }

  var quickPropertiesAnnotation: AnnotationItem? {
    guard let annotation = quickPropertiesSelectionAnnotations.first,
          quickPropertiesSelectionAnnotations.count == 1,
          annotation.type.supportsQuickPropertiesBar else {
      return nil
    }
    return annotation
  }

  var quickPropertiesMode: QuickPropertiesMode {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return .selectedItem
    }
    if quickPropertiesTool != nil {
      return .toolDefaults
    }
    return .hidden
  }

  var quickPropertiesTool: AnnotationToolType? {
    if let annotation = quickPropertiesAnnotation {
      return annotation.type.toolType
    }

    if quickPropertiesSelectionAnnotations.count == 1 {
      return quickPropertiesSelectionAnnotations[0].type.toolType
    }

    if quickPropertiesSelectionAnnotations.count > 1 {
      return quickPropertiesCommonSelectedTool ?? .selection
    }

    guard selectedTool.supportsQuickPropertiesBar else {
      return nil
    }
    return selectedTool
  }

  var showsQuickPropertiesBar: Bool {
    quickPropertiesMode != .hidden
  }

  var quickPropertiesContextTitle: String {
    switch quickPropertiesMode {
    case .selectedItem:
      if quickPropertiesSelectionAnnotations.count > 1 {
        return L10n.AnnotateContext.selected("\(quickPropertiesSelectionAnnotations.count)")
      }
      let tool = quickPropertiesCommonSelectedTool ?? quickPropertiesTool
      guard let tool, tool != .selection else {
        return L10n.AnnotateContext.selected(L10n.AnnotateUI.annotation)
      }
      return L10n.AnnotateContext.selected(tool.displayName)
    case .toolDefaults:
      guard let tool = quickPropertiesTool else { return "" }
      return L10n.AnnotateContext.defaults(tool.displayName)
    case .hidden:
      return ""
    }
  }

  var quickPropertiesSupportsStrokeColor: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickStrokeColor }
    }
    return quickPropertiesTool?.supportsQuickStrokeColor ?? false
  }

  var quickPropertiesSupportsStrokeWidth: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickStrokeWidth }
    }
    return quickPropertiesTool?.supportsQuickStrokeWidth ?? false
  }

  var quickStrokeWidthLabel: String {
    quickStrokeWidthUsesSizeLabel ? L10n.Common.size : L10n.Common.stroke
  }

  var quickStrokeWidthIcon: String {
    quickStrokeWidthUsesSizeLabel ? "arrow.up.left.and.arrow.down.right" : "line.diagonal"
  }

  var quickStrokeWidthDisplayText: String {
    let controlValue = quickStrokeWidthValue

    switch quickStrokeWidthSemanticTool {
    case .counter:
      return "\(Int(AnnotationProperties.counterDiameter(for: controlValue).rounded()))"
    case .blur:
      let value: CGFloat = switch activeBlurType {
      case .pixelated:
        AnnotationProperties.pixelatedBlurSize(for: controlValue)
      case .gaussian:
        AnnotationProperties.gaussianBlurRadius(for: controlValue)
      case .hexagonal:
        AnnotationProperties.hexagonalScale(for: controlValue)
      case .crystallized:
        AnnotationProperties.crystallizeRadius(for: controlValue)
      case .pointillism:
        AnnotationProperties.pointillismRadius(for: controlValue)
      case .halftone:
        AnnotationProperties.halftoneWidth(for: controlValue)
      case .tape:
        AnnotationProperties.tapePatternSpacing(for: controlValue)
      case .washi:
        AnnotationProperties.washiPatternSpacing(for: controlValue)
      }
      return "\(Int(value.rounded()))"
    default:
      return "\(Int(controlValue.rounded()))"
    }
  }

  private var quickStrokeWidthUsesSizeLabel: Bool {
    switch quickStrokeWidthSemanticTool {
    case .blur, .counter:
      true
    default:
      false
    }
  }

  private var quickStrokeWidthSemanticTool: AnnotationToolType? {
    let selectedStrokeTargets = quickSelectionTargets(matching: { $0.supportsQuickStrokeWidth })
    if !selectedStrokeTargets.isEmpty {
      let tools = Set(selectedStrokeTargets.map(\.type.toolType))
      guard tools.count == 1 else { return nil }
      return tools.first
    }
    return quickPropertiesTool
  }

  private var quickStrokeWidthValue: CGFloat {
    quickSelectionTargets(matching: { $0.supportsQuickStrokeWidth }).first?.properties.strokeWidth
      ?? defaultAnnotationProperties(for: quickPropertiesTool).strokeWidth
  }

  var quickPropertiesSupportsCornerRadius: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.toolType.supportsQuickCornerRadius }
    }
    return quickPropertiesTool?.supportsQuickCornerRadius ?? false
  }

  var quickStrokeColorBinding: Binding<Color> {
    Binding(
      get: { [weak self] in
        guard let self else { return .red }
        return quickSelectionTargets(matching: { $0.supportsQuickStrokeColor }).first?.properties.strokeColor
          ?? defaultAnnotationProperties(for: quickPropertiesTool).strokeColor
      },
      set: { [weak self] newColor in
        guard let self else { return }
        _ = updateQuickSelectionProperties(
          strokeColor: newColor,
          recordsUndo: true,
          matching: { $0.supportsQuickStrokeColor }
        )
        rememberSharedAnnotationColor(newColor)
      }
    )
  }

  var quickStrokeWidthBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 3 }
        return quickSelectionTargets(matching: { $0.supportsQuickStrokeWidth }).first?.properties.strokeWidth
          ?? defaultAnnotationProperties(for: quickPropertiesTool).strokeWidth
      },
      set: { [weak self] newWidth in
        guard let self else { return }
        if !updateQuickSelectionProperties(
          strokeWidth: newWidth,
          recordsUndo: true,
          matching: { $0.supportsQuickStrokeWidth }
        ) {
          rememberSharedAnnotationStrokeWidth(newWidth)
        }
      }
    )
  }

  var quickCornerRadiusBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 0 }
        return quickSelectionTargets(matching: { $0.toolType.supportsQuickCornerRadius }).first?.properties.cornerRadius
          ?? defaultAnnotationProperties(for: quickPropertiesTool).cornerRadius
      },
      set: { [weak self] newRadius in
        guard let self else { return }
        let clampedRadius = max(0, newRadius)
        if !updateQuickSelectionProperties(
          cornerRadius: clampedRadius,
          recordsUndo: true,
          matching: { $0.toolType.supportsQuickCornerRadius }
        ) {
          rememberAnnotationCornerRadius(clampedRadius, for: quickPropertiesTool)
        }
      }
    )
  }

  func activateTool(_ tool: AnnotationToolType) {
    if editingTextAnnotationId != nil {
      commitTextEditing()
    }
    if tool != .selection {
      deselectAnnotation()
    }
    selectedTool = tool
  }

  func deleteSelectedAnnotation() {
    let selectedIds = selectedAnnotationIds
    guard !selectedIds.isEmpty else { return }
    DiagnosticLogger.shared.log(.debug, .annotate, "Delete annotation", context: [
      "count": "\(selectedIds.count)",
    ])
    saveState()
    annotations.removeAll { selectedIds.contains($0.id) }
    autoSizingTextAnnotationIDs.subtract(selectedIds)
    deselectAnnotation()
  }

  /// Commit the current text editing and exit edit mode
  func commitTextEditing() {
    guard let editingId = editingTextAnnotationId else { return }

    if let annotation = annotations.first(where: { $0.id == editingId }),
       case .text(let text) = annotation.type {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        recordTextEditingUndoIfNeeded(id: editingId, newText: trimmed)
        annotations.removeAll { $0.id == editingId }
        selectedAnnotationId = nil
        hasUnsavedChanges = true
      } else {
        updateAnnotationText(id: editingId, text: trimmed)
      }
    }
    finishTextEditing()
  }

  /// Deselect current annotation
  func deselectAnnotation() {
    setSelectedAnnotationIds([])
    finishTextEditing()
  }

  /// Nudge selected annotation by delta
  func nudgeSelectedAnnotation(dx: CGFloat, dy: CGFloat) {
    let selectedIds = selectedAnnotationIds
    guard !selectedIds.isEmpty else { return }

    saveState()
    for index in annotations.indices where selectedIds.contains(annotations[index].id) {
      translateAnnotation(at: index, dx: dx, dy: dy)
    }
  }

  private func translateAnnotations(dx: CGFloat, dy: CGFloat) {
    guard dx != 0 || dy != 0 else { return }
    for index in annotations.indices {
      translateAnnotation(at: index, dx: dx, dy: dy)
    }
  }

  private func translateAnnotation(at index: Int, dx: CGFloat, dy: CGFloat) {
    annotations[index].bounds.origin.x += dx
    annotations[index].bounds.origin.y += dy

    switch annotations[index].type {
    case .arrow(let geometry):
      let updated = geometry.translatedBy(dx: dx, dy: dy)
      annotations[index].type = .arrow(updated)
      annotations[index].bounds = updated.bounds()
    case .line(let start, let end):
      annotations[index].type = .line(
        start: CGPoint(x: start.x + dx, y: start.y + dy),
        end: CGPoint(x: end.x + dx, y: end.y + dy)
      )
    case .path(let points):
      annotations[index].type = .path(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
    case .highlight(let points):
      annotations[index].type = .highlight(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
    default:
      break
    }
  }
}

nonisolated enum AnnotateTextLayout {
  static let horizontalPadding: CGFloat = 4
  static let verticalPadding: CGFloat = 4
  static let minWidth: CGFloat = 30
  static let minContentWidth: CGFloat = 20
  static let defaultInitialWidth: CGFloat = 200
  static let maxWidth: CGFloat = 2000
  static let maxHeight: CGFloat = 2000

  static func font(size: CGFloat) -> NSFont {
    let clampedSize = min(max(size, 8), 144)
    return NSFont(name: "SF Pro", size: clampedSize) ?? NSFont.systemFont(ofSize: clampedSize)
  }

  static func displayFont(size: CGFloat, scale: CGFloat) -> NSFont {
    let baseFont = font(size: size)
    let displaySize = max(baseFont.pointSize * scale, 1)

    if let scaledFont = NSFont(descriptor: baseFont.fontDescriptor, size: displaySize) {
      return scaledFont
    }

    return NSFont.systemFont(ofSize: displaySize)
  }

  static func bounds(
    text: String,
    font: NSFont,
    origin: CGPoint,
    constrainedWidth: CGFloat? = nil,
    maximumHeight: CGFloat = maxHeight
  ) -> CGRect {
    let finalWidth: CGFloat = if let constrainedWidth {
      clampedWidth(constrainedWidth)
    } else {
      preferredAutoWidth(text: text, font: font)
    }

    let contentWidth = max(finalWidth - horizontalPadding * 2, minContentWidth)
    let contentHeight = ceil(contentSize(for: text, font: font, constrainedWidth: contentWidth).height)
    let resolvedMaximumHeight = max(minimumHeight(for: font), min(maximumHeight, maxHeight))
    let finalHeight = min(
      max(contentHeight + verticalPadding * 2, minimumHeight(for: font)),
      resolvedMaximumHeight
    )

    return CGRect(
      x: origin.x,
      y: origin.y,
      width: finalWidth,
      height: finalHeight
    )
  }

  static func textRect(for text: String, font: NSFont, in bounds: CGRect) -> CGRect {
    let contentWidth = max(bounds.width - horizontalPadding * 2, minContentWidth)
    let contentHeight = ceil(contentSize(for: text, font: font, constrainedWidth: contentWidth).height)
    let drawHeight = min(contentHeight, max(bounds.height, 0))
    let verticalInset = max((bounds.height - drawHeight) / 2, 0)

    return CGRect(
      x: bounds.minX + horizontalPadding,
      y: bounds.minY + verticalInset,
      width: contentWidth,
      height: drawHeight
    )
  }

  static func textEditorInset(scale: CGFloat) -> NSSize {
    let resolvedScale = max(scale, 0.0001)
    return NSSize(
      width: horizontalPadding * resolvedScale,
      height: verticalPadding * resolvedScale
    )
  }

  static func clampedWidth(_ width: CGFloat, maximumWidth: CGFloat = maxWidth) -> CGFloat {
    let resolvedMaximumWidth = max(minWidth, min(maximumWidth, maxWidth))
    return min(max(width, minWidth), resolvedMaximumWidth)
  }

  static func preferredAutoWidth(
    text: String,
    font: NSFont,
    minimumWidth: CGFloat = defaultInitialWidth,
    maximumWidth: CGFloat = maxWidth
  ) -> CGFloat {
    let measuredWidth = ceil(singleLineSize(for: text, font: font).width) + horizontalPadding * 2
    let resolvedMaximumWidth = max(minWidth, min(maximumWidth, maxWidth))
    let resolvedMinimumWidth = min(max(minimumWidth, minWidth), resolvedMaximumWidth)
    return min(max(measuredWidth, resolvedMinimumWidth), resolvedMaximumWidth)
  }

  static func minimumHeight(for font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading) + verticalPadding * 2
  }

  private static func singleLineSize(for text: String, font: NSFont) -> CGSize {
    (measurementText(for: text) as NSString).size(withAttributes: textAttributes(font: font))
  }

  private static func contentSize(for text: String, font: NSFont, constrainedWidth: CGFloat) -> CGSize {
    let rect = (measurementText(for: text) as NSString).boundingRect(
      with: CGSize(width: constrainedWidth, height: maxHeight),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: textAttributes(font: font)
    )
    return rect.size
  }

  private static func measurementText(for text: String) -> String {
    text.isEmpty ? " " : text
  }

  private static func textAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping

    return [
      .font: font,
      .paragraphStyle: paragraphStyle,
    ]
  }
}
