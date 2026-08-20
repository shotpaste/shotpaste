//
//  L10n.swift
//  ShotPaste
//
//  Small localization helper for AppKit and shared string surfaces.
//

import Foundation

nonisolated enum L10n {
  private nonisolated static let tableMappings: [(prefix: String, tableName: String)] = [
    ("action.", "Common"),
    ("menu.", "Menubar"),
    ("common.", "Common"),
    ("appearance.", "Common"),
    ("app-identity.", "Common"),
    ("permission-row.", "Permissions"),
    ("permission.", "PermissionLabels"),
    ("crash-report.", "Errors"),
    ("preferences.tab.", "Settings"),
    ("preferences-general.", "Settings"),
    ("preferences-capture.", "Capture"),
    ("preferences-shortcuts.", "Shortcuts"),
    ("preferences-quick-access.", "QuickAccess"),
    ("preferences-history.", "Settings"),
    ("preferences-advanced.", "Settings"),
    ("preferences-permissions.", "Permissions"),
    ("history-background-style.", "Settings"),
    ("history-panel-position.", "Settings"),
    ("after-capture.", "Capture"),
    ("capture-kind.", "Capture"),
    ("capture-storage.", "Capture"),
    ("file-access.", "Permissions"),
    ("ocr.", "Capture"),
    ("one-shot.", "Capture"),
    ("screen-capture.", "Capture"),
    ("scrolling-capture.", "Capture"),
    ("scrolling-capture-status.", "Capture"),
    ("gif.", "Recording"),
    ("keystroke-position.", "Recording"),
    ("microphone.", "Recording"),
    ("recording.", "Recording"),
    ("recording-annotation.", "Recording"),
    ("recording-toolbar.", "Recording"),
    ("annotate.", "Annotate"),
    ("annotate-context.", "Annotate"),
    ("quick-access.", "QuickAccess"),
    ("shortcut-overlay.", "Shortcuts"),
    ("shortcut-guidance.", "ShortcutGuidance"),
    ("shortcut-recorder.", "Shortcuts"),
    ("shortcut-validation.", "Shortcuts"),
    ("system-shortcuts.", "Shortcuts"),
  ]

  private nonisolated static func tableName(for key: String) -> String? {
    for mapping in tableMappings where key.hasPrefix(mapping.prefix) {
      return mapping.tableName
    }

    assertionFailure("Missing localization table mapping for key: \(key)")
    return nil
  }

  private nonisolated static func bundle(for localeIdentifier: String) -> Bundle {
    guard
      !localeIdentifier.isEmpty,
      let resourcePath = Bundle.main.path(forResource: localeIdentifier, ofType: "lproj"),
      let bundle = Bundle(path: resourcePath)
    else {
      return .main
    }

    return bundle
  }

  nonisolated static func string(_ key: String, defaultValue: String, comment: String) -> String {
    NSLocalizedString(
      key,
      tableName: tableName(for: key),
      bundle: .main,
      value: defaultValue,
      comment: comment
    )
  }

  nonisolated static func string(
    _ key: String,
    defaultValue: String,
    localeIdentifier: String,
    comment _: String
  ) -> String {
    let lookupBundle = bundle(for: localeIdentifier)
    return lookupBundle.localizedString(
      forKey: key,
      value: defaultValue,
      table: tableName(for: key)
    )
  }

  nonisolated static func format(
    _ key: String,
    defaultValue: String,
    comment: String,
    _ arguments: CVarArg...
  ) -> String {
    let format = string(key, defaultValue: defaultValue, comment: comment)
    return String(format: format, locale: Locale.current, arguments: arguments)
  }

  nonisolated static func format(
    _ key: String,
    defaultValue: String,
    localeIdentifier: String,
    comment: String,
    _ arguments: CVarArg...
  ) -> String {
    let format = string(
      key,
      defaultValue: defaultValue,
      localeIdentifier: localeIdentifier,
      comment: comment
    )
    return String(
      format: format,
      locale: Locale(identifier: localeIdentifier),
      arguments: arguments
    )
  }

  enum Preferences {
    static let generalTab = string(
      "preferences.tab.general",
      defaultValue: "General",
      comment: "Preferences tab title"
    )
    static let captureTab = string(
      "preferences.tab.capture",
      defaultValue: "Capture",
      comment: "Preferences tab title"
    )
    static let quickAccessTab = string(
      "preferences.tab.quick-access",
      defaultValue: "Quick Access",
      comment: "Preferences tab title"
    )
    static let historyTab = string(
      "preferences.tab.history",
      defaultValue: "Clipboard History",
      comment: "Preferences tab title for Clipboard History"
    )
    static let shortcutsTab = string(
      "preferences.tab.shortcuts",
      defaultValue: "Shortcuts",
      comment: "Preferences tab title"
    )
    static let permissionsTab = string(
      "preferences.tab.permissions",
      defaultValue: "Permissions",
      comment: "Preferences tab title"
    )
    static let advancedTab = string(
      "preferences.tab.advanced",
      defaultValue: "Advanced",
      comment: "Preferences tab title"
    )
  }

  enum PreferencesAdvanced {
    static let urlSchemeTitle = string(
      "preferences-advanced.url-scheme-title",
      defaultValue: "URL Scheme integration",
      comment: "Advanced preferences setting title"
    )
    static let urlSchemeDescription = string(
      "preferences-advanced.url-scheme-description",
      defaultValue: "Allow external triggers via shotpaste:// URLs",
      comment: "Advanced preferences setting description"
    )
    static let mcpServerTitle = string(
      "preferences-advanced.mcp-server-title",
      defaultValue: "MCP server",
      comment: "Automation preferences MCP server setting title"
    )
    static let mcpServerDescription = string(
      "preferences-advanced.mcp-server-description",
      defaultValue: "Allow trusted agents to control ShotPaste through authenticated local MCP.",
      comment: "Automation preferences MCP server setting description"
    )
    static let diagnosticsSection = PreferencesGeneral.diagnosticsSection
    static let diagnosticLoggingTitle = PreferencesGeneral.diagnosticLoggingTitle
    static let diagnosticLoggingDescription = PreferencesGeneral.diagnosticLoggingDescription
    static let logFilesTitle = PreferencesGeneral.logFilesTitle
    static let logRetentionTitle = PreferencesGeneral.logRetentionTitle
    static func logRetentionDescription(_ days: Int) -> String {
      PreferencesGeneral.logRetentionDescription(days)
    }

    static let openFolderButton = PreferencesGeneral.openFolderButton
    static let calculating = PreferencesGeneral.calculating
    static let noLogs = PreferencesGeneral.noLogs
    static let restoreDefaultsTitle = string(
      "preferences-advanced.restore-defaults-title",
      defaultValue: "Restore defaults",
      comment: "Advanced preferences restore defaults row title"
    )
    static let restoreDefaultsDescription = string(
      "preferences-advanced.restore-defaults-description",
      defaultValue: "Reset all settings",
      comment: "Advanced preferences restore defaults row description"
    )
    static let restoreDefaultsButton = string(
      "preferences-advanced.restore-defaults-button",
      defaultValue: "Restore",
      comment: "Restore default config button"
    )
    static let restoreDefaultsConfirmButton = string(
      "preferences-advanced.restore-defaults-confirm-button",
      defaultValue: "Restore Defaults",
      comment: "Destructive confirmation button for restoring default settings"
    )
    static let restoreDefaultsSucceeded = string(
      "preferences-advanced.restore-defaults-succeeded",
      defaultValue: "Defaults restored.",
      comment: "Toast shown after settings are restored to defaults"
    )
    static let restoreDefaultsFailed = string(
      "preferences-advanced.restore-defaults-failed",
      defaultValue: "Could not restore defaults.",
      comment: "Config restore defaults failure message"
    )
    static let restoreDefaultsConfirmationTitle = string(
      "preferences-advanced.restore-defaults-confirmation-title",
      defaultValue: "Restore default settings?",
      comment: "Restore defaults confirmation alert title"
    )
    static let restoreDefaultsConfirmationMessage = string(
      "preferences-advanced.restore-defaults-confirmation-message",
      defaultValue: "If you confirm, ShotPaste will reset app settings to their default values. Saved captures are not deleted.",
      comment: "Restore defaults confirmation alert message"
    )
  }

  enum Actions {
    static let oneShot = string(
      "action.one-shot",
      defaultValue: "One Shot",
      comment: "Action title for the unified One Shot capture entry"
    )
    static let scrollingCapture = string(
      "action.scrolling-capture",
      defaultValue: "Scrolling Capture",
      comment: "Action title for scrolling screenshot capture"
    )
    static let captureTextOCR = string(
      "action.capture-text-ocr",
      defaultValue: "Capture Text (OCR)",
      comment: "Action title for OCR capture"
    )
    static let pauseResumeRecording = string(
      "action.pause-resume-recording",
      defaultValue: "Pause/Resume Recording",
      comment: "Action title for the optional pause/resume recording shortcut"
    )
    static let togglePenRecording = string(
      "action.toggle-pen-recording",
      defaultValue: "Toggle Pen/Annotations",
      comment: "Action title for toggling drawing/annotations overlay"
    )
    static let restartRecording = string(
      "action.restart-recording",
      defaultValue: "Re-record / Restart",
      comment: "Action title for restarting the recording session"
    )
    static let deleteRecording = string(
      "action.delete-recording",
      defaultValue: "Delete / Cancel",
      comment: "Action title for cancelling and deleting the active recording"
    )
    static let showQuickAccessOverlay = string(
      "action.show-quick-access-overlay",
      defaultValue: "Show Quick Access Overlay",
      comment: "Action title for showing the quick access overlay"
    )
    static let focusQuickAccess = string(
      "action.focus-quick-access",
      defaultValue: "Focus Quick Access",
      comment: "Menu action that explicitly gives keyboard focus to the Quick Access cards"
    )
    static let openHistory = string(
      "action.open-history",
      defaultValue: "Open Clipboard History",
      comment: "Action title for opening Clipboard History"
    )
  }

  enum Menu {
    static func stopRecording(_ duration: String) -> String {
      format(
        "menu.stop-recording",
        defaultValue: "Stop Recording (%@)",
        comment: "Status bar menu item title while recording. %@ is the formatted recording duration.",
        duration
      )
    }

    static let grantPermission = string(
      "menu.grant-permission",
      defaultValue: "Set Up Permissions...",
      comment: "Status bar menu item title to open the guided permission setup"
    )
    static let preferences = string(
      "menu.preferences",
      defaultValue: "Preferences...",
      comment: "Status bar menu item title for opening preferences"
    )
    static let quitShotPaste = string(
      "menu.quit-shotpaste",
      defaultValue: "Quit ShotPaste",
      comment: "Status bar menu item title for quitting the app"
    )
  }

  enum Common {
    static let activeCaptureTitle = string(
      "common.active-capture-title",
      defaultValue: "Capture in Progress",
      comment: "Alert title shown when quitting while a capture workflow is active"
    )
    static let activeCaptureMessage = string(
      "common.active-capture-message",
      defaultValue: "Return to ShotPaste to finish the current capture, or discard it and quit.",
      comment: "Alert message shown when quitting while a capture workflow is active"
    )
    static let returnToShotPaste = string(
      "common.return-to-shotpaste",
      defaultValue: "Return to ShotPaste",
      comment: "Safe alert action that cancels quitting and returns to the active workflow"
    )
    static let discardAndQuit = string(
      "common.discard-and-quit",
      defaultValue: "Discard and Quit",
      comment: "Destructive alert action that discards active work before quitting"
    )
    static let stopAndQuit = string(
      "common.stop-and-quit",
      defaultValue: "Stop and Quit",
      comment: "Alert action that saves an active recording before quitting"
    )
    static let close = string(
      "common.close",
      defaultValue: "Close",
      comment: "Generic close button title"
    )
    static let off = string(
      "common.off",
      defaultValue: "Off",
      comment: "Label shown when a shortcut or feature is turned off"
    )
    static let preferences = string(
      "common.preferences",
      defaultValue: "Preferences",
      comment: "Generic label for preferences without an ellipsis"
    )
    static let on = string(
      "common.on",
      defaultValue: "On",
      comment: "Label shown when a shortcut or feature is turned on"
    )
    static let display = string(
      "common.display",
      defaultValue: "Display",
      comment: "Generic label for display settings or options"
    )
    static let cancel = string(
      "common.cancel",
      defaultValue: "Cancel",
      comment: "Generic cancel button title"
    )
    static let ok = string(
      "common.ok",
      defaultValue: "OK",
      comment: "Generic confirmation button title"
    )
    static let notGranted = string(
      "common.not-granted",
      defaultValue: "Not Granted",
      comment: "Status label shown when a permission or access has not been granted"
    )
    static let openSettings = string(
      "common.open-settings",
      defaultValue: "Open Settings",
      comment: "Generic button title to open System Settings"
    )
    static let refresh = string(
      "common.refresh",
      defaultValue: "Refresh",
      comment: "Generic refresh button title"
    )
    static let disable = string(
      "common.disable",
      defaultValue: "Disable",
      comment: "Generic destructive disable button title"
    )
    static let openSystemSettings = string(
      "common.open-system-settings",
      defaultValue: "Open System Settings",
      comment: "Generic button title to open System Settings"
    )
    static let resetToDefault = string(
      "common.reset-to-default",
      defaultValue: "Reset to Default",
      comment: "Generic button title to reset a setting to its default value"
    )
    static let save = string(
      "common.save",
      defaultValue: "Save",
      comment: "Generic save button title"
    )
    static let none = string(
      "common.none",
      defaultValue: "None",
      comment: "Generic none option label"
    )
    static let reset = string(
      "common.reset",
      defaultValue: "Reset",
      comment: "Generic reset button title"
    )
    static let done = string(
      "common.done",
      defaultValue: "Done",
      comment: "Generic done button title"
    )
    static let deleteAction = string(
      "common.delete",
      defaultValue: "Delete",
      comment: "Generic delete button title"
    )
    static let undo = string(
      "common.undo",
      defaultValue: "Undo",
      comment: "Generic undo button title"
    )
    static let redo = string(
      "common.redo",
      defaultValue: "Redo",
      comment: "Generic redo button title"
    )
    static let copyToClipboard = string(
      "common.copy-to-clipboard",
      defaultValue: "Copy to Clipboard",
      comment: "Generic copy to clipboard button title"
    )
    static let copiedToClipboard = string(
      "common.copied-to-clipboard",
      defaultValue: "Copied to clipboard",
      comment: "Generic toast shown after copying content to the clipboard"
    )
    static let copy = string(
      "common.copy",
      defaultValue: "Copy",
      comment: "Generic copy button title"
    )
    static let open = string(
      "common.open",
      defaultValue: "Open",
      comment: "Generic open button title"
    )
    static let openInFinder = string(
      "common.open-in-finder",
      defaultValue: "Open in Finder",
      comment: "Generic button or tooltip title for opening a file in Finder"
    )
    static let moveToTrash = string(
      "common.move-to-trash",
      defaultValue: "Move to Trash",
      comment: "Generic destructive action title for moving a file to the system Trash"
    )
    static let preview = string(
      "common.preview",
      defaultValue: "Preview",
      comment: "Generic preview section title"
    )
    static let size = string(
      "common.size",
      defaultValue: "Size",
      comment: "Generic size field label"
    )
    static let status = string(
      "common.status",
      defaultValue: "Status",
      comment: "Generic status field label"
    )
    static let corners = string(
      "common.corners",
      defaultValue: "Corners",
      comment: "Generic corners setting label"
    )
    static let style = string(
      "common.style",
      defaultValue: "Style",
      comment: "Generic style setting label"
    )
    static let text = string(
      "common.text",
      defaultValue: "Text",
      comment: "Generic text label"
    )
    static let color = string(
      "common.color",
      defaultValue: "Color",
      comment: "Generic color label"
    )
    static let stroke = string(
      "common.stroke",
      defaultValue: "Stroke",
      comment: "Generic stroke setting label"
    )
    static func withShortcut(_ title: String, _ shortcut: String) -> String {
      L10n.format(
        "common.with-shortcut",
        defaultValue: "%@ (%@)",
        comment: "Generic label that appends a keyboard shortcut hint to a title. First %@ is the title, second %@ is the shortcut.",
        title,
        shortcut
      )
    }
  }

  enum CaptureKind {
    static let screenshot = string(
      "capture-kind.screenshot",
      defaultValue: "Screenshot",
      comment: "Generic label for screenshot capture type"
    )
    static let recording = string(
      "capture-kind.recording",
      defaultValue: "Recording",
      comment: "Generic label for recording capture type"
    )
  }

  enum OneShot {
    static let clipboard = string(
      "one-shot.clipboard",
      defaultValue: "Clipboard History",
      comment: "One Shot top switcher tab that opens clipboard history"
    )
    static let help = string(
      "one-shot.help",
      defaultValue: "Help",
      comment: "One Shot scrolling capture help button"
    )
    static let startRecording = string(
      "one-shot.start-recording",
      defaultValue: "Start Recording",
      comment: "One Shot recording primary action"
    )
    static let dragSwitcherHint = string(
      "one-shot.drag-switcher-hint",
      defaultValue: "Drag horizontally to move One Shot",
      comment: "Accessibility and hover hint for the One Shot top switcher drag handle"
    )
    static let dragToolbarHint = string(
      "one-shot.drag-toolbar-hint",
      defaultValue: "Drag to move the screenshot toolbar",
      comment: "Accessibility and hover hint for the One Shot screenshot toolbar drag handle"
    )
    static let modeLockedHint = string(
      "one-shot.mode-locked-hint",
      defaultValue: "This mode is locked because you started using its tools.",
      comment: "Explanation shown when a user tries to switch One Shot modes after committing"
    )
    static let scrollingHelpMessage = string(
      "one-shot.scrolling-help-message",
      defaultValue: "Keep the content inside the selected area, start capture, then scroll vertically until the full page is collected.",
      comment: "Non-committing help shown in One Shot scrolling mode"
    )
    static let shortcutDescription = string(
      "one-shot.shortcut-description",
      defaultValue: "Choose one shared area, then take a screenshot, scrolling capture, recording, or open Clipboard History",
      comment: "Shortcut settings description for One Shot"
    )
    static let sessionAlreadyActive = string(
      "one-shot.session-already-active",
      defaultValue: "Another capture session is already active.",
      comment: "Toast shown when One Shot cannot start because another capture owns the screen"
    )
    static let preparationFailed = string(
      "one-shot.preparation-failed",
      defaultValue: "One Shot could not prepare the frozen screen.",
      comment: "Fallback One Shot frozen-screen preparation error"
    )
    static let copyColorHint = string(
      "one-shot.copy-color-hint",
      defaultValue: "Command-C Copy color",
      comment: "One Shot magnifier shortcut hint"
    )
    static let switchColorHint = string(
      "one-shot.switch-color-hint",
      defaultValue: "Shift Switch HEX/RGB",
      comment: "One Shot magnifier color format shortcut hint"
    )
    static func coordinates(_ x: Int, _ y: Int) -> String {
      format(
        "one-shot.coordinates",
        defaultValue: "Coordinates: %d, %d",
        comment: "One Shot magnifier global screen coordinates. Values are x and y.",
        x,
        y
      )
    }
  }

  enum Appearance {
    static let system = string(
      "appearance.system",
      defaultValue: "System",
      comment: "Appearance mode label"
    )
    static let light = string(
      "appearance.light",
      defaultValue: "Light",
      comment: "Appearance mode label"
    )
    static let dark = string(
      "appearance.dark",
      defaultValue: "Dark",
      comment: "Appearance mode label"
    )
  }

  enum PermissionRow {
    static let required = string(
      "permission-row.required",
      defaultValue: "Required",
      comment: "Badge shown for required permissions"
    )
    static let optional = string(
      "permission-row.optional",
      defaultValue: "Optional",
      comment: "Badge shown for optional permissions"
    )
    static let granted = string(
      "permission-row.granted",
      defaultValue: "Granted",
      comment: "Status badge shown when a permission is granted"
    )
    static let notEnabled = string(
      "permission-row.not-enabled",
      defaultValue: "Not Enabled",
      comment: "Neutral status badge shown when an optional permission has not been enabled"
    )
    static let restricted = string(
      "permission-row.restricted",
      defaultValue: "Restricted",
      comment: "Status badge shown when macOS policy prevents granting a permission"
    )
  }

  enum Permission {
    static let screenRecording = string(
      "permission.screen-recording",
      defaultValue: "Screen Recording",
      comment: "Screen recording permission label"
    )
    static let saveFolder = string(
      "permission.save-folder",
      defaultValue: "Save Folder",
      comment: "Save folder permission label"
    )
    static let microphone = string(
      "permission.microphone",
      defaultValue: "Microphone",
      comment: "Microphone permission label"
    )
    static let accessibility = string(
      "permission.accessibility",
      defaultValue: "Accessibility",
      comment: "Accessibility permission label"
    )
    static let requiredForCaptures = string(
      "permission.required-for-captures",
      defaultValue: "Required for screenshots and recordings",
      comment: "Permission description for required capture-related permissions"
    )
    static let optionalForVoiceRecording = string(
      "permission.optional-voice-recording",
      defaultValue: "Optional for voice recording",
      comment: "Permission description for microphone access"
    )
    static let optionalForGlobalShortcuts = string(
      "permission.optional-global-shortcuts",
      defaultValue: "Optional for auto-scroll and shortcuts that use the Fn key",
      comment: "Permission description for accessibility access"
    )
    static let saveFolderDescription = string(
      "permission.save-folder-description",
      defaultValue: "Lets ShotPaste save screenshots and recordings to your chosen folder",
      comment: "Permission description for access to the selected capture folder"
    )
    static let screenRecordingFinishInSettings = string(
      "permission.screen-recording-finish-in-settings",
      defaultValue: "Turn on ShotPaste in System Settings, then return here. macOS may ask you to reopen the app.",
      comment: "Follow-up guidance after requesting screen recording permission"
    )
    static let grantAccess = string(
      "permission.grant-access",
      defaultValue: "Grant Access",
      comment: "Button title to grant permission or folder access"
    )
    static let refreshStatus = string(
      "permission.refresh-status",
      defaultValue: "Refresh Status",
      comment: "Button title to refresh permission or identity status"
    )
    static let unavailable = string(
      "permission.unavailable",
      defaultValue: "Unavailable",
      comment: "Badge shown when permission is unavailable due to app identity state"
    )
    static let buildIdentityNeedsAttention = string(
      "permission.identity-attention",
      defaultValue: "Build Identity Needs Attention",
      comment: "Warning title when app identity health issues block permission usage"
    )
    static let screenRecordingIdentityBlocked = string(
      "permission.identity-blocked-description",
      defaultValue: "Granted in System Settings, but this build cannot use the permission until the identity issues below are fixed.",
      comment: "Description shown when screen recording permission exists but app identity prevents using it"
    )
  }

  enum ShortcutGuidance {
    static let guideStep1 = string(
      "shortcut-guidance.guide-step-1",
      defaultValue: "Open System Settings → Keyboard → Keyboard Shortcuts",
      comment: "Step 1 in the shortcut conflict resolution guide"
    )
    static let guideStep2 = string(
      "shortcut-guidance.guide-step-2",
      defaultValue: "Select Screenshots from the sidebar",
      comment: "Step 2 in the shortcut conflict resolution guide"
    )
    static let guideStep3 = string(
      "shortcut-guidance.guide-step-3",
      defaultValue: "Uncheck the macOS screenshot shortcuts that overlap with the ShotPaste shortcuts you want to keep on",
      comment: "Step 3 in the shortcut conflict resolution guide"
    )
  }

  enum ShortcutOverlay {
    static let annotateReference = string(
      "shortcut-overlay.annotate-reference",
      defaultValue: "Annotate Reference",
      comment: "Shortcuts settings reference section title"
    )
    static let saveDone = string(
      "shortcut-overlay.save-done",
      defaultValue: "Save (Done)",
      comment: "Annotate reference item title"
    )
    static let undo = string(
      "shortcut-overlay.undo",
      defaultValue: "Undo",
      comment: "Annotate reference item title"
    )
    static let redo = string(
      "shortcut-overlay.redo",
      defaultValue: "Redo",
      comment: "Annotate reference item title"
    )
    static let deleteAnnotation = string(
      "shortcut-overlay.delete-annotation",
      defaultValue: "Delete Annotation",
      comment: "Annotate reference item title"
    )
    static let cancelDeselect = string(
      "shortcut-overlay.cancel-deselect",
      defaultValue: "Cancel / Deselect",
      comment: "Annotate reference item title"
    )
    static let nudgeAnnotation = string(
      "shortcut-overlay.nudge-annotation",
      defaultValue: "Nudge Annotation",
      comment: "Annotate reference item title"
    )
    static let nudgeTenPixels = string(
      "shortcut-overlay.nudge-10px",
      defaultValue: "Nudge 10px",
      comment: "Annotate reference item title"
    )
  }

  enum ShortcutRecorder {
    static let pressKeys = string(
      "shortcut-recorder.press-keys",
      defaultValue: "Press keys...",
      comment: "Placeholder text shown while recording a shortcut"
    )
    static let clickToRecord = string(
      "shortcut-recorder.click-to-record",
      defaultValue: "Click to record a shortcut.",
      comment: "Help text for shortcut recorder button"
    )
    static let turnOnToEdit = string(
      "shortcut-recorder.turn-on-to-edit",
      defaultValue: "Turn this shortcut on to edit it.",
      comment: "Help text shown when shortcut recorder is disabled"
    )
  }

  enum ShortcutValidation {
    static func alreadyUsedBy(_ displayName: String) -> String {
      format(
        "shortcut-validation.already-used-by",
        defaultValue: "Already used by %@.",
        comment: "Validation error for duplicate shortcut. %@ is the conflicting action name.",
        displayName
      )
    }

    static func matchesSystemConflict(_ displayName: String) -> String {
      format(
        "shortcut-validation.matches-system-conflict",
        defaultValue: "Matches %@. macOS may win.",
        comment: "Validation warning when shortcut overlaps with a macOS system shortcut. %@ is the system shortcut description.",
        displayName
      )
    }
  }

  enum PreferencesGeneral {
    static let loginItemRequiresApprovalTitle = string(
      "preferences-general.login-item-requires-approval-title",
      defaultValue: "Approval Required",
      comment: "Alert title when macOS requires approval for the login item"
    )
    static let loginItemRequiresApprovalMessage = string(
      "preferences-general.login-item-requires-approval-message",
      defaultValue: "Allow ShotPaste in System Settings → General → Login Items, then return here.",
      comment: "Alert guidance when macOS requires approval for the login item"
    )
    static let loginItemUpdateFailed = string(
      "preferences-general.login-item-update-failed",
      defaultValue: "Could not update the login item setting.",
      comment: "Toast shown when changing the login item setting fails"
    )
    static let startupSection = string(
      "preferences-general.section-startup",
      defaultValue: "Startup",
      comment: "General preferences section title"
    )
    static let appearanceSection = string(
      "preferences-general.section-appearance",
      defaultValue: "Appearance",
      comment: "General preferences section title"
    )
    static let storageSection = string(
      "preferences-general.section-storage",
      defaultValue: "Storage",
      comment: "General preferences section title"
    )
    static let updatesSection = string(
      "preferences-general.section-updates",
      defaultValue: "Software Updates",
      comment: "General preferences section title"
    )
    static let diagnosticsSection = string(
      "preferences-general.section-diagnostics",
      defaultValue: "Diagnostics",
      comment: "General preferences section title"
    )
    static let helpSection = string(
      "preferences-general.section-help",
      defaultValue: "Help",
      comment: "General preferences section title"
    )
    static let startAtLoginTitle = string(
      "preferences-general.start-at-login-title",
      defaultValue: "Start at login",
      comment: "General preferences setting title"
    )
    static let startAtLoginDescription = string(
      "preferences-general.start-at-login-description",
      defaultValue: "Launch ShotPaste when you log in",
      comment: "General preferences setting description"
    )
    static let playSoundsTitle = string(
      "preferences-general.play-sounds-title",
      defaultValue: "Play sounds",
      comment: "General preferences setting title"
    )
    static let playSoundsDescription = string(
      "preferences-general.play-sounds-description",
      defaultValue: "Audio feedback for captures",
      comment: "General preferences setting description"
    )
    static let menuBarIconTitle = string(
      "preferences-general.menu-bar-icon-title",
      defaultValue: "Show menu bar icon",
      comment: "General preferences setting title"
    )
    static let menuBarIconDescription = string(
      "preferences-general.menu-bar-icon-description",
      defaultValue: "Access ShotPaste from the menu bar. When hidden, open ShotPaste again to show settings.",
      comment: "General preferences setting description"
    )
    static let themeTitle = string(
      "preferences-general.theme-title",
      defaultValue: "Theme",
      comment: "General preferences setting title"
    )
    static let themeDescription = string(
      "preferences-general.theme-description",
      defaultValue: "Choose your preferred appearance",
      comment: "General preferences setting description"
    )
    static let languageTitle = string(
      "preferences-general.language-title",
      defaultValue: "App Language",
      comment: "General preferences setting title"
    )
    static let languageDescription = string(
      "preferences-general.language-description",
      defaultValue: "Choose the language used across ShotPaste",
      comment: "General preferences setting description"
    )
    static let languageSystem = string(
      "preferences-general.language-system",
      defaultValue: "System Default",
      comment: "General preferences picker option that follows the macOS app language"
    )
    static let languageRestartHint = string(
      "preferences-general.language-restart-hint",
      defaultValue: "Language changes apply after relaunch",
      comment: "General preferences helper text shown when a language change is pending"
    )
    static let languageRelaunchConfirmationTitle = string(
      "preferences-general.language-relaunch-confirmation-title",
      defaultValue: "Relaunch ShotPaste?",
      comment: "Alert title shown before the app relaunches to apply a language change"
    )
    static let languageRelaunchConfirmationMessage = string(
      "preferences-general.language-relaunch-confirmation-message",
      defaultValue: "ShotPaste needs to quit and reopen to apply this language change everywhere.",
      comment: "Alert message shown before the app relaunches to apply a language change"
    )
    static let languageRelaunchConfirmationAction = string(
      "preferences-general.language-relaunch-confirmation-action",
      defaultValue: "Relaunch ShotPaste",
      comment: "Alert button title that confirms relaunching the app after changing language"
    )
    static let languageRelaunchErrorTitle = string(
      "preferences-general.language-relaunch-error-title",
      defaultValue: "Could Not Relaunch ShotPaste",
      comment: "Alert title shown when the app cannot relaunch after changing language"
    )
    static let saveLocationTitle = string(
      "preferences-general.save-location-title",
      defaultValue: "Save location",
      comment: "General preferences setting title"
    )
    static let chooseButton = string(
      "preferences-general.choose-button",
      defaultValue: "Choose...",
      comment: "General preferences button title"
    )
    static let checkAutomaticallyTitle = string(
      "preferences-general.check-automatically-title",
      defaultValue: "Check automatically",
      comment: "General preferences setting title"
    )
    static let checkAutomaticallyDescription = string(
      "preferences-general.check-automatically-description",
      defaultValue: "Look for updates on launch",
      comment: "General preferences setting description"
    )
    static let updateCheckButton = string(
      "preferences-general.update-check-button",
      defaultValue: "Check for Updates",
      comment: "Button title that starts a software update check"
    )
    static let updateCurrentVersion = string(
      "preferences-general.update-current-version",
      defaultValue: "Current version",
      comment: "Label shown before the installed application version"
    )
    static let updateLatestVersion = string(
      "preferences-general.update-latest-version",
      defaultValue: "Latest version",
      comment: "Label shown before the latest GitHub Release version"
    )
    static let updateChecking = string(
      "preferences-general.update-checking",
      defaultValue: "Checking for updates...",
      comment: "Status shown while checking GitHub Releases"
    )
    static let updateUpToDate = string(
      "preferences-general.update-up-to-date",
      defaultValue: "ShotPaste is up to date.",
      comment: "Status shown when no newer stable release exists"
    )
    static let updateAvailable = string(
      "preferences-general.update-available",
      defaultValue: "Update available",
      comment: "Status shown when a newer stable release exists"
    )
    static let updateCheckFailed = string(
      "preferences-general.update-check-failed",
      defaultValue: "Unable to check for updates. Check your internet connection and try again.",
      comment: "Generic user-facing failure shown after an update check"
    )
    static let updateOpenGitHubButton = string(
      "preferences-general.update-open-github-button",
      defaultValue: "Open GitHub",
      comment: "Button title that opens the latest GitHub Release page"
    )
    static let updateOpenGitHubPrompt = string(
      "preferences-general.update-open-github-prompt",
      defaultValue: "Open the GitHub Release page to download the update?",
      comment: "Prompt asking whether to open GitHub to download an update"
    )
    static let diagnosticLoggingTitle = string(
      "preferences-general.crash-logging-title",
      defaultValue: "Diagnostic Logging",
      comment: "General preferences setting title"
    )
    static let diagnosticLoggingDescription = string(
      "preferences-general.crash-logging-description",
      defaultValue: "Save local logs for app, capture, recording, and crash diagnostics",
      comment: "General preferences setting description"
    )
    static let logFilesTitle = string(
      "preferences-general.log-files-title",
      defaultValue: "Log Files",
      comment: "General preferences setting title"
    )
    static let logRetentionTitle = string(
      "preferences-general.log-retention-title",
      defaultValue: "Keep Logs For",
      comment: "General preferences setting title"
    )
    static func logRetentionDescription(_ days: Int) -> String {
      format(
        "preferences-general.log-retention-description",
        defaultValue: "Keep one diagnostic log file per day for %d days",
        comment: "General preferences setting description. %d is the number of days.",
        days
      )
    }

    static let openFolderButton = string(
      "preferences-general.open-folder-button",
      defaultValue: "Open Folder",
      comment: "General preferences button title"
    )
    static let openReportPageButton = string(
      "preferences-general.open-report-page-button",
      defaultValue: "Open Report Page",
      comment: "General preferences button title"
    )
    static let reportIssueTitle = string(
      "preferences-general.report-issue-title",
      defaultValue: "Report a Problem",
      comment: "General preferences setting title"
    )
    static func reportIssueDescription(_ destination: String) -> String {
      format(
        "preferences-general.report-issue-description",
        defaultValue: "Send a diagnostic log bundle at %@ when something goes wrong",
        comment: "General preferences setting description. %@ is the problem report destination.",
        destination
      )
    }

    static let calculating = string(
      "preferences-general.calculating",
      defaultValue: "Calculating...",
      comment: "Placeholder while a storage value is being calculated"
    )
    static let noLogs = string(
      "preferences-general.no-logs",
      defaultValue: "No logs",
      comment: "Label shown when there are no diagnostic log files"
    )
    static let defaultSaveLocation = string(
      "preferences-general.default-save-location",
      defaultValue: "Desktop/ShotPaste",
      comment: "Default export location display label"
    )
    static func accessNotGranted(_ folderName: String) -> String {
      format(
        "preferences-general.access-not-granted",
        defaultValue: "%@ (Access not granted)",
        comment: "Export folder display when bookmark access is missing. %@ is the folder name.",
        folderName
      )
    }

    static let chooseSaveLocationMessage = string(
      "preferences-general.choose-save-location-message",
      defaultValue: "Choose where ShotPaste saves captures",
      comment: "Open panel message for selecting the default export location"
    )
    static let saveHereButton = string(
      "preferences-general.save-here-button",
      defaultValue: "Save Here",
      comment: "Open panel prompt for choosing export location"
    )
  }

  enum PreferencesPermissions {
    static let setupTitle = string(
      "preferences-permissions.setup-title",
      defaultValue: "Finish setting up ShotPaste",
      comment: "Permission guide title when required access is incomplete"
    )
    static let setupDescription = string(
      "preferences-permissions.setup-description",
      defaultValue: "Complete the required items below. Optional permissions stay off until you choose to enable them.",
      comment: "Permission guide description when required access is incomplete"
    )
    static let readyTitle = string(
      "preferences-permissions.ready-title",
      defaultValue: "ShotPaste is ready to capture",
      comment: "Permission guide title when all required access is available"
    )
    static let readyDescription = string(
      "preferences-permissions.ready-description",
      defaultValue: "Required access is complete. Enable optional features whenever you need them.",
      comment: "Permission guide description when all required access is available"
    )
    static func progress(_ completed: Int, _ total: Int) -> String {
      format(
        "preferences-permissions.progress",
        defaultValue: "%d of %d required permissions ready",
        comment: "Required permission progress. First %d is completed count, second %d is total count.",
        completed,
        total
      )
    }

    static let requiredSection = string(
      "preferences-permissions.required-section",
      defaultValue: "Required to capture",
      comment: "Section title for required permissions"
    )
    static let optionalSection = string(
      "preferences-permissions.optional-section",
      defaultValue: "Optional features",
      comment: "Section title for optional permissions"
    )
    static let privacyNote = string(
      "preferences-permissions.privacy-note",
      defaultValue: "Permissions are managed by macOS and stay under your control.",
      comment: "Privacy reassurance shown at the bottom of the permission guide"
    )
    static let dragAppTitle = string(
      "preferences-permissions.drag-app-title",
      defaultValue: "Drag ShotPaste into System Settings",
      comment: "Title for the draggable app icon in permission settings"
    )
    static let dragAppDescription = string(
      "preferences-permissions.drag-app-description",
      defaultValue: "Open a permission page, then drag this icon into its app list. If macOS does not accept the drop, use the + button. You still need to turn the switch on.",
      comment: "Instructions for dragging the app into a macOS privacy permission list"
    )
    static let requestAllSystemPermissions = string(
      "preferences-permissions.request-all-system-permissions",
      defaultValue: "Request All Permissions",
      comment: "Button requesting every system-managed permission used by ShotPaste"
    )
    static let authorizationGuideTitle = string(
      "preferences-permissions.authorization-guide-title",
      defaultValue: "Complete permissions step by step",
      comment: "Title for the guided macOS permission assistant"
    )
    static let authorizationGuideDescription = string(
      "preferences-permissions.authorization-guide-description",
      defaultValue: "ShotPaste walks you through each missing permission and skips access you already granted.",
      comment: "Description for the guided macOS permission assistant"
    )
    static let authorizationAllGranted = string(
      "preferences-permissions.authorization-all-granted",
      defaultValue: "All permissions are already granted. No action is needed.",
      comment: "Toast shown when permission guidance is unnecessary"
    )
    static let authorizationComplete = string(
      "preferences-permissions.authorization-complete",
      defaultValue: "All permissions are ready.",
      comment: "Message shown when guided permission setup completes"
    )
    static func authorizationStep(_ current: Int, _ total: Int, _ permission: String) -> String {
      format(
        "preferences-permissions.authorization-step",
        defaultValue: "Step %d of %d: %@",
        comment: "Permission guide step. First %d is current, second %d is total, %@ is permission name.",
        current,
        total,
        permission
      )
    }

    static let authorizationDragInstruction = string(
      "preferences-permissions.authorization-drag-instruction",
      defaultValue: "Drag the ShotPaste icon into the highlighted app list, then turn its switch on.",
      comment: "Instruction for drag-supported macOS permission pages"
    )
    static let authorizationMicrophoneInstruction = string(
      "preferences-permissions.authorization-microphone-instruction",
      defaultValue: "Allow microphone access in the macOS permission dialog. If you denied it earlier, change it in System Settings.",
      comment: "Instruction for the native macOS microphone permission dialog"
    )
    static let authorizationOpenCurrent = string(
      "preferences-permissions.authorization-open-current",
      defaultValue: "Open Current Settings",
      comment: "Button opening the current permission settings page"
    )
    static let authorizationCheckAndContinue = string(
      "preferences-permissions.authorization-check-and-continue",
      defaultValue: "Check & Continue",
      comment: "Button checking the current permission and advancing the guide"
    )
    static let authorizationNotDetected = string(
      "preferences-permissions.authorization-not-detected",
      defaultValue: "Permission was not detected yet. Complete the highlighted step and check again.",
      comment: "Message shown when the current guided permission is still missing"
    )
    static let authorizationOpenFailed = string(
      "preferences-permissions.authorization-open-failed",
      defaultValue: "System Settings could not be opened automatically. Use the button below.",
      comment: "Fallback message when macOS permission settings do not open"
    )
    static let authorizationHighlightDrag = string(
      "preferences-permissions.authorization-highlight-drag",
      defaultValue: "Drag ShotPaste here, then turn it on",
      comment: "Label over the highlighted drag target in System Settings"
    )
    static let authorizationHighlightEnable = string(
      "preferences-permissions.authorization-highlight-enable",
      defaultValue: "Find ShotPaste here and turn it on",
      comment: "Label over the highlighted switch target in System Settings"
    )
    static let resetSystemPermissions = string(
      "preferences-permissions.reset-system-permissions",
      defaultValue: "Reset System Permissions",
      comment: "Button resetting ShotPaste system permission decisions"
    )
    static let resetConfirmationTitle = string(
      "preferences-permissions.reset-confirmation-title",
      defaultValue: "Reset ShotPaste permissions?",
      comment: "Permission reset confirmation title"
    )
    static let resetConfirmationMessage = string(
      "preferences-permissions.reset-confirmation-message",
      defaultValue: "This resets Screen Recording, Microphone, and Accessibility decisions for ShotPaste. Your save folder remains unchanged.",
      comment: "Permission reset confirmation explanation"
    )
    static let resetSucceeded = string(
      "preferences-permissions.reset-succeeded",
      defaultValue: "System permissions were reset. Request access again when you are ready.",
      comment: "Toast shown after system permissions are reset"
    )
    static let resetFailed = string(
      "preferences-permissions.reset-failed",
      defaultValue: "Some permissions could not be reset. Try again or use System Settings.",
      comment: "Toast shown when one or more permission reset commands fail"
    )
  }

  enum PreferencesQuickAccess {
    static let noItemsForKeyboardFocus = string(
      "preferences-quick-access.no-items-for-keyboard-focus",
      defaultValue: "Capture something first to use Quick Access.",
      comment: "Message shown when keyboard focus is requested without any Quick Access cards"
    )
    static let keyboardFocusHint = string(
      "preferences-quick-access.keyboard-focus-hint",
      defaultValue: "Use arrow keys or Tab to move, Return to open, ⌘C to copy, ⌘S to save, and Esc to exit.",
      comment: "Short keyboard instructions shown when Quick Access focus mode begins"
    )
    static let positionSection = string(
      "preferences-quick-access.section-position",
      defaultValue: "Position",
      comment: "Quick access preferences section title"
    )
    static let appearanceSection = string(
      "preferences-quick-access.section-appearance",
      defaultValue: "Appearance",
      comment: "Quick access preferences section title"
    )
    static let hideCardWhenWindowOpenTitle = string(
      "preferences-quick-access.hide-card-when-window-open-title",
      defaultValue: "Auto-hide Opened Items",
      comment: "Quick access preferences setting title"
    )
    static let hideCardWhenWindowOpenDescription = string(
      "preferences-quick-access.hide-card-when-window-open-description",
      defaultValue: "Temporarily hide the item from the stack when its window is open.",
      comment: "Quick access preferences setting description"
    )
    static let animationStyleTitle = string(
      "preferences-quick-access.animation-style-title",
      defaultValue: "Animation Style",
      comment: "Quick access preferences setting title"
    )
    static let animationStyleDescription = string(
      "preferences-quick-access.animation-style-description",
      defaultValue: "Choose how cards animate in and out of the stack.",
      comment: "Quick access preferences setting description"
    )
    static let animationStyleSlide = string(
      "preferences-quick-access.animation-style-slide",
      defaultValue: "Slide",
      comment: "Quick access animation style option"
    )
    static let animationStyleScale = string(
      "preferences-quick-access.animation-style-scale",
      defaultValue: "Scale & Fade",
      comment: "Quick access animation style option"
    )

    static let behaviorsSection = string(
      "preferences-quick-access.section-behaviors",
      defaultValue: "Behaviors",
      comment: "Quick access preferences section title"
    )
    static let screenEdgeTitle = string(
      "preferences-quick-access.screen-edge-title",
      defaultValue: "Screen Edge",
      comment: "Quick access preferences setting title"
    )
    static let screenEdgeDescription = string(
      "preferences-quick-access.screen-edge-description",
      defaultValue: "Where the overlay appears",
      comment: "Quick access preferences setting description"
    )
    static let left = string(
      "preferences-quick-access.left",
      defaultValue: "Left",
      comment: "Quick access side label"
    )
    static let right = string(
      "preferences-quick-access.right",
      defaultValue: "Right",
      comment: "Quick access side label"
    )
    static let overlaySizeTitle = string(
      "preferences-quick-access.overlay-size-title",
      defaultValue: "Overlay Size",
      comment: "Quick access preferences setting title"
    )
    static let overlaySizeDescription = string(
      "preferences-quick-access.overlay-size-description",
      defaultValue: "Adjust the floating preview size",
      comment: "Quick access preferences setting description"
    )
    static let floatingOverlayTitle = string(
      "preferences-quick-access.floating-overlay-title",
      defaultValue: "Floating Overlay",
      comment: "Quick access preferences setting title"
    )
    static let floatingOverlayDescription = string(
      "preferences-quick-access.floating-overlay-description",
      defaultValue: "Show preview after capture",
      comment: "Quick access preferences setting description"
    )
    static let autoCloseTitle = string(
      "preferences-quick-access.auto-close-title",
      defaultValue: "Auto-close",
      comment: "Quick access preferences setting title"
    )
    static let closeAfter = string(
      "preferences-quick-access.close-after",
      defaultValue: "Close after",
      comment: "Quick access slider label"
    )
    static let pauseOnHoverTitle = string(
      "preferences-quick-access.pause-on-hover-title",
      defaultValue: "Pause on Hover",
      comment: "Quick access preferences setting title"
    )
    static let pauseOnHoverDescription = string(
      "preferences-quick-access.pause-on-hover-description",
      defaultValue: "Pause countdown when hovering over the card",
      comment: "Quick access preferences setting description"
    )
    static let dragAndDropTitle = string(
      "preferences-quick-access.drag-and-drop-title",
      defaultValue: "Drag & Drop",
      comment: "Quick access preferences setting title"
    )
    static let dragAndDropDescription = string(
      "preferences-quick-access.drag-and-drop-description",
      defaultValue: "Drag captures to other apps",
      comment: "Quick access preferences setting description"
    )
    static let twoFingerSwipeTitle = string(
      "preferences-quick-access.two-finger-swipe-title",
      defaultValue: "Two-finger Swipe",
      comment: "Quick access preferences setting title"
    )
    static let twoFingerSwipeDescription = string(
      "preferences-quick-access.two-finger-swipe-description",
      defaultValue: "Swipe horizontally on the preview to close it",
      comment: "Quick access preferences setting description"
    )
    static let swipeSensitivityTitle = string(
      "preferences-quick-access.swipe-sensitivity-title",
      defaultValue: "Swipe Sensitivity",
      comment: "Quick access preferences setting title"
    )
    static let swipeSensitivityDescription = string(
      "preferences-quick-access.swipe-sensitivity-description",
      defaultValue: "Adjust how fast the card follows your trackpad swipe",
      comment: "Quick access preferences setting description"
    )
    static let trackpadSwipeModeTitle = string(
      "preferences-quick-access.trackpad-swipe-mode-title",
      defaultValue: "Trackpad Swipe Direction",
      comment: "Quick access trackpad swipe mode setting title"
    )
    static let trackpadSwipeModeDescription = string(
      "preferences-quick-access.trackpad-swipe-mode-description",
      defaultValue: "Choose whether the card follows your finger or moves in the opposite direction",
      comment: "Quick access trackpad swipe mode setting description"
    )
    static let trackpadSwipeModeNatural = string(
      "preferences-quick-access.trackpad-swipe-mode-natural",
      defaultValue: "Natural (follow finger)",
      comment: "Quick access trackpad swipe mode option"
    )
    static let trackpadSwipeModeInverted = string(
      "preferences-quick-access.trackpad-swipe-mode-inverted",
      defaultValue: "Inverted (follow scroll)",
      comment: "Quick access trackpad swipe mode option"
    )
    static func closesAfter(_ seconds: Int) -> String {
      format(
        "preferences-quick-access.closes-after",
        defaultValue: "Closes after %d seconds",
        comment: "Quick access auto-close description. %d is the number of seconds.",
        seconds
      )
    }

    static let keepOpenUntilDismissed = string(
      "preferences-quick-access.keep-open",
      defaultValue: "Keep overlay open until dismissed",
      comment: "Quick access description when auto-close is disabled"
    )
    static let previewSection = string(
      "preferences-quick-access.section-preview",
      defaultValue: "Preview",
      comment: "Quick access preferences section title"
    )
    static let quickActionsSection = string(
      "preferences-quick-access.section-quick-actions",
      defaultValue: "Quick Actions",
      comment: "Quick access preferences section title"
    )
    static let quickActionsDescription = string(
      "preferences-quick-access.quick-actions-description",
      defaultValue: "Drag list rows to reorder the context menu. Drag actions onto the preview to set card positions.",
      comment: "Quick access preferences quick actions helper text"
    )
    static let resetActions = string(
      "preferences-quick-access.reset-actions",
      defaultValue: "Reset Actions",
      comment: "Quick access preferences reset button title"
    )
    static let saveOrOpenAction = string(
      "preferences-quick-access.action-save-or-open",
      defaultValue: "Save / Open",
      comment: "Quick access configurable action title"
    )
    static let pinToScreenAction = string(
      "preferences-quick-access.action-pin-to-screen",
      defaultValue: "Pin to Screen",
      comment: "Quick access configurable action title"
    )
    static let unpinAction = string(
      "preferences-quick-access.action-unpin",
      defaultValue: "Unpin",
      comment: "Quick access configurable action title"
    )
    static let notOnCard = string(
      "preferences-quick-access.not-on-card",
      defaultValue: "Not on card",
      comment: "Quick access configurable action placement badge when action is not assigned to the preview card"
    )
    static let slotCenterTop = string(
      "preferences-quick-access.slot-center-top",
      defaultValue: "Center top",
      comment: "Quick access preview placement slot title"
    )
    static let slotCenterBottom = string(
      "preferences-quick-access.slot-center-bottom",
      defaultValue: "Center bottom",
      comment: "Quick access preview placement slot title"
    )
    static let slotTopRight = string(
      "preferences-quick-access.slot-top-right",
      defaultValue: "Top right",
      comment: "Quick access preview placement slot title"
    )
    static let slotTopLeft = string(
      "preferences-quick-access.slot-top-left",
      defaultValue: "Top left",
      comment: "Quick access preview placement slot title"
    )
    static let slotBottomLeft = string(
      "preferences-quick-access.slot-bottom-left",
      defaultValue: "Bottom left",
      comment: "Quick access preview placement slot title"
    )
    static let slotBottomRight = string(
      "preferences-quick-access.slot-bottom-right",
      defaultValue: "Bottom right",
      comment: "Quick access preview placement slot title"
    )
    static let swipeLeftAction = string(
      "preferences-quick-access.swipe-left-action",
      defaultValue: "Swipe Left",
      comment: "Quick access swipe direction label"
    )
    static let swipeRightAction = string(
      "preferences-quick-access.swipe-right-action",
      defaultValue: "Swipe Right",
      comment: "Quick access swipe direction label"
    )
    static let swipeActionDismiss = string(
      "preferences-quick-access.swipe-action-dismiss",
      defaultValue: "Dismiss",
      comment: "Quick access swipe action label for dismiss behavior"
    )
    static let swipeActionsDescription = string(
      "preferences-quick-access.swipe-actions-description",
      defaultValue: "Drag actions onto the circular swipe targets to choose what runs after a two-finger swipe.",
      comment: "Quick access swipe actions helper text"
    )
    static let swipeZoneResetToDismiss = string(
      "preferences-quick-access.swipe-zone-reset-to-dismiss",
      defaultValue: "Reset to Dismiss",
      comment: "Quick access swipe zone context menu reset action"
    )
    static let swipeZoneClearAction = string(
      "preferences-quick-access.swipe-zone-clear-action",
      defaultValue: "Clear Action",
      comment: "Quick access swipe zone context menu clear action"
    )
  }

  enum PreferencesCapture {
    static let appWindowsSection = string(
      "preferences-capture.section-app-windows",
      defaultValue: "App Windows",
      comment: "Capture preferences section title"
    )
    static let desktopSection = string(
      "preferences-capture.section-desktop",
      defaultValue: "Desktop",
      comment: "Capture preferences section title"
    )
    static let screenshotFormatSection = string(
      "preferences-capture.section-screenshot-format",
      defaultValue: "Format",
      comment: "Capture preferences section title"
    )
    static let scrollingCaptureSection = string(
      "preferences-capture.section-scrolling-capture",
      defaultValue: "Scrolling Capture",
      comment: "Capture preferences section title"
    )
    static let outputNamingSection = string(
      "preferences-capture.section-output-naming",
      defaultValue: "Output Naming",
      comment: "Capture preferences section title"
    )
    static let recordingFormatSection = string(
      "preferences-capture.section-recording-format",
      defaultValue: "Recording Format",
      comment: "Capture preferences section title"
    )
    static let recordingQualitySection = string(
      "preferences-capture.section-recording-quality",
      defaultValue: "Recording Quality",
      comment: "Capture preferences section title"
    )
    static let recordingBehaviorSection = string(
      "preferences-capture.section-recording-behavior",
      defaultValue: "Recording Behavior",
      comment: "Capture preferences section title"
    )
    static let recordingControlsSection = string(
      "preferences-capture.section-recording-controls",
      defaultValue: "Recording Controls",
      comment: "Capture preferences section title"
    )
    static let mouseHighlightSection = string(
      "preferences-capture.section-mouse-highlight",
      defaultValue: "Mouse Highlight",
      comment: "Capture preferences section title"
    )
    static let keystrokeOverlaySection = string(
      "preferences-capture.section-keystroke-overlay",
      defaultValue: "Keystroke Overlay",
      comment: "Capture preferences section title"
    )
    static let audioSection = string(
      "preferences-capture.section-audio",
      defaultValue: "Audio",
      comment: "Capture preferences section title"
    )
    static let afterCaptureSection = string(
      "preferences-capture.section-after-capture",
      defaultValue: "After Capture",
      comment: "Capture preferences section title"
    )

    static let includeInScreenshotsTitle = string(
      "preferences-capture.include-in-screenshots-title",
      defaultValue: "Include in Screenshots",
      comment: "Capture preferences setting title"
    )
    static let includeInScreenshotsDescription = string(
      "preferences-capture.include-in-screenshots-description",
      defaultValue: "Show ShotPaste windows such as Annotate in captured images",
      comment: "Capture preferences setting description"
    )
    static let includeInRecordingsTitle = string(
      "preferences-capture.include-in-recordings-title",
      defaultValue: "Include in Recordings",
      comment: "Capture preferences setting title"
    )
    static let includeInRecordingsDescription = string(
      "preferences-capture.include-in-recordings-description",
      defaultValue: "Show ShotPaste windows such as Annotate in recorded videos",
      comment: "Capture preferences setting description"
    )
    static let hideDesktopIconsTitle = string(
      "preferences-capture.hide-desktop-icons-title",
      defaultValue: "Hide desktop icons",
      comment: "Capture preferences setting title"
    )
    static let hideDesktopIconsDescription = string(
      "preferences-capture.hide-desktop-icons-description",
      defaultValue: "Temporarily hide icons during capture",
      comment: "Capture preferences setting description"
    )
    static let hideDesktopWidgetsTitle = string(
      "preferences-capture.hide-desktop-widgets-title",
      defaultValue: "Hide desktop widgets",
      comment: "Capture preferences setting title"
    )
    static let hideDesktopWidgetsDescription = string(
      "preferences-capture.hide-desktop-widgets-description",
      defaultValue: "Temporarily hide widgets during capture",
      comment: "Capture preferences setting description"
    )
    static let showCursorTitle = string(
      "preferences-capture.show-cursor-title",
      defaultValue: "Show cursor",
      comment: "Capture preferences setting title"
    )
    static let showCursorDescription = string(
      "preferences-capture.show-cursor-description",
      defaultValue: "Include mouse pointer in captured screenshots",
      comment: "Capture preferences setting description"
    )
    static let recordingShowCursorDescription = string(
      "preferences-capture.recording-show-cursor-description",
      defaultValue: "Include mouse pointer in recorded videos and GIFs",
      comment: "Recording preferences setting description"
    )
    static let recordingDimNonSelectedAreaTitle = string(
      "preferences-capture.recording-dim-non-selected-area-title",
      defaultValue: "Dim Non-Selected Area",
      comment: "Recording preferences setting title"
    )
    static let recordingDimNonSelectedAreaDescription = string(
      "preferences-capture.recording-dim-non-selected-area-description",
      defaultValue: "Darken everything outside the recording region while recording so the captured area stands out. Turn off to keep other windows fully visible and usable during recording.",
      comment: "Recording preferences setting description"
    )
    static let imageFormatTitle = string(
      "preferences-capture.image-format-title",
      defaultValue: "Image Format",
      comment: "Capture preferences setting title"
    )
    static let imageFormatDescription = string(
      "preferences-capture.image-format-description",
      defaultValue: "Output format for captured screenshots",
      comment: "Capture preferences setting description"
    )
    static let webpWarning = string(
      "preferences-capture.webp-warning",
      defaultValue: "WebP encoding is slower than other formats. For faster capture speed, consider using PNG or JPEG.",
      comment: "Warning shown when WebP screenshot format is selected"
    )
    static let jpegCutoutNote = string(
      "preferences-capture.jpeg-cutout-note",
      defaultValue: "Object cutout captures require transparency. ShotPaste will save them as PNG even when JPEG is selected.",
      comment: "Informational note shown when JPEG screenshot format is selected"
    )
    static let showSessionHintsTitle = string(
      "preferences-capture.show-session-hints-title",
      defaultValue: "Show Session Hints",
      comment: "Capture preferences setting title"
    )
    static let showSessionHintsDescription = string(
      "preferences-capture.show-session-hints-description",
      defaultValue: "Keep guidance visible when starting a scrolling capture session",
      comment: "Capture preferences setting description"
    )
    static let scrollingCaptureInfo = string(
      "preferences-capture.scrolling-capture-info",
      defaultValue: "Best results come from selecting only the moving content, then scrolling in one direction at a steady pace.",
      comment: "Informational note for scrolling capture preferences"
    )
    static let screenshotTemplateTitle = string(
      "preferences-capture.screenshot-template-title",
      defaultValue: "Screenshot Template",
      comment: "Capture preferences setting title"
    )
    static let screenshotTemplateDescription = string(
      "preferences-capture.screenshot-template-description",
      defaultValue: "Pattern for auto-saved screenshot filename or subfolder path",
      comment: "Capture preferences setting description"
    )
    static let recordingTemplateTitle = string(
      "preferences-capture.recording-template-title",
      defaultValue: "Recording Template",
      comment: "Capture preferences setting title"
    )
    static let recordingTemplateDescription = string(
      "preferences-capture.recording-template-description",
      defaultValue: "Pattern for auto-saved recording filename or subfolder path",
      comment: "Capture preferences setting description"
    )
    static let availableTokens = string(
      "preferences-capture.available-tokens",
      defaultValue: "Available tokens: {datetime}, {date}, {year}, {yearShort}, {month}, {monthName}, {monthShort}, {day}, {time}, {ms}, {timestamp}, {type}, {appName}. Use / to create subfolders.",
      comment: "Informational text listing available filename template tokens"
    )
    static func screenshotPreview(_ preview: String) -> String {
      format(
        "preferences-capture.screenshot-preview",
        defaultValue: "Screenshot preview: %@",
        comment: "Filename template preview label. %@ is the preview filename.",
        preview
      )
    }

    static func recordingPreview(_ preview: String) -> String {
      format(
        "preferences-capture.recording-preview",
        defaultValue: "Recording preview: %@",
        comment: "Filename template preview label. %@ is the preview filename.",
        preview
      )
    }

    static let resetNamingDefaults = string(
      "preferences-capture.reset-naming-defaults",
      defaultValue: "Reset Naming Defaults",
      comment: "Button title to reset filename templates"
    )
    static let videoFormatTitle = string(
      "preferences-capture.video-format-title",
      defaultValue: "Video Format",
      comment: "Capture preferences setting title"
    )
    static let videoFormatDescription = string(
      "preferences-capture.video-format-description",
      defaultValue: "MOV offers better quality. MP4 provides wider compatibility.",
      comment: "Capture preferences setting description"
    )
    static let frameRateTitle = string(
      "preferences-capture.frame-rate-title",
      defaultValue: "Frame Rate",
      comment: "Capture preferences setting title"
    )
    static let frameRateDescription = string(
      "preferences-capture.frame-rate-description",
      defaultValue: "Higher FPS for smoother motion",
      comment: "Capture preferences setting description"
    )
    static let hoverBarVisibleTitle = string(
      "preferences-capture.hover-bar-visible-title",
      defaultValue: "Show Floating Controls",
      comment: "Capture preferences setting title"
    )
    static let hoverBarVisibleDescription = string(
      "preferences-capture.hover-bar-visible-description",
      defaultValue: "Display controls on screen during recording. When hidden, use the menu bar icon to stop.",
      comment: "Capture preferences setting description"
    )
    static let menuBarTimeTitle = string(
      "preferences-capture.menu-bar-time-title",
      defaultValue: "Show Timer in Menu Bar",
      comment: "Capture preferences setting title"
    )
    static let menuBarTimeDescription = string(
      "preferences-capture.menu-bar-time-description",
      defaultValue: "Display elapsed duration next to the status icon.",
      comment: "Capture preferences setting description"
    )
    static let highlightSizeTitle = string(
      "preferences-capture.highlight-size-title",
      defaultValue: "Highlight Size",
      comment: "Capture preferences setting title"
    )
    static func highlightSizeDescription(_ pixels: Int) -> String {
      format(
        "preferences-capture.highlight-size-description",
        defaultValue: "Diameter of ripple effect (%dpx)",
        comment: "Mouse highlight size description. %d is the pixel size.",
        pixels
      )
    }

    static let animationDurationTitle = string(
      "preferences-capture.animation-duration-title",
      defaultValue: "Animation Duration",
      comment: "Capture preferences setting title"
    )
    static func animationDurationDescription(_ seconds: String) -> String {
      format(
        "preferences-capture.animation-duration-description",
        defaultValue: "Ripple expand speed (%@s)",
        comment: "Mouse highlight animation duration description. %@ is the formatted seconds value.",
        seconds
      )
    }

    static let rippleCountTitle = string(
      "preferences-capture.ripple-count-title",
      defaultValue: "Ripple Count",
      comment: "Capture preferences setting title"
    )
    static let rippleCountDescription = string(
      "preferences-capture.ripple-count-description",
      defaultValue: "Number of expanding rings",
      comment: "Capture preferences setting description"
    )
    static let opacityTitle = string(
      "preferences-capture.opacity-title",
      defaultValue: "Opacity",
      comment: "Capture preferences setting title"
    )
    static func opacityDescription(_ percent: Int) -> String {
      format(
        "preferences-capture.opacity-description",
        defaultValue: "Ring transparency (%d%%)",
        comment: "Mouse highlight opacity description. %d is the percentage.",
        percent
      )
    }

    static let fontSizeTitle = string(
      "preferences-capture.font-size-title",
      defaultValue: "Font Size",
      comment: "Capture preferences setting title"
    )
    static func fontSizeDescription(_ points: Int) -> String {
      format(
        "preferences-capture.font-size-description",
        defaultValue: "Badge text size (%dpt)",
        comment: "Keystroke overlay font size description. %d is the font size in points.",
        points
      )
    }

    static let positionTitle = string(
      "preferences-capture.position-title",
      defaultValue: "Position",
      comment: "Capture preferences setting title"
    )
    static let positionDescription = string(
      "preferences-capture.position-description",
      defaultValue: "Badge placement in recording area",
      comment: "Capture preferences setting description"
    )
    static let displayDurationTitle = string(
      "preferences-capture.display-duration-title",
      defaultValue: "Display Duration",
      comment: "Capture preferences setting title"
    )
    static func displayDurationDescription(_ seconds: String) -> String {
      format(
        "preferences-capture.display-duration-description",
        defaultValue: "Time before badge fades (%@s)",
        comment: "Keystroke overlay display duration description. %@ is the formatted seconds value.",
        seconds
      )
    }

    static let systemAudioTitle = string(
      "preferences-capture.system-audio-title",
      defaultValue: "System Audio",
      comment: "Capture preferences setting title"
    )
    static let systemAudioDescription = string(
      "preferences-capture.system-audio-description",
      defaultValue: "Capture sounds from apps",
      comment: "Capture preferences setting description"
    )
    static let microphoneDescription = string(
      "preferences-capture.microphone-description",
      defaultValue: "Capture your voice",
      comment: "Capture preferences setting description"
    )
    static let ocrSection = string(
      "preferences-capture.section-ocr",
      defaultValue: "OCR (Text Extraction)",
      comment: "Capture preferences section title"
    )
    static let ocrSuccessNotificationTitle = string(
      "preferences-capture.ocr-success-notification-title",
      defaultValue: "Success Notification",
      comment: "Capture preferences setting title"
    )
    static let ocrSuccessNotificationDescription = string(
      "preferences-capture.ocr-success-notification-description",
      defaultValue: "Show a toast when text is copied to clipboard",
      comment: "Capture preferences setting description"
    )
    static let ocrLinkDetectionTitle = string(
      "preferences-capture.ocr-link-detection-title",
      defaultValue: "Detect Links",
      comment: "Capture preferences setting title"
    )
    static let ocrLinkDetectionDescription = string(
      "preferences-capture.ocr-link-detection-description",
      defaultValue: "Offer to open web links found in captured text",
      comment: "Capture preferences setting description"
    )
  }

  enum PreferencesShortcuts {
    static let actionRequired = string(
      "preferences-shortcuts.action-required",
      defaultValue: "Action Required",
      comment: "Shortcuts preferences section header"
    )
    static let systemShortcuts = string(
      "preferences-shortcuts.system-shortcuts",
      defaultValue: "System Shortcuts",
      comment: "Shortcuts preferences section header"
    )
    static let systemConflictTitle = string(
      "preferences-shortcuts.system-conflict-title",
      defaultValue: "macOS screenshot shortcuts overlap with ShotPaste",
      comment: "Title for system shortcut conflict warning"
    )
    static let systemConflictDescription = string(
      "preferences-shortcuts.system-conflict-description",
      defaultValue: "Turn off the overlapping macOS shortcuts to avoid conflicts with the ShotPaste shortcuts you keep enabled.",
      comment: "Description for system shortcut conflict warning"
    )
    static let howToDisable = string(
      "preferences-shortcuts.how-to-disable",
      defaultValue: "HOW TO DISABLE",
      comment: "Caption heading for shortcut conflict resolution steps"
    )
    static let openKeyboardShortcutsSettings = string(
      "preferences-shortcuts.open-keyboard-shortcuts-settings",
      defaultValue: "Open Keyboard Shortcuts Settings",
      comment: "Button title to open macOS keyboard shortcut settings"
    )
    static let noConflictsDetected = string(
      "preferences-shortcuts.no-conflicts-detected",
      defaultValue: "No conflicts detected",
      comment: "Title for success state when there are no system shortcut conflicts"
    )
    static let noConflictsDescription = string(
      "preferences-shortcuts.no-conflicts-description",
      defaultValue: "No overlapping macOS screenshot shortcuts were found for the ShotPaste shortcuts you currently have enabled.",
      comment: "Description for success state when there are no system shortcut conflicts"
    )
    static let globalSection = string(
      "preferences-shortcuts.global-section",
      defaultValue: "Global Shortcuts",
      comment: "Shortcuts preferences section title"
    )
    static let globalSectionDescription = string(
      "preferences-shortcuts.global-section-description",
      defaultValue: "Use keyboard shortcuts to capture from anywhere.",
      comment: "Shortcuts preferences section description"
    )
    static let fnAccessibilityHint = string(
      "preferences-shortcuts.fn-accessibility-hint",
      defaultValue: "Shortcuts that use the Fn key need Accessibility permission to work from other apps.",
      comment: "Warning shown when an Fn-based shortcut is configured but Accessibility permission is missing"
    )
    static let enableShortcutsTitle = string(
      "preferences-shortcuts.enable-shortcuts-title",
      defaultValue: "Enable Shortcuts",
      comment: "Shortcuts preferences setting title"
    )
    static let enableShortcutsDescription = string(
      "preferences-shortcuts.enable-shortcuts-description",
      defaultValue: "Capture from any app",
      comment: "Shortcuts preferences setting description"
    )
    static let disableShortcutsTitle = string(
      "preferences-shortcuts.disable-shortcuts-title",
      defaultValue: "Disable Keyboard Shortcuts?",
      comment: "Alert title for disabling global shortcuts"
    )
    static let disableShortcutsMessage = string(
      "preferences-shortcuts.disable-shortcuts-message",
      defaultValue: "You won't be able to capture screenshots or recordings using keyboard shortcuts from any app. You'll need to open ShotPaste manually to use capture features.",
      comment: "Alert message for disabling global shortcuts"
    )
    static let captureSection = string(
      "preferences-shortcuts.capture-section",
      defaultValue: "Capture Shortcuts",
      comment: "Shortcuts preferences section title"
    )
    static let recordingSection = string(
      "preferences-shortcuts.recording-section",
      defaultValue: "Recording Shortcuts",
      comment: "Shortcuts preferences section title"
    )
    static let pauseResumeRecordingDescription = string(
      "preferences-shortcuts.pause-resume-recording-description",
      defaultValue: "Pause or resume an active recording. Optional. Recommended: ⌘⇧Space.",
      comment: "Description for the optional pause/resume recording shortcut"
    )
    static let togglePenRecordingDescription = string(
      "preferences-shortcuts.toggle-pen-recording-description",
      defaultValue: "Toggle drawing toolbar and overlays. Optional.",
      comment: "Description for the optional toggle pen recording shortcut"
    )
    static let restartRecordingDescription = string(
      "preferences-shortcuts.restart-recording-description",
      defaultValue: "Restart/Re-record from scratch. Optional.",
      comment: "Description for the optional restart recording shortcut"
    )
    static let deleteRecordingDescription = string(
      "preferences-shortcuts.delete-recording-description",
      defaultValue: "Delete active recording and cancel. Optional.",
      comment: "Description for the optional delete/cancel recording shortcut"
    )
    static let historySection = string(
      "preferences-shortcuts.history-section",
      defaultValue: "Clipboard History Shortcuts",
      comment: "Shortcuts preferences section title for Clipboard History browser and panels"
    )
    static let historySectionDescription = string(
      "preferences-shortcuts.history-section-description",
      defaultValue: "Manage keyboard shortcuts for the Clipboard History browser and floating mode toggle.",
      comment: "Description for the Clipboard History shortcuts section"
    )
    static let openHistoryDescription = string(
      "preferences-shortcuts.open-history-description",
      defaultValue: "Open the Clipboard History browser",
      comment: "Description for open Clipboard History shortcut"
    )
    static let setShortcut = string(
      "preferences-shortcuts.set-shortcut",
      defaultValue: "Set shortcut",
      comment: "CTA shown on an empty shortcut recorder button"
    )
    static let resetToDefaults = string(
      "preferences-shortcuts.reset-to-defaults",
      defaultValue: "Reset to Defaults",
      comment: "Button title for resetting shortcut settings"
    )
  }

  enum Microphone {
    static let accessRequiredTitle = string(
      "microphone.access-required-title",
      defaultValue: "Microphone Access Required",
      comment: "Alert title when microphone permission is missing"
    )
    static let preferencesMessage = string(
      "microphone.preferences-message",
      defaultValue: "ShotPaste needs microphone permission. Please enable it in System Settings > Privacy & Security > Microphone.",
      comment: "Alert message when microphone permission is missing from preferences or toolbar"
    )
    static let recordingMessage = string(
      "microphone.recording-message",
      defaultValue: "ShotPaste needs microphone permission to record audio. Please grant access in System Settings.",
      comment: "Alert message when microphone permission is missing while starting a recording"
    )
    static let continueWithoutMic = string(
      "microphone.continue-without-mic",
      defaultValue: "Continue Without Mic",
      comment: "Alert button title to continue recording without microphone access"
    )
  }

  enum AnnotateUI {
    static let moveSelection = string(
      "annotate.move-selection",
      defaultValue: "Move selected area (Space + mouse drag)",
      comment: "Tooltip for dragging the inline area annotate selected region"
    )
    static func fitWithShortcut(_ shortcut: String) -> String {
      format(
        "annotate.fit-with-shortcut",
        defaultValue: "Fit (%@)",
        comment: "Zoom menu item for fitting the annotated image to the canvas. %@ is the keyboard shortcut.",
        shortcut
      )
    }

    static let zoomIn = string(
      "annotate.zoom-in",
      defaultValue: "Zoom In",
      comment: "Tooltip for increasing the inline annotation canvas zoom"
    )
    static let zoomOut = string(
      "annotate.zoom-out",
      defaultValue: "Zoom Out",
      comment: "Tooltip for decreasing the inline annotation canvas zoom"
    )
    static let panCanvas = string(
      "annotate.pan-canvas",
      defaultValue: "Pan Canvas (hold Space and drag)",
      comment: "Tooltip for moving around a zoomed inline annotation canvas"
    )
    static func zoomLevel(_ percent: Int) -> String {
      format(
        "annotate.zoom-level",
        defaultValue: "Zoom: %d%%",
        comment: "Accessibility label for inline annotation canvas zoom. %d is a percentage.",
        percent
      )
    }

    static let dragToAppHelp = string(
      "annotate.drag-to-app-help",
      defaultValue: "Drag this to another app to share the annotated image",
      comment: "Tooltip shown for the annotate drag handle"
    )
    static let copyToClipboard = string(
      "annotate.copy-to-clipboard",
      defaultValue: "Copy to clipboard",
      comment: "Tooltip shown for copying the annotated image to the clipboard"
    )
    static let unsavedChangesTitle = string(
      "annotate.unsaved-changes-title",
      defaultValue: "Unsaved Changes",
      comment: "Alert title shown when closing annotate with unsaved changes"
    )
    static let unsavedChangesMessage = string(
      "annotate.unsaved-changes-message",
      defaultValue: "You have unsaved changes. Do you want to save before closing?",
      comment: "Alert message shown when closing annotate with unsaved changes"
    )
    static let dontSave = string(
      "annotate.dont-save",
      defaultValue: "Don't Save",
      comment: "Button title for discarding annotate changes"
    )
    static let saveFailedTitle = string(
      "annotate.save-failed-title",
      defaultValue: "Save Failed",
      comment: "Alert title shown when annotate save fails"
    )
    static let saveFailedMessage = string(
      "annotate.save-failed-message",
      defaultValue: "ShotPaste couldn't write to the selected location. Please choose another folder.",
      comment: "Alert message shown when annotate save fails"
    )
    static let annotation = string(
      "annotate.annotation",
      defaultValue: "Annotation",
      comment: "Section title for annotate item properties"
    )
    static let blurType = string(
      "annotate.blur-type",
      defaultValue: "Blur Type",
      comment: "Section title for annotate blur type controls"
    )
    static let pixelated = string(
      "annotate.pixelated",
      defaultValue: "Pixelated",
      comment: "Label for pixelated blur style"
    )
    static let gaussian = string(
      "annotate.gaussian",
      defaultValue: "Gaussian",
      comment: "Label for gaussian blur style"
    )
    static let hexagonal = string(
      "annotate.hexagonal",
      defaultValue: "Hexagonal",
      comment: "Label for hexagonal blur style"
    )
    static let crystallized = string(
      "annotate.crystallized",
      defaultValue: "Starry",
      comment: "Label for starry tape cover style"
    )
    static let pointillism = string(
      "annotate.pointillism",
      defaultValue: "Grid",
      comment: "Label for grid tape cover style"
    )
    static let halftone = string(
      "annotate.halftone",
      defaultValue: "Gingham",
      comment: "Label for gingham tape cover style"
    )
    static let tape = string(
      "annotate.tape",
      defaultValue: "Tape",
      comment: "Label for tape cover style"
    )
    static let washi = string(
      "annotate.washi",
      defaultValue: "Washi",
      comment: "Label for washi cover style"
    )
    static let straight = string(
      "annotate.straight",
      defaultValue: "Straight",
      comment: "Label for the straight arrow style"
    )
    static let curvedRight = string(
      "annotate.curvedRight",
      defaultValue: "Curved Right",
      comment: "Label for the curved right arrow style"
    )
    static let curvedLeft = string(
      "annotate.curvedLeft",
      defaultValue: "Curved Left",
      comment: "Label for the curved left arrow style"
    )
    static let arrowBend = string(
      "annotate.arrow-bend",
      defaultValue: "Bend",
      comment: "Label for arrow bend direction controls"
    )
    static let arrowBendNormal = string(
      "annotate.arrow-bend-normal",
      defaultValue: "Normal",
      comment: "Label for the default arrow bend direction"
    )
    static let arrowBendReversed = string(
      "annotate.arrow-bend-reversed",
      defaultValue: "Reversed",
      comment: "Label for the reversed arrow bend direction"
    )
    static let flipArrowBend = string(
      "annotate.flip-arrow-bend",
      defaultValue: "Flip bend",
      comment: "Tooltip and accessibility label for flipping arrow bend direction"
    )
    static let arrowTypeClassic = string(
      "annotate.arrow-type-classic",
      defaultValue: "Classic",
      comment: "Label for the classic line-based arrow type"
    )
    static let arrowTypeTapered = string(
      "annotate.arrow-type-tapered",
      defaultValue: "Tapered",
      comment: "Label for the tapered arrow type"
    )
    static let arrowTypeOutlined = string(
      "annotate.arrow-type-outlined",
      defaultValue: "Outlined",
      comment: "Label for the outlined tapered arrow type"
    )
    static let arrowStartHead = string(
      "annotate.arrow-start-head",
      defaultValue: "Start",
      comment: "Label for the arrow start endpoint style picker"
    )
    static let arrowEndHead = string(
      "annotate.arrow-end-head",
      defaultValue: "End",
      comment: "Label for the arrow end endpoint style picker"
    )
    static let arrowHeadNone = string(
      "annotate.arrow-head-none",
      defaultValue: "None",
      comment: "Arrow endpoint style with no decoration"
    )
    static let arrowHeadArrow = string(
      "annotate.arrow-head-arrow",
      defaultValue: "Arrow",
      comment: "Arrow endpoint style drawn as an arrowhead"
    )
    static let arrowHeadCircle = string(
      "annotate.arrow-head-circle",
      defaultValue: "Circle",
      comment: "Arrow endpoint style drawn as a filled circle"
    )
  }

  enum ScrollingCapture {
    static let autoScroll = string(
      "scrolling-capture.auto-scroll",
      defaultValue: "Auto Scroll",
      comment: "Scrolling capture HUD button title for starting automatic scrolling"
    )
    static let runtimeReady = string(
      "scrolling-capture.runtime-ready",
      defaultValue: "Ready",
      comment: "Runtime state label for scrolling capture before starting"
    )
    static let runtimeCapturing = string(
      "scrolling-capture.runtime-capturing",
      defaultValue: "Capturing",
      comment: "Runtime state label for active scrolling capture"
    )
    static let runtimeLive = string(
      "scrolling-capture.runtime-live",
      defaultValue: "Live",
      comment: "Runtime state label for live scrolling capture preview"
    )
    static let runtimeProcessing = string(
      "scrolling-capture.runtime-processing",
      defaultValue: "Processing",
      comment: "Runtime state label for processing scrolling capture frames"
    )
    static let runtimePaused = string(
      "scrolling-capture.runtime-paused",
      defaultValue: "Paused",
      comment: "Runtime state label for paused scrolling capture recovery"
    )
    static let runtimeFinishing = string(
      "scrolling-capture.runtime-finishing",
      defaultValue: "Finishing",
      comment: "Runtime state label for finalizing scrolling capture"
    )
    static let runtimeSaving = string(
      "scrolling-capture.runtime-saving",
      defaultValue: "Saving",
      comment: "Runtime state label for saving scrolling capture output"
    )
    static let badgeCaptured = string(
      "scrolling-capture.badge-captured",
      defaultValue: "Captured",
      comment: "Badge label for committed scrolling capture preview"
    )
    static let badgeLive = string(
      "scrolling-capture.badge-live",
      defaultValue: "Live",
      comment: "Badge label for live scrolling capture preview"
    )
    static let badgeSyncing = string(
      "scrolling-capture.badge-syncing",
      defaultValue: "Syncing",
      comment: "Badge label for scrolling capture preview while syncing"
    )
    static let badgePaused = string(
      "scrolling-capture.badge-paused",
      defaultValue: "Paused",
      comment: "Badge label for paused scrolling capture preview"
    )
    static let badgeFinishing = string(
      "scrolling-capture.badge-finishing",
      defaultValue: "Finishing",
      comment: "Badge label for finalizing scrolling capture preview"
    )
    static let badgeSaving = string(
      "scrolling-capture.badge-saving",
      defaultValue: "Saving",
      comment: "Badge label for saving scrolling capture preview"
    )
    static let guidanceReleaseToLockArea = string(
      "scrolling-capture.guidance-release-to-lock-area",
      defaultValue: "Release to lock area",
      comment: "Selection guidance title shown after moving or resizing the scrolling capture region"
    )
    static let guidanceKeepOnlyScrollingContent = string(
      "scrolling-capture.guidance-keep-only-scrolling-content",
      defaultValue: "Keep only the scrolling content",
      comment: "Selection guidance detail reminding users to frame only scrolling content"
    )
    static let guidanceAreaUpdated = string(
      "scrolling-capture.guidance-area-updated",
      defaultValue: "Area updated",
      comment: "Selection guidance title shown after the scrolling capture region is updated"
    )
    static let guidancePlaceMouseInsideSelection = string(
      "scrolling-capture.guidance-place-mouse-inside-selection",
      defaultValue: "Place mouse inside the capture area",
      comment: "Selection guidance title shown when auto-scroll pauses because the pointer left the capture region"
    )
    static let guidanceReturnMouseInsideSelection = string(
      "scrolling-capture.guidance-return-mouse-inside-selection",
      defaultValue: "Move the pointer back into the selection to continue auto-scrolling",
      comment: "Selection guidance detail shown when auto-scroll pauses because the pointer left the capture region"
    )
    static let guidanceFrameOnlyScrollingContent = string(
      "scrolling-capture.guidance-frame-only-scrolling-content",
      defaultValue: "Frame only the scrolling content",
      comment: "Selection guidance title shown before starting scrolling capture"
    )
    static let guidanceThenPressStartCapture = string(
      "scrolling-capture.guidance-then-press-start-capture",
      defaultValue: "Then press Start Capture",
      comment: "Selection guidance detail shown before starting scrolling capture"
    )
    static let guidanceKeepOneDirection = string(
      "scrolling-capture.guidance-keep-one-direction",
      defaultValue: "Keep one direction",
      comment: "Selection guidance title shown when scrolling direction changes"
    )
    static let guidanceReverseScrollingCanBreakStitch = string(
      "scrolling-capture.guidance-reverse-scrolling-can-break-stitch",
      defaultValue: "Reverse scrolling can break the stitch",
      comment: "Selection guidance detail shown when scrolling direction changes"
    )
    static let guidanceKeepCapturing = string(
      "scrolling-capture.guidance-keep-capturing",
      defaultValue: "Keep capturing",
      comment: "Selection guidance title shown when scrolling capture has no savable result yet"
    )
    static let guidanceThenTryDoneAgain = string(
      "scrolling-capture.guidance-then-try-done-again",
      defaultValue: "Then try Done again",
      comment: "Selection guidance detail shown when scrolling capture has no savable result yet"
    )
    static let guidanceTryDoneAgain = string(
      "scrolling-capture.guidance-try-done-again",
      defaultValue: "Try Done again",
      comment: "Selection guidance title shown when scrolling capture save failed but current result remains available"
    )
    static let guidanceCurrentResultStillReady = string(
      "scrolling-capture.guidance-current-result-still-ready",
      defaultValue: "Current result is still ready",
      comment: "Selection guidance detail shown when scrolling capture save failed but current result remains available"
    )
    static let guidanceHeightLimitReached = string(
      "scrolling-capture.guidance-height-limit-reached",
      defaultValue: "Height limit reached",
      comment: "Selection guidance title shown when scrolling capture reaches the output height limit"
    )
    static let guidancePressDoneToSave = string(
      "scrolling-capture.guidance-press-done-to-save",
      defaultValue: "Press Done to save",
      comment: "Selection guidance detail shown when the current scrolling capture result can be saved"
    )
    static let guidanceNoNewContentDetected = string(
      "scrolling-capture.guidance-no-new-content-detected",
      defaultValue: "No new content was detected",
      comment: "Selection guidance detail shown when scrolling capture reaches the end of content"
    )
    static let guidanceCurrentStitchedResultReady = string(
      "scrolling-capture.guidance-current-stitched-result-ready",
      defaultValue: "Current stitched result is ready",
      comment: "Selection guidance detail shown when scrolling capture can be saved"
    )
    static let guidanceContinueManually = string(
      "scrolling-capture.guidance-continue-manually",
      defaultValue: "Continue manually",
      comment: "Selection guidance title shown when users should keep scrolling manually"
    )
    static let guidancePressDoneWhenReady = string(
      "scrolling-capture.guidance-press-done-when-ready",
      defaultValue: "Press Done when you're ready",
      comment: "Selection guidance detail shown when users should continue scrolling manually"
    )
    static let guidanceHoldSteady = string(
      "scrolling-capture.guidance-hold-steady",
      defaultValue: "Hold steady",
      comment: "Selection guidance title shown while the first scrolling capture frame is locking"
    )
    static let guidanceShotPasteLockingFirstFrame = string(
      "scrolling-capture.guidance-shotpaste-locking-first-frame",
      defaultValue: "ShotPaste is locking the first frame",
      comment: "Selection guidance detail shown while the first scrolling capture frame is locking"
    )
    static let guidanceSlowDown = string(
      "scrolling-capture.guidance-slow-down",
      defaultValue: "Slow down",
      comment: "Selection guidance title shown when scrolling capture needs slower scrolling"
    )
    static let guidanceKeepOneDirectionSoShotPasteCanRealign = string(
      "scrolling-capture.guidance-keep-one-direction-so-shotpaste-can-realign",
      defaultValue: "Keep one direction so ShotPaste can re-align",
      comment: "Selection guidance detail shown when scrolling capture needs recovery"
    )
    static let guidanceKeepSteadierPace = string(
      "scrolling-capture.guidance-keep-steadier-pace",
      defaultValue: "Keep a steadier pace",
      comment: "Selection guidance title shown when scrolling capture cannot align a frame"
    )
    static let guidanceStayOnOneDirection = string(
      "scrolling-capture.guidance-stay-on-one-direction",
      defaultValue: "Stay on one direction",
      comment: "Selection guidance detail shown when scrolling capture cannot align a frame"
    )
    static let guidancePreviewNeedsRecovery = string(
      "scrolling-capture.guidance-preview-needs-recovery",
      defaultValue: "Preview needs recovery",
      comment: "Selection guidance title shown when scrolling capture preview refresh fails"
    )
    static let guidanceKeepOneDirectionOrRestart = string(
      "scrolling-capture.guidance-keep-one-direction-or-restart",
      defaultValue: "Keep one direction or restart",
      comment: "Selection guidance detail shown when scrolling capture preview refresh fails"
    )
    static let guidanceKeepScrollingDown = string(
      "scrolling-capture.guidance-keep-scrolling-down",
      defaultValue: "Keep scrolling down",
      comment: "Selection guidance title shown while scrolling capture waits for new content"
    )
    static let guidanceOneDirectionSteadyPace = string(
      "scrolling-capture.guidance-one-direction-steady-pace",
      defaultValue: "One direction, steady pace",
      comment: "Selection guidance detail shown while scrolling capture waits for new content"
    )
    static let guidanceScrollDownSteadily = string(
      "scrolling-capture.guidance-scroll-down-steadily",
      defaultValue: "Scroll down steadily",
      comment: "Selection guidance title shown during active scrolling capture"
    )
    static let guidanceKeepOneDirectionForCleanStitch = string(
      "scrolling-capture.guidance-keep-one-direction-for-clean-stitch",
      defaultValue: "Keep one direction for a clean stitch",
      comment: "Selection guidance detail shown during active scrolling capture"
    )
    static let guidanceSavingCurrentResult = string(
      "scrolling-capture.guidance-saving-current-result",
      defaultValue: "Saving current result",
      comment: "Selection guidance title shown while scrolling capture saves after reaching a limit"
    )
    static let guidanceLockingCurrentCapture = string(
      "scrolling-capture.guidance-locking-current-capture",
      defaultValue: "Locking current capture",
      comment: "Selection guidance title shown while scrolling capture finalizes"
    )
    static let guidanceShotPasteSealingStitchedResult = string(
      "scrolling-capture.guidance-shotpaste-sealing-stitched-result",
      defaultValue: "ShotPaste is sealing the stitched result",
      comment: "Selection guidance detail shown while scrolling capture finalizes"
    )
    static let guidanceSavingLongScreenshot = string(
      "scrolling-capture.guidance-saving-long-screenshot",
      defaultValue: "Saving long screenshot",
      comment: "Selection guidance title shown while scrolling capture saves the final image"
    )
    static let guidancePleaseWait = string(
      "scrolling-capture.guidance-please-wait",
      defaultValue: "Please wait",
      comment: "Selection guidance detail shown while scrolling capture saves the final image"
    )
    static let startCapture = string(
      "scrolling-capture.start-capture",
      defaultValue: "Start Capture",
      comment: "Primary button title for starting scrolling capture"
    )
    static let stopAutoScroll = string(
      "scrolling-capture.stop-auto-scroll",
      defaultValue: "Stop",
      comment: "Scrolling capture HUD button title for stopping automatic scrolling"
    )
    static func sectionsCaptured(_ count: Int) -> String {
      format(
        "scrolling-capture.sections-captured",
        defaultValue: "%d section(s) captured",
        comment: "Summary shown in the scrolling capture HUD. %d is the number of captured sections.",
        count
      )
    }

    static let captionStartCaptureToLockFirstFrame = string(
      "scrolling-capture.caption-start-capture-to-lock-first-frame",
      defaultValue: "Start Capture to lock the first frame",
      comment: "Preview caption shown before scrolling capture starts"
    )
    static let captionNoSavableResultReady = string(
      "scrolling-capture.caption-no-savable-result-ready",
      defaultValue: "No savable stitched result is ready yet",
      comment: "Preview caption shown when scrolling capture has no savable result yet"
    )
    static let captionSavingStitchedResult = string(
      "scrolling-capture.caption-saving-stitched-result",
      defaultValue: "Saving stitched result...",
      comment: "Preview caption shown while scrolling capture saves the stitched output"
    )
    static let captionSaveFailedResultStillReady = string(
      "scrolling-capture.caption-save-failed-result-still-ready",
      defaultValue: "Save failed • stitched result is still ready",
      comment: "Preview caption shown when scrolling capture save fails but the result remains ready"
    )
    static func framesStitchedNoNewContent(_ count: Int) -> String {
      format(
        "scrolling-capture.caption-frames-stitched-no-new-content",
        defaultValue: "%d frames stitched • no new content",
        comment: "Preview caption shown when scrolling capture reaches the end of new content. %d is the stitched frame count.",
        count
      )
    }

    static func framesStitchedHeightLimitReached(_ count: Int) -> String {
      format(
        "scrolling-capture.caption-frames-stitched-height-limit-reached",
        defaultValue: "%d frames stitched • height limit reached",
        comment: "Preview caption shown when scrolling capture reaches the height limit. %d is the stitched frame count.",
        count
      )
    }

    static let captionLivePreviewRunning = string(
      "scrolling-capture.caption-live-preview-running",
      defaultValue: "Live preview running while ShotPaste locks the stitched frame.",
      comment: "Preview caption shown while the scrolling capture live preview stream is active"
    )
    static let captionFinalizingStitchedResult = string(
      "scrolling-capture.caption-finalizing-stitched-result",
      defaultValue: "Finalizing stitched result...",
      comment: "Preview caption shown while scrolling capture finalizes"
    )
    static let captionFirstFrameLocked = string(
      "scrolling-capture.caption-first-frame-locked",
      defaultValue: "First frame locked",
      comment: "Preview caption shown after the first scrolling capture frame is locked"
    )
    static func framesStitchedDelta(_ count: Int, _ delta: Int) -> String {
      format(
        "scrolling-capture.caption-frames-stitched-delta",
        defaultValue: "%d frames stitched • +%d px",
        comment: "Preview caption shown after appending a scrolling capture frame. %d values are stitched frame count and appended pixel delta.",
        count,
        delta
      )
    }

    static func finalizingFramesLocked(_ count: Int) -> String {
      format(
        "scrolling-capture.caption-finalizing-frames-locked",
        defaultValue: "Finalizing stitched result • %d frames locked",
        comment: "Preview caption shown while finalizing a scrolling capture with locked frames. %d is the stitched frame count.",
        count
      )
    }

    static func finalFrameLocked(_ count: Int, _ delta: Int) -> String {
      format(
        "scrolling-capture.caption-final-frame-locked",
        defaultValue: "Final frame locked • %d frames • +%d px",
        comment: "Preview caption shown when the final scrolling capture frame is locked. %d values are stitched frame count and appended pixel delta.",
        count,
        delta
      )
    }

    static let captionFinalizingCurrentResultNoNewContent = string(
      "scrolling-capture.caption-finalizing-current-result-no-new-content",
      defaultValue: "Finalizing current result • no new content",
      comment: "Preview caption shown when finalizing scrolling capture with no new content"
    )
    static let captionFinalizingCurrentResultLastFrameSkipped = string(
      "scrolling-capture.caption-finalizing-current-result-last-frame-skipped",
      defaultValue: "Finalizing current stitched result • last frame skipped",
      comment: "Preview caption shown when the last scrolling capture frame could not be aligned cleanly"
    )
    static let toastNoStitchedFrameReady = string(
      "scrolling-capture.toast-no-stitched-frame-ready",
      defaultValue: "No stitched frame is ready yet.",
      comment: "Toast shown when scrolling capture cannot save because no stitched frame is ready"
    )
    static let toastSavedStitchedImage = string(
      "scrolling-capture.toast-saved-stitched-image",
      defaultValue: "Scrolling Capture saved the stitched image.",
      comment: "Toast shown after scrolling capture saves successfully"
    )
  }

  enum RecordingToolbar {
    static let preparingRecording = string(
      "recording-toolbar.preparing-recording",
      defaultValue: "Preparing recording…",
      comment: "Status shown while ShotPaste prepares the recording pipeline"
    )
    static let formatSection = string(
      "recording-toolbar.format-section",
      defaultValue: "Format",
      comment: "Recording toolbar settings section title"
    )
    static let systemAudio = string(
      "recording-toolbar.system-audio",
      defaultValue: "System Audio",
      comment: "Recording toolbar setting label"
    )
    static let microphoneInput = string(
      "recording-toolbar.microphone-input",
      defaultValue: "Microphone",
      comment: "Recording toolbar microphone input picker label"
    )
    static let showCursor = string(
      "recording-toolbar.show-cursor",
      defaultValue: "Show Cursor",
      comment: "Recording toolbar setting label"
    )
    static let stop = string(
      "recording-toolbar.stop",
      defaultValue: "Stop",
      comment: "Recording status bar stop button title"
    )
    static func stopRecordingAccessibility(_ duration: String) -> String {
      format(
        "recording-toolbar.stop-recording-accessibility",
        defaultValue: "Stop recording - Duration: %@",
        comment: "Accessibility label for stop recording button. %@ is the formatted duration.",
        duration
      )
    }

    static let stopRecordingHint = string(
      "recording-toolbar.stop-recording-hint",
      defaultValue: "Stops and saves the recording",
      comment: "Accessibility hint for stop recording button"
    )
    static func clickToStop(_ duration: String) -> String {
      format(
        "recording-toolbar.click-to-stop",
        defaultValue: "Click to stop recording (%@)",
        comment: "Menu bar tooltip when the recording controls bar is hidden. %@ is the formatted duration.",
        duration
      )
    }

    static let statusBarAccessibility = string(
      "recording-toolbar.status-bar-accessibility",
      defaultValue: "Recording status bar",
      comment: "Accessibility label for recording status bar container"
    )
    static let recordingInProgress = string(
      "recording-toolbar.recording-in-progress",
      defaultValue: "Recording in progress",
      comment: "Accessibility label for recording status indicator while active"
    )
    static let recordingPaused = string(
      "recording-toolbar.recording-paused",
      defaultValue: "Recording paused",
      comment: "Accessibility label for recording status indicator while paused"
    )
    static let resumeRecording = string(
      "recording-toolbar.resume-recording",
      defaultValue: "Resume recording",
      comment: "Accessibility label for resume recording button"
    )
    static let pauseRecording = string(
      "recording-toolbar.pause-recording",
      defaultValue: "Pause recording",
      comment: "Accessibility label for pause recording button"
    )
    static let enableAnnotations = string(
      "recording-toolbar.enable-annotations",
      defaultValue: "Enable annotations",
      comment: "Accessibility label for enabling live annotations during recording"
    )
    static let disableAnnotations = string(
      "recording-toolbar.disable-annotations",
      defaultValue: "Disable annotations",
      comment: "Accessibility label for disabling live annotations during recording"
    )
    static let restartRecording = string(
      "recording-toolbar.restart-recording",
      defaultValue: "Restart recording",
      comment: "Accessibility label for restarting a recording"
    )
    static let deleteRecording = string(
      "recording-toolbar.delete-recording",
      defaultValue: "Delete recording",
      comment: "Accessibility label for deleting a recording"
    )
    static let outputVideo = string(
      "recording-toolbar.output-video",
      defaultValue: "Video",
      comment: "Recording output mode label"
    )
    static let outputGIF = string(
      "recording-toolbar.output-gif",
      defaultValue: "GIF",
      comment: "Recording output mode label"
    )
    static let qualityHigh = string(
      "recording-toolbar.quality-high",
      defaultValue: "High",
      comment: "Recording quality preset label"
    )
    static let qualityMedium = string(
      "recording-toolbar.quality-medium",
      defaultValue: "Medium",
      comment: "Recording quality preset label"
    )
    static let qualityLow = string(
      "recording-toolbar.quality-low",
      defaultValue: "Low",
      comment: "Recording quality preset label"
    )
  }

  enum KeystrokePosition {
    static let bottomCenter = string(
      "keystroke-position.bottom-center",
      defaultValue: "Bottom Center",
      comment: "Keystroke overlay position label"
    )
    static let bottomLeft = string(
      "keystroke-position.bottom-left",
      defaultValue: "Bottom Left",
      comment: "Keystroke overlay position label"
    )
    static let bottomRight = string(
      "keystroke-position.bottom-right",
      defaultValue: "Bottom Right",
      comment: "Keystroke overlay position label"
    )
    static let topCenter = string(
      "keystroke-position.top-center",
      defaultValue: "Top Center",
      comment: "Keystroke overlay position label"
    )
    static let topLeft = string(
      "keystroke-position.top-left",
      defaultValue: "Top Left",
      comment: "Keystroke overlay position label"
    )
    static let topRight = string(
      "keystroke-position.top-right",
      defaultValue: "Top Right",
      comment: "Keystroke overlay position label"
    )
  }

  enum Recording {
    static let quitConfirmationTitle = string(
      "recording.quit-confirmation-title",
      defaultValue: "Recording in Progress",
      comment: "Alert title shown when quitting during an active recording"
    )
    static let quitConfirmationMessage = string(
      "recording.quit-confirmation-message",
      defaultValue: "Stop and save the recording before quitting, or move the current recording to Trash.",
      comment: "Alert message shown when quitting during an active recording"
    )
    static let restartConfirmationTitle = string(
      "recording.restart-confirmation-title",
      defaultValue: "Restart Recording?",
      comment: "Alert title shown before discarding the current recording and starting again"
    )
    static let restartConfirmationMessage = string(
      "recording.restart-confirmation-message",
      defaultValue: "The current recording will be moved to Trash and a new recording will start with the same settings.",
      comment: "Alert message shown before restarting an active recording"
    )
    static let deleteConfirmationTitle = string(
      "recording.delete-confirmation-title",
      defaultValue: "Delete Recording?",
      comment: "Alert title shown before deleting an active recording"
    )
    static let deleteConfirmationMessage = string(
      "recording.delete-confirmation-message",
      defaultValue: "The current recording will be moved to Trash. This cannot be undone in ShotPaste.",
      comment: "Alert message shown before deleting an active recording"
    )
    static func trashFailedPreserved(_ path: String) -> String {
      format(
        "recording.trash-failed-preserved",
        defaultValue: "The recording couldn’t be moved to Trash. It was kept at %@.",
        comment: "Error shown when a recording cannot be moved to Trash; %@ is the preserved file path",
        path
      )
    }

    static let failedTitle = string(
      "recording.failed-title",
      defaultValue: "Recording Failed",
      comment: "Alert title shown when starting or running a recording fails"
    )
    static let saveLocationAccessRequiredTitle = string(
      "recording.save-location-access-required-title",
      defaultValue: "Save Location Access Required",
      comment: "Alert title shown when save location access is missing"
    )
    static let saveLocationAccessRequiredMessage = string(
      "recording.save-location-access-required-message",
      defaultValue: "ShotPaste needs a save folder permission to continue. Please choose a save folder in Preferences → General.",
      comment: "Alert message shown when save location access is missing"
    )
    static let chooseSaveLocationMessage = string(
      "recording.choose-save-location-message",
      defaultValue: "Choose where ShotPaste should save screenshots and recordings",
      comment: "Prompt shown when asking for an export directory during recording flows"
    )
    static let screenPermissionDenied = string(
      "recording.error.screen-permission-denied",
      defaultValue: "Screen recording permission denied",
      comment: "Error description when screen recording permission is denied"
    )
    static let microphonePermissionDenied = string(
      "recording.error.microphone-permission-denied",
      defaultValue: "Microphone permission denied",
      comment: "Error description when microphone permission is denied"
    )
    static let noDisplayFound = string(
      "recording.error.no-display-found",
      defaultValue: "No display found",
      comment: "Error description when no display matches the selected recording area"
    )
    static func shareableContentLoadFailed(_ message: String) -> String {
      format(
        "recording.error.shareable-content-load-failed",
        defaultValue: "ScreenCaptureKit could not load shareable content: %@",
        comment: "Error description when ScreenCaptureKit cannot load shareable content. %@ is the underlying error message.",
        message
      )
    }

    static func setupFailed(_ message: String) -> String {
      format(
        "recording.error.setup-failed",
        defaultValue: "Setup failed: %@",
        comment: "Error description when recording setup fails. %@ is the lower-level error message.",
        message
      )
    }

    static let failedToStartWriting = string(
      "recording.error.failed-to-start-writing",
      defaultValue: "Failed to start writing",
      comment: "Error description when the asset writer fails to start"
    )
    static let noOutputURL = string(
      "recording.error.no-output-url",
      defaultValue: "No output URL",
      comment: "Error description when the recording output URL is missing"
    )
    static let cannotAddVideoWriterInput = string(
      "recording.error.cannot-add-video-writer-input",
      defaultValue: "Cannot add video writer input",
      comment: "Error description when the video writer input cannot be added"
    )
    static let cannotAddSystemAudioWriterInput = string(
      "recording.error.cannot-add-system-audio-writer-input",
      defaultValue: "Cannot add system audio writer input",
      comment: "Error description when the system audio writer input cannot be added"
    )
    static let cannotAddMicrophoneWriterInput = string(
      "recording.error.cannot-add-microphone-writer-input",
      defaultValue: "Cannot add microphone writer input",
      comment: "Error description when the microphone writer input cannot be added"
    )
    static let selectionOutsideDisplayBounds = string(
      "recording.error.selection-outside-display-bounds",
      defaultValue: "Selection area is outside display bounds",
      comment: "Error description when the selected recording area is outside the display bounds"
    )
    static func writeFailed(_ message: String) -> String {
      format(
        "recording.error.write-failed",
        defaultValue: "Write failed: %@",
        comment: "Error description when writing recording output fails. %@ is the lower-level error message.",
        message
      )
    }

    static let cancelled = string(
      "recording.error.cancelled",
      defaultValue: "Recording cancelled",
      comment: "Error description when recording is cancelled"
    )
  }

  enum CrashReport {
    static let alertTitle = string(
      "crash-report.alert-title",
      defaultValue: "Report a Problem",
      comment: "Alert title shown when presenting a problem report dialog"
    )
    static let alertMessage = string(
      "crash-report.alert-message",
      defaultValue: "ShotPaste bundled your diagnostic logs into one file. Drag the file below to the report page.",
      comment: "Alert message shown when presenting a problem report dialog with a log bundle"
    )
    static let alertMessageNoLogBundle = string(
      "crash-report.alert-message-no-log-bundle",
      defaultValue: "ShotPaste could not prepare a diagnostic log bundle. You can still open the report page and describe the problem.",
      comment: "Alert message shown when presenting a problem report dialog without a log bundle"
    )
    static let submit = string(
      "crash-report.submit",
      defaultValue: "Open Report Page",
      comment: "Primary button title for problem report alert"
    )
    static let dismiss = string(
      "crash-report.dismiss",
      defaultValue: "Close",
      comment: "Secondary button title for problem report alert"
    )
    static let accessoryHint = string(
      "crash-report.accessory-hint",
      defaultValue: "Drag log bundle to the report page",
      comment: "Hint shown below the draggable problem report log bundle"
    )
  }

  enum FileAccess {
    nonisolated static let chooseCapturesFolderMessage = string(
      "file-access.choose-captures-folder-message",
      defaultValue: "Choose where ShotPaste should save screenshots and recordings",
      comment: "Open panel message shown when ShotPaste asks the user to grant access to a save folder"
    )
    nonisolated static let grantAccessPrompt = string(
      "file-access.grant-access-prompt",
      defaultValue: "Grant Access",
      comment: "Open panel prompt shown when ShotPaste asks the user to grant folder access"
    )
    nonisolated static let chooseFolderPrompt = string(
      "file-access.choose-folder-prompt",
      defaultValue: "Choose Folder",
      comment: "Open panel prompt shown when ShotPaste asks the user to choose a folder"
    )
    static let bookmarkSaveFailedTitle = string(
      "file-access.bookmark-save-failed-title",
      defaultValue: "Folder Access Not Granted",
      comment: "Alert title when security-scoped bookmark persistence fails"
    )
    static let bookmarkSaveFailedMessage = string(
      "file-access.bookmark-save-failed-message",
      defaultValue: "ShotPaste could not persist access to this folder. Please choose the folder again and confirm permission.",
      comment: "Alert message when security-scoped bookmark persistence fails"
    )
  }

  enum AfterCapture {
    static let copyFileAction = string(
      "after-capture.copy-file-action",
      defaultValue: "Copy File",
      comment: "After capture action title"
    )
    static let saveAction = string(
      "after-capture.save-action",
      defaultValue: "Save",
      comment: "After capture action title"
    )
    static let showQuickAccessDescription = string(
      "after-capture.show-quick-access-description",
      defaultValue: "Display overlay with quick actions",
      comment: "After capture action description"
    )
    static let copyFileDescription = string(
      "after-capture.copy-file-description",
      defaultValue: "Copy to clipboard automatically",
      comment: "After capture action description"
    )
    static let saveDescription = string(
      "after-capture.save-description",
      defaultValue: "Save to export location",
      comment: "After capture action description"
    )
    static func accessibilityLabel(_ action: String, captureKind: String) -> String {
      format(
        "after-capture.accessibility-label",
        defaultValue: "%@ for %@",
        comment: "Accessibility label for after-capture action toggle. First %@ is the action label, second %@ is the capture kind.",
        action,
        captureKind
      )
    }
  }

  enum Annotate {
    static let selectionTool = string(
      "annotate.tool.selection",
      defaultValue: "Selection",
      comment: "Annotation tool display name"
    )
    static let rectangleTool = string(
      "annotate.tool.rectangle",
      defaultValue: "Rectangle",
      comment: "Annotation tool display name"
    )
    static let filledRectangleTool = string(
      "annotate.tool.filled-rectangle",
      defaultValue: "Filled Rectangle",
      comment: "Annotation tool display name"
    )
    static let ovalTool = string(
      "annotate.tool.oval",
      defaultValue: "Oval",
      comment: "Annotation tool display name"
    )
    static let arrowTool = string(
      "annotate.tool.arrow",
      defaultValue: "Arrow",
      comment: "Annotation tool display name"
    )
    static let lineTool = string(
      "annotate.tool.line",
      defaultValue: "Line",
      comment: "Annotation tool display name"
    )
    static let textTool = string(
      "annotate.tool.text",
      defaultValue: "Text",
      comment: "Annotation tool display name"
    )
    static let highlighterTool = string(
      "annotate.tool.highlighter",
      defaultValue: "Highlighter",
      comment: "Annotation tool display name"
    )
    static let blurTool = string(
      "annotate.tool.blur",
      defaultValue: "Blur",
      comment: "Annotation tool display name"
    )
    static let spotlightTool = string(
      "annotate.tool.spotlight",
      defaultValue: "Spotlight",
      comment: "Annotation tool display name"
    )
    static let counterTool = string(
      "annotate.tool.counter",
      defaultValue: "Counter",
      comment: "Annotation tool display name"
    )
    static let pencilTool = string(
      "annotate.tool.pencil",
      defaultValue: "Pencil",
      comment: "Annotation tool display name"
    )
  }

  enum QuickAccess {
    static let lockPinnedWindow = string(
      "quick-access.pin-window.lock",
      defaultValue: "Lock and hide on mouse over",
      comment: "Pinned screenshot window tooltip for enabling click-through lock mode"
    )
    static let unlockPinnedWindow = string(
      "quick-access.pin-window.unlock",
      defaultValue: "Unlock pinned window",
      comment: "Pinned screenshot window tooltip for disabling click-through lock mode"
    )
    static let zoomPinnedWindow = string(
      "quick-access.pin-window.zoom",
      defaultValue: "Zoom pinned window",
      comment: "Pinned screenshot window tooltip for the zoom menu"
    )
    static let fitPinnedWindow = string(
      "quick-access.pin-window.fit",
      defaultValue: "Fit",
      comment: "Pinned screenshot window zoom menu item that returns to fitted size"
    )
  }

  enum AnnotateContext {
    static func selected(_ toolName: String) -> String {
      format(
        "annotate-context.selected",
        defaultValue: "Selected %@",
        comment: "Quick properties title for a selected annotation. %@ is the localized tool name.",
        toolName
      )
    }

    static func defaults(_ toolName: String) -> String {
      format(
        "annotate-context.defaults",
        defaultValue: "%@ Defaults",
        comment: "Quick properties title for annotation tool defaults. %@ is the localized tool name.",
        toolName
      )
    }
  }

  enum RecordingAnnotation {
    static func autoClear(_ toolName: String) -> String {
      format(
        "recording-annotation.auto-clear",
        defaultValue: "Auto-clear: %@",
        comment: "Menu header for annotation auto-clear settings during recording. %@ is the localized tool name.",
        toolName
      )
    }

    static let persist = string(
      "recording-annotation.persist",
      defaultValue: "Persist",
      comment: "Annotation auto-clear option that keeps annotations until manually cleared"
    )
    static func lastCount(_ count: Int) -> String {
      format(
        "recording-annotation.last-count",
        defaultValue: "Last %d",
        comment: "Annotation auto-clear option that keeps the last N annotations. %d is the number of annotations to keep.",
        count
      )
    }
  }

  enum SystemShortcuts {
    static let macOSCaptureArea = string(
      "system-shortcuts.macos-capture-area",
      defaultValue: "macOS Capture Area",
      comment: "Human-readable label for the macOS system shortcut that captures a selected area"
    )
    static let macOSCopyArea = string(
      "system-shortcuts.macos-copy-area",
      defaultValue: "macOS Copy Area",
      comment: "Human-readable label for the macOS system shortcut that copies a selected area to the clipboard"
    )
    static let macOSCaptureFullscreen = string(
      "system-shortcuts.macos-capture-fullscreen",
      defaultValue: "macOS Capture Fullscreen",
      comment: "Human-readable label for the macOS system shortcut that captures the full screen"
    )
    static let macOSCopyFullscreen = string(
      "system-shortcuts.macos-copy-fullscreen",
      defaultValue: "macOS Copy Fullscreen",
      comment: "Human-readable label for the macOS system shortcut that copies the full screen to the clipboard"
    )
    static let macOSScreenshotOptions = string(
      "system-shortcuts.macos-screenshot-options",
      defaultValue: "macOS Screenshot & Recording Options",
      comment: "Human-readable label for the macOS system shortcut that opens the screenshot and recording options"
    )
  }

  enum ScreenCapture {
    static let permissionDenied = string(
      "screen-capture.permission-denied",
      defaultValue: "Screen capture permission denied",
      comment: "Error shown when screenshot capture is attempted without screen recording permission"
    )
    static let noDisplayFound = string(
      "screen-capture.no-display-found",
      defaultValue: "No display found to capture",
      comment: "Error shown when no display matches the selected screenshot target"
    )
    nonisolated static let saveLocationPermissionRequired = string(
      "screen-capture.save-location-permission-required",
      defaultValue: "Save location permission is required.",
      comment: "Error shown when ShotPaste cannot save a screenshot because folder access has not been granted"
    )
    nonisolated static let failedToCropCapturedImage = string(
      "screen-capture.failed-to-crop-captured-image",
      defaultValue: "Failed to crop the captured image",
      comment: "Error shown when ShotPaste captures an image but fails to crop it to the selected area"
    )
    nonisolated static func couldNotCreateDirectory(_ message: String) -> String {
      format(
        "screen-capture.could-not-create-directory",
        defaultValue: "Could not create the save folder: %@",
        comment: "Error shown when ShotPaste cannot create the selected save folder. %@ is the underlying filesystem error.",
        message
      )
    }

    nonisolated static let webpEncodingFailed = string(
      "screen-capture.webp-encoding-failed",
      defaultValue: "WebP encoding failed",
      comment: "Error shown when ShotPaste cannot encode a screenshot as WebP"
    )
    nonisolated static let couldNotCreateImageDestination = string(
      "screen-capture.could-not-create-image-destination",
      defaultValue: "Could not create the image destination",
      comment: "Error shown when ShotPaste cannot create an image writer for the screenshot"
    )
    nonisolated static let failedToWriteImageToDisk = string(
      "screen-capture.failed-to-write-image-to-disk",
      defaultValue: "Failed to write the image to disk",
      comment: "Error shown when ShotPaste fails while writing a screenshot to disk"
    )
    nonisolated static func fileWriteVerificationFailed(_ fileName: String) -> String {
      format(
        "screen-capture.file-write-verification-failed",
        defaultValue: "File write verification failed for %@",
        comment: "Error shown when ShotPaste writes a screenshot file but cannot verify it afterward. %@ is the file name.",
        fileName
      )
    }

    nonisolated static let selectionOutsideDisplayBounds = string(
      "screen-capture.selection-outside-display-bounds",
      defaultValue: "The selected area is outside the display bounds",
      comment: "Error shown when the screenshot selection falls outside the active display bounds"
    )
    nonisolated static let failedToCreateImageFromFrame = string(
      "screen-capture.failed-to-create-image-from-frame",
      defaultValue: "Failed to create an image from the captured frame",
      comment: "Error shown when ShotPaste cannot convert a captured stream frame into an image"
    )
    nonisolated static let captureTimedOut = string(
      "screen-capture.capture-timed-out",
      defaultValue: "Capture timed out. Please try again.",
      comment: "Error shown when the capture stream does not deliver a frame within the time limit"
    )
    static func captureFailed(_ reason: String) -> String {
      format(
        "screen-capture.capture-failed",
        defaultValue: "Capture failed: %@",
        comment: "Error shown when screenshot capture fails. %@ is the lower-level reason.",
        reason
      )
    }

    static func saveFailed(_ reason: String) -> String {
      format(
        "screen-capture.save-failed",
        defaultValue: "Failed to save screenshot: %@",
        comment: "Error shown when saving a screenshot fails. %@ is the lower-level reason.",
        reason
      )
    }

    static let cancelled = string(
      "screen-capture.cancelled",
      defaultValue: "Capture was cancelled",
      comment: "Error shown when screenshot capture is cancelled"
    )
  }

  enum OCR {
    static let imageConversionFailed = string(
      "ocr.image-conversion-failed",
      defaultValue: "Failed to convert image for OCR processing",
      comment: "Error shown when OCR cannot convert an image into a processable format"
    )
    static let noTextFound = string(
      "ocr.no-text-found",
      defaultValue: "No text found in the selected area",
      comment: "Error shown when OCR cannot detect text in the selected area"
    )
    static let qrCodesLabel = string(
      "ocr.qr-codes-label",
      defaultValue: "QR Codes",
      comment: "Clipboard section title shown before multiple QR code payloads copied from OCR capture"
    )
    static let qrTextOnlyUnsupported = string(
      "ocr.qr-text-only-unsupported",
      defaultValue: "QR code detected, but ShotPaste can only copy text-based QR content.",
      comment: "Warning shown when OCR capture detects a QR code whose content cannot be represented as text"
    )
    static func recognitionFailed(_ message: String) -> String {
      format(
        "ocr.recognition-failed",
        defaultValue: "OCR recognition failed: %@",
        comment: "Error shown when OCR recognition fails. %@ is the underlying error message.",
        message
      )
    }

    static let linkDetectedTitle = string(
      "ocr.link-detected-title",
      defaultValue: "Link detected",
      comment: "Title of the prompt shown when OCR capture finds one web link in the recognized text"
    )
    static func linksDetectedTitle(_ count: Int) -> String {
      format(
        "ocr.links-detected-title",
        defaultValue: "%d links detected",
        comment: "Title of the prompt shown when OCR capture finds multiple web links. %d is the link count.",
        count
      )
    }

    static func openLinkAccessibility(_ link: String) -> String {
      format(
        "ocr.open-link-accessibility",
        defaultValue: "Open %@",
        comment: "Accessibility label for a button that opens a web link detected in OCR text. %@ is the link.",
        link
      )
    }

    static let openAllLinks = string(
      "ocr.open-all-links",
      defaultValue: "Open All",
      comment: "Button label to open all detected OCR links at once"
    )
    static let copyLink = string(
      "ocr.copy-link",
      defaultValue: "Copy link",
      comment: "Tooltip for copying a detected web link"
    )
    static let linkCopiedToast = string(
      "ocr.link-copied-toast",
      defaultValue: "Link copied to clipboard",
      comment: "Toast message shown when a detected link is copied to the clipboard"
    )
  }

  enum GIF {
    static let invalidVideo = string(
      "gif.invalid-video",
      defaultValue: "Invalid or empty video file",
      comment: "Error shown when converting an invalid video to GIF"
    )
    static let noFramesFromVideo = string(
      "gif.no-frames-from-video",
      defaultValue: "Could not extract any frames from video",
      comment: "Error shown when converting a video to GIF but no frames can be extracted"
    )
    static let cannotCreateOutputFile = string(
      "gif.cannot-create-output-file",
      defaultValue: "Failed to create GIF output file",
      comment: "Error shown when a GIF destination file cannot be created"
    )
    static let finalizeFailed = string(
      "gif.finalize-failed",
      defaultValue: "Failed to finalize GIF file",
      comment: "Error shown when GIF generation or resizing cannot be finalized"
    )
  }

  enum CaptureStorage {
    static let empty = string(
      "capture-storage.empty",
      defaultValue: "Empty",
      comment: "Label shown when the capture cache is empty"
    )
  }

  enum ScrollingCaptureStatus {
    static let adjustRegion = string(
      "scrolling-capture-status.adjust-region",
      defaultValue: "Adjust the region so only the moving content stays inside, then press Start Capture. Press Esc to cancel.",
      comment: "Status shown before a scrolling capture starts"
    )
    static let releaseToLockUpdatedRegion = string(
      "scrolling-capture-status.release-to-lock-updated-region",
      defaultValue: "Release to lock the updated scrolling region.",
      comment: "Status shown while dragging or resizing the scrolling capture region"
    )
    static let regionUpdated = string(
      "scrolling-capture-status.region-updated",
      defaultValue: "Region updated. Keep only the moving content inside, then press Start Capture. Press Esc to cancel.",
      comment: "Status shown after updating the scrolling capture region"
    )
    static let capturingFirstFrame = string(
      "scrolling-capture-status.capturing-first-frame",
      defaultValue: "Capturing the first frame. After that, keep scrolling downward at a steady pace.",
      comment: "Status shown when the scrolling capture session starts"
    )
    static let noSavableResultReady = string(
      "scrolling-capture-status.no-savable-result-ready",
      defaultValue: "ShotPaste couldn't lock a savable stitched image yet. You can keep capturing, try Done again, or Cancel.",
      comment: "Status shown when Done is pressed before a savable stitched result exists"
    )
    static let savingStitchedImage = string(
      "scrolling-capture-status.saving-stitched-image",
      defaultValue: "Saving the stitched long image.",
      comment: "Status shown while saving a scrolling capture result"
    )
    static let saveFailedResultStillReady = string(
      "scrolling-capture-status.save-failed-result-still-ready",
      defaultValue: "Save failed. The stitched result is frozen, so you can try Done again or Cancel.",
      comment: "Status shown when saving a scrolling capture result fails but the stitched image is still available"
    )
    static let directionChanged = string(
      "scrolling-capture-status.direction-changed",
      defaultValue: "Direction changed. Keep scrolling the same way or restart the session.",
      comment: "Status shown when the user reverses scrolling direction during scrolling capture"
    )
    static let aligningLatestContent = string(
      "scrolling-capture-status.aligning-latest-content",
      defaultValue: "Capturing and aligning the latest visible content...",
      comment: "Status shown while the live preview is being aligned into the stitched result"
    )
    static let autoScrollNeedsAccessibility = string(
      "scrolling-capture-status.auto-scroll-needs-accessibility",
      defaultValue: "Auto Scroll needs Accessibility permission. Enable ShotPaste in System Settings > Privacy & Security > Accessibility.",
      comment: "Status shown when auto-scroll cannot start because Accessibility permission is missing"
    )
    static let autoScrollPausedMoveMouseInside = string(
      "scrolling-capture-status.auto-scroll-paused-move-mouse-inside",
      defaultValue: "Auto-scroll paused. Move the pointer back into the selected region to continue.",
      comment: "Status shown when auto-scroll pauses because the pointer left the selected region"
    )
    static let mixedDirectionsFinalizing = string(
      "scrolling-capture-status.mixed-directions-finalizing",
      defaultValue: "Finalizing the current stitched result after mixed scroll directions.",
      comment: "Status shown when finalizing after mixed scroll directions were detected"
    )
    static let mixedDirectionsDetected = string(
      "scrolling-capture-status.mixed-directions-detected",
      defaultValue: "Mixed scroll directions detected. Keep one direction so ShotPaste can align.",
      comment: "Status shown when mixed scroll directions are detected during scrolling capture"
    )
    static let couldntCaptureLastFrame = string(
      "scrolling-capture-status.couldnt-capture-last-frame",
      defaultValue: "Couldn't capture the last frame. ShotPaste will save the current stitched result.",
      comment: "Status shown when the final scrolling capture frame cannot be captured"
    )
    static let unableToCaptureArea = string(
      "scrolling-capture-status.unable-to-capture-area",
      defaultValue: "Unable to capture the selected area.",
      comment: "Status shown when the selected scrolling capture area cannot be captured"
    )
    static let couldntRefreshLastFrame = string(
      "scrolling-capture-status.couldnt-refresh-last-frame",
      defaultValue: "Couldn't refresh the last frame. ShotPaste will save the current stitched result.",
      comment: "Status shown when the final scrolling capture refresh fails"
    )
    static let unableToRenderPreview = string(
      "scrolling-capture-status.unable-to-render-preview",
      defaultValue: "Unable to render the stitched preview.",
      comment: "Status shown when the scrolling capture preview cannot be rendered"
    )
    static let firstFrameLocked = string(
      "scrolling-capture-status.first-frame-locked",
      defaultValue: "First frame locked. Keep the pointer over the highlighted region and scroll downward steadily.",
      comment: "Status shown after the first scrolling capture frame is locked"
    )
    static func sessionActive(_ frameCount: Int, _ outputHeight: Int) -> String {
      format(
        "scrolling-capture-status.session-active",
        defaultValue: "Session active. %d frames stitched into %d px.",
        comment: "Status shown while a scrolling capture session is actively stitching frames. First %d is the frame count, second %d is the output height in pixels.",
        frameCount,
        outputHeight
      )
    }

    static let endReachedNoNewContent = string(
      "scrolling-capture-status.end-reached-no-new-content",
      defaultValue: "No new content detected. You're probably at the end of the scrollable content. Press Done to save.",
      comment: "Status shown when the end of scrollable content is likely reached"
    )
    static let waitingForNewContent = string(
      "scrolling-capture-status.waiting-for-new-content",
      defaultValue: "Waiting for new content. Keep the scroll moving in one direction.",
      comment: "Status shown while waiting for the next scrollable content to appear"
    )
    static let alignmentPaused = string(
      "scrolling-capture-status.alignment-paused",
      defaultValue: "Alignment paused. Slow down and keep one direction so ShotPaste can recover.",
      comment: "Status shown when scrolling capture pauses to recover alignment"
    )
    static let couldntAlignFrame = string(
      "scrolling-capture-status.couldnt-align-frame",
      defaultValue: "Couldn't align that frame. Keep the same direction and a steadier pace.",
      comment: "Status shown when a scrolling capture frame cannot be aligned"
    )
    static func heightLimitReached(_ maxHeight: Int) -> String {
      format(
        "scrolling-capture-status.height-limit-reached",
        defaultValue: "Reached the %d px output limit. Press Done to save the current result.",
        comment: "Status shown when a scrolling capture reaches the output height limit. %d is the maximum output height in pixels.",
        maxHeight
      )
    }

    static let previewRefreshFailed = string(
      "scrolling-capture-status.preview-refresh-failed",
      defaultValue: "Preview refresh failed. You can Cancel and try again.",
      comment: "Status shown when a scrolling capture preview refresh fails"
    )
    static let finalizingCurrentCapture = string(
      "scrolling-capture-status.finalizing-current-capture",
      defaultValue: "Finalizing the current capture. ShotPaste is locking the latest stitched result before saving.",
      comment: "Status shown when the scrolling capture result is being finalized"
    )
    static func finalizingFrames(_ count: Int) -> String {
      format(
        "scrolling-capture-status.finalizing-frames",
        defaultValue: "Locking the current capture. ShotPaste is sealing %d stitched frames before saving.",
        comment: "Status shown while finalizing a scrolling capture with stitched frames. %d is the number of stitched frames.",
        count
      )
    }

    static let finalizingNoNewContent = string(
      "scrolling-capture-status.finalizing-no-new-content",
      defaultValue: "No new content was detected. ShotPaste is saving the current stitched result.",
      comment: "Status shown while finalizing a scrolling capture after reaching the end of content"
    )
    static let finalizingCouldntAlignLastFrame = string(
      "scrolling-capture-status.finalizing-couldnt-align-last-frame",
      defaultValue: "Couldn't align the last frame cleanly. ShotPaste will save the current stitched result.",
      comment: "Status shown while finalizing when the last frame could not be aligned"
    )
    static let finalizingHeightLimitReached = string(
      "scrolling-capture-status.finalizing-height-limit-reached",
      defaultValue: "Height limit reached. ShotPaste is saving the current stitched result.",
      comment: "Status shown while finalizing after the scrolling capture reaches the height limit"
    )
    static let readyHintToast = string(
      "scrolling-capture-status.ready-hint-toast",
      defaultValue: "Select only the moving content, press Start Capture, then keep scrolling in one direction at a steady pace.",
      comment: "Toast shown when a scrolling capture session first appears"
    )
  }

  enum AppIdentity {
    static func unexpectedBundleIdentifier(_ currentIdentifier: String) -> String {
      format(
        "app-identity.unexpected-bundle-id",
        defaultValue: "Expected bundle ID %@, found %@.",
        comment: "Identity issue message. First %@ is expected bundle identifier. Second %@ is current bundle identifier.",
        AppBundleIdentity.expected,
        currentIdentifier
      )
    }

    static let invalidSignature = string(
      "app-identity.invalid-signature",
      defaultValue: "This app bundle does not pass macOS code-signature validation.",
      comment: "Identity issue message when bundle signature validation fails"
    )

    static func outsideApplications(_ bundlePath: String) -> String {
      format(
        "app-identity.outside-applications",
        defaultValue: "Install ShotPaste in /Applications before granting permissions. Current path: %@",
        comment: "Identity issue message. %@ is the current app bundle path.",
        bundlePath
      )
    }

    static let quarantined = string(
      "app-identity.quarantined",
      defaultValue: "This app still has the macOS quarantine flag. Reinstall with the installer script or remove quarantine before granting permissions.",
      comment: "Identity issue message when app is quarantined"
    )

    static let healthy = string(
      "app-identity.healthy",
      defaultValue: "App identity is healthy.",
      comment: "Identity summary when no issues exist"
    )
  }

  enum PreferencesHistory {
    static let searchCaptures = string(
      "preferences-history.search-captures",
      defaultValue: "Search captures",
      comment: "Search field placeholder in the expanded history browser"
    )
    static let keepOpen = string(
      "preferences-history.keep-open",
      defaultValue: "Keep History Open",
      comment: "Tooltip for keeping the expanded history browser visible when it loses focus"
    )
    static let stopKeepingOpen = string(
      "preferences-history.stop-keeping-open",
      defaultValue: "Stop Keeping History Open",
      comment: "Tooltip for restoring automatic dismissal when the expanded history browser loses focus"
    )
    static let last24HoursShort = string(
      "preferences-history.last-24-hours-short",
      defaultValue: "24H",
      comment: "Compact filter title for history items from the last 24 hours"
    )
    static let last7DaysShort = string(
      "preferences-history.last-7-days-short",
      defaultValue: "7D",
      comment: "Compact filter title for history items from the last 7 days"
    )
    static let last30DaysShort = string(
      "preferences-history.last-30-days-short",
      defaultValue: "30D",
      comment: "Compact filter title for history items from the last 30 days"
    )
    static let panelPositionTitle = string(
      "preferences-history.panel-position-title",
      defaultValue: "Panel Position",
      comment: "History settings title for panel position"
    )
    static let panelPositionDescription = string(
      "preferences-history.panel-position-description",
      defaultValue: "Choose where the floating panel appears on screen",
      comment: "History settings description for panel position"
    )
    static let displaySection = string(
      "preferences-history.display-section",
      defaultValue: "Display",
      comment: "History settings section title for display options"
    )
    static let backgroundStyleTitle = string(
      "preferences-history.background-style-title",
      defaultValue: "Background Style",
      comment: "Clipboard History settings title for choosing the background style"
    )
    static let backgroundStyleDescription = string(
      "preferences-history.background-style-description",
      defaultValue: "Applies to the Clipboard History window and floating panel",
      comment: "Clipboard History settings description for choosing the background style"
    )
    static let defaultFilterTitle = string(
      "preferences-history.default-filter-title",
      defaultValue: "Default Filter",
      comment: "History settings title for default filter"
    )
    static let defaultFilterDescription = string(
      "preferences-history.default-filter-description",
      defaultValue: "Filter shown when opening the floating panel",
      comment: "History settings description for default filter"
    )
    static let defaultFilterScreenshots = string(
      "preferences-history.default-filter-screenshots",
      defaultValue: "Screenshots",
      comment: "History settings default filter option for screenshots"
    )
    static let panelSizeTitle = string(
      "preferences-history.panel-size-title",
      defaultValue: "Panel Size",
      comment: "History settings title for floating panel size"
    )
    static let panelSizeDescription = string(
      "preferences-history.panel-size-description",
      defaultValue: "Resize the floating panel and its preview cards",
      comment: "History settings description for floating panel size"
    )
    static let panelSizeSmall = string(
      "preferences-history.panel-size-small",
      defaultValue: "S",
      comment: "History settings short label for the small end of the panel size slider"
    )
    static let panelSizeLarge = string(
      "preferences-history.panel-size-large",
      defaultValue: "L",
      comment: "History settings short label for the large end of the panel size slider"
    )
    static let retentionSection = string(
      "preferences-history.retention-section",
      defaultValue: "Retention",
      comment: "History settings section title for retention"
    )
    static let retentionDaysTitle = string(
      "preferences-history.retention-days-title",
      defaultValue: "Auto-Clear After",
      comment: "History settings title for retention days"
    )
    static func deleteAfterDays(_ days: Int) -> String {
      format(
        "preferences-history.delete-after-days",
        defaultValue: "Delete captures older than %d days",
        comment: "History settings description for retention days. %d is the number of days.",
        days
      )
    }

    static let keepForever = string(
      "preferences-history.keep-forever",
      defaultValue: "Keep captures forever",
      comment: "History settings description when retention is disabled"
    )
    static let maxCountTitle = string(
      "preferences-history.max-count-title",
      defaultValue: "Max Stored Items",
      comment: "History settings title for max stored items"
    )
    static let maxCountDescription = string(
      "preferences-history.max-count-description",
      defaultValue: "Maximum number of captures stored in Clipboard History",
      comment: "Clipboard History settings description for max stored items"
    )
    static let storageSection = string(
      "preferences-history.storage-section",
      defaultValue: "Storage",
      comment: "History settings section title for storage"
    )
    static let clearHistoryTitle = string(
      "preferences-history.clear-history-title",
      defaultValue: "Clear All Clipboard History",
      comment: "Clipboard History settings title for clearing all items"
    )
    static let clearHistoryDescription = string(
      "preferences-history.clear-history-description",
      defaultValue: "Move all captures to Trash and clear Clipboard History",
      comment: "Clipboard History settings description for clearing all items"
    )
    static let clearHistoryButton = string(
      "preferences-history.clear-history-button",
      defaultValue: "Clear Clipboard History",
      comment: "Clipboard History settings button for clearing all items"
    )
    static let clearHistoryAlertTitle = string(
      "preferences-history.clear-history-alert-title",
      defaultValue: "Clear All Clipboard History?",
      comment: "Alert title when clearing Clipboard History"
    )
    static let clearHistoryAlertMessage = string(
      "preferences-history.clear-history-alert-message",
      defaultValue: "This will move all capture files to Trash and remove them from Clipboard History. This action cannot be undone in ShotPaste.",
      comment: "Alert message when clearing Clipboard History"
    )
    static let clearHistoryConfirm = string(
      "preferences-history.clear-history-confirm",
      defaultValue: "Clear",
      comment: "Confirm button for clearing history"
    )
    static func selectedCaptures(_ count: Int) -> String {
      format(
        "preferences-history.selected-captures",
        defaultValue: "%d selected",
        comment: "History browser selection count label. %d is the number of selected captures.",
        count
      )
    }

    static let selectAll = string(
      "preferences-history.select-all",
      defaultValue: "Select All",
      comment: "Button title for selecting all visible history captures"
    )
    static let clearSelection = string(
      "preferences-history.clear-selection",
      defaultValue: "Clear",
      comment: "Button title for clearing selected history captures"
    )
    static let deleteSelectedAlertTitle = string(
      "preferences-history.delete-selected-alert-title",
      defaultValue: "Delete Selected Captures?",
      comment: "Alert title when deleting selected capture history items"
    )
    static func deleteSelectedAlertMessage(_ count: Int) -> String {
      format(
        "preferences-history.delete-selected-alert-message",
        defaultValue: "Move %d selected capture item(s) to Trash and remove them from Clipboard History.",
        comment: "Alert message when deleting selected Clipboard History items. %d is the number of selected captures.",
        count
      )
    }

    static func deletedCaptures(_ count: Int) -> String {
      format(
        "preferences-history.deleted-captures",
        defaultValue: "Deleted %d capture item(s)",
        comment: "Toast shown after deleting capture history items. %d is the number of deleted captures.",
        count
      )
    }

    static func deleteFailed(_ count: Int) -> String {
      format(
        "preferences-history.delete-failed",
        defaultValue: "Could not delete %d capture item(s)",
        comment: "Toast shown when one or more capture history items could not be moved to Trash or removed. %d is the failure count.",
        count
      )
    }
  }

  enum HistoryPanelPosition {
    static let topCenter = string(
      "history-panel-position.top-center",
      defaultValue: "Top Center",
      comment: "History panel position option"
    )
    static let bottomCenter = string(
      "history-panel-position.bottom-center",
      defaultValue: "Bottom Center",
      comment: "History panel position option"
    )
    static let center = string(
      "history-panel-position.center",
      defaultValue: "Center",
      comment: "History panel position option"
    )
  }

  enum HistoryBackgroundStyle {
    static let hud = string(
      "history-background-style.hud",
      defaultValue: "HUD",
      comment: "History background style option"
    )
    static let solid = string(
      "history-background-style.solid",
      defaultValue: "Solid",
      comment: "History background style option"
    )
  }
}

