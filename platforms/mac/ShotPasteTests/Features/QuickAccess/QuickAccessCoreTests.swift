//
//  QuickAccessCoreTests.swift
//  ShotPasteTests
//
//  Unit tests for Quick Access models and countdown behavior.
//

import AppKit
@testable import ShotPaste
import XCTest

@MainActor
final class QuickAccessCoreTests: XCTestCase {
  // Keep MainActor ObservableObjects alive for the test process; XCTest scope
  // cleanup can crash while deinitializing app-level observable stores.
  private static var retainedActionStores: [QuickAccessActionConfigurationStore] = []
  private static var retainedPinWindowStates: [QuickAccessPinWindowState] = []

  func testQuickAccessItem_formatsVideoDurationAndOmitsInvalidDurations() {
    let thumbnail = NSImage(size: CGSize(width: 16, height: 16))
    let video = QuickAccessItem(
      url: URL(fileURLWithPath: "/tmp/demo.mov"),
      thumbnail: thumbnail,
      duration: 90.9
    )
    let invalidVideo = QuickAccessItem(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/bad.mov"),
      thumbnail: thumbnail,
      capturedAt: Date(),
      itemType: .video,
      duration: -.infinity
    )
    let screenshot = QuickAccessItem(
      url: URL(fileURLWithPath: "/tmp/demo.png"),
      thumbnail: thumbnail
    )

    XCTAssertTrue(video.isVideo)
    XCTAssertEqual(video.formattedDuration, "01:30s")
    XCTAssertNil(invalidVideo.formattedDuration)
    XCTAssertFalse(screenshot.isVideo)
    XCTAssertNil(screenshot.formattedDuration)
  }

  func testQuickAccessProcessingState_identifiesProcessingOnly() {
    XCTAssertFalse(QuickAccessProcessingState.idle.isProcessing)
    XCTAssertTrue(QuickAccessProcessingState.processing(progress: nil).isProcessing)
    XCTAssertTrue(QuickAccessProcessingState.processing(progress: 0.4).isProcessing)
    XCTAssertFalse(QuickAccessProcessingState.complete.isProcessing)
    XCTAssertFalse(QuickAccessProcessingState.failed.isProcessing)
  }

  func testQuickAccessCardDragPolicy_classifiesRightPanelDirections() {
    let policy = QuickAccessCardDragPolicy(dismissDirection: 1)

    XCTAssertEqual(policy.intent(forHorizontalTranslation: 30), .undetermined)
    XCTAssertEqual(policy.intent(forHorizontalTranslation: 31), .swipeToDismiss)
    XCTAssertEqual(policy.intent(forHorizontalTranslation: -31), .dragToApp)
  }

  func testQuickAccessCardDragPolicy_classifiesLeftPanelDirections() {
    let policy = QuickAccessCardDragPolicy(dismissDirection: -1)

    XCTAssertEqual(policy.intent(forHorizontalTranslation: -31), .swipeToDismiss)
    XCTAssertEqual(policy.intent(forHorizontalTranslation: 31), .dragToApp)
  }

  func testQuickAccessCardDragPolicy_dismissesByDistanceOrVelocity() {
    let policy = QuickAccessCardDragPolicy(dismissDirection: 1)

    XCTAssertFalse(policy.shouldDismiss(horizontalTranslation: 80, horizontalVelocity: 300))
    XCTAssertTrue(policy.shouldDismiss(horizontalTranslation: 81, horizontalVelocity: 0))
    XCTAssertTrue(policy.shouldDismiss(horizontalTranslation: 10, horizontalVelocity: 301))
    XCTAssertFalse(policy.shouldDismiss(horizontalTranslation: -81, horizontalVelocity: 0))
    XCTAssertFalse(policy.shouldDismiss(horizontalTranslation: -10, horizontalVelocity: -301))
  }

