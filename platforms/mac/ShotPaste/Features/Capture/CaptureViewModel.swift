//
//  CaptureViewModel.swift
//  ShotPaste
//
//  ViewModel for screen capture operations
//

import AppKit
import Combine
import Foundation

// MARK: - Image Format Option

enum ImageFormatOption: String, CaseIterable {
  case png
  case jpeg
  case webp

  var format: ImageFormat {
    switch self {
    case .png: return .png
    case .jpeg:
      let storedQuality = UserDefaults.standard.integer(forKey: PreferencesKeys.screenshotLossyQuality)
      let quality = storedQuality == 0 ? 90 : min(max(storedQuality, 1), 100)
      return .jpeg(quality: CGFloat(quality) / 100.0)
    case .webp: return .webp
    }
  }

  var displayName: String {
    switch self {
    case .png: "PNG"
    case .jpeg: "JPEG"
    case .webp: "WebP"
    }
  }
}

// MARK: - ViewModel

@MainActor
final class ScreenCaptureViewModel: ObservableObject, KeyboardShortcutDelegate {
  @Published var hasPermission: Bool = false
  private var saveDirectory: URL

  private let captureManager = ScreenCaptureManager.shared
  private let shortcutManager = KeyboardShortcutManager.shared
  private let postCaptureHandler = PostCaptureActionHandler.shared
  private let fileAccessManager = SandboxFileAccessManager.shared
  private let tempCaptureManager = TempCaptureManager.shared
  private var isAreaSelectionActive = false
  private var cancellables = Set<AnyCancellable>()

