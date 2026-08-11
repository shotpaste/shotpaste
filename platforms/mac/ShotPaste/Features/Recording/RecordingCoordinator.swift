//
//  RecordingCoordinator.swift
//  ShotPaste
//
//  Coordinates the recording flow between UI components and recording manager
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingCoordinator: ObservableObject {
  static let shared = RecordingCoordinator()

  @Published private(set) var isActive = false

  private var toolbarWindow: RecordingToolbarWindow?
  private var regionOverlayWindows: [RecordingRegionOverlayWindow] = []
  private var selectedRect: CGRect?
  private let recorder = ScreenRecordingManager.shared
  private var isStartingRecording = false
  private var localEscapeMonitor: Any?
  private var globalEscapeMonitor: Any?
  private var onSessionEnded: (@MainActor () -> Void)?

  // Annotation overlay
  private var annotationToolbarWindow: RecordingAnnotationToolbarWindow?
  private var annotationOverlayWindow: RecordingAnnotationOverlayWindow?

  // Click highlight overlay
  private var clickHighlightWindow: MouseClickHighlightWindow?
  private var clickHighlightService: MouseClickHighlightService?

  // Keystroke overlay
  private var keystrokeOverlayWindow: KeystrokeOverlayWindow?
  private var keystrokeMonitorService: KeystrokeMonitorService?

  private struct ToolbarConfiguration {
    let format: VideoFormat
    let quality: VideoQuality
    let captureAudio: Bool
    let captureMicrophone: Bool
    let microphoneDeviceID: String
    let outputMode: RecordingOutputMode
    let showCursor: Bool
    let highlightClicks: Bool
    let showKeystrokes: Bool
    let dimNonSelectedArea: Bool
  }

  private init() {
    // Live-apply the dim preference while recording so toggling it in Settings (or the
    // toolbar options) takes effect immediately, mirroring the hover-bar live toggle.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(dimPreferenceDidChange),
      name: UserDefaults.didChangeNotification,
      object: nil
    )
  }

  private let tempCaptureManager = TempCaptureManager.shared

  private var includeOwnAppInRecordings: Bool {
    UserDefaults.standard.bool(forKey: PreferencesKeys.recordingIncludeOwnApp)
  }

  private func recordingCaptureExclusionConfiguration()
    -> (excludeOwnApplication: Bool, excludedWindowIDs: [CGWindowID]) {
    let excludeOwnApplication = !includeOwnAppInRecordings
    if excludeOwnApplication {
      return (true, [])
    }

    var windowIDs = regionOverlayWindows.map { CGWindowID($0.windowNumber) }
    if let toolbarWindow {
      windowIDs.append(CGWindowID(toolbarWindow.windowNumber))
    }
    return (false, windowIDs)
  }

  /// Whether the floating recording controls bar should be shown during recording.
  /// Shared source of truth with `AppStatusBarController` via `RecordingToolbarPreferences`.
  private var isHoverBarVisiblePreference: Bool {
    RecordingToolbarPreferences.hoverBarVisible()
  }

  // MARK: - Public API

  func stopFromStatusItem() {
    DiagnosticLogger.shared.log(.debug, .recording, "Stop requested from status item", context: [
      "recorderState": "\(recorder.state)",
    ])
    switch recorder.state {
    case .recording, .paused:
      stopRecording()
    case .preparing:
      cancel()
    case .idle, .stopping:
      break
    }
  }

  /// Toggle pen/annotations overlay from global shortcut.
  func togglePenFromShortcut() {
    guard isActive, let toolbarWindow else { return }
    toolbarWindow.annotationState.isAnnotationEnabled.toggle()
  }

  /// Restart/Re-record from global shortcut.
  func restartFromShortcut() {
    guard isActive else { return }
    restartRecording()
  }

  /// Cancel/Delete current recording from global shortcut.
  func deleteFromShortcut() {
    guard isActive else { return }
    deleteRecording()
  }

  /// Starts the recording pipeline from One Shot's already-selected rectangle
  /// and settings. One Shot is the only idle recording entry point.
  func startOneShotRecording(
    for rect: CGRect,
    options: OneShotRecordingOptions,
    onSessionEnded: (@MainActor () -> Void)? = nil
  ) {
    guard !isActive else {
      DiagnosticLogger.shared.log(.debug, .recording, "One Shot recording ignored: coordinator active")
      onSessionEnded?()
      return
    }

    isActive = true
    self.onSessionEnded = onSessionEnded
    let configuration = ToolbarConfiguration(
      format: .mp4,
      quality: RecordingToolbarPreferences.selectedQuality(),
      captureAudio: options.capturesSystemAudio,
      captureMicrophone: options.capturesMicrophone,
      microphoneDeviceID: RecordingToolbarPreferences.microphoneDeviceID(),
      outputMode: options.outputMode,
      showCursor: options.showsCursor,
      highlightClicks: RecordingToolbarPreferences.highlightClicks(),
      showKeystrokes: RecordingToolbarPreferences.showKeystrokes(),
      dimNonSelectedArea: RecordingToolbarPreferences.dimNonSelectedArea()
    )
    prepareRecordingUI(for: rect, configuration: configuration)
    startRecording()
  }

  private func setupEscapeMonitors() {
    removeEscapeMonitors()

    localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if self?.handlePreparationKeyEvent(event) == true {
        return nil
      }
      return event
    }

    globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return }
      DispatchQueue.main.async {
        _ = self?.handlePreparationKeyEvent(event)
      }
    }
  }

  @discardableResult
  private func handlePreparationKeyEvent(_ event: NSEvent) -> Bool {
    guard event.keyCode == 53 else { return false }
    cancel()
    return true
  }

  private func removeEscapeMonitors() {
    if let monitor = localEscapeMonitor {
      NSEvent.removeMonitor(monitor)
      localEscapeMonitor = nil
    }
    if let monitor = globalEscapeMonitor {
      NSEvent.removeMonitor(monitor)
      globalEscapeMonitor = nil
    }
  }

  func cancel() {
    DiagnosticLogger.shared.log(.info, .recording, "Recording coordinator cancel requested", context: [
      "isActive": "\(isActive)",
      "recorderState": "\(recorder.state)",
    ])
    Task {
      await recorder.cancelRecording()
      cleanup()
    }
  }

  private func prepareRecordingUI(for rect: CGRect, configuration: ToolbarConfiguration) {
    DiagnosticLogger.shared.log(.info, .recording, "One Shot recording UI prepared", context: [
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
      "origin": "\(Int(rect.origin.x)),\(Int(rect.origin.y))",
    ])

    selectedRect = rect

    let toolbar = RecordingToolbarWindow(anchorRect: rect)
    configureToolbarCallbacks(toolbar)
    applyToolbarConfiguration(configuration, to: toolbar)
    toolbarWindow = toolbar

    showRegionOverlay(for: rect)
    setupEscapeMonitors()
  }

  private func configureToolbarCallbacks(_ toolbar: RecordingToolbarWindow) {
    toolbar.onDelete = { [weak self] in
      self?.deleteRecording()
    }
    toolbar.onRestart = { [weak self] in
      self?.restartRecording()
    }
    toolbar.onStop = { [weak self] in
      self?.stopRecording()
    }
  }

  private func applyToolbarConfiguration(
    _ configuration: ToolbarConfiguration,
    to toolbar: RecordingToolbarWindow
  ) {
    toolbar.selectedFormat = configuration.format
    toolbar.selectedQuality = configuration.quality
    toolbar.captureAudio = configuration.captureAudio
    toolbar.captureMicrophone = configuration.captureMicrophone
    toolbar.microphoneDeviceID = configuration.microphoneDeviceID
    toolbar.outputMode = configuration.outputMode
    toolbar.state.showCursor = configuration.showCursor
    toolbar.state.highlightClicks = configuration.highlightClicks
    toolbar.state.showKeystrokes = configuration.showKeystrokes
    toolbar.state.dimNonSelectedArea = configuration.dimNonSelectedArea
  }

  private func closeRecordingUI() {
    for overlay in regionOverlayWindows {
      overlay.close()
    }
    regionOverlayWindows.removeAll()

    toolbarWindow?.onDelete = nil
    toolbarWindow?.onRestart = nil
    toolbarWindow?.onStop = nil
    toolbarWindow?.onAnnotateButtonOffsetChanged = nil
    toolbarWindow?.close()
    toolbarWindow = nil
  }

  /// Delete current recording and close
  private func deleteRecording() {
    DiagnosticLogger.shared.log(.info, .recording, "Recording delete requested", context: [
      "recorderState": "\(recorder.state)",
    ])
    Task {
      await recorder.cancelRecording()
      SoundManager.play("Funk")
      cleanup()
    }
  }

  /// Restart recording from scratch (cancel current and start new)
  private func restartRecording() {
    guard let rect = selectedRect, let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording restart ignored: missing selection or toolbar")
      return
    }

    let savedFormat = window.selectedFormat
    let savedQuality = window.selectedQuality
    let savedCaptureAudio = window.captureAudio
    let savedCaptureMicrophone = window.captureMicrophone
    let savedMicrophoneDeviceID = window.microphoneDeviceID
    let savedShowCursor = window.state.showCursor
    DiagnosticLogger.shared.log(.info, .recording, "Recording restart requested", context: [
      "format": savedFormat.rawValue,
      "quality": savedQuality.rawValue,
      "systemAudio": "\(savedCaptureAudio)",
      "microphone": "\(savedCaptureMicrophone)",
      "microphoneDevice": savedMicrophoneDeviceID,
      "showCursor": "\(savedShowCursor)",
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    Task {
      // Cancel current recording
      await recorder.cancelRecording()

      // Small delay to ensure cleanup completes
      try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s

      // Re-prepare and start recording with same settings
      do {
        var fps = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingFPS)
        if fps == 0 {
          fps = 30
        }

        guard let saveDirectory = self.resolveSaveDirectoryForOperation() else {
          DiagnosticLogger.shared.log(.warning, .recording, "Recording restart blocked: no save directory access")
          self.showSaveLocationPermissionAlert()
          return
        }

        let exclusionConfig = self.recordingCaptureExclusionConfiguration()

        let savePlan = try self.tempCaptureManager.makeRecordingSavePlan(
          exportDirectory: saveDirectory
        )

        try await recorder.prepareRecording(
          rect: rect,
          format: savedFormat,
          quality: savedQuality,
          fps: fps,
          captureSystemAudio: savedCaptureAudio,
          captureMicrophone: savedCaptureMicrophone,
          microphoneDeviceID: savedMicrophoneDeviceID,
          showCursor: savedShowCursor,
          saveDirectory: savePlan.finalDirectory,
          processingDirectory: savePlan.processingDirectory,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: exclusionConfig.excludeOwnApplication,
          excludedWindowIDs: exclusionConfig.excludedWindowIDs,
          context: CaptureContext.fromFrontmostApp()
        )

        try await recorder.startRecording()
        removeEscapeMonitors()
        DiagnosticLogger.shared.log(.info, .recording, "Recording restart completed")

        // Play sound to indicate restart
        SoundManager.play("Purr")

      } catch let error as RecordingError {
        DiagnosticLogger.shared.logError(.recording, error, "Recording restart failed")
        if !showErrorAlert(error) {
          cancel()
        }
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Recording restart failed (generic)")
        if !showErrorAlert(.setupFailed(error.localizedDescription)) {
          cancel()
        }
      }
    }
  }

  // MARK: - Private

  private func showRegionOverlay(for rect: CGRect) {
    for screen in NSScreen.screens {
      let overlay = RecordingRegionOverlayWindow(screen: screen, highlightRect: rect)
      overlay.setInteractionEnabled(false)
      overlay.orderFrontRegardless()
      regionOverlayWindows.append(overlay)
    }
  }

  /// Re-applies the dim preference to the live region overlays when it changes.
  /// Only acts while actively recording.
  @objc private func dimPreferenceDidChange() {
    guard recorder.state.isPauseResumeEligible, !regionOverlayWindows.isEmpty else { return }
    let dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
    for overlay in regionOverlayWindows {
      overlay.setDimEnabled(dimNonSelectedArea)
    }
  }

  private func startRecording() {
    guard let rect = selectedRect, let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Start recording ignored: missing selection or toolbar")
      return
    }
    guard beginRecordingStartAttempt(source: "toolbar") else { return }

    let format = window.selectedFormat
    DiagnosticLogger.shared.log(.info, .recording, "Start recording", context: [
      "format": format.rawValue,
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    // Get FPS from preferences (default 30)
    var fps = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingFPS)
    if fps == 0 {
      fps = 30
    }

    // Get quality from preferences (default high)
    let qualityString = UserDefaults.standard.string(forKey: PreferencesKeys.recordingQuality) ?? "high"
    let quality = VideoQuality(rawValue: qualityString) ?? .high

    let captureSystemAudio = window.captureAudio
    let showCursor = window.state.showCursor

    // Get microphone setting from toolbar
    let captureMicrophone = window.captureMicrophone
    let microphoneDeviceID = window.microphoneDeviceID
    DiagnosticLogger.shared.log(.debug, .recording, "Recording options resolved", context: [
      "quality": quality.rawValue,
      "fps": "\(fps)",
      "systemAudio": "\(captureSystemAudio)",
      "microphone": "\(captureMicrophone)",
      "microphoneDevice": microphoneDeviceID,
      "showCursor": "\(showCursor)",
    ])

    guard let saveDirectory = resolveSaveDirectoryForOperation() else {
      DiagnosticLogger.shared.log(.warning, .recording, "Recording start blocked: no save directory access")
      finishRecordingStartAttempt()
      showSaveLocationPermissionAlert()
      cleanup()
      return
    }

    // Save selected format to preferences
    UserDefaults.standard.set(format.rawValue, forKey: PreferencesKeys.recordingFormat)

    Task {
      do {
        let exclusionConfig = self.recordingCaptureExclusionConfiguration()
        DiagnosticLogger.shared.log(.debug, .recording, "Recording capture exclusion resolved", context: [
          "excludeOwnApp": "\(exclusionConfig.excludeOwnApplication)",
          "excludedWindows": "\(exclusionConfig.excludedWindowIDs.count)",
        ])

        let savePlan = try self.tempCaptureManager.makeRecordingSavePlan(
          exportDirectory: saveDirectory
        )

        try await recorder.prepareRecording(
          rect: rect,
          format: format,
          quality: quality,
          fps: fps,
          captureSystemAudio: captureSystemAudio,
          captureMicrophone: captureMicrophone,
          microphoneDeviceID: microphoneDeviceID,
          showCursor: showCursor,
          saveDirectory: savePlan.finalDirectory,
          processingDirectory: savePlan.processingDirectory,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: exclusionConfig.excludeOwnApplication,
          excludedWindowIDs: exclusionConfig.excludedWindowIDs,
          context: CaptureContext.fromFrontmostApp()
        )

        try await recorder.startRecording()
        removeEscapeMonitors()

        // Hide border on overlay (would appear in video), disable interaction, and
        // apply the dim preference — off keeps non-selected windows fully visible.
        let dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
        for overlay in regionOverlayWindows {
          overlay.hideBorder()
          overlay.setInteractionEnabled(false)
          overlay.setDimEnabled(dimNonSelectedArea)
        }

        // Setup annotation overlay (must be after recording starts so window exists)
        setupAnnotationOverlay(for: rect)

        // Setup click highlight overlay (must be after recording starts)
        setupClickHighlightOverlay(for: rect)

        // Setup keystroke overlay (must be after recording starts)
        setupKeystrokeOverlay(for: rect)

        // Switch to status bar
        window.showRecordingStatusBar(recorder: recorder, visible: isHoverBarVisiblePreference)
        finishRecordingStartAttempt()

      } catch let error as RecordingError {
        DiagnosticLogger.shared.logError(.recording, error, "Recording setup failed")
        finishRecordingStartAttempt()
        if case .alreadyActive = error {
          return
        }
        if !showErrorAlert(error) {
          cancel()
        }
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Recording setup failed (generic)")
        finishRecordingStartAttempt()
        if !showErrorAlert(.setupFailed(error.localizedDescription)) {
          cancel()
        }
      }
    }
  }

  @discardableResult
  private func showErrorAlert(_ error: RecordingError) -> Bool {
    DiagnosticLogger.shared.log(.error, .recording, "Error alert shown", context: ["error": error.localizedDescription])
    let alert = NSAlert()
    alert.messageText = L10n.Recording.failedTitle
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning

    // Special handling for microphone permission denied
    if case .microphonePermissionDenied = error {
      alert.messageText = L10n.Microphone.accessRequiredTitle
      alert.informativeText = L10n.Microphone.recordingMessage
      alert.addButton(withTitle: L10n.Common.openSystemSettings)
      alert.addButton(withTitle: L10n.Microphone.continueWithoutMic)
      alert.addButton(withTitle: L10n.Common.cancel)

      let response = alert.runModal()
      switch response {
      case .alertFirstButtonReturn:
        // Open System Settings > Privacy & Security > Microphone
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
          NSWorkspace.shared.open(url)
        }
        return false
      case .alertSecondButtonReturn:
        // Continue recording without microphone
        startRecordingWithoutMicrophone()
        return true
      default:
        return false
      }
    } else {
      alert.addButton(withTitle: L10n.Common.ok)
      alert.runModal()
      return false
    }
  }

  private func startRecordingWithoutMicrophone() {
    guard let rect = selectedRect, let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Microphone retry ignored: missing selection or toolbar")
      return
    }
    guard beginRecordingStartAttempt(source: "microphone-retry") else { return }

    // Disable microphone and retry
    window.captureMicrophone = false
    DiagnosticLogger.shared.log(.info, .recording, "Retrying recording without microphone")

    let format = window.selectedFormat
    var fps = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingFPS)
    if fps == 0 {
      fps = 30
    }
    let qualityString = UserDefaults.standard.string(forKey: PreferencesKeys.recordingQuality) ?? "high"
    let quality = VideoQuality(rawValue: qualityString) ?? .high
    let captureSystemAudio = window.captureAudio
    let showCursor = window.state.showCursor

    guard let saveDirectory = resolveSaveDirectoryForOperation() else {
      DiagnosticLogger.shared.log(.warning, .recording, "Microphone retry blocked: no save directory access")
      finishRecordingStartAttempt()
      showSaveLocationPermissionAlert()
      return
    }

    Task {
      do {
        let exclusionConfig = self.recordingCaptureExclusionConfiguration()

        let savePlan = try self.tempCaptureManager.makeRecordingSavePlan(
          exportDirectory: saveDirectory
        )

        try await recorder.prepareRecording(
          rect: rect,
          format: format,
          quality: quality,
          fps: fps,
          captureSystemAudio: captureSystemAudio,
          captureMicrophone: false,
          showCursor: showCursor,
          saveDirectory: savePlan.finalDirectory,
          processingDirectory: savePlan.processingDirectory,
          excludeDesktopIcons: DesktopIconManager.shared.isIconHidingEnabled,
          excludeDesktopWidgets: DesktopIconManager.shared.isWidgetHidingEnabled,
          excludeOwnApplication: exclusionConfig.excludeOwnApplication,
          excludedWindowIDs: exclusionConfig.excludedWindowIDs,
          context: CaptureContext.fromFrontmostApp()
        )
        try await recorder.startRecording()
        removeEscapeMonitors()

        let dimNonSelectedArea = RecordingToolbarPreferences.dimNonSelectedArea()
        for overlay in regionOverlayWindows {
          overlay.hideBorder()
          overlay.setInteractionEnabled(false)
          overlay.setDimEnabled(dimNonSelectedArea)
        }
        window.showRecordingStatusBar(recorder: recorder, visible: isHoverBarVisiblePreference)
        finishRecordingStartAttempt()
        DiagnosticLogger.shared.log(.info, .recording, "Microphone retry recording started")
      } catch let error as RecordingError {
        DiagnosticLogger.shared.logError(.recording, error, "Microphone retry recording failed")
        finishRecordingStartAttempt()
        if case .alreadyActive = error {
          return
        }
        if !showErrorAlert(error) {
          cancel()
        }
      } catch {
        DiagnosticLogger.shared.logError(.recording, error, "Microphone retry recording failed (generic)")
        finishRecordingStartAttempt()
        if !showErrorAlert(.setupFailed(error.localizedDescription)) {
          cancel()
        }
      }
    }
  }

  private func stopRecording() {
    // Capture output mode before cleanup closes the toolbar
    let outputMode = toolbarWindow?.state.outputMode ?? .video

    Task {
      let url = await recorder.stopRecording()
      DiagnosticLogger.shared.log(.info, .recording, "Recording stopped", context: [
        "hasOutput": "\(url != nil)",
        "outputMode": "\(outputMode)",
      ])
      if url == nil {
        DiagnosticLogger.shared.log(.warning, .recording, "Recording stop completed without output URL")
      }

      // Dismiss recording UI immediately (status bar, area overlay, etc.)
      cleanup()

      if let url {
        // Play sound
        SoundManager.play("Glass")

        if outputMode == .gif {
          // GIF mode: add to QuickAccess immediately with processing state
          await handleGIFConversion(videoURL: url)
        } else {
          // Video mode: normal post-capture flow
          await PostCaptureActionHandler.shared.handleVideoCapture(url: url)
        }
      }
    }
  }

  /// Handle GIF conversion: add to QuickAccess with progress, convert, and update
  private func handleGIFConversion(videoURL: URL) async {
    DiagnosticLogger.shared.log(
      .info,
      .recording,
      "GIF conversion started",
      context: ["file": videoURL.lastPathComponent]
    )
    let quickAccess = QuickAccessManager.shared
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(videoURL)
    let outputDirectoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(
      videoURL.deletingLastPathComponent()
    )
    defer {
      sourceAccess.stop()
      outputDirectoryAccess.stop()
    }

    // Add video to QuickAccess immediately with processing state
    await quickAccess.addVideo(url: videoURL)

    // Find the item we just added (should be first)
    guard let item = quickAccess.items.first else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion aborted: Quick Access item missing", context: [
        "file": videoURL.lastPathComponent,
      ])
      return
    }
    let itemId = item.id

    // Set initial processing state
    quickAccess.updateProcessingState(id: itemId, state: .processing(progress: 0))

    // Run GIF conversion
    do {
      let gifURL = try await GIFConverter.convert(
        videoURL: videoURL,
        options: GIFConverter.Options(
          fps: resolvedGIFFPS,
          maxWidth: GIFConverter.Options.default.maxWidth,
          loopCount: GIFConverter.Options.default.loopCount
        ),
        onProgress: { progress in
          quickAccess.updateProcessingState(id: itemId, state: .processing(progress: progress))
        }
      )

      // Generate thumbnail from GIF
      let thumbnail = SandboxFileAccessManager.shared.withScopedAccess(to: gifURL) {
        NSImage(contentsOf: gifURL)
      }

      // Update the QuickAccess item with GIF URL
      quickAccess.updateItemURL(id: itemId, newURL: gifURL, newThumbnail: thumbnail)
      quickAccess.updateProcessingState(id: itemId, state: .idle)

      // Run remaining post-capture actions (clipboard copy, etc.) on the final GIF
      // skipQuickAccess: item is already in QuickAccess from addVideo() above
      await PostCaptureActionHandler.shared.handleVideoCapture(url: gifURL, skipQuickAccess: true)

      // Delete the original video file
      SandboxFileAccessManager.shared.withScopedAccess(to: videoURL.deletingLastPathComponent()) {
        do {
          try FileManager.default.removeItem(at: videoURL)
          DiagnosticLogger.shared.log(.debug, .recording, "GIF source video deleted", context: [
            "file": videoURL.lastPathComponent,
          ])
        } catch {
          DiagnosticLogger.shared.logError(.recording, error, "Failed to delete GIF source video", context: [
            "file": videoURL.lastPathComponent,
          ])
        }
        try? RecordingMetadataStore.delete(for: videoURL)
      }

    } catch {
      DiagnosticLogger.shared.logError(.recording, error, "GIF conversion failed")
      // On failure, keep the video as-is and clear processing state
      quickAccess.updateProcessingState(id: itemId, state: .failed)

      // Auto-clear failure state after 2 seconds
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        quickAccess.updateProcessingState(id: itemId, state: .idle)
      }
    }
  }

  private var resolvedGIFFPS: Int {
    let stored = UserDefaults.standard.integer(forKey: PreferencesKeys.recordingGIFFPS)
    return [10, 15, 20, 30].contains(stored) ? stored : 15
  }

  private func cleanup() {
    DiagnosticLogger.shared.log(.debug, .recording, "Recording cleanup", context: [
      "regionOverlays": "\(regionOverlayWindows.count)",
      "hasToolbar": "\(toolbarWindow != nil)",
      "hasAnnotationOverlay": "\(annotationOverlayWindow != nil)",
      "hasClickHighlight": "\(clickHighlightWindow != nil)",
      "hasKeystrokeOverlay": "\(keystrokeOverlayWindow != nil)",
    ])
    finishRecordingStartAttempt()
    // Remove escape monitors
    removeEscapeMonitors()

    // Close click highlight overlay
    cleanupClickHighlightOverlay()

    // Close keystroke overlay
    cleanupKeystrokeOverlay()

    // Close annotation windows
    cleanupAnnotationOverlay()

    // Close region overlay windows
    closeRecordingUI()
    selectedRect = nil
    isActive = false
    let sessionEndHandler = onSessionEnded
    onSessionEnded = nil
    sessionEndHandler?()
  }

  private func beginRecordingStartAttempt(source: String) -> Bool {
    guard !isStartingRecording, recorder.state == .idle else {
      DiagnosticLogger.shared.log(.debug, .recording, "Recording start blocked: recorder busy", context: [
        "source": source,
        "state": "\(recorder.state)",
      ])
      return false
    }

    isStartingRecording = true
    toolbarWindow?.state.isPreparingToRecord = true
    return true
  }

  private func finishRecordingStartAttempt() {
    isStartingRecording = false
    toolbarWindow?.state.isPreparingToRecord = false
  }

  private func resolveSaveDirectoryForOperation() -> URL? {
    SandboxFileAccessManager.shared.ensureExportDirectoryForOperation(
      promptMessage: L10n.Recording.chooseSaveLocationMessage
    )
  }

  private func showSaveLocationPermissionAlert() {
    let alert = NSAlert()
    alert.messageText = L10n.Recording.saveLocationAccessRequiredTitle
    alert.informativeText = L10n.Recording.saveLocationAccessRequiredMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.ok)
    alert.runModal()
  }

  // MARK: - Annotation Overlay

  private func setupAnnotationOverlay(for rect: CGRect) {
    guard let window = toolbarWindow else {
      DiagnosticLogger.shared.log(.warning, .recording, "Annotation overlay setup skipped: toolbar missing")
      return
    }
    let annotationState = window.annotationState

    // Create overlay window covering recording rect
    let overlayWindow = RecordingAnnotationOverlayWindow(
      recordingRect: rect,
      annotationState: annotationState
    )
    overlayWindow.orderFrontRegardless()
    annotationOverlayWindow = overlayWindow
    DiagnosticLogger.shared.log(.info, .recording, "Annotation overlay created", context: [
      "windowID": "\(overlayWindow.overlayWindowID)",
      "rect": "\(Int(rect.width))x\(Int(rect.height))",
    ])

    // Create popover-style annotation toolbar anchored to the status bar
    let toolbarWin = RecordingAnnotationToolbarWindow(annotationState: annotationState)
    toolbarWin.anchorWindow = window
    toolbarWin.anchorButtonCenterXOffset = window.annotateButtonCenterXOffset
    annotationToolbarWindow = toolbarWin

    // Update popover anchor offset when SwiftUI layout reports button position
    window.onAnnotateButtonOffsetChanged = { [weak toolbarWin] offset in
      toolbarWin?.anchorButtonCenterXOffset = offset
      if annotationState.isAnnotationEnabled {
        toolbarWin?.positionRelativeToAnchor()
      }
    }

    // Start auto-clear timer
    annotationState.startCleanupTimer()

    // Add overlay window to ScreenCaptureKit's exceptingWindows
    // so annotations appear in the recorded video
    Task {
      await recorder.addExceptedWindow(windowID: overlayWindow.overlayWindowID)
    }
  }

  private func cleanupAnnotationOverlay() {
    if annotationOverlayWindow != nil || annotationToolbarWindow != nil {
      DiagnosticLogger.shared.log(.debug, .recording, "Annotation overlay cleanup")
    }
    toolbarWindow?.annotationState.stopCleanupTimer()
    toolbarWindow?.annotationState.isAnnotationEnabled = false

    annotationToolbarWindow?.close()
    annotationToolbarWindow = nil

    annotationOverlayWindow?.close()
    annotationOverlayWindow = nil
  }

  // MARK: - Click Highlight Overlay

  private func setupClickHighlightOverlay(for rect: CGRect) {
    let isEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.recordingHighlightClicks) as? Bool ?? false
    guard isEnabled else {
      DiagnosticLogger.shared.log(.debug, .recording, "Click highlight overlay disabled")
      return
    }

    let config = MouseHighlightConfiguration()
    let highlightWindow = MouseClickHighlightWindow(recordingRect: rect, configuration: config)
    highlightWindow.orderFrontRegardless()
    clickHighlightWindow = highlightWindow

    let service = MouseClickHighlightService()
    service.onMouseDown = { [weak highlightWindow] point, button in
      highlightWindow?.showClickEffect(at: point, button: button)
    }
    service.onMouseUp = { [weak highlightWindow] in
      highlightWindow?.dismissClickEffect()
    }
    service.onMouseDragged = { [weak highlightWindow] point in
      highlightWindow?.moveClickEffect(to: point)
    }
    service.start(recordingRect: rect)
    clickHighlightService = service
    DiagnosticLogger.shared.log(.info, .recording, "Click highlight overlay started", context: [
      "windowID": "\(highlightWindow.overlayWindowID)",
    ])

    // Add to ScreenCaptureKit's exceptingWindows so the effect is captured
    Task {
      await recorder.addExceptedWindow(windowID: highlightWindow.overlayWindowID)
    }
  }

  private func cleanupClickHighlightOverlay() {
    if clickHighlightWindow != nil || clickHighlightService != nil {
      DiagnosticLogger.shared.log(.debug, .recording, "Click highlight overlay cleanup")
    }
    clickHighlightService?.stop()
    clickHighlightService = nil
    clickHighlightWindow?.close()
    clickHighlightWindow = nil
  }

  // MARK: - Keystroke Overlay

  private func setupKeystrokeOverlay(for rect: CGRect) {
    let isEnabled = UserDefaults.standard.object(forKey: PreferencesKeys.recordingShowKeystrokes) as? Bool ?? false
    guard isEnabled else {
      DiagnosticLogger.shared.log(.debug, .recording, "Keystroke overlay disabled")
      return
    }

    let config = KeystrokeOverlayConfiguration()
    let overlayWindow = KeystrokeOverlayWindow(recordingRect: rect, configuration: config)
    overlayWindow.orderFrontRegardless()
    keystrokeOverlayWindow = overlayWindow

    let service = KeystrokeMonitorService(visibility: config.visibility)
    service.onKeystroke = { [weak overlayWindow] text in
      overlayWindow?.showKeystroke(text)
    }
    service.start()
    keystrokeMonitorService = service
    DiagnosticLogger.shared.log(.info, .recording, "Keystroke overlay started", context: [
      "windowID": "\(overlayWindow.overlayWindowID)",
    ])

    // Add to ScreenCaptureKit's exceptingWindows so keystrokes are captured
    Task {
      await recorder.addExceptedWindow(windowID: overlayWindow.overlayWindowID)
    }
  }

  private func cleanupKeystrokeOverlay() {
    if keystrokeOverlayWindow != nil || keystrokeMonitorService != nil {
      DiagnosticLogger.shared.log(.debug, .recording, "Keystroke overlay cleanup")
    }
    keystrokeMonitorService?.stop()
    keystrokeMonitorService = nil
    keystrokeOverlayWindow?.close()
    keystrokeOverlayWindow = nil
  }
}
