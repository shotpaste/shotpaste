//
//  InlineAreaAnnotateWindow.swift
//  ShotPaste
//
//  Per-display overlays for selecting and annotating a screenshot region.
//

import AppKit
import SwiftUI

@MainActor
final class InlineAreaAnnotateCoordinator {
  static let shared = InlineAreaAnnotateCoordinator()
  private var activeWindows: [InlineAreaAnnotatePanel] = []
  private weak var activeSession: InlineAreaAnnotateSession?
  private var previouslyActiveApplication: NSRunningApplication?

  var isActive: Bool {
    activeSession != nil || !activeWindows.isEmpty
  }

  func startOneShot(
    screens: [NSScreen],
    primaryDisplayID: CGDirectDisplayID,
    backdrops: [CGDirectDisplayID: AreaSelectionBackdrop],
    frozenSession: FrozenAreaCaptureSession,
    outputFormat: ImageFormat,
    context: CaptureContext = .empty,
    oneShotState: OneShotSessionState,
    resolveSaveDirectory: @escaping () -> URL?,
    onHandoff: @escaping (OneShotHandoff) -> Void,
    onComplete: @escaping (CaptureResult) -> Void
  ) {
    startSession(
      screens: screens,
      primaryDisplayID: primaryDisplayID,
      backdrops: backdrops,
      frozenSession: frozenSession,
      outputFormat: outputFormat,
      context: context,
      oneShotState: oneShotState,
      resolveSaveDirectory: resolveSaveDirectory,
      onHandoff: onHandoff,
      onComplete: onComplete
    )
  }

  @discardableResult
  func cancelActiveSession(discardChanges: Bool = false) -> Bool {
    activeSession?.cancel(discardChanges: discardChanges) ?? true
  }

  private func startSession(
    screens: [NSScreen],
    primaryDisplayID: CGDirectDisplayID,
    backdrops: [CGDirectDisplayID: AreaSelectionBackdrop],
    frozenSession: FrozenAreaCaptureSession,
    outputFormat: ImageFormat,
    context: CaptureContext,
    oneShotState: OneShotSessionState,
    resolveSaveDirectory: @escaping () -> URL?,
    onHandoff: @escaping (OneShotHandoff) -> Void,
    onComplete: @escaping (CaptureResult) -> Void
  ) {
    closeActiveWindows()
    let availableScreens = screens.filter { screen in
      guard let displayID = screen.displayID else { return false }
      return backdrops[displayID] != nil
    }
    guard !availableScreens.isEmpty else {
      onComplete(.failure(.noDisplayFound))
      return
    }

    previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)

    let wrappedOnComplete: (CaptureResult) -> Void = { [weak self] result in
      guard let self else {
        onComplete(result)
        return
      }
      activeSession = nil
      previouslyActiveApplication?.activate(options: [])
      previouslyActiveApplication = nil
      onComplete(result)
    }

    let desktopFrame = InlineAreaAnnotateSession.desktopFrame(for: availableScreens.map(\.frame))
    let displays = availableScreens.compactMap { screen -> InlineAreaAnnotateDisplay? in
      guard let displayID = screen.displayID,
            let backdrop = backdrops[displayID]
      else { return nil }
      return InlineAreaAnnotateDisplay(
        displayID: displayID,
        screenFrame: screen.frame,
        localFrame: InlineAreaAnnotateSession.localFrame(for: screen.frame, in: desktopFrame),
        controlInsets: InlineAreaControlInsets(screen: screen),
        backdropImage: NSImage(cgImage: backdrop.image, size: screen.frame.size),
        backdropCGImage: backdrop.image
      )
    }
    guard !displays.isEmpty else {
      wrappedOnComplete(.failure(.noDisplayFound))
      return
    }

    let session = InlineAreaAnnotateSession(
      primaryDisplayID: primaryDisplayID,
      desktopFrame: desktopFrame,
      displays: displays,
      frozenSession: frozenSession,
      resolveSaveDirectory: resolveSaveDirectory,
      outputFormat: outputFormat,
      context: context,
      oneShotState: oneShotState,
      onOneShotHandoff: { [weak self] handoff in
        guard let self else {
          onHandoff(handoff)
          return
        }
        activeSession = nil
        previouslyActiveApplication?.activate(options: [])
        previouslyActiveApplication = nil
        onHandoff(handoff)
      },
      onComplete: wrappedOnComplete
    )
    activeSession = session

    let windows = displays.map { display in
      InlineAreaAnnotatePanel(display: display, session: session)
    }
    activeWindows = windows

    for window in windows {
      window.onClose = { [weak self, weak window] in
        guard let self, let window else { return }
        activeWindows.removeAll { $0 === window }
      }
      session.attach(window: window)
      window.orderFrontRegardless()
      if window.displayID == primaryDisplayID {
        window.makeKey()
      }
    }
    if !windows.contains(where: { $0.displayID == primaryDisplayID }) {
      windows.first?.makeKey()
    }
  }

  private func closeActiveWindows() {
    activeSession = nil
    let windows = activeWindows
    activeWindows.removeAll()
    for window in windows {
      window.close()
    }
    previouslyActiveApplication?.activate(options: [])
    previouslyActiveApplication = nil
  }
}

final class InlineAreaAnnotatePanel: NSPanel {
  var onClose: (() -> Void)?
  let displayID: CGDirectDisplayID

  private let session: InlineAreaAnnotateSession
  private var didNotifyClose = false

