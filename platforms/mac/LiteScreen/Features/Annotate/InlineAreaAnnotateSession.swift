//
//  InlineAreaAnnotateSession.swift
//  LiteScreen
//
//  Coordinates direct area screenshot annotation before post-capture routing.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

struct InlineAreaAnnotateDisplay: Identifiable {
  let displayID: CGDirectDisplayID
  let screenFrame: CGRect
  let localFrame: CGRect
  let controlInsets: InlineAreaControlInsets
  let backdropImage: NSImage
  let backdropCGImage: CGImage

  var id: CGDirectDisplayID {
    displayID
  }
}

enum InlineAreaAnnotatePhase {
  case selecting
  case annotating
}

enum InlineAreaKeyEventSource {
  case local
  case global
}

enum InlineAreaKeyAction: Equatable {
  case passThrough
  case cancel
  case finish
  case copyCurrentImage
  case setMoveModifierActive(Bool)
  case resetMoveModifierAndPassThrough
}

@MainActor
final class InlineAreaAnnotateSession: ObservableObject {
  private struct InlineAreaCrop {
    let image: NSImage
    let localRect: CGRect
  }

  @Published var phase: InlineAreaAnnotatePhase = .selecting
  @Published var selectionRect: CGRect?
  @Published var isMoveModifierActive = false
  @Published private(set) var isSelectingOneShotOCR = false
  @Published private(set) var oneShotOCRSelectionRect: CGRect?

  let state = AnnotateState(appliesDefaultCanvasPresetOnNewImages: false)
  let desktopFrame: CGRect
  let displays: [InlineAreaAnnotateDisplay]

  private let primaryDisplayID: CGDirectDisplayID
  private let screenFramesByDisplayID: [CGDirectDisplayID: CGRect]
  private let frozenSession: FrozenAreaCaptureSession
  private let resolveSaveDirectory: () -> URL?
  private let outputFormat: ImageFormat
  private let context: CaptureContext
  let oneShotState: OneShotSessionState
  private let onOneShotHandoff: (OneShotHandoff) -> Void
  private let onComplete: (CaptureResult) -> Void
  private let windows = NSHashTable<NSWindow>.weakObjects()
  private var localKeyMonitor: Any?
  private var globalKeyMonitor: Any?
  private var selectionLocalMonitor: Any?
  private var selectionStartPoint: CGPoint?
  private var oneShotOCRSelectionStartPoint: CGPoint?
  private var stateChangeCancellable: AnyCancellable?
  private var oneShotStateCancellable: AnyCancellable?
  private var displayChangeCancellable: AnyCancellable?
  private var didComplete = false
  private var isDismissingOverlayForScreenshotExecution = false