// MARK: - Localized surfaces added outside the original generated groups

extension L10n.Common {
  static let automatic = L10n.string(
    "common.automatic", defaultValue: "Automatic", comment: "Generic automatic option"
  )
  static let fileMissing = L10n.string(
    "common.file-missing", defaultValue: "File missing", comment: "Placeholder when a file cannot be found"
  )
}

extension L10n.PreferencesGeneral {
  static let automationSection = L10n.string(
    "preferences-general.automation-section", defaultValue: "Automation", comment: "Automation settings section"
  )
}

extension L10n.PreferencesAdvanced {
  static let legalSection = L10n.string(
    "preferences-advanced.legal-section", defaultValue: "Legal", comment: "Legal settings section"
  )
  static let licensesTitle = L10n.string(
    "preferences-advanced.licenses-title", defaultValue: "Open Source Licenses", comment: "Open source notices title"
  )
  static let licensesDescription = L10n.string(
    "preferences-advanced.licenses-description",
    defaultValue: "Copyright, license, disclaimer, and patent notices",
    comment: "Open source notices description"
  )
  static let noticesUnavailable = L10n.string(
    "preferences-advanced.notices-unavailable",
    defaultValue: "The bundled third-party notices could not be loaded.",
    comment: "Fallback shown when bundled notices cannot be read"
  )
}