  func testQuickAccessTrackpadSwipeHelpers_requiresPreciseDominantHorizontalScroll() {
    XCTAssertEqual(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 12,
        scrollingDeltaY: 2,
        hasPreciseScrollingDeltas: true,
        sensitivityMultiplier: 1.0
      ),
      12
    )
    XCTAssertNil(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 12,
        scrollingDeltaY: 10,
        hasPreciseScrollingDeltas: true,
        sensitivityMultiplier: 1.0
      )
    )
    XCTAssertNil(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 0.25,
        scrollingDeltaY: 0,
        hasPreciseScrollingDeltas: true,
        sensitivityMultiplier: 1.0
      )
    )
    XCTAssertNil(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 12,
        scrollingDeltaY: 0,
        hasPreciseScrollingDeltas: false,
        sensitivityMultiplier: 1.0
      )
    )
    XCTAssertNil(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: .nan,
        scrollingDeltaY: 0,
        hasPreciseScrollingDeltas: true,
        sensitivityMultiplier: 1.0
      )
    )
  }

  func testQuickAccessTrackpadSwipeHelpers_sensitivityMultiplierAmplifiesDelta() {
    XCTAssertEqual(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 10,
        scrollingDeltaY: 1,
        hasPreciseScrollingDeltas: true,
        sensitivityMultiplier: 0.5
      ),
      5
    )
    XCTAssertEqual(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 10,
        scrollingDeltaY: 1,
        hasPreciseScrollingDeltas: true,
        sensitivityMultiplier: 3.0
      ),
      30
    )
    XCTAssertNil(
      QuickAccessTrackpadSwipeHelpers.horizontalDelta(
        scrollingDeltaX: 10,
        scrollingDeltaY: 1,
        hasPreciseScrollingDeltas: false,
        sensitivityMultiplier: 3.0
      )
    )
  }

  func testQuickAccessTrackpadSwipeHelpers_dismissesByDistanceOrVelocity() {
    XCTAssertFalse(
      QuickAccessTrackpadSwipeHelpers.shouldDismiss(
        horizontalTranslation: 80,
        horizontalVelocity: 300
      )
    )
    XCTAssertTrue(
      QuickAccessTrackpadSwipeHelpers.shouldDismiss(
        horizontalTranslation: 81,
        horizontalVelocity: 0
      )
    )
    XCTAssertTrue(
      QuickAccessTrackpadSwipeHelpers.shouldDismiss(
        horizontalTranslation: 10,
        horizontalVelocity: 301
      )
    )
  }

  func testQuickAccessTrackpadSwipeModeStore_persistsMode() {
    let defaults = makeIsolatedDefaults()

    let store = QuickAccessTrackpadSwipeModeStore(defaults: defaults)
    XCTAssertEqual(store.mode, .inverted)

    store.setMode(.natural)
    XCTAssertEqual(store.mode, .natural)

    let reloadedStore = QuickAccessTrackpadSwipeModeStore(defaults: defaults)
    XCTAssertEqual(reloadedStore.mode, .natural)
  }

  func testQuickAccessTrackpadSwipeModeStore_resetToDefault() {
    let defaults = makeIsolatedDefaults()

    let store = QuickAccessTrackpadSwipeModeStore(defaults: defaults)
    store.setMode(.natural)
    store.resetToDefault()

    XCTAssertEqual(store.mode, .inverted)
  }

  func testQuickAccessDragMonitorView_scopesScrollEventsToCardBounds() {
    final class MockLocationEvent: NSEvent {
      private let point: NSPoint

      init(point: NSPoint) {
        self.point = point
        super.init()
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }

      override var locationInWindow: NSPoint {
        point
      }
    }

    let monitor = QuickAccessDragMonitorView(
      fileURL: URL(fileURLWithPath: "/tmp/demo.png"),
      thumbnail: NSImage(size: CGSize(width: 16, height: 16)),
      dismissDirection: 1,
      dragDropEnabled: true,
      twoFingerSwipeToDismissEnabled: true,
      swipeMode: .natural,
      swipeSensitivity: 1.0,
      onDragStarted: {},
      onDragEnded: { _ in },
      onSwipeChanged: { _ in },
      onSwipeEnded: { _, _ in }
    )
    monitor.frame = NSRect(x: 0, y: 0, width: 180, height: 112)

    XCTAssertTrue(monitor.containsEventLocation(MockLocationEvent(point: NSPoint(x: 90, y: 56))))
    XCTAssertFalse(monitor.containsEventLocation(MockLocationEvent(point: NSPoint(x: 200, y: 56))))
    XCTAssertFalse(monitor.containsEventLocation(MockLocationEvent(point: NSPoint(x: 90, y: 140))))
  }

  func testQuickAccessItemEquality_tracksMutablePresentationState() {
    let id = UUID()
    let thumbnail = NSImage(size: CGSize(width: 16, height: 16))
    let capturedAt = Date()
    let thumbnailVersion = UUID()
    let base = QuickAccessItem(
      id: id,
      url: URL(fileURLWithPath: "/tmp/demo.png"),
      thumbnail: thumbnail,
      capturedAt: capturedAt,
      itemType: .screenshot,
      duration: nil,
      thumbnailVersion: thumbnailVersion
    )
    var processing = base
    processing.processingState = .processing(progress: nil)

    XCTAssertEqual(base, base)
    XCTAssertNotEqual(base, processing)

    var pinned = base
    pinned.isPinned = true
    XCTAssertNotEqual(base, pinned)
  }

  func testQuickAccessPinWindowSizing_enforcesMinimumInteractiveSizeForTinyImages() {
    let sizes = QuickAccessPinWindowSizing.sizes(
      for: CGSize(width: 24, height: 16),
      visibleSize: CGSize(width: 1440, height: 900)
    )
    let minimumSize = QuickAccessPinWindowSizing.minimumInteractiveSize

    XCTAssertGreaterThanOrEqual(sizes.base.width, minimumSize.width)
    XCTAssertGreaterThanOrEqual(sizes.base.height, minimumSize.height)
    XCTAssertLessThanOrEqual(sizes.base.width, sizes.max.width)
    XCTAssertLessThanOrEqual(sizes.base.height, sizes.max.height)
  }

  func testQuickAccessPinWindowState_clampsZoomToInteractiveMinimum() {
    let minimumSize = QuickAccessPinWindowSizing.minimumInteractiveSize
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/tiny.png"),
      image: image,
      thumbnail: image,
      baseSize: minimumSize,
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let displaySize = state.setZoomPercent(50)

    XCTAssertEqual(displaySize.width, minimumSize.width, accuracy: 0.001)
    XCTAssertEqual(displaySize.height, minimumSize.height, accuracy: 0.001)
    XCTAssertEqual(state.zoomPercent, 100)
    XCTAssertFalse(state.zoomMenuPercents.contains(50))
  }

  func testQuickAccessPinWindowState_reclampsWhenScreenSizingShrinks() {
    let image = NSImage(size: CGSize(width: 400, height: 300))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pinned.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 400, height: 300),
      maxSize: CGSize(width: 800, height: 600)
    )
    Self.retainedPinWindowStates.append(state)

    _ = state.setZoomPercent(200)
    let displaySize = state.updateSizing(
      baseSize: CGSize(width: 300, height: 225),
      maxSize: CGSize(width: 300, height: 225)
    )

    XCTAssertEqual(state.zoomPercent, 100)
    XCTAssertEqual(displaySize.width, 300, accuracy: 0.001)
    XCTAssertEqual(displaySize.height, 225, accuracy: 0.001)
  }

  func testQuickAccessPinWindowSizing_constrainedFrameClampsOversizedWindows() {
    let frame = NSRect(x: 100, y: 100, width: 900, height: 700)
    let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 600)

    let constrainedFrame = QuickAccessPinWindowSizing.constrainedFrame(
      frame,
      visibleFrame: visibleFrame
    )

    XCTAssertEqual(constrainedFrame.minX, 24, accuracy: 0.001)
    XCTAssertEqual(constrainedFrame.minY, 24, accuracy: 0.001)
    XCTAssertEqual(constrainedFrame.width, 752, accuracy: 0.001)
    XCTAssertEqual(constrainedFrame.height, 552, accuracy: 0.001)
  }

  func testQuickAccessPinWindow_scrollZoomStepRequiresUnlockedWindow() throws {
    let step = QuickAccessPinWindow.scrollZoomStep(
      scrollingDeltaY: 2,
      hasPreciseScrollingDeltas: false,
      isLocked: false
    )

    let unwrappedStep = try XCTUnwrap(step)
    XCTAssertEqual(unwrappedStep, 2.0 * QuickAccessPinWindow.scrollZoomSensitivityCoarse, accuracy: 0.001)
    XCTAssertNil(
      QuickAccessPinWindow.scrollZoomStep(
        scrollingDeltaY: 2,
        hasPreciseScrollingDeltas: false,
        isLocked: true
      )
    )
    XCTAssertNil(
      QuickAccessPinWindow.scrollZoomStep(
        scrollingDeltaY: .infinity,
        hasPreciseScrollingDeltas: false,
        isLocked: false
      )
    )

    let stepPrecise = QuickAccessPinWindow.scrollZoomStep(
      scrollingDeltaY: 2,
      hasPreciseScrollingDeltas: true,
      isLocked: false
    )
    let unwrappedPrecise = try XCTUnwrap(stepPrecise)
    XCTAssertEqual(unwrappedPrecise, 2.0 * QuickAccessPinWindow.scrollZoomSensitivityPrecise, accuracy: 0.001)

    let stepDiagonal = QuickAccessPinWindow.scrollZoomStep(
      scrollingDeltaX: 3,
      scrollingDeltaY: 4,
      hasPreciseScrollingDeltas: true,
      isLocked: false
    )
    let unwrappedDiagonal = try XCTUnwrap(stepDiagonal)
    XCTAssertEqual(unwrappedDiagonal, 5.0 * QuickAccessPinWindow.scrollZoomSensitivityPrecise, accuracy: 0.001)

    let stepHorizontal = QuickAccessPinWindow.scrollZoomStep(
      scrollingDeltaX: -5,
      scrollingDeltaY: 0,
      hasPreciseScrollingDeltas: true,
      isLocked: false
    )
    let unwrappedHorizontal = try XCTUnwrap(stepHorizontal)
    XCTAssertEqual(unwrappedHorizontal, -5.0 * QuickAccessPinWindow.scrollZoomSensitivityPrecise, accuracy: 0.001)
  }

  func testQuickAccessPinWindow_magnifyZoomStepRequiresUnlockedFiniteDelta() {
    XCTAssertEqual(
      QuickAccessPinWindow.magnifyZoomStep(magnification: 0.18, isLocked: false),
      0.18 * QuickAccessPinWindow.magnificationZoomSensitivity
    )
    XCTAssertNil(
      QuickAccessPinWindow.magnifyZoomStep(magnification: 0.18, isLocked: true)
    )
    XCTAssertNil(
      QuickAccessPinWindow.magnifyZoomStep(magnification: .nan, isLocked: false)
    )
  }

  func testQuickAccessPinWindow_requestMagnifyZoomRoutesUnlockedFiniteSteps() {
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pinned.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 320, height: 220),
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let window = QuickAccessPinWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
      state: state
    )
    defer { window.close() }

    var steps: [CGFloat] = []
    window.onZoomStepRequested = { steps.append($0) }

    XCTAssertTrue(window.requestMagnifyZoom(magnification: 0.14))
    XCTAssertEqual(steps.count, 1)
    XCTAssertEqual(steps[0], 0.14 * QuickAccessPinWindow.magnificationZoomSensitivity, accuracy: 0.001)

    state.isLocked = true

    XCTAssertFalse(window.requestMagnifyZoom(magnification: 0.14))
    XCTAssertEqual(steps.count, 1)
  }

  func testQuickAccessPinWindow_sendEventInterceptorsScrollWheel() {
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pinned.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 320, height: 220),
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let window = QuickAccessPinWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
      state: state
    )
    defer { window.close() }

    var steps: [CGFloat] = []
    window.onZoomStepRequested = { steps.append($0) }

    class MockScrollWheelEvent: NSEvent {
      private var _deltaX: CGFloat = 0.0
      private var _deltaY: CGFloat = 0.0
      private var _modifierFlags: NSEvent.ModifierFlags = []
      private var _hasPreciseDeltas: Bool = false

      static func make(
        deltaX: CGFloat = 0.0,
        deltaY: CGFloat,
        modifierFlags: NSEvent.ModifierFlags,
        hasPreciseDeltas: Bool = false
      ) -> MockScrollWheelEvent {
        let event = MockScrollWheelEvent()
        event._deltaX = deltaX
        event._deltaY = deltaY
        event._modifierFlags = modifierFlags
        event._hasPreciseDeltas = hasPreciseDeltas
        return event
      }

      override var type: NSEvent.EventType {
        .scrollWheel
      }

      override var scrollingDeltaX: CGFloat {
        _deltaX
      }

      override var scrollingDeltaY: CGFloat {
        _deltaY
      }

      override var modifierFlags: NSEvent.ModifierFlags {
        _modifierFlags
      }

      override var hasPreciseScrollingDeltas: Bool {
        _hasPreciseDeltas
      }
    }

    let eventWithCmd = MockScrollWheelEvent.make(deltaY: 2.0, modifierFlags: [.command])
    window.sendEvent(eventWithCmd)
    XCTAssertEqual(steps.count, 1)
    XCTAssertEqual(steps[0], 2.0 * QuickAccessPinWindow.scrollZoomSensitivityCoarse, accuracy: 0.001)

    let eventWithoutCmd = MockScrollWheelEvent.make(deltaY: 2.0, modifierFlags: [])
    window.sendEvent(eventWithoutCmd)
    XCTAssertEqual(steps.count, 2)
    XCTAssertEqual(steps[1], 2.0 * QuickAccessPinWindow.scrollZoomSensitivityCoarse, accuracy: 0.001)

    let eventPrecise = MockScrollWheelEvent.make(deltaY: 10.0, modifierFlags: [], hasPreciseDeltas: true)
    window.sendEvent(eventPrecise)
    XCTAssertEqual(steps.count, 3)
    XCTAssertEqual(steps[2], 10.0 * QuickAccessPinWindow.scrollZoomSensitivityPrecise, accuracy: 0.001)

    let eventDiagonal = MockScrollWheelEvent.make(deltaX: 6.0, deltaY: 8.0, modifierFlags: [], hasPreciseDeltas: true)
    window.sendEvent(eventDiagonal)
    XCTAssertEqual(steps.count, 4)
    XCTAssertEqual(steps[3], 10.0 * QuickAccessPinWindow.scrollZoomSensitivityPrecise, accuracy: 0.001)
  }

  func testQuickAccessPinWindow_requestMagnifyZoomDirectCall() {
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pinned.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 320, height: 220),
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let window = QuickAccessPinWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
      state: state
    )
    defer { window.close() }

    var steps: [CGFloat] = []
    window.onZoomStepRequested = { steps.append($0) }

    XCTAssertTrue(window.requestMagnifyZoom(magnification: 0.15))
    XCTAssertEqual(steps.count, 1)
    XCTAssertEqual(steps[0], 0.15 * QuickAccessPinWindow.magnificationZoomSensitivity, accuracy: 0.001)
  }

  func testQuickAccessPinWindow_levelSurvivesFloatingPanelConfiguration() {
    let image = NSImage(size: CGSize(width: 24, height: 16))
    let state = QuickAccessPinWindowState(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/pinned.png"),
      image: image,
      thumbnail: image,
      baseSize: CGSize(width: 320, height: 220),
      maxSize: CGSize(width: 1200, height: 900)
    )
    Self.retainedPinWindowStates.append(state)

    let window = QuickAccessPinWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
      state: state
    )
    defer { window.close() }

    XCTAssertTrue(window.isFloatingPanel)
    XCTAssertGreaterThan(window.level.rawValue, NSWindow.Level.floating.rawValue + 1)
  }

  func testQuickAccessPanel_interactiveRegionTracksVisibleCardsOnly() {
    let panelHeight =
      QuickAccessLayout.scaledCardHeight(1) * 5
        + QuickAccessLayout.cardSpacing * 4
        + QuickAccessLayout.containerPadding * 2
    let panel = QuickAccessPanel(
      contentRect: NSRect(x: 100, y: 100, width: 204, height: panelHeight)
    )
    defer { panel.close() }

    panel.updatePassthroughRegion(itemCount: 1, scale: 1)

    XCTAssertEqual(
      QuickAccessPanel.interactiveContentHeight(itemCount: 1, scale: 1, panelHeight: panelHeight),
      QuickAccessLayout.cardHeight + QuickAccessLayout.containerPadding * 2,
      accuracy: 0.001
    )
    XCTAssertTrue(panel.containsInteractivePoint(NSPoint(x: 150, y: 120)))
    XCTAssertFalse(panel.containsInteractivePoint(NSPoint(x: 150, y: panel.frame.maxY - 10)))
  }

  func testQuickAccessActionConfigurationStore_usesDefaultOrderAndEnabledActions() {
    let defaults = makeIsolatedDefaults()
    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertEqual(store.actionOrder, QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(store.orderedActions(includeDisabled: false), QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(store.slotAssignments, QuickAccessActionSlot.defaultAssignments)
    XCTAssertTrue(store.isEnabled(.pinToScreen))
  }

  func testQuickAccessActionConfigurationStore_filtersUnknownIdsAndAppendsMissingActions() {
    let defaults = makeIsolatedDefaults()
    defaults.set(
      [
        QuickAccessActionKind.delete.rawValue,
        "future-action",
        QuickAccessActionKind.copy.rawValue,
        QuickAccessActionKind.copy.rawValue,
      ],
      forKey: PreferencesKeys.quickAccessActionOrder
    )
    defaults.set(
      [
        QuickAccessActionKind.copy.rawValue,
        "future-action",
      ],
      forKey: PreferencesKeys.quickAccessEnabledActions
    )

    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertEqual(
      store.actionOrder,
      [.delete, .copy, .saveOrOpen, .dismiss, .pinToScreen]
    )
    XCTAssertEqual(store.orderedActions(includeDisabled: false), [.copy])
  }

  func testQuickAccessActionConfigurationStore_preservesExplicitPinToScreenDisable() {
    let defaults = makeIsolatedDefaults()
    defaults.set(
      QuickAccessActionKind.defaultOrder.map(\.rawValue),
      forKey: PreferencesKeys.quickAccessActionOrder
    )
    defaults.set(
      QuickAccessActionKind.defaultOrder
        .filter { $0 != .pinToScreen }
        .map(\.rawValue),
      forKey: PreferencesKeys.quickAccessEnabledActions
    )

    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertFalse(store.isEnabled(.pinToScreen))
    XCTAssertFalse(store.orderedActions(includeDisabled: false).contains(.pinToScreen))
  }

  func testQuickAccessActionConfigurationStore_togglesMovesAndPersistsActions() {
    let defaults = makeIsolatedDefaults()
    let store = makeActionConfigurationStore(defaults: defaults)

    store.setEnabled(.pinToScreen, enabled: false)
    store.moveAction(from: IndexSet(integer: 0), to: 3)

    XCTAssertFalse(store.isEnabled(.pinToScreen))
    XCTAssertEqual(
      store.actionOrder,
      [.saveOrOpen, .dismiss, .copy, .delete, .pinToScreen]
    )
    XCTAssertEqual(store.slotAssignments, QuickAccessActionSlot.defaultAssignments)

    let reloadedStore = makeActionConfigurationStore(defaults: defaults)
    XCTAssertFalse(reloadedStore.isEnabled(.pinToScreen))
    XCTAssertEqual(reloadedStore.actionOrder, store.actionOrder)
    XCTAssertEqual(reloadedStore.slotAssignments, QuickAccessActionSlot.defaultAssignments)

    reloadedStore.assignAction(.pinToScreen, to: .centerTop)
    reloadedStore.clearSlot(.bottomLeading)

    XCTAssertEqual(reloadedStore.action(in: .centerTop), .pinToScreen)
    XCTAssertNil(reloadedStore.action(in: .bottomTrailing))
    XCTAssertNil(reloadedStore.action(in: .bottomLeading))

    let placementReload = makeActionConfigurationStore(defaults: defaults)
    XCTAssertEqual(placementReload.action(in: .centerTop), .pinToScreen)
    XCTAssertNil(placementReload.action(in: .bottomTrailing))
    XCTAssertNil(placementReload.action(in: .bottomLeading))

    placementReload.resetToDefaults()
    XCTAssertEqual(placementReload.actionOrder, QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(placementReload.orderedActions(includeDisabled: false), QuickAccessActionKind.defaultOrder)
    XCTAssertEqual(placementReload.slotAssignments, QuickAccessActionSlot.defaultAssignments)
  }

  func testQuickAccessActionConfigurationStore_filtersSlotAssignmentsAndPreservesEmptySlots() {
    let defaults = makeIsolatedDefaults()
    defaults.set(
      [
        QuickAccessActionSlot.centerTop.rawValue: "future-action",
        QuickAccessActionSlot.centerBottom.rawValue: "",
        QuickAccessActionSlot.topTrailing.rawValue: QuickAccessActionKind.delete.rawValue,
        QuickAccessActionSlot.topLeading.rawValue: QuickAccessActionKind.delete.rawValue,
      ],
      forKey: PreferencesKeys.quickAccessActionSlotAssignments
    )

    let store = makeActionConfigurationStore(defaults: defaults)

    XCTAssertNil(store.action(in: .centerTop))
    XCTAssertNil(store.action(in: .centerBottom))
    XCTAssertEqual(store.action(in: .topTrailing), .delete)
    XCTAssertNil(store.action(in: .topLeading))
    XCTAssertNil(store.action(in: .bottomLeading))
    XCTAssertEqual(store.action(in: .bottomTrailing), .pinToScreen)
  }

  func testQuickAccessCountdownTimer_pauseResumePreservesRemainingTime() async throws {
    try skipIfRunningInCI()
    var didExpire = false
    let expiration = expectation(description: "timer expires after resume")
    let clock = ManualQuickAccessCountdownTimerClock()
    let timer = QuickAccessCountdownTimer(duration: 0.08, clock: clock) {
      didExpire = true
      expiration.fulfill()
    }

    timer.start()
    await clock.waitForSleepCallCount(1)
    clock.advance(by: 0.03)
    timer.pause()

    XCTAssertTrue(timer.isPaused)
    XCTAssertFalse(timer.isRunning)

    clock.advance(by: 0.12)
    await Task.yield()
    XCTAssertFalse(didExpire)

    timer.resume()
    XCTAssertTrue(timer.isRunning)

    await clock.waitForSleepCallCount(2)
    clock.advance(by: 0.05)

    await fulfillment(of: [expiration], timeout: 1.0)
    XCTAssertTrue(didExpire)
  }

  func testQuickAccessCountdownTimer_cancelPreventsExpiration() async throws {
    try skipIfRunningInCI()
    var didExpire = false
    let clock = ManualQuickAccessCountdownTimerClock()
    let timer = QuickAccessCountdownTimer(duration: 0.03, clock: clock) {
      didExpire = true
    }

    timer.start()
    await clock.waitForSleepCallCount(1)
    timer.cancel()
    clock.advance(by: 0.08)
    await Task.yield()

    XCTAssertFalse(didExpire)
    XCTAssertFalse(timer.isRunning)
    XCTAssertFalse(timer.isPaused)
  }

  func testQuickAccessCountdownTimer_reportsAccurateProgressWhenPaused() async throws {
    try skipIfRunningInCI()
    let clock = ManualQuickAccessCountdownTimerClock()
    var progressValues: [Double] = []
    let timer = QuickAccessCountdownTimer(
      duration: 0.08,
      clock: clock,
      onProgress: { progressValues.append($0) },
      onExpire: {}
    )

    timer.start()
    await clock.waitForSleepCallCount(1)
    clock.advance(by: 0.03)
    timer.pause()

    XCTAssertEqual(try XCTUnwrap(progressValues.first), 1, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(progressValues.last), 0.625, accuracy: 0.0001)
    timer.cancel()
  }

  func testQuickAccessKeyboardNavigationClampsAndHandlesEmptyStacks() {
    XCTAssertEqual(
      QuickAccessKeyboardNavigation.destinationIndex(from: 1, delta: 1, itemCount: 4),
      2
    )
    XCTAssertEqual(
      QuickAccessKeyboardNavigation.destinationIndex(from: 0, delta: -1, itemCount: 4),
      0
    )
    XCTAssertEqual(
      QuickAccessKeyboardNavigation.destinationIndex(from: 3, delta: 1, itemCount: 4),
      3
    )
    XCTAssertNil(
      QuickAccessKeyboardNavigation.destinationIndex(from: 0, delta: 1, itemCount: 0)
    )
  }

  private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "ShotPasteTests.QuickAccess.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeActionConfigurationStore(
    defaults: UserDefaults
  ) -> QuickAccessActionConfigurationStore {
    let store = QuickAccessActionConfigurationStore(defaults: defaults)
    Self.retainedActionStores.append(store)
    return store
  }
}

@MainActor
private final class ManualQuickAccessCountdownTimerClock: QuickAccessCountdownTimerClock {
  private struct SleepRequest {
    let wakeTime: TimeInterval
    let continuation: CheckedContinuation<Void, Never>
  }

  private(set) var now: TimeInterval = 0
  private var sleepRequests: [SleepRequest] = []
  private var sleepCallCount = 0
  private var sleepCallWaiters: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func sleep(for duration: TimeInterval) async {
    await withCheckedContinuation { continuation in
      sleepCallCount += 1
      resumeSatisfiedSleepCallWaiters()

      let wakeTime = now + max(0, duration)
      guard wakeTime > now else {
        continuation.resume()
        return
      }

      sleepRequests.append(SleepRequest(wakeTime: wakeTime, continuation: continuation))
    }
  }

  func advance(by duration: TimeInterval) {
    now += duration

    var readyContinuations: [CheckedContinuation<Void, Never>] = []
    sleepRequests.removeAll { request in
      guard request.wakeTime <= now else { return false }
      readyContinuations.append(request.continuation)
      return true
    }

    readyContinuations.forEach { $0.resume() }
  }

  func waitForSleepCallCount(_ expectedCount: Int) async {
    guard sleepCallCount < expectedCount else { return }

    await withCheckedContinuation { continuation in
      sleepCallWaiters.append((expectedCount, continuation))
    }
  }

  private func resumeSatisfiedSleepCallWaiters() {
    var readyContinuations: [CheckedContinuation<Void, Never>] = []
    sleepCallWaiters.removeAll { waiter in
      guard sleepCallCount >= waiter.expectedCount else { return false }
      readyContinuations.append(waiter.continuation)
      return true
    }

    readyContinuations.forEach { $0.resume() }
  }
}