  init(display: InlineAreaAnnotateDisplay, session: InlineAreaAnnotateSession) {
    displayID = display.displayID
    self.session = session
    super.init(
      contentRect: display.screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    level = .screenSaver
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
    isReleasedWhenClosed = false
    hasShadow = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    sharingType = .none
    animationBehavior = .none
    becomesKeyOnlyIfNeeded = true

    isMovable = false
    isMovableByWindowBackground = false
    minSize = display.screenFrame.size
    maxSize = display.screenFrame.size
    if let nsAppearance = ThemeManager.shared.nsAppearance {
      appearance = nsAppearance
    } else {
      let isDark = ThemeManager.shared.systemAppearance == .dark
      appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    let rootView = InlineAreaAnnotateRootView(
      session: session,
      display: display
    )
    .preferredColorScheme(ThemeManager.shared.systemAppearance)
    let hostingView = InlineAreaHostingView(rootView: rootView)
    hostingView.session = session
    contentView = hostingView
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
    minSize = frameRect.size
    maxSize = frameRect.size
    super.setFrame(frameRect, display: displayFlag)
  }

  override func keyDown(with event: NSEvent) {
    if session.handleKeyEvent(event) {
      return
    }
    super.keyDown(with: event)
  }

  override func keyUp(with event: NSEvent) {
    if session.handleKeyEvent(event) {
      return
    }
    super.keyUp(with: event)
  }

  override func close() {
    super.close()
    guard !didNotifyClose else { return }
    didNotifyClose = true
    session.windowDidClose()
    onClose?()
  }
}

private final class InlineAreaHostingView: NSHostingView<AnyView> {
  var session: InlineAreaAnnotateSession?

  convenience init(rootView: some View) {
    self.init(rootView: AnyView(rootView))
  }

  required init(rootView: AnyView) {
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  override func resetCursorRects() {
    if let session, session.phase == .selecting {
      addCursorRect(bounds, cursor: NSCursor.vectorScreenshotCrosshairLight)
    } else {
      super.resetCursorRects()
    }
  }
}

private struct InlineAreaAnnotateRootView: View {
  @ObservedObject var session: InlineAreaAnnotateSession
  let display: InlineAreaAnnotateDisplay

  @State private var movingStartRect: CGRect?
  @State private var movingPreviewRect: CGRect?
  @State private var resizingStartRect: CGRect?
  @State private var resizePreviewRect: CGRect?
  @State private var activeResizeHandle: InlineAreaResizeHandle?
  @State private var hoveredResizeHandle: InlineAreaResizeHandle?
  @State private var cursorIndicatorPoint: CGPoint?
  @State private var propertiesContentWidth: CGFloat = 0
  @State private var oneShotMagnifierSample: OneShotMagnifierSample?
  @State private var isOneShotReselecting = false
  @State private var oneShotToolbarDragStart: CGPoint?
  @State private var magnificationStartZoom: CGFloat?
  @State private var canvasPanLastTranslation: CGSize = .zero
  @AppStorage(PreferencesKeys.screenshotMagnifierEnabled) private var screenshotMagnifierEnabled = true
  @AppStorage(PreferencesKeys.screenshotMagnifierZoom) private var screenshotMagnifierZoom = 1

  var body: some View {
    GeometryReader { geometry in
      let desktopRect = resizePreviewRect ?? movingPreviewRect ?? session.selectionRect
      let viewportRect = desktopRect.map(rectInViewport)
      let isSelectionPreviewing = resizePreviewRect != nil || movingPreviewRect != nil
      let showsCursorIndicator = movingPreviewRect != nil || session.isSelectingOneShotOCR
      let selectionLabelControlSide = viewportRect.flatMap { viewportRect in
        desktopRect.flatMap { desktopRect in
          oneShotSelectionLabelControlSide(
            for: viewportRect,
            desktopRect: desktopRect,
            containerSize: geometry.size
          )
        }
      }

      ZStack(alignment: .topLeading) {
        ForEach(session.displays) { backdropDisplay in
          Image(nsImage: backdropDisplay.backdropImage)
            .resizable()
            .frame(
              width: backdropDisplay.localFrame.width, height: backdropDisplay.localFrame.height
            )
            .position(
              x: backdropDisplay.localFrame.midX - display.localFrame.minX,
              y: backdropDisplay.localFrame.midY - display.localFrame.minY
            )
        }

        selectionDimLayer(size: geometry.size, rect: viewportRect)
          .inlineAreaSelectionGesture(
            oneShotReselectionGesture,
            isEnabled: session.isOneShotSelectionEditable || isOneShotReselecting
          )

        if let desktopRect, let viewportRect {
          if session.phase == .annotating {
            if session.oneShotState.activeTab == .screenshot {
              annotateSurface(
                rect: viewportRect,
                desktopRect: desktopRect,
                usesBackdropPreview: isSelectionPreviewing
              )
            } else {
              selectionBorder(rect: viewportRect)
            }
            if !session.isSelectingOneShotOCR,
               session.state.canPanInteractively,
               session.state.isCanvasPanningMode || session.state.isSpacePanning {
              canvasPanHitArea(rect: viewportRect)
            } else if !session.isSelectingOneShotOCR,
                      session.isOneShotSelectionEditable {
              selectionMoveHitArea(rect: viewportRect, desktopRect: desktopRect)
            }
            if !session.isSelectingOneShotOCR,
               session.isOneShotSelectionResizable,
               !session.state.isCanvasPanningMode,
               !session.state.isSpacePanning {
              resizeHandles(rect: viewportRect, desktopRect: desktopRect)
            }
            if !session.isSelectingOneShotOCR,
               session.controlDisplayID(for: desktopRect) == display.displayID {
              controls(rect: viewportRect, desktopRect: desktopRect, containerSize: geometry.size)
            }
          } else {
            selectionBorder(rect: viewportRect)
          }
        }

        if session.isSelectingOneShotOCR, let desktopRect {
          oneShotOCRSelectionOverlay(outerRect: rectInViewport(desktopRect))
        }

        if showsCursorIndicator, let cursorIndicatorPoint {
          InlineAreaCursorIndicator(point: cursorIndicatorPoint)
        }

        if session.oneShotState.showsTopSwitcher,
           session.oneShotState.switcherDisplayID == display.displayID {
          oneShotSwitcher(state: session.oneShotState, containerSize: geometry.size)
        }

        if shouldShowOneShotMagnifier,
           let oneShotMagnifierSample,
           let cursorIndicatorPoint {
          OneShotMagnifierView(
            sample: oneShotMagnifierSample,
            format: session.oneShotState.colorFormat
          )
          .position(
            oneShotMagnifierPosition(
              cursor: cursorIndicatorPoint,
              containerSize: geometry.size
            )
          )
        }

        if let viewportRect {
          oneShotSelectionSizeLabel(
            rect: viewportRect,
            containerSize: geometry.size,
            controlSide: selectionLabelControlSide
          )
        }

        if let prompt = session.activePrompt {
          overlayPrompt(prompt, containerSize: geometry.size)
        }
      }
      .coordinateSpace(name: InlineAreaCoordinateSpace.root)
      .onContinuousHover(coordinateSpace: .named(InlineAreaCoordinateSpace.root)) { phase in
        switch phase {
        case .active(let location):
          cursorIndicatorPoint = location
          updateOneShotMagnifier(at: location, containerSize: geometry.size)
          updateNativeCursorForIndicator(showsCursorIndicator)
        case .ended:
          cursorIndicatorPoint = nil
          oneShotMagnifierSample = nil
          session.oneShotState.updateCurrentColor(hex: nil, rgb: nil)
          InlineAreaNativeCursor.restoreArrow()
        }
      }
      .inlineAreaSelectionGesture(
        selectionGesture,
        isEnabled: session.phase == .selecting && session.activePrompt == nil
      )
    }
    .ignoresSafeArea()
    .onAppear {
      if session.phase == .selecting {
        session.refreshCursor()
        DispatchQueue.main.async {
          session.refreshCursor()
          DispatchQueue.main.async {
            session.refreshCursor()
          }
        }
      }
    }
  }

  private func overlayPrompt(
    _ prompt: InlineAreaOverlayPrompt,
    containerSize: CGSize
  ) -> some View {
    ZStack {
      Color.black.opacity(0.48)
        .contentShape(Rectangle())
        .onTapGesture {}

      if session.activePromptDisplayID == display.displayID {
        InlineAreaOverlayPromptCard(prompt: prompt) { action in
          session.resolveActivePrompt(action)
        }
        .frame(width: min(440, max(300, containerSize.width - 40)))
        .position(x: containerSize.width / 2, y: containerSize.height / 2)
      }
    }
    .frame(width: containerSize.width, height: containerSize.height)
    .zIndex(10_000)
    .accessibilityIdentifier("oneshot-overlay-prompt")
  }

  private var selectionGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard session.phase == .selecting else { return }
        guard !oneShotSwitcherRect(in: display.localFrame.size).contains(value.startLocation) else {
          return
        }
        let currentLocation = desktopPoint(for: value.location)
        cursorIndicatorPoint = value.location
        updateOneShotMagnifier(at: value.location, containerSize: display.localFrame.size)
        updateNativeCursorForIndicator(true)
        session.beginSelection(at: desktopPoint(for: value.startLocation))
        session.updateSelection(to: currentLocation)
      }
      .onEnded { value in
        guard session.phase == .selecting else { return }
        session.endSelection(at: desktopPoint(for: value.location))
        cursorIndicatorPoint = nil
        InlineAreaNativeCursor.restoreArrow()
      }
  }

  private var oneShotReselectionGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard session.isOneShotSelectionEditable || isOneShotReselecting else { return }
        let start = desktopPoint(for: value.startLocation)
        if !isOneShotReselecting {
          guard session.selectionRect?.contains(start) != true else { return }
          isOneShotReselecting = true
          session.beginOneShotReselection(at: start)
        }
        cursorIndicatorPoint = value.location
        updateOneShotMagnifier(at: value.location, containerSize: display.localFrame.size)
        session.updateSelection(to: desktopPoint(for: value.location))
      }
      .onEnded { value in
        guard isOneShotReselecting else { return }
        session.endSelection(at: desktopPoint(for: value.location))
        isOneShotReselecting = false
        cursorIndicatorPoint = nil
        oneShotMagnifierSample = nil
      }
  }

  private var oneShotOCRSelectionGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard session.isSelectingOneShotOCR else { return }
        cursorIndicatorPoint = value.location
        updateNativeCursorForIndicator(true)
        session.beginOneShotOCRSelection(at: desktopPoint(for: value.startLocation))
        session.updateOneShotOCRSelection(to: desktopPoint(for: value.location))
      }
      .onEnded { value in
        guard session.isSelectingOneShotOCR else { return }
        session.endOneShotOCRSelection(at: desktopPoint(for: value.location))
        cursorIndicatorPoint = nil
        InlineAreaNativeCursor.restoreArrow()
      }
  }

  @ViewBuilder
  private func oneShotOCRSelectionOverlay(outerRect: CGRect) -> some View {
    let ocrRect = session.oneShotOCRSelectionRect.map(rectInViewport)

    Canvas { context, _ in
      var dimPath = Path(outerRect.standardized)
      if let ocrRect, !ocrRect.isNull {
        dimPath.addPath(Path(ocrRect.standardized))
      }
      context.fill(
        dimPath,
        with: .color(.black.opacity(0.5)),
        style: FillStyle(eoFill: true)
      )
      if let ocrRect, ocrRect.width > 0, ocrRect.height > 0 {
        context.stroke(
          Path(ocrRect.standardized),
          with: .color(.white),
          style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
        )
      }
    }
    .allowsHitTesting(false)

    Color.clear
      .contentShape(Rectangle())
      .frame(width: outerRect.width, height: outerRect.height)
      .position(x: outerRect.midX, y: outerRect.midY)
      .gesture(oneShotOCRSelectionGesture)
      .accessibilityLabel(L10n.Actions.captureTextOCR)
      .accessibilityIdentifier("oneshot-ocr-selection-area")
  }

  private func rectInViewport(_ desktopRect: CGRect) -> CGRect {
    desktopRect.offsetBy(dx: -display.localFrame.minX, dy: -display.localFrame.minY)
  }

  private func desktopPoint(for viewportPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: viewportPoint.x + display.localFrame.minX,
      y: viewportPoint.y + display.localFrame.minY
    )
  }

  private func selectionDimLayer(size: CGSize, rect: CGRect?) -> some View {
    Canvas { context, canvasSize in
      var path = Path(CGRect(origin: .zero, size: canvasSize))
      if let rect {
        path.addPath(Path(rect.standardized))
      }
      context.fill(path, with: .color(.black.opacity(0.42)), style: FillStyle(eoFill: true))
    }
    .frame(width: size.width, height: size.height)
  }

  private func annotateSurface(
    rect: CGRect,
    desktopRect: CGRect,
    usesBackdropPreview: Bool
  ) -> some View {
    let imageSize = session.state.sourceImage?.size ?? rect.size
    let stableDesktopRect = session.selectionRect ?? desktopRect
    let previewLayout = InlineAreaAnnotationPreviewLayout.resolve(
      stableSelectionRect: stableDesktopRect,
      displayFrame: display.localFrame,
      imageSize: imageSize
    )

    return ZStack(alignment: .topLeading) {
      if usesBackdropPreview {
        // Keep the annotation layer at a fixed display-sized frame while the
        // selection changes. The selection acts only as a mask, so annotations
        // outside the old bounds remain renderable and are revealed on expansion.
        annotationCanvasSurface(
          size: display.localFrame.size,
          displayScale: previewLayout.displayScale,
          canvasBounds: previewLayout.canvasBounds
        )
        .mask(
          Rectangle()
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
        )
        .allowsHitTesting(false)
      } else {
        interactiveAnnotationCanvasSurface(rect: rect, imageSize: imageSize)
      }

      selectionBorder(rect: rect)
        .allowsHitTesting(false)
    }
    .frame(
      width: display.localFrame.width,
      height: display.localFrame.height,
      alignment: .topLeading
    )
  }

  private func interactiveAnnotationCanvasSurface(
    rect: CGRect,
    imageSize: CGSize
  ) -> some View {
    let fitScale = max(rect.width / max(imageSize.width, 1), 0.0001)
    let zoomLevel = session.state.zoomLevel
    let displayScale = fitScale * zoomLevel
    let renderedSize = CGSize(
      width: rect.width * zoomLevel,
      height: rect.height * zoomLevel
    )

    return ZStack {
      if zoomLevel < 0.999 {
        Color(nsColor: .windowBackgroundColor)
      }

      ZStack {
        if let image = session.state.sourceImage {
          Image(nsImage: image)
            .resizable()
            .frame(width: renderedSize.width, height: renderedSize.height)
        }

        annotationCanvasSurface(
          size: renderedSize,
          displayScale: displayScale,
          canvasBounds: CGRect(origin: .zero, size: imageSize)
        )
      }
      .frame(width: renderedSize.width, height: renderedSize.height)
      .offset(
        x: session.state.panOffset.width,
        y: session.state.panOffset.height
      )
    }
    .frame(width: rect.width, height: rect.height)
    .clipped()
    .contentShape(Rectangle())
    .simultaneousGesture(canvasMagnificationGesture)
    .onAppear {
      updateCanvasViewportMetrics(rect: rect, fitScale: fitScale)
    }
    .onChange(of: rect.size) { _ in
      updateCanvasViewportMetrics(rect: rect, fitScale: fitScale)
    }
    .onChange(of: imageSize) { _ in
      updateCanvasViewportMetrics(rect: rect, fitScale: fitScale)
    }
    .position(x: rect.midX, y: rect.midY)
  }

  private func annotationCanvasSurface(
    size: CGSize,
    displayScale: CGFloat,
    canvasBounds: CGRect
  ) -> some View {
    ZStack {
      CanvasDrawingView(
        state: session.state,
        displayScale: displayScale,
        canvasBounds: canvasBounds,
        permitsAnnotationOverflow: true
      )
      .frame(width: size.width, height: size.height)

      if session.state.editingTextAnnotationId != nil {
        TextEditOverlay(
          state: session.state,
          scale: displayScale,
          canvasBounds: canvasBounds
        )
        .frame(width: size.width, height: size.height)
        .clipped()
      }
    }
    .frame(width: size.width, height: size.height)
  }

  private var canvasMagnificationGesture: some Gesture {
    MagnificationGesture()
      .onChanged { magnification in
        guard session.commitOneShotInteraction(.screenshotViewport) else { return }
        if magnificationStartZoom == nil {
          magnificationStartZoom = session.state.zoomLevel
        }
        let startZoom = magnificationStartZoom ?? session.state.zoomLevel
        session.state.setZoomLevel(startZoom * magnification)
      }
      .onEnded { _ in
        magnificationStartZoom = nil
      }
  }

  private func updateCanvasViewportMetrics(
    rect: CGRect,
    fitScale: CGFloat
  ) {
    session.state.updateViewportMetrics(
      containerSize: rect.size,
      baseCanvasSize: rect.size,
      fitScale: fitScale
    )
  }

  private func selectionMoveHitArea(rect: CGRect, desktopRect: CGRect) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      .gesture(moveGesture(for: desktopRect))
      .onHover { hovering in
        if hovering {
          NSCursor.openHand.set()
        } else {
          NSCursor.arrow.set()
        }
      }
  }

  private func canvasPanHitArea(rect: CGRect) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
      .gesture(canvasPanGesture)
      .onHover { hovering in
        if hovering {
          NSCursor.openHand.set()
        } else {
          NSCursor.arrow.set()
        }
      }
      .accessibilityLabel(L10n.AnnotateUI.panCanvas)
  }

  private var canvasPanGesture: some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        let delta = CGSize(
          width: value.translation.width - canvasPanLastTranslation.width,
          height: value.translation.height - canvasPanLastTranslation.height
        )
        canvasPanLastTranslation = value.translation
        session.state.pan(by: delta)
        NSCursor.closedHand.set()
      }
      .onEnded { _ in
        canvasPanLastTranslation = .zero
        NSCursor.openHand.set()
      }
  }

  private func controls(rect: CGRect, desktopRect: CGRect, containerSize: CGSize) -> some View {
    oneShotControls(
      state: session.oneShotState,
      rect: rect,
      desktopRect: desktopRect,
      containerSize: containerSize
    )
  }

  @ViewBuilder
  private func oneShotControls(
    state: OneShotSessionState,
    rect: CGRect,
    desktopRect _: CGRect,
    containerSize: CGSize
  ) -> some View {
    switch state.activeTab {
    case .screenshot:
      let placement = oneShotScreenshotPlacement(
        for: rect,
        containerSize: containerSize,
        showsProperties: session.state.showsQuickPropertiesBar
      )
      InlineAreaControlDeck(
        session: session,
        maxWidth: placement.toolbarWidth,
        moveGesture: oneShotToolbarMoveGesture(
          defaultCenter: placement.toolbarCenter,
          toolbarWidth: placement.toolbarWidth,
          containerSize: containerSize
        )
      )
      .frame(width: placement.toolbarWidth, height: InlineAreaLayout.toolbarHeight)
      .position(
        oneShotToolbarCenter(
          defaultCenter: placement.toolbarCenter,
          containerSize: containerSize,
          width: placement.toolbarWidth
        )
      )

      InlineAreaPropertiesBar(
        state: session.state,
        maxWidth: placement.propertiesWidth,
        popoverEdge: placement.propertiesPopoverEdge,
        onContentWidthChange: { width in
          let roundedWidth = ceil(width)
          guard abs(propertiesContentWidth - roundedWidth) > 0.5 else { return }
          propertiesContentWidth = roundedWidth
        }
      )
      .frame(width: placement.propertiesWidth, height: InlineAreaLayout.propertiesHeight)
      .opacity(session.state.showsQuickPropertiesBar ? 1 : 0)
      .allowsHitTesting(session.state.showsQuickPropertiesBar)
      .position(placement.propertiesCenter)

    case .scrolling:
      OneShotScrollingControls(
        state: state,
        onStart: { session.startOneShotScrollingCapture() }
      )
      .fixedSize()
      .position(
        oneShotBelowSelectionCenter(
          rect: rect,
          size: CGSize(width: 350, height: state.showsScrollingHelp ? 132 : 60),
          containerSize: containerSize
        )
      )

    case .recording:
      OneShotRecordingControls(
        state: state,
        onStart: { session.startOneShotRecording() }
      )
      .position(oneShotRecordingCenter(rect: rect, containerSize: containerSize))

    case .clipboard:
      EmptyView()
    }
  }

  private func oneShotScreenshotPlacement(
    for rect: CGRect,
    containerSize: CGSize,
    showsProperties: Bool
  ) -> InlineAreaControlPlacement {
    let standard = controlPlacement(
      for: rect,
      containerSize: containerSize,
      showsProperties: showsProperties,
      propertiesContentWidth: propertiesContentWidth,
      controlInsets: display.controlInsets
    )
    let availableWidth = max(
      0,
      containerSize.width - display.controlInsets.leading - display.controlInsets.trailing
        - InlineAreaLayout.screenPadding * 2
    )
    let width = min(900, availableWidth)
    let minimumCenterX = display.controlInsets.leading + InlineAreaLayout.screenPadding + width / 2
    let maximumCenterX =
      containerSize.width - display.controlInsets.trailing
        - InlineAreaLayout.screenPadding - width / 2
    let centerX =
      minimumCenterX <= maximumCenterX
        ? min(max(rect.midX, minimumCenterX), maximumCenterX)
        : rect.midX
    return InlineAreaControlPlacement(
      toolbarWidth: width,
      propertiesWidth: min(standard.propertiesWidth, availableWidth),
      toolbarCenter: CGPoint(x: centerX, y: standard.toolbarCenter.y),
      propertiesCenter: standard.propertiesCenter,
      propertiesPopoverEdge: standard.propertiesPopoverEdge,
      toolbarSide: standard.toolbarSide
    )
  }

  private func oneShotSelectionLabelControlSide(
    for rect: CGRect,
    desktopRect: CGRect,
    containerSize: CGSize
  ) -> InlineAreaVerticalSide? {
    guard session.phase == .annotating,
          session.oneShotState.activeTab == .screenshot,
          session.controlDisplayID(for: desktopRect) == display.displayID
    else {
      return nil
    }

    return oneShotScreenshotPlacement(
      for: rect,
      containerSize: containerSize,
      showsProperties: session.state.showsQuickPropertiesBar
    ).toolbarSide
  }

  private func oneShotToolbarCenter(
    defaultCenter: CGPoint,
    containerSize: CGSize,
    width: CGFloat
  ) -> CGPoint {
    guard let stored = session.oneShotState.modeToolbarPosition else { return defaultCenter }
    let local = CGPoint(
      x: stored.x - display.localFrame.minX,
      y: stored.y - display.localFrame.minY
    )
    let halfWidth = width / 2
    let halfHeight = InlineAreaLayout.toolbarHeight / 2
    return CGPoint(
      x: min(
        max(local.x, display.controlInsets.leading + halfWidth + 12),
        containerSize.width - display.controlInsets.trailing - halfWidth - 12
      ),
      y: min(
        max(local.y, display.controlInsets.top + halfHeight + 12),
        containerSize.height - display.controlInsets.bottom - halfHeight - 12
      )
    )
  }

  private func oneShotToolbarMoveGesture(
    defaultCenter: CGPoint,
    toolbarWidth: CGFloat,
    containerSize: CGSize
  ) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard session.commitOneShotInteraction(.screenshotToolbarDrag) else { return }
        if oneShotToolbarDragStart == nil {
          let current = oneShotToolbarCenter(
            defaultCenter: defaultCenter,
            containerSize: containerSize,
            width: toolbarWidth
          )
          oneShotToolbarDragStart = CGPoint(
            x: current.x + display.localFrame.minX,
            y: current.y + display.localFrame.minY
          )
        }
        guard let start = oneShotToolbarDragStart else { return }
        session.oneShotState.modeToolbarPosition = CGPoint(
          x: start.x + value.translation.width,
          y: start.y + value.translation.height
        )
      }
      .onEnded { _ in
        oneShotToolbarDragStart = nil
      }
  }

  private func oneShotBelowSelectionCenter(
    rect: CGRect,
    size: CGSize,
    containerSize: CGSize
  ) -> CGPoint {
    let minX = display.controlInsets.leading + OneShotLayout.modeToolbarGap + size.width / 2
    let maxX =
      containerSize.width - display.controlInsets.trailing
        - OneShotLayout.modeToolbarGap - size.width / 2
    let x = minX <= maxX ? min(max(rect.midX, minX), maxX) : rect.midX
    let belowY = rect.maxY + OneShotLayout.modeToolbarGap + size.height / 2
    let maxY =
      containerSize.height - display.controlInsets.bottom
        - OneShotLayout.modeToolbarGap - size.height / 2
    let aboveY = rect.minY - OneShotLayout.modeToolbarGap - size.height / 2
    let y =
      belowY <= maxY
        ? belowY
        : max(display.controlInsets.top + OneShotLayout.modeToolbarGap + size.height / 2, aboveY)
    return CGPoint(x: x, y: y)
  }

  private func oneShotRecordingCenter(rect: CGRect, containerSize: CGSize) -> CGPoint {
    let size = OneShotLayout.recordingPanelSize
    let minX = display.controlInsets.leading + 12 + size.width / 2
    let maxX = containerSize.width - display.controlInsets.trailing - 12 - size.width / 2
    let minY = display.controlInsets.top + 12 + size.height / 2
    let maxY = containerSize.height - display.controlInsets.bottom - 12 - size.height / 2
    return CGPoint(
      x: minX <= maxX ? min(max(rect.midX, minX), maxX) : rect.midX,
      y: minY <= maxY ? min(max(rect.midY, minY), maxY) : rect.midY
    )
  }

  private func oneShotSwitcher(state: OneShotSessionState, containerSize: CGSize) -> some View {
    let width = min(
      OneShotLayout.switcherPreferredWidth,
      max(
        320,
        containerSize.width - display.controlInsets.leading - display.controlInsets.trailing - 24
      )
    )
    let minX =
      display.screenFrame.minX + display.controlInsets.leading
        + OneShotLayout.switcherScreenInset + width / 2
    let maxX =
      display.screenFrame.maxX - display.controlInsets.trailing
        - OneShotLayout.switcherScreenInset - width / 2
    let range =
      minX <= maxX
        ? ClosedRange(uncheckedBounds: (lower: minX, upper: maxX))
        : ClosedRange(uncheckedBounds: (lower: state.switcherX, upper: state.switcherX))
    let localX = state.switcherX - display.screenFrame.minX
    let y =
      display.controlInsets.top + OneShotLayout.switcherTopGap
        + OneShotLayout.switcherHeight / 2
    return OneShotTopSwitcher(
      state: state,
      width: width,
      horizontalRange: range,
      onSelect: { session.selectOneShotTab($0) }
    )
    .position(x: localX, y: y)
  }

  private func oneShotSwitcherRect(in containerSize: CGSize) -> CGRect {
    let state = session.oneShotState
    guard state.showsTopSwitcher,
          state.switcherDisplayID == display.displayID
    else { return .null }
    let width = min(
      OneShotLayout.switcherPreferredWidth,
      max(
        320,
        containerSize.width - display.controlInsets.leading - display.controlInsets.trailing - 24
      )
    )
    let center = CGPoint(
      x: state.switcherX - display.screenFrame.minX,
      y: display.controlInsets.top + OneShotLayout.switcherTopGap + OneShotLayout.switcherHeight / 2
    )
    return CGRect(
      x: center.x - width / 2,
      y: center.y - OneShotLayout.switcherHeight / 2,
      width: width,
      height: OneShotLayout.switcherHeight
    )
  }

  private func updateOneShotMagnifier(at location: CGPoint, containerSize: CGSize) {
    guard shouldShowOneShotMagnifier else {
      oneShotMagnifierSample = nil
      session.oneShotState.updateCurrentColor(hex: nil, rgb: nil)
      return
    }
    let globalPoint = CGPoint(
      x: display.screenFrame.minX + location.x,
      y: display.screenFrame.maxY - location.y
    )
    let sample = OneShotMagnifierSampler.sample(
      image: display.backdropCGImage,
      localPoint: location,
      displaySize: containerSize,
      globalPoint: globalPoint,
      sampleRadius: magnifierSampleRadius
    )
    oneShotMagnifierSample = sample
    session.oneShotState.updateCurrentColor(hex: sample?.hex, rgb: sample?.rgb)
  }

  private var shouldShowOneShotMagnifier: Bool {
    guard screenshotMagnifierEnabled, session.activePrompt == nil else { return false }
    switch session.oneShotState.phase {
    case .armed, .selecting:
      return true
    case .selected, .committed:
      return isOneShotReselecting || movingPreviewRect != nil || resizePreviewRect != nil
    case .idle, .preparing, .executing, .terminating:
      return false
    }
  }

  private var magnifierSampleRadius: Int {
    // A higher requested zoom shows a smaller source region in the fixed-size loupe.
    max(2, 8 - min(max(screenshotMagnifierZoom, 1), 20) / 3)
  }

  private func oneShotMagnifierPosition(cursor: CGPoint, containerSize: CGSize) -> CGPoint {
    let size = OneShotLayout.magnifierSize
    let gap: CGFloat = 18
    var x = cursor.x + gap + size.width / 2
    var y = cursor.y + gap + size.height / 2
    if x + size.width / 2 > containerSize.width - 8 {
      x = cursor.x - gap - size.width / 2
    }
    if y + size.height / 2 > containerSize.height - 8 {
      y = cursor.y - gap - size.height / 2
    }
    return CGPoint(
      x: min(max(x, size.width / 2 + 8), containerSize.width - size.width / 2 - 8),
      y: min(max(y, size.height / 2 + 8), containerSize.height - size.height / 2 - 8)
    )
  }

  private func oneShotSelectionSizeLabel(
    rect: CGRect,
    containerSize: CGSize,
    controlSide: InlineAreaVerticalSide?
  ) -> some View {
    let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
    let labelSize = CGSize(
      width: max(82, CGFloat(text.count) * 8 + 20),
      height: InlineAreaLayout.selectionSizeLabelHeight
    )
    let y = InlineAreaLayout.selectionSizeLabelCenterY(
      for: rect,
      controlTopInset: display.controlInsets.top,
      controlSide: controlSide
    )
    let x = min(
      max(rect.minX + labelSize.width / 2, labelSize.width / 2 + 8),
      containerSize.width - labelSize.width / 2 - 8
    )
    return Text(verbatim: text)
      .font(.system(size: 12, weight: .semibold, design: .monospaced))
      .foregroundStyle(Color.primary)
      .frame(width: labelSize.width, height: labelSize.height)
      .background(OneShotSizeLabelBackground())
      .position(x: x, y: y)
      .allowsHitTesting(false)
      .accessibilityIdentifier("oneshot-selection-size")
  }

  private func moveGesture(for desktopRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        guard activeResizeHandle == nil else { return }
        if movingStartRect == nil {
          movingStartRect = desktopRect
        }
        guard let start = movingStartRect else { return }
        let previewRect = session.clampedSelectionPreview(
          for: start.offsetBy(dx: value.translation.width, dy: value.translation.height)
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          cursorIndicatorPoint = value.location
          movingPreviewRect = previewRect
        }
        updateOneShotMagnifier(at: value.location, containerSize: display.localFrame.size)
        updateNativeCursorForIndicator(true)
      }
      .onEnded { value in
        let start = movingStartRect ?? desktopRect
        let finalRect = session.clampedSelectionPreview(
          for: start.offsetBy(dx: value.translation.width, dy: value.translation.height)
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          session.moveSelection(to: finalRect, refreshImage: true)
          movingPreviewRect = nil
          movingStartRect = nil
        }
        cursorIndicatorPoint = nil
        InlineAreaNativeCursor.restoreOpenHand()
      }
  }

  @ViewBuilder
  private func resizeHandles(rect: CGRect, desktopRect: CGRect) -> some View {
    let visualOutset = InlineAreaResizeHandleChrome.visualOutset
    InlineAreaResizeHandlesOverlay()
      .frame(
        width: rect.width + visualOutset * 2,
        height: rect.height + visualOutset * 2
      )
      .position(x: rect.midX, y: rect.midY)
      .allowsHitTesting(false)

    ForEach(InlineAreaResizeHandle.allCases) { handle in
      InlineAreaResizeHandleHitTarget(handle: handle) { hovering in
        if hovering {
          hoveredResizeHandle = handle
          handle.cursor.set()
        } else if hoveredResizeHandle == handle {
          hoveredResizeHandle = nil
          updateNativeCursorForIndicator(false)
        }
      }
      .position(handle.position(in: rect))
      .gesture(
        resizeGesture(
          for: handle,
          desktopRect: desktopRect,
          containerSize: session.desktopFrame.size
        )
      )
    }
  }

  private func resizeGesture(
    for handle: InlineAreaResizeHandle,
    desktopRect: CGRect,
    containerSize: CGSize
  ) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(InlineAreaCoordinateSpace.root))
      .onChanged { value in
        if resizingStartRect == nil {
          resizingStartRect = desktopRect
        }
        guard let start = resizingStartRect else { return }
        let previewRect = resizedSelectionRect(
          from: start,
          handle: handle,
          translation: value.translation,
          containerSize: containerSize
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          activeResizeHandle = handle
          movingPreviewRect = nil
          resizePreviewRect = previewRect
          cursorIndicatorPoint = value.location
        }
        handle.cursor.set()
        updateOneShotMagnifier(at: value.location, containerSize: display.localFrame.size)
      }
      .onEnded { value in
        let start = resizingStartRect ?? desktopRect
        let finalRect = resizedSelectionRect(
          from: start,
          handle: handle,
          translation: value.translation,
          containerSize: containerSize
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
          session.resizeSelection(to: finalRect, previousRect: start)
          resizePreviewRect = nil
          resizingStartRect = nil
          activeResizeHandle = nil
          cursorIndicatorPoint = nil
          oneShotMagnifierSample = nil
        }
        updateNativeCursorForIndicator(false)
      }
  }

  private func resizedSelectionRect(
    from start: CGRect,
    handle: InlineAreaResizeHandle,
    translation: CGSize,
    containerSize: CGSize
  ) -> CGRect {
    let rect = start.standardized
    let minSize = InlineAreaLayout.minimumSelectionSize
    var minX = rect.minX
    var maxX = rect.maxX
    var minY = rect.minY
    var maxY = rect.maxY

    if handle.adjustsLeft {
      minX = clamped(rect.minX + translation.width, min: 0, max: maxX - minSize)
    }
    if handle.adjustsRight {
      maxX = clamped(rect.maxX + translation.width, min: minX + minSize, max: containerSize.width)
    }
    if handle.adjustsTop {
      minY = clamped(rect.minY + translation.height, min: 0, max: maxY - minSize)
    }
    if handle.adjustsBottom {
      maxY = clamped(rect.maxY + translation.height, min: minY + minSize, max: containerSize.height)
    }

    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
  }

  private func selectionBorder(rect: CGRect) -> some View {
    Rectangle()
      .strokeBorder(Color.white, lineWidth: InlineAreaResizeHandleChrome.borderWidth)
      .shadow(color: .black.opacity(0.45), radius: 2)
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
  }

  private func controlPlacement(
    for rect: CGRect,
    containerSize: CGSize,
    showsProperties: Bool,
    propertiesContentWidth: CGFloat,
    controlInsets: InlineAreaControlInsets
  ) -> InlineAreaControlPlacement {
    InlineAreaControlGeometry.placement(
      for: rect,
      containerSize: containerSize,
      showsProperties: showsProperties,
      propertiesContentWidth: propertiesContentWidth,
      controlInsets: controlInsets
    )
  }

  private func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    guard minValue <= maxValue else { return value }
    return min(max(value, minValue), maxValue)
  }

  private func updateNativeCursorForIndicator(_ isIndicatorVisible: Bool) {
    if session.activePrompt != nil {
      InlineAreaNativeCursor.restoreArrow()
    } else if !session.isSelectingOneShotOCR,
              let resizeHandle = activeResizeHandle ?? hoveredResizeHandle {
      resizeHandle.cursor.set()
    } else if session.phase == .selecting {
      NSCursor.vectorScreenshotCrosshairLight.set()
    } else if isIndicatorVisible {
      InlineAreaNativeCursor.hide()
    } else {
      InlineAreaNativeCursor.restoreArrow()
    }
  }
}