extension L10n.PreferencesHistory {
  static let mediaClipboardTitle = L10n.string(
    "preferences-history.media-clipboard-title",
    defaultValue: "Archive copied text, images, and videos",
    comment: "Clipboard archive toggle title"
  )
  static let mediaClipboardDescription = L10n.string(
    "preferences-history.media-clipboard-description",
    defaultValue: "Keep clipboard content even if its original file moves or is deleted.",
    comment: "Clipboard archive toggle description"
  )
  static let capturesFolderButton = L10n.string(
    "preferences-history.captures-folder-button", defaultValue: "Captures", comment: "Open captures folder button"
  )
  static let clipboardFolderButton = L10n.string(
    "preferences-history.clipboard-folder-button", defaultValue: "Clipboard", comment: "Open clipboard folder button"
  )
  static let noMatches = L10n.string(
    "preferences-history.no-matches", defaultValue: "No matches found", comment: "Empty search result title"
  )
  static let noScreenshots = L10n.string(
    "preferences-history.no-screenshots", defaultValue: "No screenshots yet", comment: "Empty screenshot history title"
  )
  static let noScrollingScreenshots = L10n.string(
    "preferences-history.no-scrolling-screenshots",
    defaultValue: "No scrolling screenshots yet",
    comment: "Empty scrolling screenshot history title"
  )
  static let noRecordings = L10n.string(
    "preferences-history.no-recordings", defaultValue: "No recordings yet", comment: "Empty recording history title"
  )
  static let noClipboardItems = L10n.string(
    "preferences-history.no-clipboard-items",
    defaultValue: "No clipboard items yet",
    comment: "Empty clipboard history title"
  )
  static let noCaptures = L10n.string(
    "preferences-history.no-captures", defaultValue: "No captures yet", comment: "Empty capture history title"
  )
  static let searchSuggestion = L10n.string(
    "preferences-history.search-suggestion",
    defaultValue: "Try a different search term.",
    comment: "Empty search result suggestion"
  )
  static let captureSuggestion = L10n.string(
    "preferences-history.capture-suggestion",
    defaultValue: "Take a screenshot or record your screen to see it here.",
    comment: "Empty capture history suggestion"
  )
  static let anyTime = L10n.string(
    "preferences-history.any-time", defaultValue: "Any Time", comment: "History time filter for all dates"
  )
}