  init() {
    fileAccessManager.ensureExportLocationInitialized()
    saveDirectory = fileAccessManager.resolvedExportDirectoryURL()

    // Set up shortcut delegate
    shortcutManager.delegate = self

    // Subscribe to capture completions for post-capture actions
    captureManager.captureCompletedPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] url in
        guard let self else { return }
        Task {
          await self.postCaptureHandler.handleScreenshotCapture(url: url)
        }
      }
      .store(in: &cancellables)

    captureManager.$hasPermission
      .receive(on: DispatchQueue.main)
      .sink { [weak self] hasPermission in
        self?.hasPermission = hasPermission
      }
      .store(in: &cancellables)

    // Sync permission state
    Task {
      await updatePermissionState()
    }
  }

  private var includesOwnAppInScreenshots: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.screenshotIncludeOwnApp) as? Bool
      ?? PreferencesKeys.defaultScreenshotIncludeOwnApp
  }

  private var showsCursorInScreenshots: Bool {
    UserDefaults.standard.object(forKey: PreferencesKeys.screenshotShowCursor) as? Bool ?? false
  }

  /// Always read format from UserDefaults to stay in sync with Settings @AppStorage
  private var resolvedFormat: ImageFormat {
    if let raw = UserDefaults.standard.string(forKey: PreferencesKeys.screenshotFormat),
       let option = ImageFormatOption(rawValue: raw) {
      return option.format
    }
    return .png
  }

  private let frozenSnapshotWindowHideSettleDelay: TimeInterval = 1.0 / 60.0

  @MainActor
  final class HiddenWindowSession {
    static var onPostSyntheticMouseEvent: ((NSEvent) -> Void)?

    private struct Entry {
      weak var window: NSWindow?
      let windowNumber: Int
      let orderIndex: Int
    }

    private var entries: [Entry]
    private let keyWindowNumber: Int?
    private let mainWindowNumber: Int?
    private let shouldReactivateApp: Bool
    private var didRestore = false

    init(
      windows: [NSWindow] = [],
      keyWindow: NSWindow? = nil,
      mainWindow: NSWindow? = nil,
      shouldReactivateApp: Bool = false
    ) {
      entries = windows.enumerated().map { index, window in
        Entry(window: window, windowNumber: window.windowNumber, orderIndex: index)
      }
      keyWindowNumber = keyWindow?.windowNumber
      mainWindowNumber = mainWindow?.windowNumber
      self.shouldReactivateApp = shouldReactivateApp
    }

    /// This session owns no actor-bound teardown work. Avoid asking the
    /// back-deployed Swift runtime to schedule deinitialization on MainActor.
    nonisolated deinit {}

    var didHideWindows: Bool {
      !entries.isEmpty
    }

    func restore() {
      guard !didRestore else { return }
      didRestore = true

      let liveEntries = entries.compactMap { entry -> (window: NSWindow, windowNumber: Int, orderIndex: Int)? in
        guard let window = entry.window else { return nil }
        return (window, entry.windowNumber, entry.orderIndex)
      }
      guard !liveEntries.isEmpty else { return }

      for entry in liveEntries.sorted(by: { $0.orderIndex < $1.orderIndex }) where !entry.window.isVisible {
        entry.window.orderFront(nil)
      }

      let keyCandidate = liveEntries.first {
        $0.windowNumber == keyWindowNumber && $0.window.canBecomeKey
      } ?? liveEntries.first {
        $0.windowNumber == mainWindowNumber && $0.window.canBecomeKey
      } ?? liveEntries.last(where: { $0.window.canBecomeKey })

      if let keyCandidate {
        keyCandidate.window.makeKeyAndOrderFront(nil)
      }

      if shouldReactivateApp {
        NSApp.activate(ignoringOtherApps: true)
      }

      // Force cursor tracking re-evaluation on restored windows.
      // orderFront does not trigger mouseEntered, so if the mouse is
      // already over a restored window, tracking areas won't fire and
      // the cursor may appear stuck or invisible.
      // Post a synthetic mouse-moved event to force macOS to
      // re-evaluate cursor rects immediately.
      DispatchQueue.main.async {
        let mouseLocation = NSEvent.mouseLocation
        if let syntheticEvent = NSEvent.mouseEvent(
          with: .mouseMoved,
          location: mouseLocation,
          modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: 0,
          context: nil,
          eventNumber: 0,
          clickCount: 0,
          pressure: 0
        ) {
          NSApp.postEvent(syntheticEvent, atStart: false)
          Self.onPostSyntheticMouseEvent?(syntheticEvent)
        }
      }

      DiagnosticLogger.shared.log(.debug, .ui, "Hidden ShotPaste windows restored", context: [
        "count": "\(liveEntries.count)",
      ])
    }
  }

  private func hideVisibleNormalWindowsIfNeeded(_ shouldHide: Bool) -> HiddenWindowSession {
    guard shouldHide else { return HiddenWindowSession() }

    let visibleNormalWindows = NSApp.windows.filter {
      $0.isVisible &&
        $0.level == .normal &&
        $0.className != "NSStatusBarWindow"
    }
    let session = HiddenWindowSession(
      windows: visibleNormalWindows,
      keyWindow: NSApp.keyWindow,
      mainWindow: NSApp.mainWindow,
      shouldReactivateApp: NSApp.isActive
    )
    guard !visibleNormalWindows.isEmpty else { return session }

    visibleNormalWindows.forEach { $0.orderOut(nil) }
    DiagnosticLogger.shared.log(.debug, .ui, "ShotPaste windows hidden for capture", context: [
      "count": "\(visibleNormalWindows.count)",
    ])
    return session
  }

  // MARK: - KeyboardShortcutDelegate

  func shortcutTriggered(_ action: ShortcutAction) {
    switch action {
    case .startOneShot:
      startOneShot()
    case .startTranslation:
      startOneShot(initialTab: .translation)
    case .startAgentIntent:
      AgentModeController.shared.startIntentCapture()
    case .startAudioRecording:
      startAudioRecording()
    case .pauseResumeRecording:
      togglePauseFromShortcut()
    case .togglePenRecording:
      togglePenRecordingFromShortcut()
    case .restartRecording:
      restartRecordingFromShortcut()
    case .deleteRecording:
      deleteRecordingFromShortcut()
    case .openHistory:
      HistoryWindowController.shared.showWindow()
    }
  }

  func updatePermissionState() async {
    await captureManager.checkPermission()
    hasPermission = captureManager.hasPermission
  }

  /// Audio uses the same screen-recording permission boundary but has its own
  /// preparation/lifecycle coordinator and never enters One Shot selection.
  func startAudioRecording() {
    guard hasPermission else {
      requestPermission()
      return
    }
    AudioRecordingCoordinator.shared.showPreparation()
  }

  func requestPermission(showRecoveryIfDenied: Bool = true) {
    Task {
      let granted = await captureManager.requestPermission()
      await updatePermissionState()
      if showRecoveryIfDenied, !granted || !hasPermission {
        if !NSApp.isActive {
          for await _ in NotificationCenter.default.notifications(
            named: NSApplication.didBecomeActiveNotification
          ) {
            break
          }
          await updatePermissionState()
        }
        guard !hasPermission else { return }
        presentScreenPermissionRecovery()
      }
    }
  }

  func openSettings() {
    captureManager.openScreenRecordingPreferences()
  }

  private func presentScreenPermissionRecovery() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L10n.Permission.screenRecording
    alert.informativeText = L10n.Permission.screenRecordingFinishInSettings
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.openSettings)
    alert.addButton(withTitle: L10n.Common.openSystemSettings)
    alert.addButton(withTitle: L10n.Common.cancel)

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      AppStatusBarController.shared.openPreferencesWindow(tab: .permissions)
    case .alertSecondButtonReturn:
      captureManager.openScreenRecordingPreferences()
    default:
      break
    }
  }

  @discardableResult
  func startOneShot(initialTab: OneShotTab = .screenshot) -> Bool {
    guard !AudioRecordingCoordinator.shared.isBlockingOtherCapture else {
      DiagnosticLogger.shared.log(
        .debug,
        .capture,
        "One Shot ignored while audio recording is active"
      )
      return false
    }
    guard hasPermission else {
      requestPermission()
      return false
    }

    guard !isAreaSelectionActive else {
      AppToastManager.shared.show(
        message: L10n.OneShot.sessionAlreadyActive,
        style: .warning,
        position: .bottomCenter
      )
      return false
    }

    let primaryDisplayID = ScreenUtility.activeDisplayID()
    let primaryScreen = NSScreen.screens.first(where: { $0.displayID == primaryDisplayID })
      ?? ScreenUtility.activeScreen()

    let context = CaptureContext.fromFrontmostApp()
    let showCursor = showsCursorInScreenshots
    let excludeDesktopIcons = DesktopIconManager.shared.isIconHidingEnabled
    let excludeDesktopWidgets = DesktopIconManager.shared.isWidgetHidingEnabled
    let excludeOwnApplication = !includesOwnAppInScreenshots
    let prefetchedContentTask = captureManager.prefetchShareableContent(
      includeDesktopWindows: excludeDesktopIcons || excludeDesktopWidgets
    )

    var hiddenWindowSession: HiddenWindowSession?
    guard let oneShotState = OneShotCoordinator.shared.beginPreparation(
      switcherDisplayID: primaryDisplayID,
      switcherX: primaryScreen.frame.midX,
      initialTab: initialTab,
      onTeardown: { [weak self] in
        hiddenWindowSession?.restore()
        self?.isAreaSelectionActive = false
      },
      onOCRImage: { [weak self] image in
        self?.processOneShotOCRImage(image)
      },
      resolveScrollingConfiguration: { [weak self] in
        guard let self,
              let exportDirectory = self.fileAccessManager.ensureExportDirectoryForOperation(
                promptMessage: L10n.Recording.chooseSaveLocationMessage
              ) else { return nil }
        self.saveDirectory = exportDirectory
        return OneShotScrollingConfiguration(
          saveDirectory: self.tempCaptureManager.resolveSaveDirectory(
            for: .screenshot,
            exportDirectory: exportDirectory
          ),
          format: self.resolvedFormat,
          prefetchedContentTask: prefetchedContentTask
        )
      }
    ) else { return false }

    isAreaSelectionActive = true
    DiagnosticLogger.shared.log(.info, .capture, "One Shot preparation started", context: [
      "displayID": "\(primaryDisplayID)",
      "excludeOwnApplication": excludeOwnApplication ? "true" : "false",
      "format": resolvedFormat.fileExtension,
    ])

    Task { @MainActor [weak self] in
      guard let self else {
        OneShotCoordinator.shared.failPreparation(.captureFailed(L10n.OneShot.preparationFailed))
        return
      }

      do {
        // SCShareableContent may display macOS's direct-capture confirmation.
        // Keep every app window and capture overlay off screen until that task
        // finishes, otherwise the prompt can be captured into the frozen
        // backdrop while the real, clickable dialog remains underneath.
        if let prefetchedContentTask {
          _ = try await prefetchedContentTask.value
        }

        hiddenWindowSession = hideVisibleNormalWindowsIfNeeded(excludeOwnApplication)
        if hiddenWindowSession?.didHideWindows == true {
          try? await Task.sleep(
            nanoseconds: UInt64(frozenSnapshotWindowHideSettleDelay * 1_000_000_000)
          )
        }

        let prepared = try await prepareInlineAreaAnnotateFrozenSession(
          showCursor: showCursor,
          excludeDesktopIcons: excludeDesktopIcons,
          excludeDesktopWidgets: excludeDesktopWidgets,
          excludeOwnApplication: excludeOwnApplication,
          prefetchedContentTask: prefetchedContentTask
        )
        DiagnosticLogger.shared.log(.debug, .capture, "One Shot frozen snapshot prepared", context: [
          "excludeOwnApplication": excludeOwnApplication ? "true" : "false",
          "mode": prepared.mode,
        ])
        let snapshotDisplayIDs = prepared.session.displayIDs
        let screens = NSScreen.screens.filter { screen in
          guard let displayID = screen.displayID else { return false }
          return snapshotDisplayIDs.contains(displayID)
        }
        guard !screens.isEmpty else {
          prepared.session.invalidate()
          OneShotCoordinator.shared.failPreparation(.noDisplayFound)
          return
        }

        OneShotCoordinator.shared.start(
          state: oneShotState,
          screens: screens,
          primaryDisplayID: snapshotDisplayIDs.contains(primaryDisplayID)
            ? primaryDisplayID
            : screens.compactMap(\.displayID).first ?? primaryDisplayID,
          backdrops: prepared.session.backdrops,
          frozenSession: prepared.session,
          outputFormat: resolvedFormat,
          context: context,
          resolveScreenshotSaveDirectory: { [weak self] in
            guard let self,
                  let exportDirectory = fileAccessManager.ensureExportDirectoryForOperation(
                    promptMessage: L10n.Recording.chooseSaveLocationMessage
                  ) else { return nil }
            saveDirectory = exportDirectory
            return tempCaptureManager.resolveSaveDirectory(
              for: .screenshot,
              exportDirectory: exportDirectory
            )
          }
        )
      } catch let error as CaptureError {
        OneShotCoordinator.shared.failPreparation(error)
      } catch {
        OneShotCoordinator.shared.failPreparation(.captureFailed(error.localizedDescription))
      }
    }
    return true
  }

  private func prepareInlineAreaAnnotateFrozenSession(
    showCursor: Bool,
    excludeDesktopIcons: Bool,
    excludeDesktopWidgets: Bool,
    excludeOwnApplication: Bool,
    prefetchedContentTask: ShareableContentPrefetchTask?
  ) async throws -> (session: FrozenAreaCaptureSession, mode: String) {
    // Hiding an app window does not guarantee that WindowServer has removed its
    // last composited frame. When ShotPaste must be excluded, use
    // ScreenCaptureKit's application filter instead of risking a translucent
    // CoreGraphics ghost in the frozen backdrop.
    let canUseFastPath = FrozenSnapshotCapturePolicy.canUseCoreGraphics(
      showCursor: showCursor,
      excludeDesktopIcons: excludeDesktopIcons,
      excludeDesktopWidgets: excludeDesktopWidgets,
      excludeOwnApplication: excludeOwnApplication
    )
    if canUseFastPath {
      // Resolve NSScreen data on main thread (AppKit requirement), then run
      // CGDisplayCreateImage concurrently off-main for all displays.
      let captureManager = captureManager
      let screens = NSScreen.screens
      let screenInputs: [(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        backingScaleFactor: CGFloat,
        colorSpaceName: CFString?
      )] =
        screens.compactMap { screen in
          guard let displayID = screen.displayID else { return nil }
          return (
            displayID,
            screen.frame,
            screen.backingScaleFactor,
            captureManager.preferredCaptureColorSpaceName(for: screen)
          )
        }
      let snapshots = await withTaskGroup(of: FrozenDisplaySnapshot?.self) { group in
        for input in screenInputs {
          group.addTask {
            captureManager.captureFastDisplaySnapshotOffMain(
              displayID: input.displayID,
              screenFrame: input.screenFrame,
              backingScaleFactor: input.backingScaleFactor,
              colorSpaceName: input.colorSpaceName
            )
          }
        }
        var results: [FrozenDisplaySnapshot] = []
        for await snapshot in group {
          if let snapshot {
            results.append(snapshot)
          }
        }
        return results
      }
      if !snapshots.isEmpty, snapshots.count == NSScreen.screens.count {
        return (FrozenAreaCaptureSession.fromSnapshots(snapshots), "coregraphics-all")
      }
    }

    let shareableContentTask = prefetchedContentTask ?? captureManager.prefetchShareableContent(
      includeDesktopWindows: excludeDesktopIcons || excludeDesktopWidgets
    )
    let session = try await FrozenAreaCaptureSession.prepare(
      displayIDs: nil,
      showCursor: showCursor,
      excludeDesktopIcons: excludeDesktopIcons,
      excludeDesktopWidgets: excludeDesktopWidgets,
      excludeOwnApplication: excludeOwnApplication,
      prefetchedContentTask: shareableContentTask
    )
    return (session, "screencapturekit-all")
  }

  /// Pause/resume entry from global shortcut. No-op when no active recording.
  /// Reuses existing `ScreenRecordingManager.togglePause()` (already used by the menu bar).
  func togglePauseFromShortcut() {
    if AudioRecordingCoordinator.shared.isRecording {
      AudioRecordingCoordinator.shared.pauseOrResume()
      return
    }
    let state = ScreenRecordingManager.shared.state
    guard state.isPauseResumeEligible else {
      DiagnosticLogger.shared.log(.debug, .recording, "Pause shortcut ignored: no active recording", context: [
        "state": "\(state)",
      ])
      return
    }
    DiagnosticLogger.shared.log(.info, .recording, "Pause shortcut: toggle", context: [
      "fromState": "\(state)",
    ])
    ScreenRecordingManager.shared.togglePause()
  }

  /// Toggle pen/annotations overlay from global shortcut.
  func togglePenRecordingFromShortcut() {
    guard RecordingCoordinator.shared.isActive else { return }
    RecordingCoordinator.shared.togglePenFromShortcut()
  }

  /// Restart/Re-record from global shortcut.
  func restartRecordingFromShortcut() {
    if AudioRecordingCoordinator.shared.isRecording {
      AudioRecordingCoordinator.shared.restart()
      return
    }
    guard RecordingCoordinator.shared.isActive else { return }
    RecordingCoordinator.shared.restartFromShortcut()
  }

  /// Cancel/Delete current recording from global shortcut.
  func deleteRecordingFromShortcut() {
    if AudioRecordingCoordinator.shared.isRecording {
      AudioRecordingCoordinator.shared.delete()
      return
    }
    guard RecordingCoordinator.shared.isActive else { return }
    RecordingCoordinator.shared.deleteFromShortcut()
  }

  // MARK: - OCR Capture

  private func processOneShotOCRImage(_ image: CGImage) {
    let operationStartTime = CFAbsoluteTimeGetCurrent()
    AppStatusBarController.shared.setProcessing(true)
    Task { @MainActor [weak self] in
      guard let self else {
        AppStatusBarController.shared.setProcessing(false)
        return
      }
      await processOCRImage(
        image,
        source: "oneShot",
        captureDurationMs: "0.0",
        operationStartTime: operationStartTime
      )
    }
  }

  private func processOCRImage(
    _ image: CGImage,
    source: String,
    captureDurationMs: String,
    operationStartTime: CFAbsoluteTime
  ) async {
    let processingStartTime = CFAbsoluteTimeGetCurrent()
    async let qrResultTask = detectQRCodes(in: image)
    async let recognizedTextTask = recognizeOCRText(in: image)
    let (qrResult, recognizedText) = await (qrResultTask, recognizedTextTask)
    let processingDurationMs = Self.elapsedMilliseconds(since: processingStartTime)
    let totalDurationMs = Self.elapsedMilliseconds(since: operationStartTime)

    let clipboardText = OCRQRPayloadComposer.compose(
      recognizedText: recognizedText,
      qrDetections: qrResult.detections,
      qrSectionTitle: L10n.OCR.qrCodesLabel
    )
    let performanceContext = [
      "captureMs": captureDurationMs,
      "processingMs": processingDurationMs,
      "source": source,
      "totalMs": totalDurationMs,
    ]

    AppStatusBarController.shared.setProcessing(false)

    guard let clipboardText else {
      if qrResult.unsupportedPayloadCount > 0 {
        var context = performanceContext
        context["unsupportedQRCount"] = "\(qrResult.unsupportedPayloadCount)"
        DiagnosticLogger.shared.log(
          .warning,
          .ocr,
          "OCR QR capture found unsupported QR payloads",
          context: context
        )
        AppToastManager.shared.show(
          message: L10n.OCR.qrTextOnlyUnsupported,
          style: .warning,
          position: .bottomCenter
        )
      } else {
        DiagnosticLogger.shared.log(
          .warning,
          .ocr,
          "OCR capture failed: no text or QR payload found",
          context: performanceContext
        )
        AppToastManager.shared.show(
          message: L10n.OCR.noTextFound,
          style: .warning,
          position: .bottomCenter
        )
      }
      QuickAccessSound.failed.play()
      return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(clipboardText, forType: .string)

    var successContext = performanceContext
    successContext["chars"] = "\(clipboardText.count)"
    successContext["qrCount"] = "\(qrResult.detections.count)"
    successContext["unsupportedQRCount"] = "\(qrResult.unsupportedPayloadCount)"
    DiagnosticLogger.shared.log(.info, .ocr, "OCR text copied to clipboard", context: successContext)
    let showOCRNotification = UserDefaults.standard
      .object(forKey: PreferencesKeys.ocrSuccessNotificationEnabled) as? Bool ?? false
    if showOCRNotification {
      AppToastManager.shared.show(
        message: L10n.Common.copiedToClipboard,
        style: .success,
        position: .bottomCenter
      )
      QuickAccessSound.complete.play()
    }

    let linkDetectionEnabled = UserDefaults.standard
      .object(forKey: PreferencesKeys.ocrLinkDetectionEnabled) as? Bool ?? true
    if linkDetectionEnabled {
      let detectedLinks = OCRLinkDetector.detectWebLinks(in: clipboardText)
      if !detectedLinks.isEmpty {
        OCRLinkPromptManager.shared.show(links: detectedLinks)
      }
    }
  }

  private func detectQRCodes(in image: CGImage) async -> QRCodeDetectionResult {
    let startTime = CFAbsoluteTimeGetCurrent()

    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try await QRCodeService.shared.detect(in: image)
      }.value

      if result.hasCopyablePayloads || result.unsupportedPayloadCount > 0 {
        DiagnosticLogger.shared.log(
          .info,
          .ocr,
          "OCR QR detection completed",
          context: [
            "qrCount": "\(result.detections.count)",
            "unsupportedQRCount": "\(result.unsupportedPayloadCount)",
            "payloadTypes": result.detections
              .map(\.classification.diagnosticName)
              .joined(separator: ","),
            "durationMs": Self.elapsedMilliseconds(since: startTime),
          ]
        )
      } else {
        DiagnosticLogger.shared.log(
          .debug,
          .ocr,
          "OCR QR detection completed without QR payloads",
          context: ["durationMs": Self.elapsedMilliseconds(since: startTime)]
        )
      }
      return result
    } catch {
      DiagnosticLogger.shared.logError(
        .ocr,
        error,
        "OCR QR detection failed",
        context: ["durationMs": Self.elapsedMilliseconds(since: startTime)]
      )
      return .empty
    }
  }

  private func recognizeOCRText(in image: CGImage) async -> String? {
    let startTime = CFAbsoluteTimeGetCurrent()

    do {
      let text = try await OCRService.shared.recognizeText(
        from: image,
        preferredLanguageIdentifier: preferredOCRLanguageIdentifier,
        contentType: .interfaceText
      )
      DiagnosticLogger.shared.log(
        .debug,
        .ocr,
        "OCR text recognition timing",
        context: ["durationMs": Self.elapsedMilliseconds(since: startTime)]
      )
      return text
    } catch OCRError.noTextFound {
      DiagnosticLogger.shared.log(
        .debug,
        .ocr,
        "OCR text recognition found no text",
        context: ["durationMs": Self.elapsedMilliseconds(since: startTime)]
      )
      return nil
    } catch {
      DiagnosticLogger.shared.logError(
        .ocr,
        error,
        "OCR text recognition failed",
        context: ["durationMs": Self.elapsedMilliseconds(since: startTime)]
      )
      return nil
    }
  }

  private var preferredOCRLanguageIdentifier: String {
    let stored = UserDefaults.standard.string(forKey: PreferencesKeys.ocrRecognitionLanguage) ?? "auto"
    return stored == "auto" ? AppLanguageManager.shared.activeOCRLanguageIdentifier : stored
  }

  private static func elapsedMilliseconds(since startTime: CFAbsoluteTime) -> String {
    String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
  }
}