private struct InlineAreaOverlayPromptCard: View {
  @Environment(\.colorScheme) private var colorScheme

  let prompt: InlineAreaOverlayPrompt
  let action: (InlineAreaOverlayPromptAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(palette.iconForeground)
          .frame(width: 44, height: 44)
          .background(
            palette.iconBackground,
            in: RoundedRectangle(cornerRadius: Size.radiusLg, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.primaryText)
          Text(message)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Rectangle()
        .fill(palette.divider)
        .frame(height: 1)

      buttons
    }
    .padding(20)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(palette.surface)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(palette.border, lineWidth: 1)
    }
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.56 : 0.34), radius: 28, x: 0, y: 12)
  }

  private var buttons: some View {
    HStack(spacing: Spacing.sm) {
      Button(L10n.Common.cancel) {
        action(.cancel)
      }
      .buttonStyle(.bordered)
      .tint(palette.neutralButtonTint)

      Spacer()

      switch prompt {
      case .unsavedChanges:
        Button(L10n.AnnotateUI.dontSave, role: .destructive) {
          action(.secondary)
        }
        .buttonStyle(.bordered)
        .tint(.red)

        Button(L10n.Common.save) {
          action(.primary)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)

      case .saveLocationRecovery:
        Button(L10n.FileAccess.chooseFolderPrompt) {
          action(.primary)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)

      case .saveFailure:
        Button(L10n.Common.copy) {
          action(.tertiary)
        }
        .buttonStyle(.bordered)
        .tint(palette.neutralButtonTint)

        Button(L10n.FileAccess.chooseFolderPrompt) {
          action(.secondary)
        }
        .buttonStyle(.bordered)
        .tint(palette.neutralButtonTint)

        Button(L10n.Common.save) {
          action(.primary)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
      }
    }
    .controlSize(.regular)
  }

  private var title: String {
    switch prompt {
    case .unsavedChanges:
      L10n.AnnotateUI.unsavedChangesTitle
    case .saveLocationRecovery:
      L10n.Recording.saveLocationAccessRequiredTitle
    case .saveFailure:
      L10n.AnnotateUI.saveFailedTitle
    }
  }

  private var message: String {
    switch prompt {
    case .unsavedChanges:
      L10n.AnnotateUI.unsavedChangesMessage
    case .saveLocationRecovery:
      L10n.Recording.saveLocationAccessRequiredMessage
    case .saveFailure(let detail, _):
      detail
    }
  }

  private var icon: String {
    switch prompt {
    case .unsavedChanges:
      "exclamationmark.triangle.fill"
    case .saveLocationRecovery:
      "folder.badge.questionmark"
    case .saveFailure:
      "externaldrive.badge.exclamationmark"
    }
  }

  private var palette: InlineAreaOverlayPromptPalette {
    InlineAreaOverlayPromptPalette(colorScheme: colorScheme)
  }
}