extension L10n.PreferencesCapture {
  static let pixelMagnifierTitle = L10n.string(
    "preferences-capture.pixel-magnifier-title", defaultValue: "Pixel Magnifier", comment: "Screenshot setting title"
  )
  static let pixelMagnifierDescription = L10n.string(
    "preferences-capture.pixel-magnifier-description",
    defaultValue: "Show magnified pixels and color values while selecting.",
    comment: "Screenshot setting description"
  )
  static let magnifierZoomTitle = L10n.string(
    "preferences-capture.magnifier-zoom-title", defaultValue: "Initial Magnification", comment: "Magnifier zoom title"
  )
  static let magnifierZoomDescription = L10n.string(
    "preferences-capture.magnifier-zoom-description", defaultValue: "Starting magnifier zoom (1–20×)",
    comment: "Magnifier zoom description"
  )
  static let lossyQualityTitle = L10n.string(
    "preferences-capture.lossy-quality-title", defaultValue: "Lossy Quality", comment: "Image quality setting title"
  )
  static let lossyQualityDescription = L10n.string(
    "preferences-capture.lossy-quality-description", defaultValue: "JPEG and WebP quality (1–100)",
    comment: "Image quality setting description"
  )
  static let colorSpaceTitle = L10n.string(
    "preferences-capture.color-space-title", defaultValue: "Color Space", comment: "Screenshot color space title"
  )
  static let colorSpaceDescription = L10n.string(
    "preferences-capture.color-space-description",
    defaultValue: "Match the display automatically, or use sRGB or Display P3.",
    comment: "Screenshot color space description"
  )
  static let captureSuccessNotificationTitle = L10n.string(
    "preferences-capture.capture-success-notification-title",
    defaultValue: "Capture Success Notification",
    comment: "Capture notification setting title"
  )
  static let captureSuccessNotificationDescription = L10n.string(
    "preferences-capture.capture-success-notification-description",
    defaultValue: "Show a notification after a screenshot or recording is saved.",
    comment: "Capture notification setting description"
  )
  static let ocrLanguageTitle = L10n.string(
    "preferences-capture.ocr-language-title", defaultValue: "OCR Language", comment: "OCR language setting title"
  )
  static let ocrLanguageDescription = L10n.string(
    "preferences-capture.ocr-language-description",
    defaultValue: "Language profile used for text recognition.",
    comment: "OCR language setting description"
  )
  static let followAppLanguage = L10n.string(
    "preferences-capture.follow-app-language", defaultValue: "Follow App Language", comment: "OCR language option"
  )
  static let videoCodecTitle = L10n.string(
    "preferences-capture.video-codec-title", defaultValue: "Video Codec", comment: "Recording codec setting title"
  )
  static let videoCodecDescription = L10n.string(
    "preferences-capture.video-codec-description",
    defaultValue: "H.264 favors compatibility; HEVC makes smaller files when supported.",
    comment: "Recording codec setting description"
  )
  static let gifFrameRateTitle = L10n.string(
    "preferences-capture.gif-frame-rate-title", defaultValue: "GIF Frame Rate", comment: "GIF frame rate setting title"
  )
  static let gifFrameRateDescription = L10n.string(
    "preferences-capture.gif-frame-rate-description",
    defaultValue: "Frame rate used when recording to GIF.",
    comment: "GIF frame rate setting description"
  )
  static let highlightMouseClicksTitle = L10n.string(
    "preferences-capture.highlight-mouse-clicks-title",
    defaultValue: "Highlight Mouse Clicks",
    comment: "Mouse click overlay setting title"
  )
  static let highlightMouseClicksDescription = L10n.string(
    "preferences-capture.highlight-mouse-clicks-description",
    defaultValue: "Show configurable ripples for left and right clicks.",
    comment: "Mouse click overlay setting description"
  )
  static let showKeystrokesTitle = L10n.string(
    "preferences-capture.show-keystrokes-title", defaultValue: "Show Keystrokes",
    comment: "Keystroke overlay setting title"
  )
  static let showKeystrokesDescription = L10n.string(
    "preferences-capture.show-keystrokes-description",
    defaultValue: "Show selected key presses in recordings.",
    comment: "Keystroke overlay setting description"
  )
  static let leftClickColorTitle = L10n.string(
    "preferences-capture.left-click-color-title", defaultValue: "Left-Click Color",
    comment: "Left click color setting title"
  )
  static let leftClickColorDescription = L10n.string(
    "preferences-capture.left-click-color-description", defaultValue: "Color of left-click rings.",
    comment: "Left click color description"
  )
  static let rightClickColorTitle = L10n.string(
    "preferences-capture.right-click-color-title", defaultValue: "Right-Click Color",
    comment: "Right click color setting title"
  )
  static let rightClickColorDescription = L10n.string(
    "preferences-capture.right-click-color-description", defaultValue: "Color of right-click rings.",
    comment: "Right click color description"
  )
  static let visibilityRuleTitle = L10n.string(
    "preferences-capture.visibility-rule-title", defaultValue: "Visibility Rule",
    comment: "Keystroke visibility setting title"
  )
  static let visibilityRuleDescription = L10n.string(
    "preferences-capture.visibility-rule-description",
    defaultValue: "Choose which key presses appear in recordings.",
    comment: "Keystroke visibility setting description"
  )
  static let systemAudioVolumeTitle = L10n.string(
    "preferences-capture.system-audio-volume-title", defaultValue: "System Audio Volume",
    comment: "System audio volume title"
  )
  static let systemAudioVolumeDescription = L10n.string(
    "preferences-capture.system-audio-volume-description", defaultValue: "Volume applied to captured app audio.",
    comment: "System audio volume description"
  )
  static let microphoneVolumeTitle = L10n.string(
    "preferences-capture.microphone-volume-title", defaultValue: "Microphone Volume", comment: "Microphone volume title"
  )
  static let microphoneVolumeDescription = L10n.string(
    "preferences-capture.microphone-volume-description", defaultValue: "Volume applied to microphone audio.",
    comment: "Microphone volume description"
  )
  static let liveAnnotationSection = L10n.string(
    "preferences-capture.live-annotation-section", defaultValue: "Live Annotation",
    comment: "Live annotation settings section"
  )
  static let annotationDefaultColorTitle = L10n.string(
    "preferences-capture.annotation-default-color-title", defaultValue: "Default Color",
    comment: "Annotation default color title"
  )
  static let annotationDefaultColorDescription = L10n.string(
    "preferences-capture.annotation-default-color-description",
    defaultValue: "Starting color for new recording annotations.",
    comment: "Annotation default color description"
  )
  static let annotationDefaultWidthTitle = L10n.string(
    "preferences-capture.annotation-default-width-title", defaultValue: "Default Width",
    comment: "Annotation default width title"
  )
  static let annotationDefaultWidthDescription = L10n.string(
    "preferences-capture.annotation-default-width-description",
    defaultValue: "Starting stroke width for new annotations.",
    comment: "Annotation default width description"
  )
  static let annotationClearModeTitle = L10n.string(
    "preferences-capture.annotation-clear-mode-title", defaultValue: "Default Clear Mode",
    comment: "Annotation clear mode title"
  )
  static let annotationClearModeDescription = L10n.string(
    "preferences-capture.annotation-clear-mode-description",
    defaultValue: "How new annotations are removed during recording.",
    comment: "Annotation clear mode description"
  )
  static let clearModeManual = L10n.string(
    "preferences-capture.clear-mode-manual", defaultValue: "Manual", comment: "Manual annotation clear mode"
  )
  static let clearModeAfterTime = L10n.string(
    "preferences-capture.clear-mode-after-time", defaultValue: "After Time", comment: "Timed annotation clear mode"
  )
  static let clearModeMaximumCount = L10n.string(
    "preferences-capture.clear-mode-maximum-count", defaultValue: "Maximum Count",
    comment: "Count based annotation clear mode"
  )
  static let clearDelayTitle = L10n.string(
    "preferences-capture.clear-delay-title", defaultValue: "Clear Delay", comment: "Annotation clear delay title"
  )
  static let clearDelayDescription = L10n.string(
    "preferences-capture.clear-delay-description", defaultValue: "Seconds before an annotation is removed.",
    comment: "Annotation clear delay description"
  )
  static let annotationMaxCountTitle = L10n.string(
    "preferences-capture.annotation-max-count-title", defaultValue: "Maximum Count",
    comment: "Annotation maximum count title"
  )
  static let annotationMaxCountDescription = L10n.string(
    "preferences-capture.annotation-max-count-description",
    defaultValue: "Maximum annotations kept for each tool.",
    comment: "Annotation maximum count description"
  )
  static let fadeBeforeClearingTitle = L10n.string(
    "preferences-capture.fade-before-clearing-title", defaultValue: "Fade Before Clearing",
    comment: "Annotation fade toggle title"
  )
  static let fadeBeforeClearingDescription = L10n.string(
    "preferences-capture.fade-before-clearing-description",
    defaultValue: "Fade timed annotations before removing them.",
    comment: "Annotation fade toggle description"
  )
  static let fadeDurationTitle = L10n.string(
    "preferences-capture.fade-duration-title", defaultValue: "Fade Duration", comment: "Annotation fade duration title"
  )
  static let fadeDurationDescription = L10n.string(
    "preferences-capture.fade-duration-description", defaultValue: "Length of the fade animation.",
    comment: "Annotation fade duration description"
  )
  static let temporaryModifierTitle = L10n.string(
    "preferences-capture.temporary-modifier-title", defaultValue: "Temporary Modifier",
    comment: "Temporary annotation modifier title"
  )
  static let temporaryModifierDescription = L10n.string(
    "preferences-capture.temporary-modifier-description",
    defaultValue: "Hold this key while drawing to use a temporary clear mode.",
    comment: "Temporary annotation modifier description"
  )
  static let temporaryClearModeTitle = L10n.string(
    "preferences-capture.temporary-clear-mode-title", defaultValue: "Temporary Clear Mode",
    comment: "Temporary clear mode title"
  )
  static let temporaryClearModeDescription = L10n.string(
    "preferences-capture.temporary-clear-mode-description",
    defaultValue: "Clear mode used only while the modifier is held.",
    comment: "Temporary clear mode description"
  )
}

extension L10n.Recording {
  nonisolated static let keystrokeVisibilityAll = L10n.string(
    "recording.keystroke-visibility-all", defaultValue: "All Keys", comment: "Keystroke visibility option"
  )
  nonisolated static let keystrokeVisibilitySpecialAndShortcuts = L10n.string(
    "recording.keystroke-visibility-special-and-shortcuts",
    defaultValue: "Special Keys and Shortcuts",
    comment: "Keystroke visibility option"
  )
  nonisolated static let keystrokeVisibilityShortcutsOnly = L10n.string(
    "recording.keystroke-visibility-shortcuts-only", defaultValue: "Shortcuts Only",
    comment: "Keystroke visibility option"
  )
  nonisolated static let keystrokeVisibilitySpecialOnly = L10n.string(
    "recording.keystroke-visibility-special-only", defaultValue: "Special Keys Only",
    comment: "Keystroke visibility option"
  )
}

extension L10n.AnnotateUI {}

extension L10n.ShortcutOverlay {
  static let spaceKey = L10n.string(
    "shortcut-overlay.space-key", defaultValue: "Space", comment: "Space bar key label"
  )
}
