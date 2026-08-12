//
//  PreferencesKeys.swift
//  ShotPaste
//
//  Shared UserDefaults keys for preferences
//

import Foundation

/// Centralized keys for UserDefaults storage
nonisolated enum PreferencesKeys {
  // General
  static let playSounds = "playSounds"
  static let urlSchemeEnabled = "urlSchemeEnabled"
  static let showMenuBarIcon = "showMenuBarIcon"
  static let exportLocation = "exportLocation"
  static let exportLocationBookmark = "exportLocation.bookmark"
  static let configurationFileBookmark = "configuration.fileBookmark"
  static let configurationDirectoryBookmark = "configuration.directoryBookmark"
  static let configurationLastAppliedSignature = "configuration.lastAppliedSignature"
  static let hideDesktopIcons = "hideDesktopIcons"
  static let hideDesktopWidgets = "hideDesktopWidgets"

  /// Appearance
  static let appearanceMode = "appearanceMode"

  // Shortcuts
  static let shortcutsEnabled = "shortcutsEnabled"
  static let oneShotShortcut = "oneShotShortcut"
  static let disabledGlobalShortcuts = "shortcuts.disabledGlobalActions"
  static let clearedGlobalShortcuts = "shortcuts.clearedGlobalActions"

  // Screenshot
  static let screenshotFormat = "screenshot.format"
  static let screenshotFileNameTemplate = "screenshot.fileNameTemplate"
  static let screenshotIncludeOwnApp = "screenshot.includeOwnApp"
  static let screenshotShowCursor = "screenshot.showCursor"
  static let screenshotWindowTargeting = "screenshot.windowTargeting"
  static let screenshotMagnifierEnabled = "screenshot.magnifierEnabled"
  static let screenshotMagnifierZoom = "screenshot.magnifierZoom"
  static let screenshotScale = "screenshot.scale"
  static let screenshotColorSpace = "screenshot.colorSpace"
  static let screenshotLossyQuality = "screenshot.lossyQuality"
  static let screenshotSuccessNotificationEnabled = "screenshot.successNotificationEnabled"
  static let scrollingCaptureShowHints = "scrollingCapture.showHints"
  static let backgroundCutoutAutoCropEnabled = "backgroundCutout.autoCropEnabled"
  static let annotateCanvasPresets = "annotate.canvasPresets.v1"
  static let annotateDefaultCanvasPresetId = "annotate.defaultCanvasPresetId.v1"
  static let annotatePrimaryColor = "annotate.primaryColor.v1"
  static let annotateParameterDefaults = "annotate.parameterDefaults.v1"
  static let annotateToolParameterDefaults = "annotate.toolParameterDefaults.v1"
  static let ocrSuccessNotificationEnabled = "ocr.successNotificationEnabled"
  static let ocrLinkDetectionEnabled = "ocr.linkDetectionEnabled"
  static let ocrRecognitionLanguage = "ocr.recognitionLanguage"

  // Quick Access
  static let quickAccessTrackpadSwipeMode = "quickAccess.trackpad.swipe.mode"
  static let quickAccessActionOrder = "quickAccess.actions.order.v1"
  static let quickAccessEnabledActions = "quickAccess.actions.enabled.v1"
  static let quickAccessActionSlotAssignments = "quickAccess.actions.slots.v1"
  static let quickAccessSwipeLeftAction = "quickAccess.swipe.action.left"
  static let quickAccessSwipeRightAction = "quickAccess.swipe.action.right"
  static let quickAccessHideCardWhenWindowOpen = "quickAccess.hideCardWhenWindowOpen"
  static let quickAccessAnimationStyle = "quickAccess.animationStyle"

  // Recording
  static let recordingFormat = "recording.format"
  static let recordingFileNameTemplate = "recording.fileNameTemplate"
  static let recordingFPS = "recording.fps"
  static let recordingQuality = "recording.quality"
  static let recordingVideoCodec = "recording.videoCodec"
  static let recordingGIFFPS = "recording.gifFPS"
  static let recordingCaptureAudio = "recording.captureAudio"
  static let recordingCaptureMicrophone = "recording.captureMicrophone"
  static let recordingSystemAudioVolume = "recording.systemAudioVolume"
  static let recordingMicrophoneVolume = "recording.microphoneVolume"
  static let recordingMicrophoneDeviceID = "recording.microphoneDeviceID"
  static let recordingOutputMode = "recording.outputMode"
  static let recordingIncludeOwnApp = "recording.includeOwnApp"
  static let recordingShowCursor = "recording.showCursor"
  static let recordingDimNonSelectedArea = "recording.dimNonSelectedArea"
  static let recordingHighlightClicks = "recording.highlightClicks"
  static let recordingShowKeystrokes = "recording.showKeystrokes"
  static let recordingHoverBarVisible = "recording.hoverBarVisible"
  static let recordingShowTimeOnMenuBar = "recording.showTimeOnMenuBar"
  static let recordingHoverBarFrameOrigin = "recording.hoverBarFrameOrigin"

  // Mouse Highlight Customization
  static let mouseHighlightSize = "recording.mouseHighlight.size"
  static let mouseHighlightAnimationDuration = "recording.mouseHighlight.animationDuration"
  static let mouseHighlightLeftColor = "recording.mouseHighlight.leftColor"
  static let mouseHighlightRightColor = "recording.mouseHighlight.rightColor"
  static let mouseHighlightOpacity = "recording.mouseHighlight.opacity"
  static let mouseHighlightRippleCount = "recording.mouseHighlight.rippleCount"

  // Keystroke Overlay Customization
  static let keystrokeFontSize = "recording.keystroke.fontSize"
  static let keystrokePosition = "recording.keystroke.position"
  static let keystrokeDisplayDuration = "recording.keystroke.displayDuration"
  static let keystrokeVisibility = "recording.keystroke.visibility"

  // Recording Annotation
  static let recordingAnnotationColor = "recording.annotation.color"
  static let recordingAnnotationWidth = "recording.annotation.width"
  static let recordingAnnotationClearMode = "recording.annotation.clearMode"
  static let recordingAnnotationClearSeconds = "recording.annotation.clearSeconds"
  static let recordingAnnotationMaxCount = "recording.annotation.maxCount"
  static let recordingAnnotationToolPolicies = "recording.annotation.toolPolicies"
  static let recordingAnnotationFadeEnabled = "recording.annotation.fadeEnabled"
  static let recordingAnnotationFadeDuration = "recording.annotation.fadeDuration"
  static let recordingAnnotationTemporaryModifier = "recording.annotation.temporaryModifier"
  static let recordingAnnotationTemporaryClearMode = "recording.annotation.temporaryClearMode"

  // Diagnostics
  static let diagnosticsEnabled = "diagnostics.enabled"
  static let diagnosticsRetentionDays = "diagnostics.retentionDays"
  static let diagnosticsSessionActive = "diagnostics.sessionActive"

  // History
  static let historyEnabled = "history.enabled"
  static let historyRetentionDays = "history.retentionDays"
  static let historyMaxCount = "history.maxCount"
  static let defaultHistoryRetentionDays = 30
  static let defaultHistoryMaxCount = 1_000
  static let mediaClipboardEnabled = "history.mediaClipboardEnabled"
  static let historyBackgroundStyle = "history.backgroundStyle"
  static let historyFloatingScale = "history.floating.scale"
}