private struct InlineAreaOverlayPromptPalette {
  let surface: Color
  let primaryText: Color
  let secondaryText: Color
  let border: Color
  let divider: Color
  let iconForeground: Color
  let iconBackground: Color
  let neutralButtonTint: Color

  init(colorScheme: ColorScheme) {
    if colorScheme == .dark {
      surface = Color(red: 0.12, green: 0.125, blue: 0.14)
      primaryText = Color.white.opacity(0.96)
      secondaryText = Color.white.opacity(0.72)
      border = Color.white.opacity(0.18)
      divider = Color.white.opacity(0.12)
      iconForeground = Color(red: 1, green: 0.66, blue: 0.24)
      iconBackground = Color(red: 1, green: 0.58, blue: 0.12).opacity(0.16)
      neutralButtonTint = Color.white.opacity(0.76)
    } else {
      surface = Color(red: 0.975, green: 0.978, blue: 0.985)
      primaryText = Color.black.opacity(0.90)
      secondaryText = Color.black.opacity(0.62)
      border = Color.black.opacity(0.16)
      divider = Color.black.opacity(0.10)
      iconForeground = Color(red: 0.76, green: 0.32, blue: 0.02)
      iconBackground = Color(red: 0.90, green: 0.42, blue: 0.04).opacity(0.13)
      neutralButtonTint = Color.black.opacity(0.66)
    }
  }
}

private enum InlineAreaCoordinateSpace {
  static let root = "inline-area-annotate-root"
}

struct InlineAreaAnnotationPreviewLayout: Equatable {
  let displayScale: CGFloat
  let canvasBounds: CGRect

  static func resolve(
    stableSelectionRect: CGRect,
    displayFrame: CGRect,
    imageSize: CGSize
  ) -> InlineAreaAnnotationPreviewLayout {
    let stable = stableSelectionRect.standardized
    let display = displayFrame.standardized
    let displayScale = max(stable.width / max(imageSize.width, 1), 0.0001)
    return InlineAreaAnnotationPreviewLayout(
      displayScale: displayScale,
      canvasBounds: CGRect(
        x: (display.minX - stable.minX) / displayScale,
        y: (stable.maxY - display.maxY) / displayScale,
        width: display.width / displayScale,
        height: display.height / displayScale
      )
    )
  }
}

private struct InlineAreaCursorIndicator: View {
  let point: CGPoint

  private let frameSize: CGFloat = 28
  private let lineLength: CGFloat = 10

  var body: some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      var path = Path()
      path.move(to: CGPoint(x: center.x, y: center.y - lineLength))
      path.addLine(to: CGPoint(x: center.x, y: center.y + lineLength))
      path.move(to: CGPoint(x: center.x - lineLength, y: center.y))
      path.addLine(to: CGPoint(x: center.x + lineLength, y: center.y))

      context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
      context.stroke(path, with: .color(.white), lineWidth: 1.5)
    }
    .frame(width: frameSize, height: frameSize)
    .position(point)
    .allowsHitTesting(false)
  }
}