  init(
    primaryDisplayID: CGDirectDisplayID,
    desktopFrame: CGRect,
    displays: [InlineAreaAnnotateDisplay],
    frozenSession: FrozenAreaCaptureSession,
    resolveSaveDirectory: @escaping () -> URL?,
    outputFormat: ImageFormat,
    context: CaptureContext = .empty,
    oneShotState: OneShotSessionState,
    onOneShotHandoff: @escaping (OneShotHandoff) -> Void,
    onComplete: @escaping (CaptureResult) -> Void
  ) {
    self.primaryDisplayID = primaryDisplayID
    self.desktopFrame = desktopFrame
    self.displays = displays
    screenFramesByDisplayID = Dictionary(uniqueKeysWithValues: displays.map {
      ($0.displayID, $0.screenFrame)
    })
    self.frozenSession = frozenSession
    self.resolveSaveDirectory = resolveSaveDirectory
    self.outputFormat = outputFormat
    self.context = context
    self.oneShotState = oneShotState
    self.onOneShotHandoff = onOneShotHandoff
    self.onComplete = onComplete
    stateChangeCancellable = state.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in
        self?.objectWillChange.send()
      }
    }
    oneShotStateCancellable = oneShotState.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in
        self?.objectWillChange.send()
      }
    }
    displayChangeCancellable = NotificationCenter.default.publisher(
      for: NSApplication.didChangeScreenParametersNotification
    ).sink { [weak self] _ in
      Task { @MainActor in
        self?.cancel()
      }
    }
  }

  func attach(window: NSWindow) {
    windows.add(window)
    if localKeyMonitor == nil, globalKeyMonitor == nil {
      installKeyMonitors()
    }
  }

  func refreshCursor() {
    if phase == .selecting {
      NSCursor.vectorScreenshotCrosshairLight.set()
    }
    for window in windows.allObjects {
      if let hostingView = window.contentView {
        window.invalidateCursorRects(for: hostingView)
      }
    }
  }

  func beginSelection(at localPoint: CGPoint) {
    guard phase == .selecting else { return }
    guard selectionStartPoint == nil else { return }
    oneShotState.beginSelection()
    selectionStartPoint = localPoint
    installSelectionMonitorIfNeeded()
    updateSelection(to: localPoint)
  }

  func updateSelection(to localPoint: CGPoint) {
    guard phase == .selecting, let start = selectionStartPoint else { return }
    selectionRect = clampedSelectionRect(CGRect(
      x: min(start.x, localPoint.x),
      y: min(start.y, localPoint.y),
      width: abs(localPoint.x - start.x),
      height: abs(localPoint.y - start.y)
    ).standardized)
    syncOneShotSelection(isFinal: false)
  }

  func endSelection(at localPoint: CGPoint) {
    guard phase == .selecting, selectionStartPoint != nil else { return }
    updateSelection(to: localPoint)
    removeSelectionMonitor()
    selectionStartPoint = nil

    guard let rect = selectionRect, rect.width > 5, rect.height > 5 else {
      selectionRect = nil
      _ = oneShotState.finishSelection(nil, displayIDs: [])
      return
    }
    beginAnnotating(with: rect)
    guard phase == .annotating else {
      selectionRect = nil
      _ = oneShotState.finishSelection(nil, displayIDs: [])
      return
    }
    syncOneShotSelection(isFinal: true)
    if let selectionRect {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "One Shot selection completed",
        context: [
          "height": "\(Int(selectionRect.height.rounded()))",
          "width": "\(Int(selectionRect.width.rounded()))",
        ]
      )
    }
  }

  func beginAnnotating(with localRect: CGRect) {
    let clampedRect = clampedSelectionRect(localRect.standardized)
    guard clampedRect.width > 5, clampedRect.height > 5,
          let crop = cropImage(for: clampedRect) else { return }

    selectionRect = crop.localRect
    state.loadImage(crop.image, url: nil)
    state.selectedTool = .selection
    phase = .annotating
  }

  func moveSelection(to localRect: CGRect, refreshImage: Bool) {
    guard oneShotState.selectionIsEditable else { return }
    let clampedRect = clampedSelectionRect(localRect.standardized)
    guard refreshImage else {
      selectionRect = clampedRect
      syncOneShotSelection(isFinal: false)
      return
    }
    guard let crop = cropImage(for: clampedRect) else { return }
    selectionRect = crop.localRect
    state.replaceSourceImagePreservingAnnotations(crop.image)
    syncOneShotSelection(isFinal: false)
  }

  func resizeSelection(to localRect: CGRect, previousRect: CGRect) {
    guard oneShotState.selectionIsEditable else { return }
    let clampedRect = clampedSelectionRect(localRect.standardized)
    guard clampedRect.width > 5,
          clampedRect.height > 5,
          let crop = cropImage(for: clampedRect) else { return }

    let standardizedPreviousRect = previousRect.standardized
    let annotationOffset = CGPoint(
      x: standardizedPreviousRect.minX - crop.localRect.minX,
      y: standardizedPreviousRect.minY - crop.localRect.minY
    )

    selectionRect = crop.localRect
    state.replaceSourceImagePreservingAnnotations(crop.image, annotationOffset: annotationOffset)
    syncOneShotSelection(isFinal: false)
  }

  var isOneShotSelectionEditable: Bool {
    oneShotState.selectionIsEditable
  }

  func beginOneShotReselection(at localPoint: CGPoint) {
    guard isOneShotSelectionEditable else { return }
    phase = .selecting
    selectionRect = nil
    selectionStartPoint = nil
    beginSelection(at: localPoint)
  }

  func activateOneShotOCRSelection() {
    guard phase == .annotating,
          oneShotState.activeTab == .screenshot,
          selectionRect != nil,
          commitOneShotInteraction(.screenshotOCR) else { return }
    state.commitTextEditing()
    oneShotOCRSelectionRect = nil
    oneShotOCRSelectionStartPoint = nil
    isSelectingOneShotOCR = true
  }

  func beginOneShotOCRSelection(at localPoint: CGPoint) {
    guard isSelectingOneShotOCR,
          oneShotOCRSelectionStartPoint == nil,
          let selectionRect,
          selectionRect.contains(localPoint) else { return }
    oneShotOCRSelectionStartPoint = localPoint
    installSelectionMonitorIfNeeded()
    updateOneShotOCRSelection(to: localPoint)
  }

  func updateOneShotOCRSelection(to localPoint: CGPoint) {
    guard isSelectingOneShotOCR,
          let start = oneShotOCRSelectionStartPoint,
          let selectionRect else { return }
    let point = CGPoint(
      x: min(max(localPoint.x, selectionRect.minX), selectionRect.maxX),
      y: min(max(localPoint.y, selectionRect.minY), selectionRect.maxY)
    )
    oneShotOCRSelectionRect = CGRect(
      x: min(start.x, point.x),
      y: min(start.y, point.y),
      width: abs(point.x - start.x),
      height: abs(point.y - start.y)
    ).standardized.intersection(selectionRect)
  }

  func endOneShotOCRSelection(at localPoint: CGPoint) {
    guard isSelectingOneShotOCR, oneShotOCRSelectionStartPoint != nil else { return }
    updateOneShotOCRSelection(to: localPoint)
    oneShotOCRSelectionStartPoint = nil
    removeSelectionMonitor()

    guard let rect = oneShotOCRSelectionRect,
          rect.width > 5,
          rect.height > 5 else {
      oneShotOCRSelectionRect = nil
      return
    }
    guard let crop = cropImage(for: rect),
          let image = AnnotateExporter.bestCGImage(from: crop.image) else {
      complete(.failure(.captureFailed(L10n.ScreenCapture.failedToCropCapturedImage)))
      return
    }
    guard oneShotState.beginExecuting() else { return }
    isSelectingOneShotOCR = false
    DiagnosticLogger.shared.log(
      .info,
      .ocr,
      "One Shot OCR subregion selected",
      context: [
        "height": "\(Int(rect.height.rounded()))",
        "width": "\(Int(rect.width.rounded()))",
      ]
    )
    performOneShotHandoff(.ocr(image: image))
  }

  func selectOneShotTab(_ tab: OneShotTab) {
    guard tab != oneShotState.activeTab else { return }
    let previousTab = oneShotState.activeTab
    switch oneShotState.requestTab(tab) {
    case .switched:
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "One Shot mode switched",
        context: ["from": previousTab.rawValue, "to": tab.rawValue]
      )
      objectWillChange.send()
    case .openClipboard:
      DiagnosticLogger.shared.log(.info, .action, "One Shot clipboard handoff requested")
      selectionRect = nil
      oneShotState.beginTerminating(clearSelection: true)
      performOneShotHandoff(.clipboard)
    case .rejected:
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "One Shot mode switch rejected",
        context: [
          "active": previousTab.rawValue,
          "requested": tab.rawValue,
          "phase": oneShotState.phase.rawValue,
        ]
      )
      AppToastManager.shared.show(
        message: L10n.OneShot.modeLockedHint,
        style: .info,
        position: .topCenter
      )
    }
  }

  @discardableResult
  func commitOneShotInteraction(_ reason: OneShotCommitReason) -> Bool {
    let wasCommitted = oneShotState.phase == .committed
    let result = oneShotState.commitModeInteraction(reason)
    if result, !wasCommitted {
      DiagnosticLogger.shared.log(
        .info,
        .action,
        "One Shot mode committed",
        context: ["mode": oneShotState.activeTab.rawValue, "reason": reason.rawValue]
      )
    }
    return result
  }

  func toggleOneShotScrollingHelp() {
    oneShotState.toggleScrollingHelp()
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "One Shot scrolling help toggled",
      context: ["visible": oneShotState.showsScrollingHelp ? "true" : "false"]
    )
  }

  func startOneShotScrollingCapture() {
    guard oneShotState.activeTab == .scrolling,
          let rect = selectionRect,
          oneShotState.commitModeInteraction(.scrollingStart),
          oneShotState.beginExecuting() else { return }
    DiagnosticLogger.shared.log(.info, .action, "One Shot scrolling handoff started")
    performOneShotHandoff(.scrolling(rect: screenRect(for: rect)))
  }

  func startOneShotRecording() {
    guard oneShotState.activeTab == .recording,
          let rect = selectionRect,
          oneShotState.commitModeInteraction(.recordingStart),
          oneShotState.beginExecuting() else { return }
    DiagnosticLogger.shared.log(.info, .action, "One Shot recording handoff started")
    performOneShotHandoff(.recording(
      rect: screenRect(for: rect),
      options: oneShotState.recordingOptions
    ))
  }

  func clampedSelectionPreview(for localRect: CGRect) -> CGRect {
    clampedSelectionRect(localRect.standardized)
  }

  func handleKeyEvent(_ event: NSEvent, source: InlineAreaKeyEventSource = .local) -> Bool {
    if isSelectingOneShotOCR {
      if Self.matchesCancelShortcut(event) {
        cancel()
      }
      return event.type == .keyDown
    }

    if event.type == .flagsChanged,
       event.keyCode == 56 || event.keyCode == 60,
       event.modifierFlags.contains(.shift),
       oneShotState.phase == .armed {
      oneShotState.toggleColorFormat()
      return true
    }

    if oneShotState.phase == .armed,
       Self.matchesCommandCopyShortcut(event),
       let value = oneShotState.currentColorValue {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(value, forType: .string)
      SoundManager.play("Pop")
      return true
    }

    if oneShotState.activeTab != .screenshot,
       oneShotState.phase == .selected || oneShotState.phase == .committed {
      if Self.matchesCancelShortcut(event) {
        cancel()
        return true
      }
      return false
    }

    let action = Self.keyAction(
      for: event,
      source: source,
      phase: phase,
      hasTextResponder: windows.allObjects.contains { $0.firstResponder is NSTextView },
      hasKeyWindow: windows.allObjects.contains { $0.isKeyWindow }
    )

    if phase != .annotating {
      isMoveModifierActive = false
    }

    switch action {
    case .passThrough:
      return false
    case .cancel:
      cancel()
      return true
    case .finish:
      Task { await finish() }
      return true
    case .copyCurrentImage:
      copyCurrentImage()
      return true
    case .setMoveModifierActive(let active):
      isMoveModifierActive = active
      return true
    case .resetMoveModifierAndPassThrough:
      isMoveModifierActive = false
      return false
    }
  }

  func cancel() {
    complete(.failure(.cancelled))
  }

  func windowDidClose() {
    guard !isDismissingOverlayForScreenshotExecution else { return }
    complete(.failure(.cancelled), closeWindow: false)
  }

  func controlDisplayID(for localRect: CGRect) -> CGDirectDisplayID {
    let bestMatch = displays
      .compactMap { display -> (displayID: CGDirectDisplayID, area: CGFloat)? in
        let intersection = display.localFrame.intersection(localRect)
        guard !intersection.isEmpty else { return nil }
        return (display.displayID, intersection.width * intersection.height)
      }
      .max { $0.area < $1.area }

    return bestMatch?.displayID ?? primaryDisplayID
  }

  func finish() async {
    await finish(pinToScreen: false)
  }

  func finishAndPin() async {
    guard commitOneShotInteraction(.screenshotPin) else { return }
    await finish(pinToScreen: true)
  }

  private func finish(pinToScreen: Bool) async {
    guard phase == .annotating else { return }
    if !pinToScreen {
      guard commitOneShotInteraction(.screenshotFinish) else { return }
    }
    if let selectionRect, let crop = cropImage(for: selectionRect) {
      self.selectionRect = crop.localRect
      state.replaceSourceImagePreservingAnnotations(crop.image)
    }

    guard let renderedImage = AnnotateExporter.renderFinalImage(state: state),
          let cgImage = AnnotateExporter.bestCGImage(from: renderedImage) else {
      complete(.failure(.captureFailed(L10n.ScreenCapture.failedToCropCapturedImage)))
      return
    }

    guard oneShotState.beginExecuting() else { return }
    dismissOverlayForOneShotScreenshotExecution()

    guard let saveDirectory = resolveSaveDirectory() else {
      complete(.failure(.saveFailed(L10n.ScreenCapture.saveLocationPermissionRequired)))
      return
    }

    let result = await ScreenCaptureManager.shared.saveProcessedImage(
      cgImage,
      to: saveDirectory,
      format: outputFormat,
      scaleFactor: Self.imageScale(renderedImage),
      emitCompletion: !pinToScreen,
      context: context
    )

    if case .success = result {
      SoundManager.playScreenshotCapture()
    }
    complete(result)
    if pinToScreen, case .success(let url) = result {
      await PostCaptureActionHandler.shared.handleScreenshotCapture(url: url, pinToScreen: true)
    }
  }

  func copyCurrentImage() {
    guard commitOneShotInteraction(.screenshotCopy) else { return }
    guard let image = AnnotateExporter.renderFinalImage(state: state) else { return }
    ClipboardHelper.copyImage(image)
    SoundManager.play("Pop")
  }

  private func cropImage(for localRect: CGRect) -> InlineAreaCrop? {
    do {
      let screenRect = screenRect(for: localRect)
      let displayIDs = Self.displayIDsIntersecting(
        screenRect,
        screenFramesByDisplayID: screenFramesByDisplayID
      )
      guard let displayID = Self.primaryDisplayID(
        for: screenRect,
        screenFramesByDisplayID: screenFramesByDisplayID,
        fallback: primaryDisplayID
      ) else {
        throw CaptureError.captureFailed(L10n.ScreenCapture.selectionOutsideDisplayBounds)
      }

      let selection = AreaSelectionResult(
        rect: screenRect,
        displayID: displayID,
        displayIDs: displayIDs.isEmpty ? [displayID] : displayIDs
      )
      let outputScaleFactor = Self.preferredOutputScaleFactor
      let result = selection.spansMultipleDisplays
        ? try frozenSession.cropCompositeImage(
          for: selection,
          minimumOutputScaleFactor: outputScaleFactor
        )
        : try frozenSession.cropImage(
          for: selection,
          minimumOutputScaleFactor: outputScaleFactor
        )
      let image = NSImage(cgImage: result.image, size: result.screenRect.size)
      let localRect = Self.localRect(for: result.screenRect, in: desktopFrame)
      return InlineAreaCrop(image: image, localRect: clampedSelectionRect(localRect))
    } catch {
      DiagnosticLogger.shared.logError(.capture, error, "Inline area annotate crop failed")
      return nil
    }
  }

  private func screenRect(for localRect: CGRect) -> CGRect {
    Self.screenRect(for: localRect, in: desktopFrame)
  }

  private func clampedSelectionRect(_ rect: CGRect) -> CGRect {
    var result = rect
    result.size.width = min(max(result.width, 1), desktopFrame.width)
    result.size.height = min(max(result.height, 1), desktopFrame.height)
    result.origin.x = min(max(result.minX, 0), max(0, desktopFrame.width - result.width))
    result.origin.y = min(max(result.minY, 0), max(0, desktopFrame.height - result.height))
    return result
  }

  private func installKeyMonitors() {
    localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown,
      .keyUp,
      .flagsChanged,
    ]) { [weak self] event in
      guard self?.handleKeyEvent(event) == true else { return event }
      return nil
    }
    globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .keyDown,
      .keyUp,
      .flagsChanged,
    ]) { [weak self] event in
      Task { @MainActor in
        _ = self?.handleKeyEvent(event, source: .global)
      }
    }
  }

  private func removeKeyMonitors() {
    if let localKeyMonitor {
      NSEvent.removeMonitor(localKeyMonitor)
      self.localKeyMonitor = nil
    }
    if let globalKeyMonitor {
      NSEvent.removeMonitor(globalKeyMonitor)
      self.globalKeyMonitor = nil
    }
  }

  private func installSelectionMonitorIfNeeded() {
    guard selectionLocalMonitor == nil else { return }
    selectionLocalMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      switch event.type {
      case .leftMouseDragged:
        MainActor.assumeIsolated {
          guard let self else { return }
          let point = self.localDesktopPoint(for: NSEvent.mouseLocation)
          if self.isSelectingOneShotOCR {
            self.updateOneShotOCRSelection(to: point)
          } else {
            self.updateSelection(to: point)
          }
        }
        return nil
      case .leftMouseUp:
        MainActor.assumeIsolated {
          guard let self else { return }
          let point = self.localDesktopPoint(for: NSEvent.mouseLocation)
          if self.isSelectingOneShotOCR {
            self.endOneShotOCRSelection(at: point)
          } else {
            self.endSelection(at: point)
          }
        }
        return nil
      default:
        return event
      }
    }
  }

  private func removeSelectionMonitor() {
    if let selectionLocalMonitor {
      NSEvent.removeMonitor(selectionLocalMonitor)
      self.selectionLocalMonitor = nil
    }
  }

  private func localDesktopPoint(for screenPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: screenPoint.x - desktopFrame.minX,
      y: desktopFrame.maxY - screenPoint.y
    )
  }

  private func complete(_ result: CaptureResult, closeWindow: Bool = true) {
    guard !didComplete else { return }
    didComplete = true
    displayChangeCancellable = nil
    isMoveModifierActive = false
    isSelectingOneShotOCR = false
    oneShotOCRSelectionRect = nil
    oneShotOCRSelectionStartPoint = nil
    removeKeyMonitors()
    removeSelectionMonitor()
    frozenSession.invalidate()

    // Restore cursor before closing windows — the inline overlay uses a
    // transparent 1×1 cursor that could persist if window closure does not
    // trigger cursor rect re-evaluation.
    NSCursor.arrow.set()

    if closeWindow {
      for window in windows.allObjects {
        window.close()
      }
    }
    onComplete(result)
  }

  private func performOneShotHandoff(_ handoff: OneShotHandoff) {
    guard !didComplete else { return }
    didComplete = true
    displayChangeCancellable = nil
    isMoveModifierActive = false
    isSelectingOneShotOCR = false
    oneShotOCRSelectionRect = nil
    oneShotOCRSelectionStartPoint = nil
    removeKeyMonitors()
    removeSelectionMonitor()
    frozenSession.invalidate()
    NSCursor.arrow.set()
    for window in windows.allObjects {
      window.close()
    }
    onOneShotHandoff(handoff)
  }

  private func dismissOverlayForOneShotScreenshotExecution() {
    guard !isDismissingOverlayForScreenshotExecution else { return }
    isDismissingOverlayForScreenshotExecution = true
    displayChangeCancellable = nil
    isMoveModifierActive = false
    removeKeyMonitors()
    removeSelectionMonitor()
    frozenSession.invalidate()
    NSCursor.arrow.set()
    for window in windows.allObjects {
      window.close()
    }
  }

  private func syncOneShotSelection(isFinal: Bool) {
    guard let selectionRect else { return }
    let globalRect = screenRect(for: selectionRect)
    let displayIDs = Self.displayIDsIntersecting(
      globalRect,
      screenFramesByDisplayID: screenFramesByDisplayID
    )
    if isFinal {
      _ = oneShotState.finishSelection(globalRect, displayIDs: displayIDs)
    } else if oneShotState.phase == .selecting {
      oneShotState.updateSelection(globalRect, displayIDs: displayIDs)
    } else {
      oneShotState.updateEditableSelection(globalRect, displayIDs: displayIDs)
    }
  }

  private static func imageScale(_ image: NSImage) -> CGFloat {
    guard let rep = image.representations.first as? NSBitmapImageRep,
          image.size.width > 0,
          image.size.height > 0 else { return 1 }
    return max(CGFloat(rep.pixelsWide) / image.size.width, CGFloat(rep.pixelsHigh) / image.size.height, 1)
  }

  private static var preferredOutputScaleFactor: CGFloat {
    max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0, 2.0)
  }

  nonisolated static func matchesCommandSaveShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
          !flags.contains(.control),
          !flags.contains(.option) else { return false }
    return event.keyCode == 1 || event.charactersIgnoringModifiers?.lowercased() == "s"
  }

  nonisolated static func matchesCommandCopyShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command),
          !flags.contains(.control),
          !flags.contains(.option),
          !flags.contains(.shift) else { return false }
    return event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
  }

  nonisolated static func shouldHandleCommandCopyShortcut(
    _ event: NSEvent,
    isLocalEvent: Bool,
    hasTextResponder: Bool,
    hasKeyWindow: Bool
  ) -> Bool {
    matchesCommandCopyShortcut(event) && !hasTextResponder && (isLocalEvent || hasKeyWindow)
  }

  nonisolated static func keyAction(
    for event: NSEvent,
    source: InlineAreaKeyEventSource,
    phase: InlineAreaAnnotatePhase,
    hasTextResponder: Bool,
    hasKeyWindow: Bool
  ) -> InlineAreaKeyAction {
    guard phase == .annotating else {
      return matchesCancelShortcut(event) ? .cancel : .passThrough
    }

    if matchesCommandSaveShortcut(event) {
      return .finish
    }

    if hasTextResponder {
      return matchesMoveModifierKey(event) ? .resetMoveModifierAndPassThrough : .passThrough
    }

    if shouldHandleCommandCopyShortcut(
      event,
      isLocalEvent: source == .local,
      hasTextResponder: hasTextResponder,
      hasKeyWindow: hasKeyWindow
    ) {
      return .copyCurrentImage
    }

    if matchesMoveModifierKey(event) {
      return .setMoveModifierActive(event.type == .keyDown)
    }

    if matchesFinishShortcut(event) {
      return .finish
    }

    if matchesCancelShortcut(event) {
      return .cancel
    }

    return .passThrough
  }

  nonisolated static func matchesFinishShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    return event.keyCode == 36 || event.keyCode == 76
  }

  nonisolated static func matchesCancelShortcut(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    return event.keyCode == 53
  }

  nonisolated static func matchesMoveModifierKey(_ event: NSEvent) -> Bool {
    event.keyCode == 49 && (event.type == .keyDown || event.type == .keyUp)
  }

  nonisolated static func desktopFrame(for screenFrames: [CGRect]) -> CGRect {
    screenFrames.reduce(CGRect.null) { partialResult, frame in
      partialResult.union(frame)
    }
  }

  nonisolated static func localFrame(for screenFrame: CGRect, in desktopFrame: CGRect) -> CGRect {
    CGRect(
      x: screenFrame.minX - desktopFrame.minX,
      y: desktopFrame.maxY - screenFrame.maxY,
      width: screenFrame.width,
      height: screenFrame.height
    )
  }

  nonisolated static func screenRect(for localRect: CGRect, in desktopFrame: CGRect) -> CGRect {
    CGRect(
      x: desktopFrame.minX + localRect.minX,
      y: desktopFrame.maxY - localRect.maxY,
      width: localRect.width,
      height: localRect.height
    )
  }

  nonisolated static func localRect(for screenRect: CGRect, in desktopFrame: CGRect) -> CGRect {
    CGRect(
      x: screenRect.minX - desktopFrame.minX,
      y: desktopFrame.maxY - screenRect.maxY,
      width: screenRect.width,
      height: screenRect.height
    )
  }

  nonisolated static func displayIDsIntersecting(
    _ screenRect: CGRect,
    screenFramesByDisplayID: [CGDirectDisplayID: CGRect]
  ) -> Set<CGDirectDisplayID> {
    Set(screenFramesByDisplayID.compactMap { displayID, frame in
      frame.intersects(screenRect) ? displayID : nil
    })
  }

  nonisolated static func primaryDisplayID(
    for screenRect: CGRect,
    screenFramesByDisplayID: [CGDirectDisplayID: CGRect],
    fallback: CGDirectDisplayID?
  ) -> CGDirectDisplayID? {
    let bestMatch = screenFramesByDisplayID
      .compactMap { displayID, frame -> (displayID: CGDirectDisplayID, area: CGFloat)? in
        let intersection = frame.intersection(screenRect)
        guard !intersection.isEmpty else { return nil }
        return (displayID, intersection.width * intersection.height)
      }
      .max { $0.area < $1.area }

    return bestMatch?.displayID ?? fallback
  }
}
