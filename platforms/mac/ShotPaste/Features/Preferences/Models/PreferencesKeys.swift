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
  static let mcpServerEnabled = "automation.mcp.enabled"
  static let mcpServerPort = "automation.mcp.port"
  static let mcpServerAuthToken = "automation.mcp.authToken"
  static let showMenuBarIcon = "showMenuBarIcon"
  static let exportLocation = "exportLocation"
  static let exportLocationBookmark = "exportLocation.bookmark"
  static let checkForUpdatesAutomatically = "updates.checkAutomatically"
  static let lastUpdateCheckDate = "updates.lastCheckDate"
  static let lastPromptedUpdateVersion = "updates.lastPromptedVersion"
  static let configurationLastAppliedSignature = "configuration.lastAppliedSignature"
  static let permissionGuidePresentedVersion = "permissions.guide.presentedVersion"
  static let oneShotGuidancePresentedVersion = "oneShot.guidance.presentedVersion"
  static let hideDesktopIcons = "hideDesktopIcons"
  static let hideDesktopWidgets = "hideDesktopWidgets"

  /// Appearance
  static let appearanceMode = "appearanceMode"

  // Shortcuts
  static let oneShotShortcut = "oneShotShortcut"
  static let disabledGlobalShortcuts = "shortcuts.disabledGlobalActions"
  static let clearedGlobalShortcuts = "shortcuts.clearedGlobalActions"

  // Agent Mode
  static let agentModeEnabled = "agent.mode.enabled"
  static let agentShortcut = "agent.shortcut"
  static let agentProviderEndpoint = "agent.provider.endpoint"
  static let agentProviderModel = "agent.provider.model"
  static let agentProviderProtocol = "agent.provider.protocol"
  static let agentProviderAPIKey = "agent.provider.apiKey"
  static let agentThinkingEnabled = "agent.provider.thinkingEnabled"
  static let agentProviderSendsImages = "agent.provider.sendsImages"
  static let agentMaxActions = "agent.session.maxActions"
  static let agentScreenshotRetentionEnabled = "agent.session.retainScreenshots"
  static let agentTranslationTimeoutSeconds = "agent.translation.timeoutSeconds"
  static let agentTranslationPromptMode = "agent.translation.promptMode"
  static let agentTranslationPrompt = "agent.translation.prompt"
  /// Controls whether local OCR text may be sent to the configured translation provider.
  /// This is intentionally independent from `agentProviderSendsImages`, which only
  /// controls screenshots sent by Agent Mode.
  static let agentTranslationSendsRecognizedText = "agent.translation.sendRecognizedText"

  // Screenshot
  static let screenshotFormat = "screenshot.format"
  static let screenshotFileNameTemplate = "screenshot.fileNameTemplate"
  static let screenshotIncludeOwnApp = "screenshot.includeOwnApp"
  static let defaultScreenshotIncludeOwnApp = true
  static let screenshotShowCursor = "screenshot.showCursor"
  static let screenshotMagnifierEnabled = "screenshot.magnifierEnabled"
  static let screenshotMagnifierZoom = "screenshot.magnifierZoom"
  static let screenshotColorSpace = "screenshot.colorSpace"
  static let screenshotLossyQuality = "screenshot.lossyQuality"
  static let screenshotSuccessNotificationEnabled = "screenshot.successNotificationEnabled"
  static let scrollingCaptureShowHints = "scrollingCapture.showHints"
  static let annotatePrimaryColor = "annotate.primaryColor.v1"
  static let annotateParameterDefaults = "annotate.parameterDefaults.v1"
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