private enum InlineAreaNativeCursor {
  private static let hiddenCursor: NSCursor = {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 1,
      pixelsHigh: 1,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 4,
      bitsPerPixel: 32
    )
    if let rep {
      if let bitmapData = rep.bitmapData {
        for offset in 0 ..< (rep.bytesPerRow * rep.pixelsHigh) {
          bitmapData[offset] = 0
        }
      }
      image.addRepresentation(rep)
    }
    return NSCursor(image: image, hotSpot: .zero)
  }()

  static func hide() {
    hiddenCursor.set()
  }

  static func restoreArrow() {
    NSCursor.arrow.set()
  }

  static func restoreOpenHand() {
    NSCursor.openHand.set()
  }
}

private struct InlineAreaSelectionGestureModifier<SelectionGesture: Gesture>: ViewModifier {
  let selectionGesture: SelectionGesture
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .contentShape(Rectangle())
        .gesture(selectionGesture)
    } else {
      content
    }
  }
}

private extension View {
  func inlineAreaSelectionGesture(
    _ selectionGesture: some Gesture,
    isEnabled: Bool
  ) -> some View {
    modifier(
      InlineAreaSelectionGestureModifier(
        selectionGesture: selectionGesture,
        isEnabled: isEnabled
      )
    )
  }
}

struct InlineAreaControlInsets: Equatable {
  var top: CGFloat
  var leading: CGFloat
  var bottom: CGFloat
  var trailing: CGFloat

  static let zero = InlineAreaControlInsets()

  init(
    top: CGFloat = 0,
    leading: CGFloat = 0,
    bottom: CGFloat = 0,
    trailing: CGFloat = 0
  ) {
    self.top = max(0, top)
    self.leading = max(0, leading)
    self.bottom = max(0, bottom)
    self.trailing = max(0, trailing)
  }

  init(screen: NSScreen) {
    self.init(
      screenFrame: screen.frame,
      visibleFrame: screen.visibleFrame,
      safeAreaInsets: screen.safeAreaInsets
    )
  }

  init(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    safeAreaInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
  ) {
    let visibleTop = max(0, screenFrame.maxY - visibleFrame.maxY)
    let visibleLeading = max(0, visibleFrame.minX - screenFrame.minX)
    let visibleBottom = max(0, visibleFrame.minY - screenFrame.minY)
    let visibleTrailing = max(0, screenFrame.maxX - visibleFrame.maxX)

    self.init(
      top: max(visibleTop, safeAreaInsets.top),
      leading: max(visibleLeading, safeAreaInsets.left),
      bottom: max(visibleBottom, safeAreaInsets.bottom),
      trailing: max(visibleTrailing, safeAreaInsets.right)
    )
  }

  var controlTopPadding: CGFloat {
    top + InlineAreaLayout.screenPadding
  }

  var controlLeadingPadding: CGFloat {
    leading + InlineAreaLayout.screenPadding
  }

  var controlBottomPadding: CGFloat {
    bottom + InlineAreaLayout.screenPadding
  }

  var controlTrailingPadding: CGFloat {
    trailing + InlineAreaLayout.screenPadding
  }
}

enum InlineAreaVerticalSide: Equatable {
  case above
  case below
}

private enum InlineAreaResizeHandle: CaseIterable, Identifiable {
  case topLeft
  case top
  case topRight
  case right
  case bottomRight
  case bottom
  case bottomLeft
  case left

  var id: Self {
    self
  }

  var adjustsLeft: Bool {
    switch self {
    case .topLeft, .bottomLeft, .left:
      true
    default:
      false
    }
  }

  var adjustsRight: Bool {
    switch self {
    case .topRight, .right, .bottomRight:
      true
    default:
      false
    }
  }

  var adjustsTop: Bool {
    switch self {
    case .topLeft, .top, .topRight:
      true
    default:
      false
    }
  }

  var adjustsBottom: Bool {
    switch self {
    case .bottomLeft, .bottom, .bottomRight:
      true
    default:
      false
    }
  }

  var cursor: NSCursor {
    switch self {
    case .top, .bottom:
      .resizeUpDown
    case .left, .right:
      .resizeLeftRight
    case .topLeft, .bottomRight:
      InlineAreaResizeCursor.diagonal(nwse: true)
    case .topRight, .bottomLeft:
      InlineAreaResizeCursor.diagonal(nwse: false)
    }
  }

  func position(in rect: CGRect) -> CGPoint {
    switch self {
    case .topLeft:
      CGPoint(x: rect.minX, y: rect.minY)
    case .top:
      CGPoint(x: rect.midX, y: rect.minY)
    case .topRight:
      CGPoint(x: rect.maxX, y: rect.minY)
    case .right:
      CGPoint(x: rect.maxX, y: rect.midY)
    case .bottomRight:
      CGPoint(x: rect.maxX, y: rect.maxY)
    case .bottom:
      CGPoint(x: rect.midX, y: rect.maxY)
    case .bottomLeft:
      CGPoint(x: rect.minX, y: rect.maxY)
    case .left:
      CGPoint(x: rect.minX, y: rect.midY)
    }
  }
}

private enum InlineAreaResizeHandleChrome {
  // Keep the visible resize chrome aligned with Windows so each of the eight
  // handles reads as a separate draggable target instead of a heavy border.
  static let borderWidth: CGFloat = 1.4
  static let hitSize: CGFloat = 24
  static let cornerSize: CGFloat = 16
  static let cornerPathInset: CGFloat = 1
  static let edgeLength: CGFloat = 22
  static let thickness: CGFloat = 2.4
  static let shadowOffset: CGFloat = 1
  static let visualOutset: CGFloat = cornerSize / 2 + thickness / 2 + shadowOffset
}

private struct InlineAreaResizeHandlesOverlay: View {
  var body: some View {
    Canvas { context, size in
      let visualOutset = InlineAreaResizeHandleChrome.visualOutset
      let rect = CGRect(
        x: visualOutset,
        y: visualOutset,
        width: max(0, size.width - visualOutset * 2),
        height: max(0, size.height - visualOutset * 2)
      )
      let shortestSide = min(rect.width, rect.height)
      let cornerSize = min(
        InlineAreaResizeHandleChrome.cornerSize,
        max(10, shortestSide * 0.38)
      )

      drawCornerHandles(in: rect, size: cornerSize, context: &context)
      drawEdgeHandles(in: rect, cornerSize: cornerSize, context: &context)
    }
  }

  private func drawCornerHandles(
    in rect: CGRect,
    size: CGFloat,
    context: inout GraphicsContext
  ) {
    drawCorner(
      at: CGPoint(x: rect.minX, y: rect.minY),
      corner: .topLeft,
      size: size,
      context: &context
    )
    drawCorner(
      at: CGPoint(x: rect.maxX, y: rect.minY),
      corner: .topRight,
      size: size,
      context: &context
    )
    drawCorner(
      at: CGPoint(x: rect.minX, y: rect.maxY),
      corner: .bottomLeft,
      size: size,
      context: &context
    )
    drawCorner(
      at: CGPoint(x: rect.maxX, y: rect.maxY),
      corner: .bottomRight,
      size: size,
      context: &context
    )
  }

  private func drawCorner(
    at point: CGPoint,
    corner: InlineAreaResizeHandle,
    size: CGFloat,
    context: inout GraphicsContext
  ) {
    let thickness = InlineAreaResizeHandleChrome.thickness
    let outerOffset = max(0, size / 2 - InlineAreaResizeHandleChrome.cornerPathInset)
    let innerExtent = size / 2
    let armLength = outerOffset + innerExtent

    let horizontalRect: CGRect
    let verticalRect: CGRect

    switch corner {
    case .topLeft, .topRight, .bottomLeft, .bottomRight:
      let isLeft = corner.adjustsLeft
      let isTop = corner.adjustsTop
      let elbow = CGPoint(
        x: point.x + (isLeft ? -outerOffset : outerOffset),
        y: point.y + (isTop ? -outerOffset : outerOffset)
      )
      horizontalRect = CGRect(
        x: isLeft ? elbow.x : elbow.x - armLength,
        y: elbow.y - thickness / 2,
        width: armLength,
        height: thickness
      )
      verticalRect = CGRect(
        x: elbow.x - thickness / 2,
        y: isTop ? elbow.y : elbow.y - armLength,
        width: thickness,
        height: armLength
      )
    default:
      return
    }

    drawHandleBar(horizontalRect, context: &context)
    drawHandleBar(verticalRect, context: &context)
  }

  private func drawEdgeHandles(
    in rect: CGRect,
    cornerSize: CGFloat,
    context: inout GraphicsContext
  ) {
    let thickness = InlineAreaResizeHandleChrome.thickness
    let minimumGap: CGFloat = 12

    if rect.width >= cornerSize * 2 + minimumGap {
      let length = min(
        InlineAreaResizeHandleChrome.edgeLength,
        max(10, rect.width - cornerSize * 2 - 8)
      )
      let halfLength = length / 2
      drawHandleBar(
        CGRect(
          x: rect.midX - halfLength,
          y: rect.minY - thickness / 2,
          width: length,
          height: thickness
        ),
        context: &context
      )
      drawHandleBar(
        CGRect(
          x: rect.midX - halfLength,
          y: rect.maxY - thickness / 2,
          width: length,
          height: thickness
        ),
        context: &context
      )
    }

    if rect.height >= cornerSize * 2 + minimumGap {
      let length = min(
        InlineAreaResizeHandleChrome.edgeLength,
        max(10, rect.height - cornerSize * 2 - 8)
      )
      let halfLength = length / 2
      drawHandleBar(
        CGRect(
          x: rect.minX - thickness / 2,
          y: rect.midY - halfLength,
          width: thickness,
          height: length
        ),
        context: &context
      )
      drawHandleBar(
        CGRect(
          x: rect.maxX - thickness / 2,
          y: rect.midY - halfLength,
          width: thickness,
          height: length
        ),
        context: &context
      )
    }
  }

  private func drawHandleBar(_ rect: CGRect, context: inout GraphicsContext) {
    context.fill(
      Path(
        rect.offsetBy(
          dx: 0,
          dy: InlineAreaResizeHandleChrome.shadowOffset
        )
      ),
      with: .color(.black.opacity(0.5))
    )
    context.fill(Path(rect), with: .color(.white))
  }
}

private struct InlineAreaResizeHandleHitTarget: View {
  let handle: InlineAreaResizeHandle
  let onHoverChange: (Bool) -> Void

  var body: some View {
    Color.clear
      .frame(
        width: InlineAreaResizeHandleChrome.hitSize, height: InlineAreaResizeHandleChrome.hitSize
      )
      .contentShape(Rectangle())
      .onHover(perform: onHoverChange)
  }
}

struct InlineAreaControlPlacement {
  let toolbarWidth: CGFloat
  let propertiesWidth: CGFloat
  let toolbarCenter: CGPoint
  let propertiesCenter: CGPoint
  let propertiesPopoverEdge: Edge
  let toolbarSide: InlineAreaVerticalSide
}

private enum InlineAreaToolbarMetrics {
  static let iconButtonSize: CGFloat = ToolbarConstants.iconButtonSize
  static let iconSize: CGFloat = ToolbarConstants.iconSize
  static let buttonCornerRadius: CGFloat = ToolbarConstants.buttonCornerRadius
  static let toolbarCornerRadius: CGFloat = ToolbarConstants.toolbarCornerRadius
  static let dividerHeight: CGFloat = ToolbarConstants.dividerHeight
  static let itemSpacing: CGFloat = ToolbarConstants.itemSpacing
  static let groupSpacing: CGFloat = ToolbarConstants.groupSpacing
  static let horizontalPadding: CGFloat = ToolbarConstants.horizontalPadding
  static let verticalPadding: CGFloat = ToolbarConstants.verticalPadding
  static let hoverAnimation: Animation = ToolbarConstants.hoverAnimation
}

