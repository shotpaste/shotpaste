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

  private struct PersistedAnnotationProperties: Codable {
    var strokeColor: RGBAColor
    var fillColor: RGBAColor
    var strokeWidth: CGFloat
    var cornerRadius: CGFloat
    var fontSize: CGFloat
    var fontName: String
    var spotlightOpacity: CGFloat?

    init?(_ properties: AnnotationProperties) {
      guard let strokeColor = RGBAColor(color: properties.strokeColor),
            let fillColor = RGBAColor(color: properties.fillColor) else {
        return nil
      }

      self.strokeColor = strokeColor
      self.fillColor = fillColor
      strokeWidth = properties.strokeWidth
      cornerRadius = properties.cornerRadius
      fontSize = properties.fontSize
      fontName = properties.fontName
      spotlightOpacity = properties.spotlightOpacity
    }

    var annotationProperties: AnnotationProperties {
      AnnotationProperties(
        strokeColor: strokeColor.color,
        fillColor: fillColor.color,
        strokeWidth: strokeWidth,
        cornerRadius: cornerRadius,
        fontSize: fontSize,
        fontName: fontName,
        spotlightOpacity: spotlightOpacity ?? 0.5
      )
    }
  }

  private static let canvasPresetLimit: Int = 20
  private let canvasPresetStore: AnnotateCanvasPresetStore
  private let defaults: UserDefaults
  private let appliesDefaultCanvasPresetOnNewImages: Bool
  private var suppressCanvasEffectChangeTracking = false

  // MARK: - Source Image

  @Published var sourceImage: NSImage?

  /// Whether an image is loaded
  var hasImage: Bool {
    sourceImage != nil
  }

  private var isQuickPropertiesSyncEnabled: Bool {
    true
  }

  // MARK: - Tool State

  @Published var selectedTool: AnnotationToolType = .selection {
    didSet { syncActiveToolProperties() }
  }

  @Published var strokeWidth: CGFloat = 3
  @Published var strokeColor: Color = .red
  @Published var fillColor: Color = .clear
  @Published var rectangleCornerRadius: CGFloat = 0
  @Published var blurType: BlurType = .pixelated
  @Published var arrowStyle: ArrowStyle = .straight
  @Published var arrowType: ArrowType = .tapered
  @Published var arrowBendDirection: ArrowBendDirection = .primary
  @Published var arrowStartHead: ArrowEndpointStyle = .none
  @Published var arrowEndHead: ArrowEndpointStyle = .arrow
  @Published var spotlightOpacity: CGFloat = 0.5
  @Published private var annotationToolProperties: [AnnotationToolType: AnnotationProperties] = [:]
  private var isQuickPropertiesGestureEditing = false
  private var quickPropertiesGestureUndoSnapshot: AnnotationSnapshot?
  // Sidebar property slider drags (e.g. text font size) coalesce undo into one
  // checkpoint per gesture instead of one snapshot per tick (see issue #335).
  private var isPropertySliderGestureEditing = false
  private var propertySliderGestureUndoSnapshot: AnnotationSnapshot?
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

  var actualPixelZoomLevel: CGFloat {
    guard fitScale > 0 else { return 1.0 }
    return clampedZoom(1.0 / fitScale)
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

  // MARK: - Background Settings

  @Published var backgroundStyle: BackgroundStyle = .none {
    didSet {
      if backgroundStyle.supportsBlurredBackgroundEffect == false, isBlurredBackgroundEnabled {
        isBlurredBackgroundEnabled = false
      }
      handleCanvasEffectDidChange()
    }
  }

  @Published var isBlurredBackgroundEnabled: Bool = false {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published var blurredBackgroundEffect: BlurredBackgroundEffect = .soft {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  var isBlurredBackgroundEffectActive: Bool {
    backgroundStyle.supportsBlurredBackgroundEffect && isBlurredBackgroundEnabled
  }

  @Published var padding: CGFloat = 0 {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published var inset: CGFloat = 0
  @Published var autoBalance: Bool = true
  @Published var shadowIntensity: CGFloat = 0.3 {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published var cornerRadius: CGFloat = AnnotateCanvasDefaults.cornerRadius {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published var imageAlignment: ImageAlignment = .center {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published var aspectRatio: AspectRatioOption = .auto {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published var aspectRatioOrientation: AspectRatioOrientation = .horizontal {
    didSet {
      handleCanvasEffectDidChange()
    }
  }

  @Published private(set) var canvasPresets: [AnnotateCanvasPreset] = []
  @Published var selectedCanvasPresetId: UUID?
  @Published private(set) var isSelectedCanvasPresetDirty: Bool = false
  @Published private(set) var defaultCanvasPresetId: UUID?
  @Published private(set) var isDefaultCanvasPresetAutoApplied = false

  enum CanvasPresetMutationResult {
    case success
    case invalidName
    case limitReached
    case unavailablePayload
    case missingSelection
  }

  var selectedCanvasPreset: AnnotateCanvasPreset? {
    guard let selectedCanvasPresetId else { return nil }
    return canvasPresets.first(where: { $0.id == selectedCanvasPresetId })
  }

  var defaultCanvasPreset: AnnotateCanvasPreset? {
    guard let defaultCanvasPresetId else { return nil }
    return canvasPresets.first(where: { $0.id == defaultCanvasPresetId })
  }

  var canUpdateSelectedCanvasPreset: Bool {
    selectedCanvasPresetId != nil && isSelectedCanvasPresetDirty
  }

  var canDeleteSelectedCanvasPreset: Bool {
    selectedCanvasPresetId != nil
  }

  var isCanvasPresetLimitReached: Bool {
    canvasPresets.count >= Self.canvasPresetLimit
  }

  var requiresRenderedOutputForSharing: Bool {
    hasUnsavedChanges || isDefaultCanvasPresetAutoApplied
  }

  var nextSuggestedCanvasPresetName: String {
    "Preset \(canvasPresets.count + 1)"
  }

  var isNoneCanvasEffectsActive: Bool {
    backgroundStyle == .none
      && abs(padding) <= 0.0001
      && abs(shadowIntensity) <= 0.0001
      && abs(cornerRadius) <= 0.0001
      && aspectRatio == .auto
  }

  var canvasEffectsSnapshot: AnnotationCanvasEffects {
    AnnotationCanvasEffects(
      backgroundStyle: backgroundStyle,
      isBlurredBackgroundEnabled: isBlurredBackgroundEnabled,
      blurredBackgroundEffect: blurredBackgroundEffect,
      padding: padding,
      inset: inset,
      autoBalance: autoBalance,
      shadowIntensity: shadowIntensity,
      cornerRadius: cornerRadius,
      imageAlignment: imageAlignment,
      aspectRatio: aspectRatio,
      aspectRatioOrientation: aspectRatioOrientation
    )
  }

  func applyCanvasEffects(
    _ effects: AnnotationCanvasEffects,
    preferredSelectedCanvasPresetId: UUID? = nil,
    preferredPresetDirtyState: Bool? = nil
  ) {
    withCanvasEffectChangeTrackingSuspended {
      backgroundStyle = effects.backgroundStyle
      isBlurredBackgroundEnabled = effects.isBlurredBackgroundEnabled && effects.backgroundStyle
        .supportsBlurredBackgroundEffect
      blurredBackgroundEffect = effects.blurredBackgroundEffect
      padding = effects.padding
      inset = effects.inset
      autoBalance = effects.autoBalance
      shadowIntensity = effects.shadowIntensity
      cornerRadius = effects.cornerRadius
      imageAlignment = effects.imageAlignment
      aspectRatio = effects.aspectRatio
      aspectRatioOrientation = effects.aspectRatioOrientation
    }

    restoreCanvasPresetSelection(
      preferredSelectedCanvasPresetId: preferredSelectedCanvasPresetId,
      preferredPresetDirtyState: preferredPresetDirtyState
    )
    isDefaultCanvasPresetAutoApplied = false

    previewPadding = nil
    previewInset = nil
    previewShadowIntensity = nil
    previewCornerRadius = nil
  }

  func loadCanvasPresets() {
    canvasPresets = canvasPresetStore.loadPresets()
    defaultCanvasPresetId = canvasPresetStore.loadDefaultPresetId(validating: canvasPresets)
    if let selectedCanvasPresetId,
       canvasPresets.contains(where: { $0.id == selectedCanvasPresetId }) == false {
      self.selectedCanvasPresetId = nil
    }
    recomputeCanvasPresetDirtyState()
  }

  func isDefaultCanvasPreset(_ preset: AnnotateCanvasPreset) -> Bool {
    defaultCanvasPresetId == preset.id
  }

  func toggleDefaultCanvasPreset(id: UUID) {
    if defaultCanvasPresetId == id {
      clearDefaultCanvasPreset()
    } else {
      setDefaultCanvasPreset(id: id)
    }
  }

  func setDefaultCanvasPreset(id: UUID) {
    guard canvasPresets.contains(where: { $0.id == id }) else { return }
    defaultCanvasPresetId = id
    canvasPresetStore.saveDefaultPresetId(id)
  }

  func clearDefaultCanvasPreset() {
    defaultCanvasPresetId = nil
    canvasPresetStore.clearDefaultPresetId()
  }

  func resetCanvasEffectsToNone() {
    let beforePayload = currentCanvasPresetPayload()
    withCanvasEffectChangeTrackingSuspended {
      backgroundStyle = .none
      isBlurredBackgroundEnabled = false
      blurredBackgroundEffect = .soft
      padding = 0
      shadowIntensity = 0
      cornerRadius = 0
      aspectRatio = .auto
      aspectRatioOrientation = .horizontal
      previewPadding = nil
      previewShadowIntensity = nil
      previewCornerRadius = nil
    }
    selectedCanvasPresetId = nil
    isSelectedCanvasPresetDirty = false
    isDefaultCanvasPresetAutoApplied = false

    if let beforePayload,
       let afterPayload = currentCanvasPresetPayload(),
       beforePayload.approximatelyEquals(afterPayload) == false {
      hasUnsavedChanges = true
    }
  }

  func applyCanvasPreset(_ preset: AnnotateCanvasPreset, marksUnsaved: Bool = true) {
    let beforePayload = currentCanvasPresetPayload()
    withCanvasEffectChangeTrackingSuspended {
      let presetBackgroundStyle = preset.payload.backgroundStyle.toBackgroundStyle()
      backgroundStyle = presetBackgroundStyle
      isBlurredBackgroundEnabled = preset.payload.isBlurredBackgroundEnabled &&
        presetBackgroundStyle.supportsBlurredBackgroundEffect
      blurredBackgroundEffect = preset.payload.blurredBackgroundEffect
      padding = preset.payload.padding
      shadowIntensity = preset.payload.shadowIntensity
      cornerRadius = preset.payload.cornerRadius
      aspectRatio = preset.payload.aspectRatio
      aspectRatioOrientation = preset.payload.aspectRatioOrientation
      previewPadding = nil
      previewShadowIntensity = nil
      previewCornerRadius = nil
    }
    selectedCanvasPresetId = preset.id
    isSelectedCanvasPresetDirty = false

    let afterPayload = currentCanvasPresetPayload()
    let didChange: Bool = if let beforePayload, let afterPayload {
      beforePayload.approximatelyEquals(afterPayload) == false
    } else {
      beforePayload != nil || afterPayload != nil
    }

    if marksUnsaved, didChange {
      isDefaultCanvasPresetAutoApplied = false
    } else if !marksUnsaved {
      isDefaultCanvasPresetAutoApplied = didChange
    }

    if marksUnsaved, didChange {
      hasUnsavedChanges = true
    }
  }

  @discardableResult
  func saveCurrentCanvasAsPreset(name: String) -> CanvasPresetMutationResult {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName.isEmpty == false else {
      return .invalidName
    }

    guard canvasPresets.count < Self.canvasPresetLimit else {
      return .limitReached
    }

    guard let payload = currentCanvasPresetPayload() else {
      return .unavailablePayload
    }

    let uniqueName = uniqueCanvasPresetName(from: trimmedName)
    let preset = AnnotateCanvasPreset(name: uniqueName, payload: payload)
    canvasPresets.insert(preset, at: 0)
    selectedCanvasPresetId = preset.id
    isSelectedCanvasPresetDirty = false
    persistCanvasPresets()
    return .success
  }

  @discardableResult
  func updateSelectedCanvasPreset() -> CanvasPresetMutationResult {
    guard let selectedCanvasPresetId,
          let index = canvasPresets.firstIndex(where: { $0.id == selectedCanvasPresetId }) else {
      return .missingSelection
    }

    guard let payload = currentCanvasPresetPayload() else {
      return .unavailablePayload
    }

    var updatedPreset = canvasPresets[index]
    updatedPreset.payload = payload
    updatedPreset.updatedAt = Date()
    canvasPresets.remove(at: index)
    canvasPresets.insert(updatedPreset, at: 0)
    self.selectedCanvasPresetId = updatedPreset.id
    isSelectedCanvasPresetDirty = false
    persistCanvasPresets()
    return .success
  }

  @discardableResult
  func deleteSelectedCanvasPreset() -> Bool {
    guard let selectedCanvasPresetId else {
      return false
    }
    return deleteCanvasPreset(id: selectedCanvasPresetId)
  }

  @discardableResult
  func deleteCanvasPreset(id: UUID) -> Bool {
    let isDeletingSelectedPreset = selectedCanvasPresetId == id

    let countBefore = canvasPresets.count
    canvasPresets.removeAll(where: { $0.id == id })
    guard canvasPresets.count != countBefore else {
      return false
    }

    if isDeletingSelectedPreset {
      selectedCanvasPresetId = nil
      isSelectedCanvasPresetDirty = false
    } else {
      recomputeCanvasPresetDirtyState()
    }

    if defaultCanvasPresetId == id {
      clearDefaultCanvasPreset()
    }

    persistCanvasPresets()
    return true
  }

  func recomputeCanvasPresetDirtyState() {
    guard let selectedPreset = selectedCanvasPreset else {
      isSelectedCanvasPresetDirty = false
      return
    }

    guard let currentPayload = currentCanvasPresetPayload() else {
      isSelectedCanvasPresetDirty = true
      return
    }

    isSelectedCanvasPresetDirty = currentPayload.approximatelyEquals(selectedPreset.payload) == false
  }

  private func handleCanvasEffectDidChange() {
    recomputeCanvasPresetDirtyState()
    guard !suppressCanvasEffectChangeTracking else { return }
    isDefaultCanvasPresetAutoApplied = false
    hasUnsavedChanges = true
  }

  private func withCanvasEffectChangeTrackingSuspended(_ operation: () -> Void) {
    suppressCanvasEffectChangeTracking = true
    operation()
    suppressCanvasEffectChangeTracking = false
    recomputeCanvasPresetDirtyState()
  }

  private func currentCanvasPresetPayload() -> AnnotateCanvasPresetPayload? {
    guard let codableStyle = CodableBackgroundStyle(from: backgroundStyle) else {
      return nil
    }

    return AnnotateCanvasPresetPayload(
      backgroundStyle: codableStyle,
      isBlurredBackgroundEnabled: isBlurredBackgroundEffectActive,
      blurredBackgroundEffect: blurredBackgroundEffect,
      padding: padding,
      shadowIntensity: shadowIntensity,
      cornerRadius: cornerRadius,
      aspectRatio: aspectRatio,
      aspectRatioOrientation: aspectRatioOrientation
    )
  }

  private func restoreCanvasPresetSelection(
    preferredSelectedCanvasPresetId: UUID?,
    preferredPresetDirtyState: Bool?
  ) {
    if let preferredSelectedCanvasPresetId,
       canvasPresets.contains(where: { $0.id == preferredSelectedCanvasPresetId }) {
      selectedCanvasPresetId = preferredSelectedCanvasPresetId
      if let preferredPresetDirtyState {
        isSelectedCanvasPresetDirty = preferredPresetDirtyState
      } else {
        recomputeCanvasPresetDirtyState()
      }
      return
    }

    guard let currentPayload = currentCanvasPresetPayload(),
          let matchingPreset = canvasPresets.first(where: { $0.payload.approximatelyEquals(currentPayload) }) else {
      selectedCanvasPresetId = nil
      isSelectedCanvasPresetDirty = false
      return
    }

    selectedCanvasPresetId = matchingPreset.id
    isSelectedCanvasPresetDirty = false
  }

  private func uniqueCanvasPresetName(
    from baseName: String,
    excludingId: UUID? = nil
  ) -> String {
    let normalizedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedBaseName.isEmpty == false else {
      return nextSuggestedCanvasPresetName
    }

    let existingNames = Set(
      canvasPresets
        .filter { preset in
          guard let excludingId else { return true }
          return preset.id != excludingId
        }
        .map { $0.name.lowercased() }
    )

    if existingNames.contains(normalizedBaseName.lowercased()) == false {
      return normalizedBaseName
    }

    var suffix = 2
    while suffix < 1_000 {
      let candidate = "\(normalizedBaseName) \(suffix)"
      if existingNames.contains(candidate.lowercased()) == false {
        return candidate
      }
      suffix += 1
    }

    return "\(normalizedBaseName) \(UUID().uuidString.prefix(4))"
  }

  private func persistCanvasPresets() {
    canvasPresetStore.savePresets(canvasPresets)
  }

  private func applyDefaultCanvasPresetForNewImageIfNeeded() {
    guard appliesDefaultCanvasPresetOnNewImages,
          let defaultCanvasPreset else { return }
    applyCanvasPreset(defaultCanvasPreset, marksUnsaved: false)
  }

  // MARK: - Preview Values (for smooth slider dragging)

  /// Preview values during slider drag - nil when not dragging
  @Published var previewPadding: CGFloat?
  @Published var previewInset: CGFloat?
  @Published var previewShadowIntensity: CGFloat?
  @Published var previewCornerRadius: CGFloat?

  /// Effective values for canvas rendering (preview overrides actual during drag)
  var effectivePadding: CGFloat {
    previewPadding ?? padding
  }

  var effectiveInset: CGFloat {
    previewInset ?? inset
  }

  var effectiveShadowIntensity: CGFloat {
    previewShadowIntensity ?? shadowIntensity
  }

  var effectiveCornerRadius: CGFloat {
    previewCornerRadius ?? cornerRadius
  }

  // MARK: - Display Metrics (for inset padding layout)

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

  var imageAspectRatio: CGFloat {
    imageWidth / imageHeight
  }

  var sourceImageBounds: CGRect {
    CGRect(origin: .zero, size: CGSize(width: imageWidth, height: imageHeight))
  }

  var activeAnnotationBounds: CGRect {
    sourceImageBounds
  }

  /// Calculate display scale for given container size
  /// Image shrinks to fit within (container - padding*2)
  func displayScale(for containerSize: CGSize, margin: CGFloat = 40) -> CGFloat {
    let availableWidth = containerSize.width - margin * 2
    let availableHeight = containerSize.height - margin * 2

    // Available space for image after padding
    let imageAreaWidth = max(availableWidth - padding * 2, 1)
    let imageAreaHeight = max(availableHeight - padding * 2, 1)

    let scaleX = imageAreaWidth / imageWidth
    let scaleY = imageAreaHeight / imageHeight

    return min(scaleX, scaleY, 1.0) // Don't scale up
  }

  /// Calculate image offset within container based on alignment
  /// Note: ZStack centers children, so offset is relative to center (not top-left)
  /// - containerSize: The background size (already scaled)
  /// - imageDisplaySize: The image size (already scaled)
  /// - displayPadding: The padding in display coordinates (already scaled) - unused for seamless alignment
  func imageOffset(for containerSize: CGSize, imageDisplaySize: CGSize, displayPadding _: CGFloat) -> CGPoint {
    // For SEAMLESS edge alignment: use total extra space (container - image)
    // This moves image to touch the background edge with NO gap
    let totalExtraWidth = containerSize.width - imageDisplaySize.width
    let totalExtraHeight = containerSize.height - imageDisplaySize.height

    // In ZStack, children are centered. Offset is relative to center.
    // For center: offset = 0
    // For edges: offset = +/- totalExtraSpace/2 (moves image to touch edge)
    let xOffset: CGFloat
    let yOffset: CGFloat

    switch imageAlignment {
    case .center:
      xOffset = 0
      yOffset = 0
    case .topLeft:
      xOffset = -totalExtraWidth / 2
      yOffset = -totalExtraHeight / 2 // Negative Y = move up toward top
    case .top:
      xOffset = 0
      yOffset = -totalExtraHeight / 2
    case .topRight:
      xOffset = totalExtraWidth / 2
      yOffset = -totalExtraHeight / 2
    case .left:
      xOffset = -totalExtraWidth / 2
      yOffset = 0
    case .right:
      xOffset = totalExtraWidth / 2
      yOffset = 0
    case .bottomLeft:
      xOffset = -totalExtraWidth / 2
      yOffset = totalExtraHeight / 2 // Positive Y = move down toward bottom
    case .bottom:
      xOffset = 0
      yOffset = totalExtraHeight / 2
    case .bottomRight:
      xOffset = totalExtraWidth / 2
      yOffset = totalExtraHeight / 2
    }

    return CGPoint(x: xOffset, y: yOffset)
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

  init(
    defaults: UserDefaults = .standard,
    canvasPresetStore: AnnotateCanvasPresetStore? = nil,
    appliesDefaultCanvasPresetOnNewImages: Bool = true
  ) {
    self.defaults = defaults
    self.canvasPresetStore = canvasPresetStore ?? AnnotateCanvasPresetStore.shared
    self.appliesDefaultCanvasPresetOnNewImages = appliesDefaultCanvasPresetOnNewImages
    sourceImage = nil
    loadSharedAnnotationColor()
    loadSharedAnnotationParameterDefaults()
    loadAnnotationToolProperties()
    loadCanvasPresets()
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

    return AnnotateRenderSnapshot(
      sourceImage: sourceImage,
      annotations: annotations,
      backgroundStyle: backgroundStyle,
      isBlurredBackgroundEffectActive: isBlurredBackgroundEffectActive,
      blurredBackgroundEffect: blurredBackgroundEffect,
      padding: padding,
      cornerRadius: cornerRadius,
      shadowIntensity: shadowIntensity,
      imageAlignment: imageAlignment,
      aspectRatio: aspectRatio,
      aspectRatioOrientation: aspectRatioOrientation
    )
  }

  private func resetCanvasForNewBaseImage(image: NSImage) {
    let shouldApplyDefaultPreset = !hasImage
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
    isDefaultCanvasPresetAutoApplied = false

    if shouldApplyDefaultPreset {
      applyDefaultCanvasPresetForNewImageIfNeeded()
    }
  }

  /// Load image and adjust size for Retina displays
  static func loadImageWithCorrectScale(from url: URL) -> NSImage? {
    guard let image = SandboxFileAccessManager.shared.withScopedAccess(to: url, {
      NSImage(contentsOf: url)
    }) else { return nil }

    let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
    if let normalizedSize = normalizedRetinaLogicalSizeIfNeeded(for: image, scaleFactor: scaleFactor) {
      image.size = normalizedSize
    }

    return image
  }

  private static func normalizedRetinaLogicalSizeIfNeeded(
    for image: NSImage,
    scaleFactor: CGFloat
  ) -> NSSize? {
    guard scaleFactor > 1 else { return nil }
    guard let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
      return nil
    }

    let pixelWidth = CGFloat(rep.pixelsWide)
    let pixelHeight = CGFloat(rep.pixelsHigh)
    let currentSize = image.size
    let expectedSize = NSSize(
      width: pixelWidth / scaleFactor,
      height: pixelHeight / scaleFactor
    )

    let isAlreadyScaled =
      abs(currentSize.width - expectedSize.width) < 0.5 &&
      abs(currentSize.height - expectedSize.height) < 0.5
    if isAlreadyScaled {
      return nil
    }

    let isUnscaledLogicalSize =
      abs(currentSize.width - pixelWidth) < 0.5 &&
      abs(currentSize.height - pixelHeight) < 0.5
    return isUnscaledLogicalSize ? expectedSize : nil
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
    isDefaultCanvasPresetAutoApplied = false
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
    if annotations[index].properties.textPresentation == .callout,
       let tailTarget = annotations[index].properties.calloutTailTarget,
       TextBubbleGeometry.isDefaultTail(
         tailTarget,
         for: currentBounds,
         fontSize: annotations[index].properties.fontSize
       ) {
      annotations[index].properties.calloutTailTarget = defaultCalloutTailTarget(
        for: newBounds,
        fontSize: annotations[index].properties.fontSize
      )
    }
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
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    spotlightOpacity: CGFloat? = nil,
    recordsUndo: Bool = false
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    let colorUpdate = normalizedColorUpdate(
      for: annotations[index],
      strokeColor: strokeColor,
      fillColor: fillColor
    )

    guard annotationPropertiesWillChange(
      annotations[index],
      strokeWidth: strokeWidth,
      fontSize: fontSize,
      strokeColor: colorUpdate.strokeColor,
      fillColor: colorUpdate.fillColor,
      cornerRadius: cornerRadius,
      spotlightOpacity: spotlightOpacity
    ) else { return }

    if recordsUndo {
      if let snapshot = propertySliderGestureUndoSnapshot {
        pushUndoSnapshot(snapshot, annotationCount: snapshot.annotations.count)
        propertySliderGestureUndoSnapshot = nil
      } else if !isPropertySliderGestureEditing {
        saveState()
      }
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
    if let strokeColor = colorUpdate.strokeColor {
      annotations[index].properties.strokeColor = strokeColor
    }
    if let fillColor = colorUpdate.fillColor {
      annotations[index].properties.fillColor = fillColor
    }
    if let cornerRadius {
      annotations[index].properties.cornerRadius = max(0, cornerRadius)
    }
    if let spotlightOpacity {
      annotations[index].properties.spotlightOpacity = AnnotationProperties.clampedSpotlightOpacity(spotlightOpacity)
    }

    // Spotlight dimming paints the full canvas — its opacity edits need a full
    // redraw; everything else is scoped to the edited annotation's bounds.
    if spotlightOpacity != nil {
      pendingFullCanvasInvalidation = true
    } else {
      pendingPropertyEditRects.append(oldSelectionBounds.union(annotations[index].selectionBounds))
    }
    hasUnsavedChanges = true
  }

  func updateAnnotationPrimaryColor(
    id: UUID,
    color: Color,
    recordsUndo: Bool = false
  ) {
    updateAnnotationProperties(
      id: id,
      strokeColor: color,
      recordsUndo: recordsUndo
    )
    if isQuickPropertiesSyncEnabled {
      rememberSharedAnnotationColor(color)
    }
  }

  private func normalizedColorUpdate(
    for annotation: AnnotationItem,
    strokeColor: Color?,
    fillColor: Color?
  ) -> (strokeColor: Color?, fillColor: Color?) {
    if case .filledRectangle = annotation.type,
       let color = strokeColor ?? fillColor {
      return (color, color)
    }

    return (strokeColor, fillColor)
  }

  private func annotationPropertiesWillChange(
    _ annotation: AnnotationItem,
    strokeWidth: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    strokeColor: Color? = nil,
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    spotlightOpacity: CGFloat? = nil
  ) -> Bool {
    let properties = annotation.properties
    let colorUpdate = normalizedColorUpdate(
      for: annotation,
      strokeColor: strokeColor,
      fillColor: fillColor
    )

    if let strokeWidth,
       properties.strokeWidth != AnnotationProperties.clampedControlValue(strokeWidth) {
      return true
    }
    if let fontSize,
       properties.fontSize != fontSize {
      return true
    }
    if let strokeColor = colorUpdate.strokeColor,
       properties.strokeColor != strokeColor {
      return true
    }
    if let fillColor = colorUpdate.fillColor,
       properties.fillColor != fillColor {
      return true
    }
    if let cornerRadius,
       properties.cornerRadius != max(0, cornerRadius) {
      return true
    }
    if let spotlightOpacity,
       properties.spotlightOpacity != AnnotationProperties.clampedSpotlightOpacity(spotlightOpacity) {
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
    fontName: String? = nil,
    constrainedWidth: CGFloat? = nil,
    maximumHeight: CGFloat = AnnotateTextLayout.maxHeight,
    presentation: TextPresentation = .plain
  ) -> CGRect {
    AnnotateTextLayout.bounds(
      text: text,
      font: AnnotateTextLayout.font(size: fontSize, fontName: fontName),
      origin: origin,
      constrainedWidth: constrainedWidth,
      maximumHeight: maximumHeight,
      presentation: presentation
    )
  }

  private func resizedTextBounds(
    id: UUID,
    text: String,
    properties: AnnotationProperties,
    currentBounds: CGRect
  ) -> CGRect {
    let font = AnnotateTextLayout.font(size: properties.fontSize, fontName: properties.fontName)
    let annotationBounds = activeAnnotationBounds.standardized
    let topY = currentBounds.maxY
    let availableWidth = max(annotationBounds.maxX - currentBounds.minX, AnnotateTextLayout.minWidth)
    let availableHeight = max(
      topY - annotationBounds.minY,
      AnnotateTextLayout.minimumHeight(for: font, presentation: properties.textPresentation)
    )
    let targetWidth: CGFloat = if autoSizingTextAnnotationIDs.contains(id) {
      AnnotateTextLayout.preferredAutoWidth(
        text: text,
        font: font,
        minimumWidth: AnnotateTextLayout.minWidth,
        maximumWidth: availableWidth,
        presentation: properties.textPresentation
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
      fontName: properties.fontName,
      constrainedWidth: targetWidth,
      maximumHeight: availableHeight,
      presentation: properties.textPresentation
    )
    bounds.origin.y = topY - bounds.height
    return bounds
  }

  /// Get selected annotation if it's a text type
  var selectedTextAnnotation: AnnotationItem? {
    guard let annotation = selectedAnnotation,
          case .text = annotation.type else {
      return nil
    }
    return annotation
  }

  /// Get selected annotation (any type)
  var selectedAnnotation: AnnotationItem? {
    guard selectedAnnotationIds.count == 1,
          let id = selectedAnnotationIds.first else { return nil }
    return annotations.first { $0.id == id }
  }

  var selectedArrowAnnotation: AnnotationItem? {
    guard let annotation = selectedAnnotation,
          case .arrow = annotation.type else {
      return nil
    }
    return annotation
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
    applySharedAnnotationColorToToolDefaults(color)
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

  private func loadAnnotationToolProperties() {
    guard let data = defaults.data(forKey: PreferencesKeys.annotateToolParameterDefaults),
          let decoded = try? JSONDecoder().decode([String: PersistedAnnotationProperties].self, from: data)
    else { return }

    annotationToolProperties = decoded.reduce(into: [:]) { result, entry in
      guard let tool = AnnotationToolType(rawValue: entry.key) else { return }
      result[tool] = sanitizedAnnotationProperties(entry.value.annotationProperties, for: tool)
    }
  }

  private func persistAnnotationToolProperties() {
    let payload = annotationToolProperties.reduce(into: [String: PersistedAnnotationProperties]()) { result, entry in
      guard let persisted = PersistedAnnotationProperties(entry.value) else { return }
      result[entry.key.rawValue] = persisted
    }

    guard let data = try? JSONEncoder().encode(payload) else { return }
    defaults.set(data, forKey: PreferencesKeys.annotateToolParameterDefaults)
  }

  private func sanitizedAnnotationProperties(
    _ properties: AnnotationProperties,
    for tool: AnnotationToolType
  ) -> AnnotationProperties {
    var sanitized = properties
    sanitized.strokeWidth = AnnotationProperties.clampedControlValue(properties.strokeWidth)
    sanitized.cornerRadius = max(0, properties.cornerRadius)
    sanitized.fontSize = min(max(properties.fontSize, 12), 72)
    sanitized.spotlightOpacity = AnnotationProperties.clampedSpotlightOpacity(properties.spotlightOpacity)
    if tool == .filledRectangle {
      sanitized.fillColor = sanitized.strokeColor
    }
    return sanitized
  }

  private func rememberSharedAnnotationStrokeWidth(_ strokeWidth: CGFloat) {
    let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    sharedAnnotationParameterDefaults.strokeWidth = clampedWidth
    persistSharedAnnotationParameterDefaults()

    for tool in AnnotationToolType.allCases where tool.supportsQuickStrokeWidth {
      updateDefaultAnnotationProperties(for: tool, strokeWidth: clampedWidth)
    }

    if !selectedTool.supportsQuickPropertiesBar {
      self.strokeWidth = clampedWidth
    }
  }

  private func rememberSharedAnnotationCornerRadius(_ cornerRadius: CGFloat) {
    let clampedRadius = max(0, cornerRadius)
    sharedAnnotationParameterDefaults.cornerRadius = clampedRadius
    persistSharedAnnotationParameterDefaults()

    for tool in AnnotationToolType.allCases where tool.supportsQuickCornerRadius && tool != .spotlight {
      updateDefaultAnnotationProperties(for: tool, cornerRadius: clampedRadius)
    }

    if !selectedTool.supportsQuickPropertiesBar {
      rectangleCornerRadius = clampedRadius
    }
  }

  private func rememberSharedSpotlightCornerRadius(_ cornerRadius: CGFloat) {
    let clampedRadius = max(0, cornerRadius)
    sharedAnnotationParameterDefaults.spotlightCornerRadius = clampedRadius
    persistSharedAnnotationParameterDefaults()
    updateDefaultAnnotationProperties(for: .spotlight, cornerRadius: clampedRadius)
  }

  private func rememberSharedAnnotationFontSize(_ fontSize: CGFloat) {
    let clampedSize = min(max(fontSize, 12), 72)
    sharedAnnotationParameterDefaults.fontSize = clampedSize
    persistSharedAnnotationParameterDefaults()

    updateDefaultAnnotationProperties(for: .text, fontSize: clampedSize)
  }

  private func rememberAnnotationPrimaryColor(_ color: Color, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationColor(color)
      return
    }

    if let tool, tool.supportsQuickStrokeColor {
      updateDefaultAnnotationProperties(for: tool, strokeColor: color)
    } else {
      strokeColor = color
    }
  }

  private func rememberAnnotationStrokeWidth(_ strokeWidth: CGFloat, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationStrokeWidth(strokeWidth)
      return
    }

    let clampedWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    if let tool, tool.supportsQuickStrokeWidth {
      updateDefaultAnnotationProperties(for: tool, strokeWidth: clampedWidth)
    } else {
      self.strokeWidth = clampedWidth
    }
  }

  private func rememberAnnotationCornerRadius(_ cornerRadius: CGFloat, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      if tool == .spotlight {
        rememberSharedSpotlightCornerRadius(cornerRadius)
      } else {
        rememberSharedAnnotationCornerRadius(cornerRadius)
      }
      return
    }

    let clampedRadius = max(0, cornerRadius)
    if let tool, tool.supportsQuickCornerRadius {
      updateDefaultAnnotationProperties(for: tool, cornerRadius: clampedRadius)
    } else {
      rectangleCornerRadius = clampedRadius
    }
  }

  private func rememberAnnotationFontSize(_ fontSize: CGFloat, for tool: AnnotationToolType?) {
    guard !isQuickPropertiesSyncEnabled else {
      rememberSharedAnnotationFontSize(fontSize)
      return
    }

    let clampedSize = min(max(fontSize, 12), 72)
    if let tool, tool == .text {
      updateDefaultAnnotationProperties(for: tool, fontSize: clampedSize)
    }
  }

  private func applySharedAnnotationColorToToolDefaults(_ color: Color) {
    for tool in AnnotationToolType.allCases where tool.supportsQuickStrokeColor {
      var properties = defaultAnnotationProperties(for: tool)
      properties.strokeColor = color
      if tool == .filledRectangle {
        properties.fillColor = color
      }
      annotationToolProperties[tool] = properties
    }
    persistAnnotationToolProperties()

    if selectedTool.supportsQuickPropertiesBar {
      applyToolPropertiesToLegacyState(defaultAnnotationProperties(for: selectedTool), for: selectedTool)
    } else {
      strokeColor = color
    }
  }

  private func defaultAnnotationProperties(for tool: AnnotationToolType?) -> AnnotationProperties {
    guard let tool else {
      var properties = AnnotationProperties(strokeColor: sharedAnnotationColor ?? .red)
      applySharedParameterDefaults(to: &properties, for: nil)
      return properties
    }
    var properties = annotationToolProperties[tool] ?? baseAnnotationProperties(for: tool)
    if isQuickPropertiesSyncEnabled {
      applySynchronizedQuickProperties(to: &properties, for: tool)
    }

    return properties
  }

  private func baseAnnotationProperties(for tool: AnnotationToolType) -> AnnotationProperties {
    if tool == .spotlight {
      var properties = AnnotationProperties(
        strokeColor: sharedAnnotationColor ?? .red,
        fillColor: .clear,
        strokeWidth: 3,
        cornerRadius: 14,
        spotlightOpacity: spotlightOpacity
      )
      applySharedParameterDefaults(to: &properties, for: tool)
      return properties
    }
    var properties = AnnotationProperties(strokeColor: sharedAnnotationColor ?? .red)
    if tool == .blur {
      properties.strokeWidth = AnnotationProperties.controlValueRange.lowerBound
    }
    applySharedParameterDefaults(to: &properties, for: tool)
    if tool == .filledRectangle {
      properties.fillColor = properties.strokeColor
    }
    return properties
  }

  private func applySynchronizedQuickProperties(
    to properties: inout AnnotationProperties,
    for tool: AnnotationToolType
  ) {
    let sharedProperties = baseAnnotationProperties(for: tool)

    if tool.supportsQuickStrokeColor {
      properties.strokeColor = sharedProperties.strokeColor
      if tool == .filledRectangle {
        properties.fillColor = sharedProperties.strokeColor
      }
    }

    if tool.supportsQuickStrokeWidth {
      properties.strokeWidth = sharedProperties.strokeWidth
    }

    if tool.supportsQuickCornerRadius {
      properties.cornerRadius = sharedProperties.cornerRadius
    }

    if tool == .text {
      properties.fontSize = sharedProperties.fontSize
    }
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
    if tool == .filledRectangle {
      properties.fillColor = properties.strokeColor
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
    sharedAnnotationParameterDefaults.fontSize == nil && annotationToolProperties[.text] == nil
  }

  private func updateDefaultAnnotationProperties(
    for tool: AnnotationToolType,
    strokeWidth: CGFloat? = nil,
    strokeColor: Color? = nil,
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    fontName: String? = nil,
    spotlightOpacity: CGFloat? = nil
  ) {
    var properties = defaultAnnotationProperties(for: tool)

    if let strokeWidth {
      properties.strokeWidth = AnnotationProperties.clampedControlValue(strokeWidth)
    }
    if tool == .filledRectangle,
       let color = strokeColor ?? fillColor {
      properties.strokeColor = color
      properties.fillColor = color
    } else {
      if let strokeColor {
        properties.strokeColor = strokeColor
      }
      if let fillColor {
        properties.fillColor = fillColor
      }
    }
    if let cornerRadius {
      properties.cornerRadius = max(0, cornerRadius)
    }
    if let fontSize {
      properties.fontSize = min(max(fontSize, 12), 72)
    }
    if let fontName {
      properties.fontName = fontName
    }
    if let spotlightOpacity {
      properties.spotlightOpacity = AnnotationProperties.clampedSpotlightOpacity(spotlightOpacity)
    }

    let sanitized = sanitizedAnnotationProperties(properties, for: tool)
    annotationToolProperties[tool] = sanitized
    persistAnnotationToolProperties()
    if selectedTool == tool {
      applyToolPropertiesToLegacyState(sanitized, for: tool)
    }
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
    applyToolPropertiesToLegacyState(defaultAnnotationProperties(for: selectedTool), for: selectedTool)
  }

  private func applyToolPropertiesToLegacyState(
    _ properties: AnnotationProperties,
    for tool: AnnotationToolType
  ) {
    strokeColor = properties.strokeColor
    fillColor = properties.fillColor
    strokeWidth = properties.strokeWidth
    if tool.supportsQuickCornerRadius {
      rectangleCornerRadius = properties.cornerRadius
    }
    if tool == .spotlight {
      spotlightOpacity = properties.spotlightOpacity
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

  /// Marks a sidebar property slider drag as one undo gesture. The pre-gesture
  /// snapshot is pushed once on the first actual change; a drag that changes
  /// nothing records no undo entry.
  func setPropertySliderGestureEditing(_ isEditing: Bool) {
    if isEditing {
      guard !isPropertySliderGestureEditing else { return }
      isPropertySliderGestureEditing = true
      propertySliderGestureUndoSnapshot = currentSnapshot()
    } else {
      isPropertySliderGestureEditing = false
      propertySliderGestureUndoSnapshot = nil
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
    fillColor: Color? = nil,
    cornerRadius: CGFloat? = nil,
    fontSize: CGFloat? = nil,
    spotlightOpacity: CGFloat? = nil,
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
        fillColor: fillColor,
        cornerRadius: cornerRadius,
        spotlightOpacity: spotlightOpacity
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
        fillColor: fillColor,
        cornerRadius: cornerRadius,
        spotlightOpacity: spotlightOpacity
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

  var quickPropertiesSupportsTextBackground: Bool {
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

  var quickPropertiesSupportsTextPresentation: Bool {
    quickPropertiesSupportsTextBackground
  }

  var quickTextPresentation: TextPresentation {
    quickSelectionTargets(matching: {
      if case .text = $0 {
        return true
      }
      return false
    }).first?.properties.textPresentation
      ?? defaultAnnotationProperties(for: quickPropertiesTool).textPresentation
  }

  func setTextPresentation(_ presentation: TextPresentation) {
    let selected = quickSelectionTargets(matching: {
      if case .text = $0 {
        return true
      }
      return false
    })

    guard !selected.isEmpty else {
      guard quickPropertiesTool == .text else { return }
      var properties = defaultAnnotationProperties(for: .text)
      properties.textPresentation = presentation
      properties.calloutTailTarget = nil
      if presentation != .plain, properties.fillColor == .clear {
        properties.fillColor = .black
      }
      annotationToolProperties[.text] = properties
      return
    }

    saveState()
    for annotation in selected {
      guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { continue }
      annotations[index].properties.textPresentation = presentation
      if presentation == .plain {
        annotations[index].properties.calloutTailTarget = nil
      } else if presentation == .callout {
        annotations[index].properties.calloutTailTarget = annotations[index].properties.calloutTailTarget
          ?? defaultCalloutTailTarget(for: annotations[index].bounds, fontSize: annotations[index].properties.fontSize)
      } else {
        annotations[index].properties.calloutTailTarget = nil
      }
      if presentation != .plain, annotations[index].properties.fillColor == .clear {
        annotations[index].properties.fillColor = .black
      }
    }
    hasUnsavedChanges = true
  }

  func prepareTextCalloutTail(for id: UUID) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text = annotations[index].type,
          annotations[index].properties.textPresentation == .callout,
          annotations[index].properties.calloutTailTarget == nil else { return }
    annotations[index].properties.calloutTailTarget = defaultCalloutTailTarget(
      for: annotations[index].bounds,
      fontSize: annotations[index].properties.fontSize
    )
  }

  func updateTextCalloutTail(id: UUID, target: CGPoint) {
    guard let index = annotations.firstIndex(where: { $0.id == id }),
          case .text = annotations[index].type,
          annotations[index].properties.textPresentation == .callout else { return }
    annotations[index].properties.calloutTailTarget = TextBubbleGeometry.resolvedTailTarget(
      in: annotations[index].bounds,
      requestedTarget: target,
      fontSize: annotations[index].properties.fontSize
    )
    hasUnsavedChanges = true
  }

  private func defaultCalloutTailTarget(for bounds: CGRect, fontSize: CGFloat) -> CGPoint {
    TextBubbleGeometry.defaultTailTarget(for: bounds, fontSize: fontSize)
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
          rememberAnnotationFontSize(clampedSize, for: quickPropertiesTool)
        }
      }
    )
  }

  var quickTextBackgroundBinding: Binding<Color> {
    Binding(
      get: { [weak self] in
        guard let self else { return .clear }
        return quickSelectionTargets(matching: {
          if case .text = $0 {
            return true
          }
          return false
        }).first?.properties.fillColor
          ?? defaultAnnotationProperties(for: quickPropertiesTool).fillColor
      },
      set: { [weak self] newColor in
        guard let self else { return }
        if !updateQuickSelectionProperties(
          fillColor: newColor,
          recordsUndo: true,
          matching: {
            if case .text = $0 {
              return true
            }
            return false
          }
        ) {
          if let tool = quickPropertiesTool {
            updateDefaultAnnotationProperties(for: tool, fillColor: newColor)
          }
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

  var quickPropertiesSelectedAnnotationCount: Int {
    quickPropertiesSelectionAnnotations.count
  }

  var quickPropertiesShowsSelectionStyle: Bool {
    if quickPropertiesSelectionAnnotations.isEmpty {
      return selectedTool == .selection
    }

    return quickPropertiesSelectionAnnotations.allSatisfy { annotation in
      annotation.type.toolType == .selection || !annotation.type.supportsQuickPropertiesBar
    }
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

  var quickPropertiesSupportsFill: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport { $0.supportsQuickFillColor }
    }
    return quickPropertiesTool?.supportsQuickFillColor ?? false
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

  var quickPropertiesSupportsSpotlightOpacity: Bool {
    if !quickPropertiesSelectionAnnotations.isEmpty {
      return quickSelectionAnySupport {
        if case .spotlight = $0 {
          return true
        }
        return false
      }
    }
    return quickPropertiesTool == .spotlight
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
        let didUpdateSelection = updateQuickSelectionProperties(
          strokeColor: newColor,
          recordsUndo: true,
          matching: { $0.supportsQuickStrokeColor }
        )
        if didUpdateSelection {
          if isQuickPropertiesSyncEnabled {
            rememberSharedAnnotationColor(newColor)
          }
        } else {
          rememberAnnotationPrimaryColor(newColor, for: quickPropertiesTool)
        }
        if !didUpdateSelection, quickPropertiesTool == nil {
          strokeColor = newColor
        }
      }
    )
  }

  var quickFillColorBinding: Binding<Color> {
    Binding(
      get: { [weak self] in
        guard let self else { return .clear }
        return quickSelectionTargets(matching: { $0.supportsQuickFillColor }).first?.properties.fillColor
          ?? defaultAnnotationProperties(for: quickPropertiesTool).fillColor
      },
      set: { [weak self] newColor in
        guard let self else { return }
        if !updateQuickSelectionProperties(
          fillColor: newColor,
          recordsUndo: true,
          matching: { $0.supportsQuickFillColor }
        ) {
          if let tool = quickPropertiesTool {
            updateDefaultAnnotationProperties(for: tool, fillColor: newColor)
          } else {
            fillColor = newColor
          }
        }
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
          rememberAnnotationStrokeWidth(newWidth, for: quickPropertiesTool)
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

  var quickSpotlightOpacityBinding: Binding<CGFloat> {
    Binding(
      get: { [weak self] in
        guard let self else { return 0.5 }
        return quickSelectionTargets(matching: {
          if case .spotlight = $0 {
            return true
          }
          return false
        }).first?.properties.spotlightOpacity
          ?? defaultAnnotationProperties(for: quickPropertiesTool).spotlightOpacity
      },
      set: { [weak self] newOpacity in
        guard let self else { return }
        if !updateQuickSelectionProperties(
          spotlightOpacity: newOpacity,
          recordsUndo: true,
          matching: {
            if case .spotlight = $0 {
              return true
            }
            return false
          }
        ) {
          rememberAnnotationSpotlightOpacity(newOpacity, for: quickPropertiesTool)
        }
      }
    )
  }

  private func rememberAnnotationSpotlightOpacity(_ opacity: CGFloat, for tool: AnnotationToolType?) {
    let clampedOpacity = AnnotationProperties.clampedSpotlightOpacity(opacity)
    // Always sync the global published value so annotationCreationProperties picks it up for new regions.
    spotlightOpacity = clampedOpacity
    if let tool, tool == .spotlight {
      updateDefaultAnnotationProperties(for: tool, spotlightOpacity: clampedOpacity)
    }
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

  static func font(size: CGFloat, fontName: String? = nil) -> NSFont {
    let clampedSize = min(max(size, 8), 144)

    if let fontName,
       let namedFont = NSFont(name: fontName, size: clampedSize) {
      return namedFont
    }

    return NSFont.systemFont(ofSize: clampedSize)
  }

  static func displayFont(size: CGFloat, fontName: String? = nil, scale: CGFloat) -> NSFont {
    let baseFont = font(size: size, fontName: fontName)
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
    maximumHeight: CGFloat = maxHeight,
    presentation: TextPresentation = .plain
  ) -> CGRect {
    let finalWidth: CGFloat = if let constrainedWidth {
      clampedWidth(constrainedWidth)
    } else {
      preferredAutoWidth(text: text, font: font, presentation: presentation)
    }

    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    let contentWidth = max(finalWidth - insets.width * 2, minContentWidth)
    let contentHeight = ceil(contentSize(for: text, font: font, constrainedWidth: contentWidth).height)
    let resolvedMaximumHeight = max(minimumHeight(for: font), min(maximumHeight, maxHeight))
    let finalHeight = min(
      max(contentHeight + insets.height * 2, minimumHeight(for: font, presentation: presentation)),
      resolvedMaximumHeight
    )

    return CGRect(
      x: origin.x,
      y: origin.y,
      width: finalWidth,
      height: finalHeight
    )
  }

  static func textRect(for text: String, font: NSFont, in bounds: CGRect,
                       presentation: TextPresentation = .plain) -> CGRect {
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    let contentWidth = max(bounds.width - insets.width * 2, minContentWidth)
    let contentHeight = ceil(contentSize(for: text, font: font, constrainedWidth: contentWidth).height)
    let drawHeight = min(contentHeight, max(bounds.height, 0))
    let verticalInset = max((bounds.height - drawHeight) / 2, 0)

    return CGRect(
      x: bounds.minX + insets.width,
      y: bounds.minY + verticalInset,
      width: contentWidth,
      height: drawHeight
    )
  }

  static func measuredHeight(text: String, font: NSFont, constrainedWidth: CGFloat) -> CGFloat {
    bounds(
      text: text,
      font: font,
      origin: .zero,
      constrainedWidth: constrainedWidth
    ).height
  }

  static func textEditorInset(scale: CGFloat, presentation: TextPresentation = .plain,
                              fontSize: CGFloat = 16) -> NSSize {
    let resolvedScale = max(scale, 0.0001)
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: fontSize)
    return NSSize(
      width: insets.width * resolvedScale,
      height: insets.height * resolvedScale
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
    maximumWidth: CGFloat = maxWidth,
    presentation: TextPresentation = .plain
  ) -> CGFloat {
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    let measuredWidth = ceil(singleLineSize(for: text, font: font).width) + insets.width * 2
    let resolvedMaximumWidth = max(minWidth, min(maximumWidth, maxWidth))
    let resolvedMinimumWidth = min(max(minimumWidth, minWidth), resolvedMaximumWidth)
    return min(max(measuredWidth, resolvedMinimumWidth), resolvedMaximumWidth)
  }

  static func minimumHeight(for font: NSFont, presentation: TextPresentation = .plain) -> CGFloat {
    let insets = TextBubbleGeometry.contentInsets(for: presentation, fontSize: font.pointSize)
    return ceil(font.ascender - font.descender + font.leading) + insets.height * 2
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