enum InlineAreaLayout {
  static let toolbarHeight: CGFloat =
    InlineAreaToolbarMetrics.iconButtonSize + InlineAreaToolbarMetrics.verticalPadding * 2
  static let propertiesHeight: CGFloat = 38
  static let controlStackSpacing: CGFloat = 6
  static let selectionGap: CGFloat = 12
  static let selectionSizeLabelHeight: CGFloat = 28
  static let selectionSizeLabelGap: CGFloat = 8
  static let screenPadding: CGFloat = 16
  static let controlPanelOuterHorizontalInset: CGFloat = 12
  static let minimumSelectionSize: CGFloat = 24
  static func reservedControlHeight(showsProperties: Bool) -> CGFloat {
    if showsProperties {
      return toolbarHeight + controlStackSpacing + propertiesHeight
    }
    return toolbarHeight
  }

  static func selectionSizeLabelCenterY(
    for rect: CGRect,
    controlTopInset: CGFloat,
    controlSide: InlineAreaVerticalSide?
  ) -> CGFloat {
    let halfHeight = selectionSizeLabelHeight / 2
    let preferredY = rect.minY - selectionSizeLabelGap - halfHeight
    let insideY = min(
      rect.maxY - halfHeight - selectionSizeLabelGap,
      rect.minY + halfHeight + selectionSizeLabelGap
    )
    if controlSide != .above, preferredY >= controlTopInset + 4 {
      return preferredY
    }
    return insideY
  }
}

enum InlineAreaControlGeometry {
  static func placement(
    for rect: CGRect,
    containerSize: CGSize,
    showsProperties: Bool,
    propertiesContentWidth: CGFloat,
    controlInsets: InlineAreaControlInsets
  ) -> InlineAreaControlPlacement {
    let toolbarWidth = controlDeckWidth(
      for: containerSize,
      controlInsets: controlInsets
    )
    let propertiesWidth = propertiesBarWidth(
      for: containerSize,
      toolbarWidth: toolbarWidth,
      showsProperties: showsProperties,
      contentWidth: propertiesContentWidth,
      controlInsets: controlInsets
    )
    let toolbarX = clampedControlCenterX(
      rect.midX,
      width: toolbarWidth,
      containerSize: containerSize,
      controlInsets: controlInsets
    )
    let propertiesX = clampedControlCenterX(
      rect.midX,
      width: propertiesWidth,
      containerSize: containerSize,
      controlInsets: controlInsets
    )
    let verticalSide = preferredVerticalSide(
      for: rect,
      containerSize: containerSize,
      controlInsets: controlInsets
    )
    let centers = controlCenters(
      for: rect,
      side: verticalSide,
      containerSize: containerSize,
      showsProperties: showsProperties,
      controlInsets: controlInsets
    )
    let splitSides = splitControlSides(
      for: rect,
      preferredSide: verticalSide,
      containerSize: containerSize,
      showsProperties: showsProperties,
      controlInsets: controlInsets
    )
    let toolbarCenterY =
      splitSides == nil
        ? centers.toolbar
        : singleControlCenter(
          for: rect,
          height: InlineAreaLayout.toolbarHeight,
          side: splitSides?.toolbar ?? verticalSide,
          containerSize: containerSize,
          controlInsets: controlInsets
        )
    let propertiesCenterY =
      splitSides == nil
        ? centers.properties
        : singleControlCenter(
          for: rect,
          height: InlineAreaLayout.propertiesHeight,
          side: splitSides?.properties ?? verticalSide,
          containerSize: containerSize,
          controlInsets: controlInsets
        )
    let propertiesSide = splitSides?.properties ?? verticalSide

    return InlineAreaControlPlacement(
      toolbarWidth: toolbarWidth,
      propertiesWidth: propertiesWidth,
      toolbarCenter: CGPoint(x: toolbarX, y: toolbarCenterY),
      propertiesCenter: CGPoint(x: propertiesX, y: propertiesCenterY),
      propertiesPopoverEdge: propertiesSide == .above ? .bottom : .top,
      toolbarSide: splitSides?.toolbar ?? verticalSide
    )
  }

  private static func controlDeckWidth(
    for containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    min(664, availableControlWidth(for: containerSize, controlInsets: controlInsets))
  }

  private static func propertiesBarWidth(
    for containerSize: CGSize,
    toolbarWidth: CGFloat,
    showsProperties: Bool,
    contentWidth: CGFloat,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    let availableWidth = availableControlWidth(for: containerSize, controlInsets: controlInsets)
    guard showsProperties else {
      return min(toolbarWidth, availableWidth)
    }

    let measuredContentWidth = contentWidth + InlineAreaLayout.controlPanelOuterHorizontalInset
    let measuredWidth = contentWidth > 0 ? measuredContentWidth : toolbarWidth
    return min(availableWidth, max(toolbarWidth, measuredWidth))
  }

  private static func availableControlWidth(
    for containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    max(
      0,
      containerSize.width - controlInsets.controlLeadingPadding
        - controlInsets.controlTrailingPadding
    )
  }

  private static func clampedControlCenterX(
    _ preferredX: CGFloat,
    width: CGFloat,
    containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    let minX = width / 2 + controlInsets.controlLeadingPadding
    let maxX = containerSize.width - width / 2 - controlInsets.controlTrailingPadding
    guard minX <= maxX else {
      return containerSize.width / 2
    }
    return clamped(preferredX, min: minX, max: maxX)
  }

  private static func preferredVerticalSide(
    for rect: CGRect,
    containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> InlineAreaVerticalSide {
    let aboveSpace = spaceAbove(rect, controlInsets: controlInsets)
    let belowSpace = spaceBelow(rect, containerSize: containerSize, controlInsets: controlInsets)

    if belowSpace >= InlineAreaLayout.toolbarHeight {
      return .below
    }
    if aboveSpace >= InlineAreaLayout.toolbarHeight {
      return .above
    }
    if rect.minY <= controlInsets.controlTopPadding + InlineAreaLayout.selectionGap {
      return .below
    }
    return aboveSpace >= belowSpace ? .above : .below
  }

  private static func splitControlSides(
    for rect: CGRect,
    preferredSide: InlineAreaVerticalSide,
    containerSize: CGSize,
    showsProperties: Bool,
    controlInsets: InlineAreaControlInsets
  ) -> (toolbar: InlineAreaVerticalSide, properties: InlineAreaVerticalSide)? {
    guard showsProperties else { return nil }

    let aboveSpace = spaceAbove(rect, controlInsets: controlInsets)
    let belowSpace = spaceBelow(rect, containerSize: containerSize, controlInsets: controlInsets)

    let preferredSpace = preferredSide == .above ? aboveSpace : belowSpace
    if preferredSpace >= InlineAreaLayout.reservedControlHeight(showsProperties: true) {
      return nil
    }

    switch preferredSide {
    case .above:
      if aboveSpace >= InlineAreaLayout.toolbarHeight,
         belowSpace >= InlineAreaLayout.propertiesHeight {
        return (.above, .below)
      }
      if aboveSpace >= InlineAreaLayout.propertiesHeight,
         belowSpace >= InlineAreaLayout.toolbarHeight {
        return (.below, .above)
      }
    case .below:
      if belowSpace >= InlineAreaLayout.toolbarHeight,
         aboveSpace >= InlineAreaLayout.propertiesHeight {
        return (.below, .above)
      }
      if belowSpace >= InlineAreaLayout.propertiesHeight,
         aboveSpace >= InlineAreaLayout.toolbarHeight {
        return (.above, .below)
      }
    }

    return nil
  }

  private static func controlCenters(
    for rect: CGRect,
    side: InlineAreaVerticalSide,
    containerSize: CGSize,
    showsProperties: Bool,
    controlInsets: InlineAreaControlInsets
  ) -> (toolbar: CGFloat, properties: CGFloat) {
    let reservedHeight = InlineAreaLayout.reservedControlHeight(showsProperties: showsProperties)
    let minGroupCenter = controlInsets.controlTopPadding + reservedHeight / 2
    let maxGroupCenter =
      containerSize.height - controlInsets.controlBottomPadding - reservedHeight / 2
    let rawGroupCenter: CGFloat = switch side {
    case .above:
      rect.minY - InlineAreaLayout.selectionGap - reservedHeight / 2
    case .below:
      rect.maxY + InlineAreaLayout.selectionGap + reservedHeight / 2
    }

    let groupCenter = clamped(rawGroupCenter, min: minGroupCenter, max: maxGroupCenter)
    let groupTop = groupCenter - reservedHeight / 2
    let toolbarCenter = groupTop + InlineAreaLayout.toolbarHeight / 2
    let propertiesCenter =
      showsProperties
        ? groupTop + InlineAreaLayout.toolbarHeight + InlineAreaLayout.controlStackSpacing
        + InlineAreaLayout.propertiesHeight / 2
        : toolbarCenter

    return (toolbarCenter, propertiesCenter)
  }

  private static func singleControlCenter(
    for rect: CGRect,
    height: CGFloat,
    side: InlineAreaVerticalSide,
    containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    let rawCenter: CGFloat = switch side {
    case .above:
      rect.minY - InlineAreaLayout.selectionGap - height / 2
    case .below:
      rect.maxY + InlineAreaLayout.selectionGap + height / 2
    }

    return clamped(
      rawCenter,
      min: controlInsets.controlTopPadding + height / 2,
      max: containerSize.height - controlInsets.controlBottomPadding - height / 2
    )
  }

  private static func spaceAbove(
    _ rect: CGRect,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    rect.minY - controlInsets.controlTopPadding - InlineAreaLayout.selectionGap
  }

  private static func spaceBelow(
    _ rect: CGRect,
    containerSize: CGSize,
    controlInsets: InlineAreaControlInsets
  ) -> CGFloat {
    containerSize.height - rect.maxY - controlInsets.controlBottomPadding
      - InlineAreaLayout.selectionGap
  }

  private static func clamped(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat)
    -> CGFloat {
    guard minValue <= maxValue else { return value }
    return min(max(value, minValue), maxValue)
  }
}

private enum InlineAreaChrome {
  static let cornerRadius: CGFloat = InlineAreaToolbarMetrics.toolbarCornerRadius
  static let controlCornerRadius: CGFloat = InlineAreaToolbarMetrics.buttonCornerRadius
  static let controlSize: CGFloat = InlineAreaToolbarMetrics.iconButtonSize
  static let moveControlWidth: CGFloat = 72
  static let propertyControlHeight: CGFloat = 24
  static let itemBackground = Color.primary.opacity(0.06)
  static let itemSelectedBackground = Color.primary.opacity(0.12)
  static let itemSelectedForeground = Color.primary
  static let itemSelectedBorder = Color.clear
  static let itemBorder = Color.clear
  static let divider = Color.primary.opacity(0.15)
  static let primaryText = Color.primary.opacity(0.86)
  static let secondaryText = Color.secondary.opacity(0.88)
}

private struct InlineAreaPanelBorder: View {
  @Environment(\.colorScheme) var colorScheme

  var body: some View {
    RoundedRectangle(cornerRadius: InlineAreaChrome.cornerRadius, style: .continuous)
      .strokeBorder(
        colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12),
        lineWidth: 1.0
      )
  }
}

private struct InlineAreaPanelBackgroundTint: View {
  @Environment(\.colorScheme) var colorScheme

  var body: some View {
    if colorScheme == .dark {
      Color.black.opacity(0.25)
    } else {
      Color.white.opacity(0.15)
    }
  }
}

private extension View {
  func inlineAreaPanelChrome() -> some View {
    background(InlineAreaPanelBackgroundTint())
      .background(InlineAreaHudMaterialBackground(cornerRadius: InlineAreaChrome.cornerRadius))
      .clipShape(RoundedRectangle(cornerRadius: InlineAreaChrome.cornerRadius, style: .continuous))
      .overlay(InlineAreaPanelBorder())
      .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)
      .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
  }
}

private struct InlineAreaHudMaterialBackground: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context _: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    configure(view)
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
    configure(nsView)
  }

  private func configure(_ view: NSVisualEffectView) {
    view.material = .hudWindow
    view.state = .active
    view.blendingMode = .withinWindow
    view.wantsLayer = true
    view.layer?.cornerRadius = cornerRadius
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true

    // Explicitly set vibrancy appearance to match color scheme
    let isDark = ThemeManager.shared.systemAppearance == .dark
    view.appearance = NSAppearance(named: isDark ? .vibrantDark : .vibrantLight)
  }
}

enum InlineAreaResizeCursor {
  static func diagonal(nwse: Bool) -> NSCursor {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()

    let path = NSBezierPath()
    path.lineCapStyle = .round
    path.lineJoinStyle = .round

    if nwse {
      path.move(to: NSPoint(x: 3, y: 13))
      path.line(to: NSPoint(x: 13, y: 3))
      path.move(to: NSPoint(x: 3, y: 9))
      path.line(to: NSPoint(x: 3, y: 13))
      path.line(to: NSPoint(x: 7, y: 13))
      path.move(to: NSPoint(x: 9, y: 3))
      path.line(to: NSPoint(x: 13, y: 3))
      path.line(to: NSPoint(x: 13, y: 7))
    } else {
      path.move(to: NSPoint(x: 3, y: 3))
      path.line(to: NSPoint(x: 13, y: 13))
      path.move(to: NSPoint(x: 3, y: 7))
      path.line(to: NSPoint(x: 3, y: 3))
      path.line(to: NSPoint(x: 7, y: 3))
      path.move(to: NSPoint(x: 9, y: 13))
      path.line(to: NSPoint(x: 13, y: 13))
      path.line(to: NSPoint(x: 13, y: 9))
    }

    // Match the high-contrast treatment of system cursors: the white halo
    // stays visible over dark captures, while the black core remains clear
    // over light captures.
    NSColor.white.withAlphaComponent(0.96).setStroke()
    path.lineWidth = 4
    path.stroke()
    NSColor.black.withAlphaComponent(0.92).setStroke()
    path.lineWidth = 1.8
    path.stroke()
    image.unlockFocus()
    image.isTemplate = false
    return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
  }
}

private struct InlineAreaControlDeck<MoveGesture: Gesture>: View {
  @ObservedObject var session: InlineAreaAnnotateSession
  let maxWidth: CGFloat
  let moveGesture: MoveGesture

  var body: some View {
    HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
          InlineAreaMoveHandle(isToolbarHandle: true)
            .gesture(moveGesture)

          InlineAreaDivider()

          ForEach(Array(AnnotationToolType.oneShotToolGroups.enumerated()), id: \.offset) { index, tools in
            if index > 0 {
              InlineAreaDivider()
            }
            InlineAreaToolGroup(tools: tools, selectedTool: session.state.selectedTool) { tool in
              guard session.commitOneShotInteraction(.screenshotTool) else { return }
              session.state.activateTool(tool)
            }
          }
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      .disabled(session.isExporting)
      .opacity(session.isExporting ? 0.55 : 1)
      .frame(minWidth: 0, maxWidth: .infinity)

      InlineAreaDivider()

      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(
          icon: "arrow.uturn.backward",
          tooltip: L10n.Common.withShortcut(L10n.Common.undo, "⌘Z"),
          isEnabled: session.state.canUndo
        ) {
          guard session.commitOneShotInteraction(.screenshotUndoRedo) else { return }
          session.state.undo()
        }

        InlineAreaIconButton(
          icon: "arrow.uturn.forward",
          tooltip: L10n.Common.withShortcut(L10n.Common.redo, "⇧⌘Z"),
          isEnabled: session.state.canRedo
        ) {
          guard session.commitOneShotInteraction(.screenshotUndoRedo) else { return }
          session.state.redo()
        }
      }
      .disabled(session.isExporting)
      .opacity(session.isExporting ? 0.55 : 1)
      .fixedSize(horizontal: true, vertical: false)

      InlineAreaDivider()

      InlineAreaIconButton(
        icon: "viewfinder",
        tooltip: L10n.Actions.captureTextOCR,
        customGlyph: .ocr,
        accessibilityIdentifier: "oneshot-screenshot-ocr"
      ) {
        session.activateOneShotOCRSelection()
      }
      .disabled(session.isExporting)
      .opacity(session.isExporting ? 0.55 : 1)

      InlineAreaDivider()

      InlineAreaZoomControls(session: session)
        .disabled(session.isExporting)
        .opacity(session.isExporting ? 0.55 : 1)
        .fixedSize(horizontal: true, vertical: false)

      InlineAreaDivider()

      HStack(spacing: InlineAreaToolbarMetrics.itemSpacing) {
        InlineAreaIconButton(
          icon: "pin",
          tooltip: L10n.PreferencesQuickAccess.pinToScreenAction,
          isEnabled: !session.isExporting,
          accessibilityIdentifier: "oneshot-screenshot-pin"
        ) {
          Task { await session.finishAndPin() }
        }

        InlineAreaIconButton(
          icon: "doc.on.doc",
          tooltip: L10n.Common.withShortcut(L10n.AnnotateUI.copyToClipboard, "⌘C"),
          isEnabled: !session.isExporting,
          accessibilityIdentifier: "oneshot-screenshot-copy"
        ) {
          session.copyCurrentImage()
        }

        InlineAreaIconButton(
          icon: "xmark",
          tooltip: L10n.Common.withShortcut(L10n.Common.cancel, "Esc"),
          isEnabled: !session.isExporting,
          accessibilityIdentifier: "oneshot-screenshot-cancel"
        ) {
          session.cancel()
        }

        InlineAreaIconButton(
          icon: "checkmark",
          tooltip: L10n.Common.withShortcut(L10n.Common.done, "↩"),
          isEnabled: !session.isExporting,
          isProminent: true,
          isLoading: session.isExporting,
          accessibilityIdentifier: "oneshot-screenshot-finish"
        ) {
          Task { await session.finish() }
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: max(0, maxWidth - InlineAreaToolbarMetrics.horizontalPadding * 2))
    .padding(.horizontal, InlineAreaToolbarMetrics.horizontalPadding)
    .padding(.vertical, InlineAreaToolbarMetrics.verticalPadding)
    .inlineAreaPanelChrome()
    .animation(.easeOut(duration: 0.16), value: session.state.selectedTool)
    .accessibilityIdentifier("oneshot-screenshot-toolbar")
  }
}

private struct InlineAreaZoomControls: View {
  @ObservedObject var session: InlineAreaAnnotateSession

  var body: some View {
    HStack(spacing: InlineAreaToolbarMetrics.groupSpacing) {
      InlineAreaIconButton(
        icon: "hand.draw",
        tooltip: L10n.AnnotateUI.panCanvas,
        isEnabled: session.state.canPanInteractively,
        isSelected: session.state.isCanvasPanningMode
      ) {
        guard session.commitOneShotInteraction(.screenshotViewport) else { return }
        session.state.isCanvasPanningMode.toggle()
      }

      InlineAreaIconButton(
        icon: "minus.magnifyingglass",
        tooltip: L10n.Common.withShortcut(L10n.AnnotateUI.zoomOut, "⌘−")
      ) {
        guard session.commitOneShotInteraction(.screenshotViewport) else { return }
        session.state.zoomOut()
      }

      Menu {
        Button(L10n.AnnotateUI.fitWithShortcut("⌘0")) {
          guard session.commitOneShotInteraction(.screenshotViewport) else { return }
          session.state.fitCanvasToViewport()
        }
        Divider()
        ForEach(session.state.zoomMenuPresetPercents, id: \.self) { percent in
          Button("\(percent)%") {
            guard session.commitOneShotInteraction(.screenshotViewport) else { return }
            session.state.setDisplayedZoomPercent(percent)
          }
        }
      } label: {
        Text("\(session.state.currentDisplayedZoomPercent)%")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .frame(minWidth: 42)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(L10n.AnnotateUI.zoomLevel(session.state.currentDisplayedZoomPercent))
      .accessibilityLabel(L10n.AnnotateUI.zoomLevel(session.state.currentDisplayedZoomPercent))

      InlineAreaIconButton(
        icon: "plus.magnifyingglass",
        tooltip: L10n.Common.withShortcut(L10n.AnnotateUI.zoomIn, "⌘+")
      ) {
        guard session.commitOneShotInteraction(.screenshotViewport) else { return }
        session.state.zoomIn()
      }
    }
  }
}

private struct InlineAreaToolGroup: View {
  let tools: [AnnotationToolType]
  let selectedTool: AnnotationToolType
  let action: (AnnotationToolType) -> Void

  var body: some View {
    HStack(spacing: InlineAreaToolbarMetrics.groupSpacing) {
      ForEach(tools, id: \.self) { tool in
        InlineAreaToolButton(tool: tool, selectedTool: selectedTool) {
          action(tool)
        }
      }
    }
  }
}

private struct InlineAreaToolButton: View {
  let tool: AnnotationToolType
  let selectedTool: AnnotationToolType
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      InlineAreaToolGlyph(
        tool: tool,
        color: .primary.opacity(isSelected || isHovering ? 1.0 : 0.85)
      )
      .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
      .background(buttonBackground)
      .contentShape(
        RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .help(tool.displayName)
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
    .accessibilityLabel(tool.displayName)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var isSelected: Bool {
    selectedTool == tool
  }

  private var buttonBackground: some View {
    RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
      .fill(
        isSelected
          ? Color.primary.opacity(0.12) : (isHovering ? Color.primary.opacity(0.10) : Color.clear)
      )
  }
}

private struct InlineAreaToolGlyph: View {
  let tool: AnnotationToolType
  let color: Color

  var body: some View {
    switch tool {
    case .text:
      ZStack {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .stroke(color, lineWidth: 1.4)
          .frame(width: 16, height: 16)
        Text(verbatim: "T")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(color)
          // The rounded glyph's asymmetric side bearings make a mathematically
          // centered "T" look slightly left of the surrounding square.
          .offset(x: 0.5)
      }
    case .blur:
      InlineAreaMosaicGlyph(color: color)
    default:
      Image(systemName: tool.icon)
        .font(.system(size: InlineAreaToolbarMetrics.iconSize, weight: .medium))
        .foregroundStyle(color)
    }
  }
}

private struct InlineAreaMosaicGlyph: View {
  let color: Color
  private let opacities: [Double] = [1, 0.48, 0.78, 0.62, 1, 0.42, 0.82, 0.58, 1]

  var body: some View {
    VStack(spacing: 1) {
      ForEach(0 ..< 3, id: \.self) { row in
        HStack(spacing: 1) {
          ForEach(0 ..< 3, id: \.self) { column in
            Rectangle()
              .fill(color.opacity(opacities[row * 3 + column]))
              .frame(width: 4, height: 4)
          }
        }
      }
    }
    .frame(width: 16, height: 16)
  }
}

private struct InlineAreaMoveHandle: View {
  let isToolbarHandle: Bool
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Image(
        systemName: isToolbarHandle
          ? "circle.grid.3x3.fill" : "arrow.up.and.down.and.arrow.left.and.right"
      )
      .font(.system(size: 12, weight: .medium))

      if !isToolbarHandle {
        Text(L10n.ShortcutOverlay.spaceKey)
          .font(.system(size: 11, weight: .semibold))
          .lineLimit(1)
      }
    }
    .foregroundColor(.primary.opacity(isHovering ? 1.0 : 0.85))
    .frame(
      width: isToolbarHandle ? InlineAreaChrome.controlSize : InlineAreaChrome.moveControlWidth,
      height: InlineAreaChrome.controlSize
    )
    .background(
      RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
        .fill(isHovering ? Color.primary.opacity(0.10) : Color.clear)
    )
    .contentShape(
      RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
    )
    .help(isToolbarHandle ? L10n.OneShot.dragToolbarHint : L10n.AnnotateUI.moveSelection)
    .accessibilityLabel(isToolbarHandle ? L10n.OneShot.dragToolbarHint : L10n.AnnotateUI.moveSelection)
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
  }
}

private enum InlineAreaCustomGlyph {
  case ocr
}

private struct InlineAreaIconButton: View {
  let icon: String
  let tooltip: String
  var isEnabled: Bool = true
  var isProminent: Bool = false
  var isSelected: Bool = false
  var isLoading: Bool = false
  var customGlyph: InlineAreaCustomGlyph?
  var accessibilityIdentifier: String?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      glyph
        .font(.system(size: InlineAreaToolbarMetrics.iconSize, weight: .medium))
        .foregroundColor(foregroundColor)
        .frame(width: InlineAreaChrome.controlSize, height: InlineAreaChrome.controlSize)
        .background(background)
        .contentShape(
          RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
        )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled || isLoading)
    .opacity(isEnabled ? 1 : 0.42)
    .help(tooltip)
    .accessibilityLabel(tooltip)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(accessibilityIdentifier ?? "")
    .onHover { isHovering = $0 }
    .animation(InlineAreaToolbarMetrics.hoverAnimation, value: isHovering)
  }

  @ViewBuilder
  private var glyph: some View {
    if isLoading {
      ProgressView()
        .controlSize(.small)
        .accessibilityHidden(true)
    } else if customGlyph == .ocr {
      ZStack {
        Image(systemName: "viewfinder")
        Text(verbatim: "T")
          .font(.system(size: 7, weight: .bold, design: .rounded))
      }
    } else {
      Image(systemName: icon)
    }
  }

  private var foregroundColor: Color {
    if isSelected {
      return .accentColor
    }
    return .primary.opacity(isHovering || isProminent ? 1.0 : 0.85)
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
      .fill(
        isSelected
          ? Color.accentColor.opacity(0.16)
          : (isHovering ? Color.primary.opacity(0.10) : Color.clear)
      )
  }
}

private struct InlineAreaDivider: View {
  var body: some View {
    RecordingToolbarDivider()
  }
}

private struct InlineAreaPropertiesBar: View {
  @ObservedObject var state: AnnotateState
  let maxWidth: CGFloat
  let popoverEdge: Edge
  let onContentWidthChange: (CGFloat) -> Void

  private let strokeColors: [Color] = [
    .red, .orange, .yellow, .green, .blue, .purple, .white, .black,
  ]
  var body: some View {
    ZStack(alignment: .leading) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          contextPill

          if state.quickPropertiesSupportsStrokeColor {
            InlineAreaColorControl(
              title: colorTitle,
              selectedColor: state.quickStrokeColorBinding,
              colors: strokeColors
            )
          }

          if state.quickPropertiesSupportsBlurType {
            InlineAreaSegmentedPicker(
              title: L10n.AnnotateUI.blurType,
              items: BlurType.allCases,
              selection: state.quickBlurTypeBinding,
              icon: { $0.icon },
              tooltip: \.displayName
            )
          }

          if state.quickPropertiesSupportsArrowStyle {
            InlineAreaSegmentedPicker(
              title: L10n.Common.style,
              items: ArrowStyle.allCases,
              selection: state.quickArrowStyleBinding,
              icon: { $0.icon },
              isFlipped: { $0 == .curvedRight },
              tooltip: \.displayName
            )

            InlineAreaSegmentedPicker(
              title: L10n.Common.display,
              items: ArrowType.allCases,
              selection: state.quickArrowTypeBinding,
              icon: { $0.icon },
              isFlipped: { _ in state.arrowStyle == .curvedRight },
              tooltip: \.displayName
            )

            if state.quickPropertiesSupportsArrowBendDirection {
              InlineAreaArrowBendControl(
                bendDirection: state.quickArrowBendDirectionBinding
              )
            }

            if state.quickPropertiesSupportsArrowEndpoints {
              InlineAreaSegmentedPicker(
                title: L10n.AnnotateUI.arrowStartHead,
                items: ArrowEndpointStyle.allCases,
                selection: state.quickArrowStartHeadBinding,
                icon: { $0.icon },
                tooltip: \.displayName
              )

              InlineAreaSegmentedPicker(
                title: L10n.AnnotateUI.arrowEndHead,
                items: ArrowEndpointStyle.allCases,
                selection: state.quickArrowEndHeadBinding,
                icon: { $0.icon },
                tooltip: \.displayName
              )
            }
          }

          if state.quickPropertiesSupportsStrokeWidth {
            InlineAreaSliderControl(
              title: state.quickStrokeWidthLabel,
              icon: state.quickStrokeWidthIcon,
              value: state.quickStrokeWidthBinding,
              range: AnnotationProperties.controlValueRange,
              step: 1,
              displayText: state.quickStrokeWidthDisplayText,
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }

          if state.quickPropertiesSupportsTextFontSize {
            InlineAreaSliderControl(
              title: L10n.Common.size,
              icon: "textformat.size",
              value: state.quickTextFontSizeBinding,
              range: 12 ... 72,
              step: 1,
              displayText: "\(Int(state.quickTextFontSizeBinding.wrappedValue.rounded()))",
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }

          if state.quickPropertiesSupportsCornerRadius {
            InlineAreaSliderControl(
              title: L10n.Common.corners,
              icon: "roundedbottom.horizontal",
              value: state.quickCornerRadiusBinding,
              range: 0 ... 60,
              step: 1,
              displayText: "\(Int(state.quickCornerRadiusBinding.wrappedValue.rounded()))",
              onEditingChanged: state.setQuickPropertiesControlEditing
            )
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
          GeometryReader { proxy in
            Color.clear.preference(
              key: InlineAreaPropertiesContentWidthKey.self,
              value: proxy.size.width
            )
          }
        )
      }
      .frame(maxWidth: max(0, maxWidth - InlineAreaLayout.controlPanelOuterHorizontalInset))
    }
    .frame(width: maxWidth, height: InlineAreaLayout.propertiesHeight, alignment: .leading)
    .inlineAreaPanelChrome()
    .onPreferenceChange(InlineAreaPropertiesContentWidthKey.self) { width in
      onContentWidthChange(max(0, width))
    }
  }

  private var colorTitle: String {
    state.quickPropertiesTool == .text ? L10n.Common.text : L10n.Common.color
  }

  private var contextPill: some View {
    HStack(spacing: 6) {
      Image(systemName: state.quickPropertiesTool?.icon ?? "slider.horizontal.3")
        .font(.system(size: 11, weight: .bold))

      Text(state.quickPropertiesContextTitle)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .foregroundColor(InlineAreaChrome.primaryText)
    .padding(.horizontal, 8)
    .frame(height: InlineAreaChrome.propertyControlHeight)
    .frame(maxWidth: 142)
    .background(
      Capsule()
        .fill(InlineAreaChrome.itemBackground)
    )
  }
}

private struct InlineAreaPropertiesContentWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct InlineAreaColorControl: View {
  let title: String
  @Binding var selectedColor: Color
  let colors: [Color]

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      HStack(spacing: 5) {
        ForEach(colors, id: \.self) { color in
          Button {
            selectedColor = color
          } label: {
            InlineAreaColorSwatch(
              color: color,
              isSelected: InlineAreaColorPalette.colorsMatch(selectedColor, color),
              size: 15
            )
            .frame(width: 20, height: InlineAreaChrome.propertyControlHeight)
          }
          .buttonStyle(.plain)
          .help(InlineAreaColorPalette.isClear(color) ? L10n.Common.none : title)
        }
      }
    }
  }
}

private struct InlineAreaColorSwatch: View {
  let color: Color
  let isSelected: Bool
  let size: CGFloat

  var body: some View {
    ZStack {
      Circle()
        .fill(InlineAreaColorPalette.isClear(color) ? Color.clear : color)
        .frame(width: size, height: size)
        .overlay(
          Circle()
            .strokeBorder(
              isSelected ? Color.accentColor : Color.primary.opacity(0.32),
              lineWidth: isSelected ? 2 : 1
            )
        )

      if InlineAreaColorPalette.isClear(color) {
        Image(systemName: "slash.circle")
          .font(.system(size: max(9, size * 0.5), weight: .semibold))
          .foregroundColor(InlineAreaChrome.secondaryText)
      }
    }
  }
}

private enum InlineAreaColorPalette {
  private static let tolerance = 0.004

  static func isClear(_ color: Color) -> Bool {
    guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return false }
    return converted.alphaComponent <= tolerance
  }

  static func colorsMatch(_ lhs: Color, _ rhs: Color) -> Bool {
    guard let left = NSColor(lhs).usingColorSpace(.sRGB),
          let right = NSColor(rhs).usingColorSpace(.sRGB)
    else { return lhs == rhs }

    return abs(left.redComponent - right.redComponent) <= tolerance
      && abs(left.greenComponent - right.greenComponent) <= tolerance
      && abs(left.blueComponent - right.blueComponent) <= tolerance
      && abs(left.alphaComponent - right.alphaComponent) <= tolerance
  }
}

private struct InlineAreaSegmentedPicker<Item: Identifiable & Equatable>: View {
  let title: String
  let items: [Item]
  @Binding var selection: Item
  let icon: (Item) -> String
  var isFlipped: ((Item) -> Bool)?
  let tooltip: KeyPath<Item, String>

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      HStack(spacing: 4) {
        ForEach(items) { item in
          Button {
            selection = item
          } label: {
            Image(systemName: icon(item))
              .font(.system(size: 12, weight: .medium))
              .scaleEffect(x: 1, y: isFlipped?(item) == true ? -1 : 1)
              .foregroundColor(
                selection == item
                  ? InlineAreaChrome.itemSelectedForeground : InlineAreaChrome.secondaryText
              )
              .frame(width: 25, height: InlineAreaChrome.propertyControlHeight)
              .background(
                RoundedRectangle(
                  cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous
                )
                .fill(
                  selection == item
                    ? InlineAreaChrome.itemSelectedBackground : InlineAreaChrome.itemBackground
                )
              )
              .overlay(
                RoundedRectangle(
                  cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous
                )
                .stroke(
                  selection == item
                    ? InlineAreaChrome.itemSelectedBorder : InlineAreaChrome.itemBorder,
                  lineWidth: 1
                )
              )
          }
          .buttonStyle(.plain)
          .help(item[keyPath: tooltip])
        }
      }
    }
  }
}

private struct InlineAreaArrowBendControl: View {
  @Binding var bendDirection: ArrowBendDirection

  var body: some View {
    InlineAreaPropertyGroup(title: L10n.AnnotateUI.arrowBend) {
      Button {
        bendDirection = bendDirection.toggled
      } label: {
        Image(systemName: bendDirection.icon)
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(
            bendDirection == .alternate
              ? InlineAreaChrome.itemSelectedForeground : InlineAreaChrome.secondaryText
          )
          .frame(width: 25, height: InlineAreaChrome.propertyControlHeight)
          .background(
            RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
              .fill(
                bendDirection == .alternate
                  ? InlineAreaChrome.itemSelectedBackground : InlineAreaChrome.itemBackground
              )
          )
          .overlay(
            RoundedRectangle(cornerRadius: InlineAreaChrome.controlCornerRadius, style: .continuous)
              .stroke(
                bendDirection == .alternate
                  ? InlineAreaChrome.itemSelectedBorder : InlineAreaChrome.itemBorder, lineWidth: 1
              )
          )
      }
      .buttonStyle(.plain)
      .help("\(L10n.AnnotateUI.flipArrowBend): \(bendDirection.displayName)")
      .accessibilityLabel(L10n.AnnotateUI.flipArrowBend)
    }
  }
}

private struct InlineAreaSliderControl: View {
  let title: String
  let icon: String
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  let step: CGFloat
  let displayText: String
  let onEditingChanged: (Bool) -> Void

  var body: some View {
    InlineAreaPropertyGroup(title: title) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .semibold))
          .foregroundColor(InlineAreaChrome.secondaryText)

        Slider(
          value: $value.stepped(by: step, in: range),
          in: range,
          onEditingChanged: onEditingChanged
        )
        .frame(width: 58)
        .controlSize(.small)

        Text(displayText)
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(InlineAreaChrome.secondaryText)
          .lineLimit(1)
          .monospacedDigit()
          .frame(width: 34, alignment: .trailing)
      }
    }
  }
}

private struct InlineAreaPropertyGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(InlineAreaChrome.secondaryText)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .fixedSize(horizontal: true, vertical: false)

      content
    }
  }
}
