//
//  L10n.swift
//  LiteScreen
//
//  Small localization helper for AppKit and shared string surfaces.
//

import Foundation

nonisolated enum L10n {
  private nonisolated static let tableMappings: [(prefix: String, tableName: String)] = [
    ("action.", "Common"),
    ("combine.", "Combine"),
    ("menu.", "Menubar"),
    ("common.", "Common"),
    ("whats-new.", "WhatsNew"),
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
    ("foreground-cutout.", "Capture"),
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
    static let backupSection = string(
      "preferences-advanced.backup-section",
      defaultValue: "Backup",
      comment: "Advanced preferences backup section title"
    )
    static let integrationSection = string(
      "preferences-advanced.section-integration",
      defaultValue: "Integration",
      comment: "Advanced preferences integration section title"
    )
    static let urlSchemeTitle = string(
      "preferences-advanced.url-scheme-title",
      defaultValue: "URL Scheme integration",
      comment: "Advanced preferences setting title"
    )
    static let urlSchemeDescription = string(
      "preferences-advanced.url-scheme-description",
      defaultValue: "Allow external triggers via litescreen:// URLs",
      comment: "Advanced preferences setting description"
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
    static let exportTitle = string(
      "preferences-advanced.export-title",
      defaultValue: "Export backup",
      comment: "Advanced preferences export row title"
    )
    static let exportDescription = string(
      "preferences-advanced.export-description",
      defaultValue: "Save portable copy",
      comment: "Advanced preferences export row description"
    )
    static let importTitle = string(
      "preferences-advanced.import-title",
      defaultValue: "Import backup",
      comment: "Advanced preferences import row title"
    )
    static let importDescription = string(
      "preferences-advanced.import-description",
      defaultValue: "Replace from .toml file",
      comment: "Advanced preferences import row description"
    )
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
    static let exportButton = string(
      "preferences-advanced.export-button",
      defaultValue: "Export",
      comment: "Export config button"
    )
    static let importButton = string(
      "preferences-advanced.import-button",
      defaultValue: "Import",
      comment: "Import config button"
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
    static let openConfigButton = string(
      "preferences-advanced.open-config-button",
      defaultValue: "Open config.toml",
      comment: "Open TOML config file button"
    )
    static let configSyncStatusTitle = string(
      "preferences-advanced.config-sync-status-title",
      defaultValue: "config.toml sync",
      comment: "Settings row title for config.toml background sync status"
    )
    static let syncNowButton = string(
      "preferences-advanced.sync-now-button",
      defaultValue: "Sync Now",
      comment: "Button title for manually syncing current settings into config.toml"
    )
    static let configSyncBadgeSynced = string(
      "preferences-advanced.config-sync-badge-synced",
      defaultValue: "Synced",
      comment: "Badge label when config.toml matches current settings"
    )
    static let configSyncBadgeQueued = string(
      "preferences-advanced.config-sync-badge-queued",
      defaultValue: "Queued",
      comment: "Badge label when config.toml sync is queued"
    )
    static let configSyncBadgeSyncing = string(
      "preferences-advanced.config-sync-badge-syncing",
      defaultValue: "Syncing",
      comment: "Badge label while config.toml is syncing"
    )
    static let configSyncBadgeAccessNeeded = string(
      "preferences-advanced.config-sync-badge-access-needed",
      defaultValue: "Access Needed",
      comment: "Badge label when config folder access is required before syncing config.toml"
    )
    static let configSyncBadgeReviewNeeded = string(
      "preferences-advanced.config-sync-badge-review-needed",
      defaultValue: "Review Needed",
      comment: "Badge label when config.toml has external changes that need user review"
    )
    static let configSyncBadgeFailed = string(
      "preferences-advanced.config-sync-badge-failed",
      defaultValue: "Failed",
      comment: "Badge label when config.toml sync failed"
    )
    static let configSyncIdleDescription = string(
      "preferences-advanced.config-sync-idle-description",
      defaultValue: "Current settings will sync to config.toml automatically.",
      comment: "Config sync row description before the first sync result is available"
    )
    static let configSyncQueuedDescription = string(
      "preferences-advanced.config-sync-queued-description",
      defaultValue: "Sync queued. Lite Screen will update config.toml shortly.",
      comment: "Config sync row description when sync is queued"
    )
    static let configSyncWritingDescription = string(
      "preferences-advanced.config-sync-writing-description",
      defaultValue: "Writing current settings to config.toml.",
      comment: "Config sync row description while sync is writing config.toml"
    )
    static func configSyncUpToDateDescription(_ time: String) -> String {
      format(
        "preferences-advanced.config-sync-up-to-date-description",
        defaultValue: "config.toml already matches current settings. Last checked at %@.",
        comment: "Config sync row description when config.toml was already current. %@ is a localized time.",
        time
      )
    }

    static func configSyncSyncedDescription(_ time: String) -> String {
      format(
        "preferences-advanced.config-sync-synced-description",
        defaultValue: "config.toml updated from current settings at %@.",
        comment: "Config sync row description after config.toml is written. %@ is a localized time.",
        time
      )
    }

    static let configAccessWarningTitle = string(
      "preferences-advanced.config-access-warning-title",
      defaultValue: "Config folder access needed",
      comment: "Warning title when Lite Screen has not been granted config folder access"
    )
    static func configAccessWarningDescription(_ path: String) -> String {
      format(
        "preferences-advanced.config-access-warning-description",
        defaultValue: "Grant access to %@ once so Lite Screen can create config.toml and apply direct edits on launch.",
        comment: "Warning description when config folder access is missing. %@ is the expected config directory path.",
        path
      )
    }

    static let grantConfigAccessButton = string(
      "preferences-advanced.grant-config-access-button",
      defaultValue: "Grant Access",
      comment: "Button title to grant config folder access"
    )
    static let configAccessRequiredToast = string(
      "preferences-advanced.config-access-required-toast",
      defaultValue: "Grant config folder access first.",
      comment: "Toast shown when a config backup action requires folder access first"
    )
    static let configAccessReady = string(
      "preferences-advanced.config-access-ready",
      defaultValue: "config.toml is ready.",
      comment: "Toast shown after config folder access is granted"
    )
    static let exportSucceeded = string(
      "preferences-advanced.export-succeeded",
      defaultValue: "Config backup exported.",
      comment: "Toast shown after config export succeeds"
    )
    static let openConfigSucceeded = string(
      "preferences-advanced.open-config-succeeded",
      defaultValue: "config.toml opened.",
      comment: "Toast shown after config.toml is opened"
    )
    static let configSyncing = string(
      "preferences-advanced.config-syncing",
      defaultValue: "Syncing config.toml...",
      comment: "Toast shown while Lite Screen syncs current settings into config.toml"
    )
    static let configSynced = string(
      "preferences-advanced.config-synced",
      defaultValue: "config.toml synced.",
      comment: "Toast shown after Lite Screen syncs current settings into config.toml"
    )
    static let configSyncNeedsConfirmation = string(
      "preferences-advanced.config-sync-needs-confirmation",
      defaultValue: "config.toml has external changes.",
      comment: "Toast shown when Lite Screen needs confirmation before replacing externally changed config.toml"
    )
    static let configSyncConfirmationTitle = string(
      "preferences-advanced.config-sync-confirmation-title",
      defaultValue: "Sync config.toml?",
      comment: "Confirmation alert title before replacing a config file with external changes"
    )
    static let configSyncConfirmationMessage = string(
      "preferences-advanced.config-sync-confirmation-message",
      defaultValue: "config.toml no longer matches Lite Screen settings and may have edits from outside the app. Syncing will replace it with current settings.",
      comment: "Confirmation alert message before replacing a config file with external changes"
    )
    static let syncConfigConfirmButton = string(
      "preferences-advanced.sync-config-confirm-button",
      defaultValue: "Sync & Open",
      comment: "Confirmation button that replaces config.toml with current settings and opens it"
    )
    static let openExistingConfigButton = string(
      "preferences-advanced.open-existing-config-button",
      defaultValue: "Open Existing",
      comment: "Confirmation button that opens config.toml without syncing current settings"
    )
    static let importSucceeded = string(
      "preferences-advanced.import-succeeded",
      defaultValue: "Backup imported and config.toml replaced.",
      comment: "Toast shown after a backup import replaces the managed config file"
    )
    static let restoreDefaultsSucceeded = string(
      "preferences-advanced.restore-defaults-succeeded",
      defaultValue: "Defaults restored.",
      comment: "Toast shown after settings are restored to defaults"
    )
    static let operationFinished = string(
      "preferences-advanced.operation-finished",
      defaultValue: "Done.",
      comment: "Fallback toast when a config backup operation completes"
    )
    static let openConfigUnavailable = string(
      "preferences-advanced.open-config-unavailable",
      defaultValue: "Could not open config.toml.",
      comment: "Open config file unavailable result message"
    )
    static let exportPanelTitle = string(
      "preferences-advanced.export-panel-title",
      defaultValue: "Export Lite Screen Config",
      comment: "Config export save panel title"
    )
    static let importPanelTitle = string(
      "preferences-advanced.import-panel-title",
      defaultValue: "Import Lite Screen Config",
      comment: "Config import open panel title"
    )
    static func exported(_ path: String) -> String {
      format(
        "preferences-advanced.exported",
        defaultValue: "Exported config to %@",
        comment: "Config export success message",
        path
      )
    }

    static func openedConfig(_ path: String) -> String {
      format(
        "preferences-advanced.opened-config",
        defaultValue: "Opened config.toml from %@",
        comment: "Config file opened success message",
        path
      )
    }

    static func configAccessGranted(_ path: String) -> String {
      format(
        "preferences-advanced.config-access-granted",
        defaultValue: "Config folder access granted. config.toml is ready at %@",
        comment: "Config folder access success message. %@ is the config file path.",
        path
      )
    }

    static func openConfigMissing(_ path: String) -> String {
      format(
        "preferences-advanced.open-config-missing",
        defaultValue: "No config file exists at %@. Export a backup first, then open it here.",
        comment: "Config file missing warning message",
        path
      )
    }

    static func openConfigFailed(_ path: String) -> String {
      format(
        "preferences-advanced.open-config-failed",
        defaultValue: "macOS could not open %@.",
        comment: "Config file open failure message",
        path
      )
    }

    static let exportFailed = string(
      "preferences-advanced.export-failed",
      defaultValue: "Config export failed.",
      comment: "Config export failure message"
    )
    static let importFailed = string(
      "preferences-advanced.import-failed",
      defaultValue: "Config import failed.",
      comment: "Config import failure message"
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
      defaultValue: "If you confirm, Lite Screen will replace config.toml with default values and reset app settings. Saved captures are not deleted.",
      comment: "Restore defaults confirmation alert message"
    )
    static func importFailedWithErrors(_ count: Int) -> String {
      format(
        "preferences-advanced.import-failed-with-errors",
        defaultValue: "Config import failed with %d error(s).",
        comment: "Config import validation error summary",
        count
      )
    }

    static func imported(_ count: Int) -> String {
      format(
        "preferences-advanced.imported",
        defaultValue: "Imported %d config setting(s).",
        comment: "Config import success summary",
        count
      )
    }

    static func importedWithWarnings(_ count: Int, _ warningCount: Int) -> String {
      format(
        "preferences-advanced.imported-with-warnings",
        defaultValue: "Imported %d config setting(s) with %d warning(s).",
        comment: "Config import success with warnings summary",
        count,
        warningCount
      )
    }
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
      defaultValue: "Grant Permission...",
      comment: "Status bar menu item title to request missing permissions"
    )
    static let preferences = string(
      "menu.preferences",
      defaultValue: "Preferences...",
      comment: "Status bar menu item title for opening preferences"
    )
    static let quitLiteScreen = string(
      "menu.quit-litescreen",
      defaultValue: "Quit Lite Screen",
      comment: "Status bar menu item title for quitting the app"
    )
  }

  enum Combine {
    static let mode = string("combine.mode", defaultValue: "Combine mode", comment: "Label for combine mode picker")
    static let autoStitch = string(
      "combine.auto-stitch",
      defaultValue: "Auto Stitch",
      comment: "Automatic image stitching mode"
    )
    static let freeCanvas = string(
      "combine.free-canvas",
      defaultValue: "Free Canvas",
      comment: "Free image arrangement mode"
    )
    static let arrangement = string(
      "combine.arrangement",
      defaultValue: "Arrangement",
      comment: "Combine arrangement section title"
    )
    static let spacing = string("combine.spacing", defaultValue: "Spacing", comment: "Combine spacing section title")
    static let imageGap = string("combine.image-gap", defaultValue: "Image Gap", comment: "Gap between combined images")
    static let images = string("combine.images", defaultValue: "Images", comment: "Combined image list title")
    static func image(_ index: Int) -> String {
      format("combine.image-index", defaultValue: "Image %d", comment: "Combined image list item", index)
    }

    static let moveEarlier = string(
      "combine.move-earlier",
      defaultValue: "Move Earlier",
      comment: "Move combined image earlier"
    )
    static let moveLater = string(
      "combine.move-later",
      defaultValue: "Move Later",
      comment: "Move combined image later"
    )
    static let smart = string("combine.smart", defaultValue: "Smart", comment: "Smart combine direction")
    static let horizontal = string(
      "combine.horizontal",
      defaultValue: "Horizontal",
      comment: "Horizontal combine direction"
    )
    static let vertical = string("combine.vertical", defaultValue: "Vertical", comment: "Vertical combine direction")
    static let open = string("combine.open", defaultValue: "Combine Images", comment: "Open combine images action")
    static let pickerTitle = string(
      "combine.picker-title",
      defaultValue: "Choose Images to Combine",
      comment: "Combine image picker title"
    )
    static let pickerMessage = string(
      "combine.picker-message",
      defaultValue: "Select two or more images.",
      comment: "Combine image picker message"
    )
    static let pickerConfirm = string(
      "combine.picker-confirm",
      defaultValue: "Combine",
      comment: "Combine image picker confirmation"
    )
    static let saveTitle = string(
      "combine.save-title",
      defaultValue: "Save Combined Image",
      comment: "Combine save dialog title"
    )
    static let saveMessage = string(
      "combine.save-message",
      defaultValue: "Choose how to export the stitched result.",
      comment: "Combine save dialog message"
    )
    static let saveToFile = string(
      "combine.save-to-file",
      defaultValue: "Save to File…",
      comment: "Save combined image to file"
    )
    static let copyToClipboard = string(
      "combine.copy-to-clipboard",
      defaultValue: "Copy to Clipboard",
      comment: "Copy combined image to clipboard"
    )
  }

  enum Common {
    static let tryItOut = string(
      "common.try-it-out",
      defaultValue: "Try It Out",
      comment: "Try it out button title"
    )
    static let next = string(
      "common.next",
      defaultValue: "Next",
      comment: "Primary next action button title"
    )
    static let continueAction = string(
      "common.continue",
      defaultValue: "Continue",
      comment: "Generic continue button title"
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
    static let width = string(
      "common.width",
      defaultValue: "Width",
      comment: "Generic label for width"
    )
    static let height = string(
      "common.height",
      defaultValue: "Height",
      comment: "Generic label for height"
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
    static let importAction = string(
      "common.import",
      defaultValue: "Import",
      comment: "Generic import button title"
    )
    static let exportAction = string(
      "common.export",
      defaultValue: "Export",
      comment: "Generic export button title"
    )
    static let share = string(
      "common.share",
      defaultValue: "Share",
      comment: "Generic share button title"
    )
    static let saveAs = string(
      "common.save-as",
      defaultValue: "Save as...",
      comment: "Generic save as button title"
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
    static let more = string(
      "common.more",
      defaultValue: "More",
      comment: "Generic more button title"
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
    static let apply = string(
      "common.apply",
      defaultValue: "Apply",
      comment: "Generic apply button title"
    )
    static let deleteAction = string(
      "common.delete",
      defaultValue: "Delete",
      comment: "Generic delete button title"
    )
    static let overwrite = string(
      "common.overwrite",
      defaultValue: "Overwrite",
      comment: "Generic overwrite button title"
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
    static let restore = string(
      "common.restore",
      defaultValue: "Restore",
      comment: "Generic restore button title"
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
    static let renameFile = string(
      "common.rename-file",
      defaultValue: "Rename file",
      comment: "Generic tooltip or label for renaming a file"
    )
    static let preview = string(
      "common.preview",
      defaultValue: "Preview",
      comment: "Generic preview section title"
    )
    static let file = string(
      "common.file",
      defaultValue: "File",
      comment: "Generic file section title"
    )
    static let name = string(
      "common.name",
      defaultValue: "Name",
      comment: "Generic name field label"
    )
    static let path = string(
      "common.path",
      defaultValue: "Path",
      comment: "Generic path field label"
    )
    static let size = string(
      "common.size",
      defaultValue: "Size",
      comment: "Generic size field label"
    )
    static let format = string(
      "common.format",
      defaultValue: "Format",
      comment: "Generic format field label"
    )
    static let resolution = string(
      "common.resolution",
      defaultValue: "Resolution",
      comment: "Generic resolution field label"
    )
    static let aspectRatio = string(
      "common.aspect-ratio",
      defaultValue: "Aspect Ratio",
      comment: "Generic aspect ratio field label"
    )
    static let duration = string(
      "common.duration",
      defaultValue: "Duration",
      comment: "Generic duration field label"
    )
    static let created = string(
      "common.created",
      defaultValue: "Created",
      comment: "Generic created date field label"
    )
    static let modified = string(
      "common.modified",
      defaultValue: "Modified",
      comment: "Generic modified date field label"
    )
    static let status = string(
      "common.status",
      defaultValue: "Status",
      comment: "Generic status field label"
    )
    static let currentSize = string(
      "common.current-size",
      defaultValue: "Current Size",
      comment: "Generic current file size label"
    )
    static let estimated = string(
      "common.estimated",
      defaultValue: "Estimated",
      comment: "Generic estimated value label"
    )
    static let estimatedSize = string(
      "common.estimated-size",
      defaultValue: "Estimated Size",
      comment: "Generic estimated file size label"
    )
    static let quality = string(
      "common.quality",
      defaultValue: "Quality",
      comment: "Generic quality section title"
    )
    static let dimensions = string(
      "common.dimensions",
      defaultValue: "Dimensions",
      comment: "Generic dimensions section title"
    )
    static let audio = string(
      "common.audio",
      defaultValue: "Audio",
      comment: "Generic audio section title"
    )
    static let video = string(
      "common.video",
      defaultValue: "Video",
      comment: "Generic video section title"
    )
    static let background = string(
      "common.background",
      defaultValue: "Background",
      comment: "Generic background section title"
    )
    static let colors = string(
      "common.colors",
      defaultValue: "Colors",
      comment: "Generic colors section title"
    )
    static let gradients = string(
      "common.gradients",
      defaultValue: "Gradients",
      comment: "Generic gradients section title"
    )
    static let padding = string(
      "common.padding",
      defaultValue: "Padding",
      comment: "Generic padding setting label"
    )
    static let inset = string(
      "common.inset",
      defaultValue: "Inset",
      comment: "Generic inset setting label"
    )
    static let shadow = string(
      "common.shadow",
      defaultValue: "Shadow",
      comment: "Generic shadow setting label"
    )
    static let corners = string(
      "common.corners",
      defaultValue: "Corners",
      comment: "Generic corners setting label"
    )
    static let rotation = string(
      "common.rotation",
      defaultValue: "Rotation",
      comment: "Generic rotation section title"
    )
    static let perspective = string(
      "common.perspective",
      defaultValue: "Perspective",
      comment: "Generic perspective section title"
    )
    static let style = string(
      "common.style",
      defaultValue: "Style",
      comment: "Generic style setting label"
    )
    static let fill = string(
      "common.fill",
      defaultValue: "Fill",
      comment: "Generic fill setting label"
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
    static let solid = string(
      "common.solid",
      defaultValue: "Solid",
      comment: "Generic solid color label"
    )
    static let free = string(
      "common.free",
      defaultValue: "Free",
      comment: "Generic free-form option label"
    )
    static let dates = string(
      "common.dates",
      defaultValue: "Dates",
      comment: "Generic dates section title"
    )
    static let low = string(
      "common.low",
      defaultValue: "Low",
      comment: "Generic low option label"
    )
    static let medium = string(
      "common.medium",
      defaultValue: "Medium",
      comment: "Generic medium option label"
    )
    static let high = string(
      "common.high",
      defaultValue: "High",
      comment: "Generic high option label"
    )
    static let original = string(
      "common.original",
      defaultValue: "Original",
      comment: "Generic original option label"
    )
    static let favorite = string(
      "common.favorite",
      defaultValue: "Favorite",
      comment: "Generic favorite section title"
    )
    static let dragColorsHere = string(
      "common.drag-colors-here",
      defaultValue: "Drag colors here",
      comment: "Instruction shown in color favorite drop zones"
    )
    static let custom = string(
      "common.custom",
      defaultValue: "Custom",
      comment: "Generic custom option label"
    )
    static let unsaved = string(
      "common.unsaved",
      defaultValue: "Unsaved",
      comment: "Generic unsaved status label"
    )
    static let active = string(
      "common.active",
      defaultValue: "Active",
      comment: "Generic active status label"
    )
    static let ready = string(
      "common.ready",
      defaultValue: "Ready",
      comment: "Generic ready status label"
    )
    static let enabled = string(
      "common.enabled",
      defaultValue: "Enabled",
      comment: "Generic enabled state label"
    )
    static let disabled = string(
      "common.disabled",
      defaultValue: "Disabled",
      comment: "Generic disabled state label"
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
      defaultValue: "Optional for global shortcuts",
      comment: "Permission description for accessibility access"
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
    static let recordingSection = string(
      "shortcut-guidance.section-recording",
      defaultValue: "Recording",
      comment: "Shortcut group title in the Shortcuts settings reference"
    )
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
      defaultValue: "Uncheck the macOS screenshot shortcuts that overlap with the Lite Screen shortcuts you want to keep on",
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
    static func usedBy(_ displayName: String) -> String {
      format(
        "shortcut-recorder.used-by",
        defaultValue: "Used by %@",
        comment: "Conflict label for a shortcut already used by another action or tool. %@ is the conflicting action name.",
        displayName
      )
    }
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
      defaultValue: "Launch Lite Screen when you log in",
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
      defaultValue: "Access Lite Screen from the menu bar. When hidden, open Lite Screen again to show settings.",
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
      defaultValue: "Choose the language used across Lite Screen",
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
      defaultValue: "Relaunch Lite Screen?",
      comment: "Alert title shown before the app relaunches to apply a language change"
    )
    static let languageRelaunchConfirmationMessage = string(
      "preferences-general.language-relaunch-confirmation-message",
      defaultValue: "Lite Screen needs to quit and reopen to apply this language change everywhere.",
      comment: "Alert message shown before the app relaunches to apply a language change"
    )
    static let languageRelaunchConfirmationAction = string(
      "preferences-general.language-relaunch-confirmation-action",
      defaultValue: "Relaunch Lite Screen",
      comment: "Alert button title that confirms relaunching the app after changing language"
    )
    static let languageRelaunchErrorTitle = string(
      "preferences-general.language-relaunch-error-title",
      defaultValue: "Could Not Relaunch Lite Screen",
      comment: "Alert title shown when the app cannot relaunch after changing language"
    )
    static let saveLocationTitle = string(
      "preferences-general.save-location-title",
      defaultValue: "Save location",
      comment: "General preferences setting title"
    )
    static let saveLocationDescription = string(
      "preferences-general.save-location-description",
      defaultValue: "Where Lite Screen stores captures",
      comment: "General preferences setting description"
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
    static let downloadAutomaticallyTitle = string(
      "preferences-general.download-automatically-title",
      defaultValue: "Download automatically",
      comment: "General preferences setting title"
    )
    static let downloadAutomaticallyDescription = string(
      "preferences-general.download-automatically-description",
      defaultValue: "Download updates in background",
      comment: "General preferences setting description"
    )
    static let lastCheckedTitle = string(
      "preferences-general.last-checked-title",
      defaultValue: "Last checked",
      comment: "General preferences setting title"
    )
    static let never = string(
      "preferences-general.never",
      defaultValue: "Never",
      comment: "Label shown when an event has never happened"
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
      defaultValue: "Desktop/Lite Screen",
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
      defaultValue: "Choose where Lite Screen saves captures",
      comment: "Open panel message for selecting the default export location"
    )
    static let saveHereButton = string(
      "preferences-general.save-here-button",
      defaultValue: "Save Here",
      comment: "Open panel prompt for choosing export location"
    )
  }

  enum PreferencesPermissions {
    static let intro = string(
      "preferences-permissions.intro",
      defaultValue: "Lite Screen requires certain permissions to capture your screen and audio.",
      comment: "Introductory text for the permissions preferences tab"
    )
  }

  enum PreferencesQuickAccess {
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
    static let primaryActionBadge = string(
      "preferences-quick-access.badge-primary",
      defaultValue: "Primary",
      comment: "Quick access configurable action placement badge"
    )
    static let cornerActionBadge = string(
      "preferences-quick-access.badge-corner",
      defaultValue: "Corner",
      comment: "Quick access configurable action placement badge"
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
    static let swipeActionsSection = string(
      "preferences-quick-access.section-swipe-actions",
      defaultValue: "Swipe Actions",
      comment: "Quick access preferences section title for swipe action zones"
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
    static let screenshotPresetSection = string(
      "preferences-capture.section-screenshot-preset",
      defaultValue: "Preset",
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
      defaultValue: "Show Lite Screen windows such as Annotate in captured images",
      comment: "Capture preferences setting description"
    )
    static let includeInRecordingsTitle = string(
      "preferences-capture.include-in-recordings-title",
      defaultValue: "Include in Recordings",
      comment: "Capture preferences setting title"
    )
    static let includeInRecordingsDescription = string(
      "preferences-capture.include-in-recordings-description",
      defaultValue: "Show Lite Screen windows such as Annotate in recorded videos",
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
      defaultValue: "Object cutout captures require transparency. Lite Screen will save them as PNG even when JPEG is selected.",
      comment: "Informational note shown when JPEG screenshot format is selected"
    )
    static let defaultPresetTitle = string(
      "preferences-capture.default-preset-title",
      defaultValue: "Default Preset",
      comment: "Capture preferences setting title"
    )
    static let defaultPresetDescription = string(
      "preferences-capture.default-preset-description",
      defaultValue: "Apply an Annotate preset right after each screenshot capture",
      comment: "Capture preferences setting description"
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
    static let qualityTitle = string(
      "preferences-capture.quality-title",
      defaultValue: "Quality",
      comment: "Capture preferences setting title"
    )
    static let qualityDescription = string(
      "preferences-capture.quality-description",
      defaultValue: "Higher quality = larger file size",
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
    static let highlightColorTitle = string(
      "preferences-capture.highlight-color-title",
      defaultValue: "Highlight Color",
      comment: "Capture preferences setting title"
    )
    static let highlightColorDescription = string(
      "preferences-capture.highlight-color-description",
      defaultValue: "Color of click rings",
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
    static let microphoneInputTitle = string(
      "preferences-capture.microphone-input-title",
      defaultValue: "Microphone Input",
      comment: "Capture preferences setting title"
    )
    static let microphoneInputDescription = string(
      "preferences-capture.microphone-input-description",
      defaultValue: "Choose the built-in or external microphone used for recordings",
      comment: "Capture preferences setting description"
    )
    static let microphoneRequiresMacOS = string(
      "preferences-capture.microphone-requires-macos",
      defaultValue: "Requires macOS 15.0+",
      comment: "Capture preferences description when microphone capture is unavailable on the current macOS version"
    )
    static let removeBackground = string(
      "preferences-capture.remove-background",
      defaultValue: "Remove Background",
      comment: "Caption label for background removal settings"
    )
    static let autoCropSubjectTitle = string(
      "preferences-capture.auto-crop-subject-title",
      defaultValue: "Auto-Crop Subject",
      comment: "Capture preferences setting title"
    )
    static let autoCropSubjectDescription = string(
      "preferences-capture.auto-crop-subject-description",
      defaultValue: "Applies to background removal in capture and Annotate",
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
      defaultValue: "macOS screenshot shortcuts overlap with Lite Screen",
      comment: "Title for system shortcut conflict warning"
    )
    static let systemConflictDescription = string(
      "preferences-shortcuts.system-conflict-description",
      defaultValue: "Turn off the overlapping macOS shortcuts to avoid conflicts with the Lite Screen shortcuts you keep enabled.",
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
      defaultValue: "No overlapping macOS screenshot shortcuts were found for the Lite Screen shortcuts you currently have enabled.",
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
      defaultValue: "You won't be able to capture screenshots or recordings using keyboard shortcuts from any app. You'll need to open Lite Screen manually to use capture features.",
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
    static let recorderHint = string(
      "preferences-shortcuts.recorder-hint",
      defaultValue: "Click a shortcut button to record new keys. Use Backspace/Delete while recording to clear keys. Use the row toggle to turn a shortcut off. Press Esc to cancel.",
      comment: "Hint text below editable shortcut recorder rows"
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
      defaultValue: "Lite Screen needs microphone permission. Please enable it in System Settings > Privacy & Security > Microphone.",
      comment: "Alert message when microphone permission is missing from preferences or toolbar"
    )
    static let recordingMessage = string(
      "microphone.recording-message",
      defaultValue: "Lite Screen needs microphone permission to record audio. Please grant access in System Settings.",
      comment: "Alert message when microphone permission is missing while starting a recording"
    )
    static let continueWithoutMic = string(
      "microphone.continue-without-mic",
      defaultValue: "Continue Without Mic",
      comment: "Alert button title to continue recording without microphone access"
    )
    static let doNotUse = string(
      "microphone.do-not-use",
      defaultValue: "Do Not Use Microphone",
      comment: "Microphone menu option to disable microphone capture"
    )
    static let unavailableVersion = string(
      "microphone.unavailable-version",
      defaultValue: "Microphone unavailable on this macOS version",
      comment: "Accessibility label when microphone capture is unavailable on current macOS version"
    )
    static let mute = string(
      "microphone.mute",
      defaultValue: "Mute microphone",
      comment: "Accessibility label for muting the microphone"
    )
    static let unmute = string(
      "microphone.unmute",
      defaultValue: "Unmute microphone",
      comment: "Accessibility label for unmuting the microphone"
    )
    static let on = string(
      "microphone.on",
      defaultValue: "Microphone on",
      comment: "Tooltip when microphone capture is enabled"
    )
    static let off = string(
      "microphone.off",
      defaultValue: "Microphone off",
      comment: "Tooltip when microphone capture is disabled"
    )
    static let options = string(
      "microphone.options",
      defaultValue: "Microphone options",
      comment: "Accessibility label for the microphone options menu button"
    )
    static let chooseInput = string(
      "microphone.choose-input",
      defaultValue: "Choose a microphone input",
      comment: "Accessibility hint for the microphone options menu button"
    )
    static let doubleTapToToggle = string(
      "microphone.double-tap-toggle",
      defaultValue: "Double-tap to toggle",
      comment: "Accessibility hint for toggling microphone capture"
    )
    static let systemDefault = string(
      "microphone.system-default",
      defaultValue: "System Default Microphone",
      comment: "Microphone picker option for the current macOS default input device"
    )
    static let unavailable = string(
      "microphone.unavailable",
      defaultValue: "Unavailable",
      comment: "Microphone picker suffix for a stored input device that is not currently connected"
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

    static let modeAnnotate = string(
      "annotate.mode-annotate",
      defaultValue: "Annotate",
      comment: "Annotate editor mode label"
    )
    static let modeMockup = string(
      "annotate.mode-mockup",
      defaultValue: "Mockup",
      comment: "Annotate editor mode label"
    )
    static let modePreview = string(
      "annotate.mode-preview",
      defaultValue: "Preview",
      comment: "Annotate editor mode label"
    )
    static let dragToApp = string(
      "annotate.drag-to-app",
      defaultValue: "Drag to app",
      comment: "Annotate drag handle label"
    )
    static let dragToAppHelp = string(
      "annotate.drag-to-app-help",
      defaultValue: "Drag this to another app to share the annotated image",
      comment: "Tooltip shown for the annotate drag handle"
    )
    static let pinWindow = string(
      "annotate.pin-window",
      defaultValue: "Pin window",
      comment: "Tooltip shown for pinning the annotate window"
    )
    static let unpinWindow = string(
      "annotate.unpin-window",
      defaultValue: "Unpin window",
      comment: "Tooltip shown for unpinning the annotate window"
    )
    static let copyToClipboard = string(
      "annotate.copy-to-clipboard",
      defaultValue: "Copy to clipboard",
      comment: "Tooltip shown for copying the annotated image to the clipboard"
    )
    static let deleteScreenshotTitle = string(
      "annotate.delete-screenshot-title",
      defaultValue: "Delete Screenshot",
      comment: "Alert title shown before deleting the source screenshot from annotate"
    )
    static func deleteScreenshotMessage(_ filename: String) -> String {
      format(
        "annotate.delete-screenshot-message",
        defaultValue: "This will move \"%@\" to Trash.",
        comment: "Alert message shown before deleting the source screenshot from annotate. %@ is the file name.",
        filename
      )
    }

    static let backgroundCutoutTitle = string(
      "annotate.background-cutout-title",
      defaultValue: "Background Cutout",
      comment: "Alert title for annotate background cutout errors"
    )
    static let unableToRemoveBackground = string(
      "annotate.unable-to-remove-background",
      defaultValue: "Unable to remove background.",
      comment: "Fallback error shown when background removal fails without a specific localized message"
    )
    static let crop = string(
      "annotate.crop",
      defaultValue: "Crop",
      comment: "Tooltip for entering crop mode in annotate"
    )
    static let rotateLeft = string(
      "annotate.rotate-left",
      defaultValue: "Rotate left 90°",
      comment: "Tooltip for rotating the source image 90° counter-clockwise"
    )
    static let rotateRight = string(
      "annotate.rotate-right",
      defaultValue: "Rotate right 90°",
      comment: "Tooltip for rotating the source image 90° clockwise"
    )
    static let toggleSidebar = string(
      "annotate.toggle-sidebar",
      defaultValue: "Toggle sidebar",
      comment: "Tooltip for toggling the annotate sidebar"
    )
    static let backgroundRemovedClickToRestore = string(
      "annotate.background-removed-click-to-restore",
      defaultValue: "Background Removed (Click to restore)",
      comment: "Tooltip shown when background cutout is active and can be restored"
    )
    static let removeBackgroundAutoCropsWhenSafe = string(
      "annotate.remove-background-auto-crops-when-safe",
      defaultValue: "Remove Background (Auto-crops when safe)",
      comment: "Tooltip shown when background cutout will auto-crop after removing the background"
    )
    static let removeBackgroundAutoCropDisabledInSettings = string(
      "annotate.remove-background-auto-crop-disabled",
      defaultValue: "Remove Background (Auto-crop disabled in Settings)",
      comment: "Tooltip shown when background cutout is available but auto-crop is disabled in settings"
    )
    static let requiresMacOS14OrLater = string(
      "annotate.requires-macos-14",
      defaultValue: "Requires macOS 14+",
      comment: "Tooltip shown when background cutout is unavailable on older macOS versions"
    )
    static let dropImageHere = string(
      "annotate.drop-image-here",
      defaultValue: "Drop an image here",
      comment: "Empty state title for annotate when no image is loaded"
    )
    static let backgroundRatio = string(
      "annotate.background-ratio",
      defaultValue: "Background Ratio",
      comment: "Section label for choosing the annotation background canvas aspect ratio"
    )
    static let toggleRuleOfThirdsGrid = string(
      "annotate.toggle-rule-of-thirds-grid",
      defaultValue: "Toggle rule of thirds grid",
      comment: "Tooltip for showing or hiding the crop grid"
    )
    static let toggleCropOrientation = string(
      "annotate.toggle-crop-orientation",
      defaultValue: "Switch crop orientation",
      comment: "Tooltip for switching crop aspect ratio between landscape and portrait"
    )
    static let toggleAspectRatioOrientation = string(
      "annotate.toggle-aspect-ratio-orientation",
      defaultValue: "Switch aspect ratio orientation",
      comment: "Tooltip for switching annotate background aspect ratio between horizontal and vertical"
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
      defaultValue: "Lite Screen couldn't write to the selected location. Please choose another folder.",
      comment: "Alert message shown when annotate save fails"
    )
    static let defaultAnnotatedFileName = string(
      "annotate.default-annotated-file-name",
      defaultValue: "annotated_image",
      comment: "Default file name for a new annotated image without a source URL"
    )
    static let jpegRemovesTransparencyTitle = string(
      "annotate.jpeg-removes-transparency-title",
      defaultValue: "JPEG Removes Transparency",
      comment: "Alert title shown before saving a transparent cutout image as JPEG"
    )
    static let jpegRemovesTransparencyMessage = string(
      "annotate.jpeg-removes-transparency-message",
      defaultValue: "This image uses a transparent background cutout. Saving as JPEG will flatten transparency to an opaque background. Use PNG or WebP to keep transparency.",
      comment: "Alert message shown before saving a transparent cutout image as JPEG"
    )
    static let saveAsJPEG = string(
      "annotate.save-as-jpeg",
      defaultValue: "Save as JPEG",
      comment: "Button title for confirming JPEG export without transparency"
    )
    static let presets = string(
      "annotate.presets",
      defaultValue: "Presets",
      comment: "Section title for annotate canvas presets"
    )
    static let selectPreset = string(
      "annotate.select-preset",
      defaultValue: "Select preset",
      comment: "Placeholder label for choosing an annotate canvas preset"
    )
    static let resetCanvasEffectsHelp = string(
      "annotate.reset-canvas-effects-help",
      defaultValue: "Reset background, padding, shadow, and corners",
      comment: "Tooltip for resetting annotate canvas effects"
    )
    static let applySavedStylePreset = string(
      "annotate.apply-saved-style-preset",
      defaultValue: "Apply a saved style preset",
      comment: "Tooltip for opening the annotate saved preset picker"
    )
    static let addNewPreset = string(
      "annotate.add-new-preset",
      defaultValue: "Add new preset",
      comment: "Button title for creating a new annotate preset"
    )
    static let noPresetsYet = string(
      "annotate.no-presets-yet",
      defaultValue: "No presets yet",
      comment: "Empty state label when no annotate presets have been saved"
    )
    static let deletePresetHelp = string(
      "annotate.delete-preset-help",
      defaultValue: "Delete preset",
      comment: "Tooltip for deleting an annotate preset"
    )
    static let setDefaultPresetHelp = string(
      "annotate.set-default-preset-help",
      defaultValue: "Use as default preset",
      comment: "Tooltip for setting an annotate preset as the default"
    )
    static let clearDefaultPresetHelp = string(
      "annotate.clear-default-preset-help",
      defaultValue: "Clear default preset",
      comment: "Tooltip for clearing the default annotate preset"
    )
    static let updatePreset = string(
      "annotate.update-preset",
      defaultValue: "Update preset",
      comment: "Button title for updating the selected annotate preset"
    )
    static let updateSelectedPresetHelp = string(
      "annotate.update-selected-preset-help",
      defaultValue: "Update selected preset with current values",
      comment: "Tooltip for updating the selected annotate preset"
    )
    static let savePresetTitle = string(
      "annotate.save-preset-title",
      defaultValue: "Save Preset",
      comment: "Alert title for saving a new annotate preset"
    )
    static let savePresetMessage = string(
      "annotate.save-preset-message",
      defaultValue: "Enter a name for this canvas preset.",
      comment: "Alert message for saving a new annotate preset"
    )
    static let updatePresetTitle = string(
      "annotate.update-preset-title",
      defaultValue: "Update Preset",
      comment: "Alert title for updating an annotate preset"
    )
    static func updatePresetMessage(_ presetName: String) -> String {
      format(
        "annotate.update-preset-message",
        defaultValue: "Replace \"%@\" with current settings?",
        comment: "Alert message for updating an annotate preset. %@ is the preset name.",
        presetName
      )
    }

    static let deletePresetTitle = string(
      "annotate.delete-preset-title",
      defaultValue: "Delete Preset",
      comment: "Alert title for deleting an annotate preset"
    )
    static func deletePresetMessage(_ presetName: String) -> String {
      format(
        "annotate.delete-preset-message",
        defaultValue: "Delete \"%@\"?",
        comment: "Alert message for deleting an annotate preset. %@ is the preset name.",
        presetName
      )
    }

    static let presetNamePlaceholder = string(
      "annotate.preset-name-placeholder",
      defaultValue: "Preset name",
      comment: "Placeholder text for the annotate preset name field"
    )
    static let presetLimitReachedTitle = string(
      "annotate.preset-limit-reached-title",
      defaultValue: "Preset Limit Reached",
      comment: "Alert title shown when the annotate preset limit is reached"
    )
    static let presetLimitReachedMessage = string(
      "annotate.preset-limit-reached-message",
      defaultValue: "You can save up to 20 presets. Delete one to add a new preset.",
      comment: "Alert message shown when the annotate preset limit is reached"
    )
    static let unableToSavePresetTitle = string(
      "annotate.unable-to-save-preset-title",
      defaultValue: "Unable to Save Preset",
      comment: "Alert title shown when the current annotate canvas style cannot be saved as a preset"
    )
    static let unableToSavePresetMessage = string(
      "annotate.unable-to-save-preset-message",
      defaultValue: "Current canvas style cannot be stored as a preset right now.",
      comment: "Alert message shown when the current annotate canvas style cannot be saved as a preset"
    )
    static let textStyle = string(
      "annotate.text-style",
      defaultValue: "Text Style",
      comment: "Section title for annotate text styling controls"
    )
    static let textColor = string(
      "annotate.text-color",
      defaultValue: "Text Color",
      comment: "Label for annotate text color controls"
    )
    static let annotation = string(
      "annotate.annotation",
      defaultValue: "Annotation",
      comment: "Section title for annotate item properties"
    )
    static let alignment = string(
      "annotate.alignment",
      defaultValue: "Alignment",
      comment: "Section title for annotate image alignment controls"
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
    static let pixelatedBlurDescription = string(
      "annotate.pixelated-blur-description",
      defaultValue: "Classic square-pixel blur effect",
      comment: "Description shown for the pixelated blur style"
    )
    static let gaussianBlurDescription = string(
      "annotate.gaussian-blur-description",
      defaultValue: "Smooth Gaussian blur similar to CSS filter",
      comment: "Description shown for the gaussian blur style"
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
    static let hexagonalBlurDescription = string(
      "annotate.hexagonal-blur-description",
      defaultValue: "Artistic hexagonal pixelation effect",
      comment: "Description shown for the hexagonal blur style"
    )
    static let crystallizedBlurDescription = string(
      "annotate.crystallized-blur-description",
      defaultValue: "Lavender paper tape with a starry pattern",
      comment: "Description shown for the starry tape style"
    )
    static let pointillismBlurDescription = string(
      "annotate.pointillism-blur-description",
      defaultValue: "Peach paper tape with a grid line pattern",
      comment: "Description shown for the grid tape style"
    )
    static let halftoneBlurDescription = string(
      "annotate.halftone-blur-description",
      defaultValue: "Cream paper tape with a gingham check pattern",
      comment: "Description shown for the gingham tape style"
    )
    static let tapeBlurDescription = string(
      "annotate.tape-blur-description",
      defaultValue: "Off-white paper tape with diagonal patterns",
      comment: "Description shown for the tape cover style"
    )
    static let washiBlurDescription = string(
      "annotate.washi-blur-description",
      defaultValue: "Pastel teal paper tape with grid dot patterns",
      comment: "Description shown for the washi cover style"
    )
    static let blurredBackground = string(
      "annotate.blurred-background",
      defaultValue: "Blurred",
      comment: "Section title for annotate blurred background controls"
    )
    static let blurredBackgroundSoft = string(
      "annotate.blurred-background-soft",
      defaultValue: "Soft",
      comment: "Label for the soft blurred background preset"
    )
    static let blurredBackgroundFrosted = string(
      "annotate.blurred-background-frosted",
      defaultValue: "Frosted",
      comment: "Label for the frosted blurred background preset"
    )
    static let blurredBackgroundVivid = string(
      "annotate.blurred-background-vivid",
      defaultValue: "Vivid",
      comment: "Label for the vivid blurred background preset"
    )
    static let blurredBackgroundDim = string(
      "annotate.blurred-background-dim",
      defaultValue: "Dim",
      comment: "Label for the dim blurred background preset"
    )
    static let watermarkSingle = string(
      "annotate.watermark-single",
      defaultValue: "Single",
      comment: "Label for a single watermark style"
    )
    static let watermarkDiagonal = string(
      "annotate.watermark-diagonal",
      defaultValue: "Diagonal",
      comment: "Label for a centered diagonal watermark style"
    )
    static let watermarkTiled = string(
      "annotate.watermark-tiled",
      defaultValue: "Tiled",
      comment: "Label for a repeated tiled watermark style"
    )
    static let watermarkOpacity = string(
      "annotate.watermark-opacity",
      defaultValue: "Opacity",
      comment: "Label for watermark opacity controls"
    )
    static let spotlightOpacity = string(
      "annotate.spotlight-opacity",
      defaultValue: "Darkness",
      comment: "Label for spotlight darkness controls"
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
    static let straightArrowHelp = string(
      "annotate.straight-arrow-help",
      defaultValue: "Direct line from start to end",
      comment: "Helper text for the straight arrow style"
    )
    static let curvedRightArrowHelp = string(
      "annotate.curved-right-arrow-help",
      defaultValue: "Arrow curving to the right",
      comment: "Helper text for the curved right arrow style"
    )
    static let curvedLeftArrowHelp = string(
      "annotate.curved-left-arrow-help",
      defaultValue: "Arrow curving to the left",
      comment: "Helper text for the curved left arrow style"
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
    static let xAxis = string(
      "annotate.x-axis",
      defaultValue: "X Axis",
      comment: "Label for the X axis rotation slider in mockup controls"
    )
    static let yAxis = string(
      "annotate.y-axis",
      defaultValue: "Y Axis",
      comment: "Label for the Y axis rotation slider in mockup controls"
    )
    static let zAxis = string(
      "annotate.z-axis",
      defaultValue: "Z Axis",
      comment: "Label for the Z axis rotation slider in mockup controls"
    )
    static let depth = string(
      "annotate.depth",
      defaultValue: "Depth",
      comment: "Label for the perspective depth slider in mockup controls"
    )
    static let resetMockup = string(
      "annotate.reset-mockup",
      defaultValue: "Reset Mockup",
      comment: "Button title for resetting mockup controls"
    )
    static let autoBalance = string(
      "annotate.auto-balance",
      defaultValue: "Auto-balance",
      comment: "Toggle label for automatically balancing canvas effects in annotate"
    )
    static let openSidebarForMoreControls = string(
      "annotate.open-sidebar-for-more-controls",
      defaultValue: "Open sidebar for more annotate controls",
      comment: "Tooltip for opening the full annotate sidebar from the quick properties bar"
    )
    static let resetToDefaults = string(
      "annotate.reset-to-defaults",
      defaultValue: "Reset to Defaults",
      comment: "Tooltip for resetting mockup values to defaults"
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
    static let previewPressStartToBegin = string(
      "scrolling-capture.preview-press-start-to-begin",
      defaultValue: "Press Start Capture to begin.",
      comment: "Preview description shown before scrolling capture starts"
    )
    static let previewShowingLatestStitchedCapture = string(
      "scrolling-capture.preview-showing-latest-stitched-capture",
      defaultValue: "Showing the latest stitched capture.",
      comment: "Preview description shown when the committed stitched capture is displayed"
    )
    static let previewMatchesStitchedCapture = string(
      "scrolling-capture.preview-matches-stitched-capture",
      defaultValue: "Preview matches the stitched capture.",
      comment: "Preview description shown when the live preview matches the stitched output"
    )
    static let previewShowingLatestWhileLockingNewerContent = string(
      "scrolling-capture.preview-showing-latest-while-locking-newer-content",
      defaultValue: "Showing the latest stitched result while Lite Screen locks newer content.",
      comment: "Preview description shown while scrolling capture syncs newer content"
    )
    static let previewPausedScrollSlowly = string(
      "scrolling-capture.preview-paused-scroll-slowly",
      defaultValue: "Preview paused - scroll slowly so Lite Screen can re-align.",
      comment: "Preview description shown when scrolling capture needs recovery"
    )
    static let previewFinishingSavingCapture = string(
      "scrolling-capture.preview-finishing-saving-capture",
      defaultValue: "Finishing up - saving your capture.",
      comment: "Preview description shown when scrolling capture is finalizing"
    )
    static let previewSavingCapture = string(
      "scrolling-capture.preview-saving-capture",
      defaultValue: "Saving your capture...",
      comment: "Preview description shown while scrolling capture is saving"
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
    static let guidanceLiteScreenLockingFirstFrame = string(
      "scrolling-capture.guidance-lite-screen-locking-first-frame",
      defaultValue: "Lite Screen is locking the first frame",
      comment: "Selection guidance detail shown while the first scrolling capture frame is locking"
    )
    static let guidanceSlowDown = string(
      "scrolling-capture.guidance-slow-down",
      defaultValue: "Slow down",
      comment: "Selection guidance title shown when scrolling capture needs slower scrolling"
    )
    static let guidanceKeepOneDirectionSoLiteScreenCanRealign = string(
      "scrolling-capture.guidance-keep-one-direction-so-lite-screen-can-realign",
      defaultValue: "Keep one direction so Lite Screen can re-align",
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
    static let guidanceLiteScreenSealingStitchedResult = string(
      "scrolling-capture.guidance-lite-screen-sealing-stitched-result",
      defaultValue: "Lite Screen is sealing the stitched result",
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
      defaultValue: "Live preview running while Lite Screen locks the stitched frame.",
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
    static let toastSessionAlreadyActive = string(
      "scrolling-capture.toast-session-already-active",
      defaultValue: "A scrolling capture session is already active.",
      comment: "Toast shown when the user tries to start a second scrolling capture session while one is already active"
    )
  }

  enum RecordingToolbar {
    static let options = string(
      "recording-toolbar.options",
      defaultValue: "Options",
      comment: "Button title for recording toolbar options"
    )
    static let recordingOptionsAccessibility = string(
      "recording-toolbar.options-accessibility",
      defaultValue: "Recording options",
      comment: "Accessibility label for recording toolbar options button"
    )
    static let recordingOptionsHint = string(
      "recording-toolbar.options-hint",
      defaultValue: "Opens settings for format, quality, and overlays",
      comment: "Accessibility hint for recording toolbar options button"
    )
    static let settingsTitle = string(
      "recording-toolbar.settings-title",
      defaultValue: "Recording Settings",
      comment: "Popover title for recording toolbar settings"
    )
    static let formatSection = string(
      "recording-toolbar.format-section",
      defaultValue: "Format",
      comment: "Recording toolbar settings section title"
    )
    static let qualitySection = string(
      "recording-toolbar.quality-section",
      defaultValue: "Quality",
      comment: "Recording toolbar settings section title"
    )
    static let audioSection = string(
      "recording-toolbar.audio-section",
      defaultValue: "Audio",
      comment: "Recording toolbar settings section title"
    )
    static let overlaysSection = string(
      "recording-toolbar.overlays-section",
      defaultValue: "Overlays",
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
    static let highlightClicks = string(
      "recording-toolbar.highlight-clicks",
      defaultValue: "Highlight Clicks",
      comment: "Recording toolbar setting label"
    )
    static let showKeystrokes = string(
      "recording-toolbar.show-keystrokes",
      defaultValue: "Show Keystrokes",
      comment: "Recording toolbar setting label"
    )
    static let showCursor = string(
      "recording-toolbar.show-cursor",
      defaultValue: "Show Cursor",
      comment: "Recording toolbar setting label"
    )
    static let dimNonSelectedArea = string(
      "recording-toolbar.dim-non-selected-area",
      defaultValue: "Dim Non-Selected Area",
      comment: "Recording toolbar setting label"
    )
    static let outputModeAccessibilityPrefix = string(
      "recording-toolbar.output-mode-accessibility-prefix",
      defaultValue: "Output mode",
      comment: "Accessibility label prefix for current output mode"
    )
    static let outputModeHint = string(
      "recording-toolbar.output-mode-hint",
      defaultValue: "Opens output format selection",
      comment: "Accessibility hint for output mode selector"
    )
    static let record = string(
      "recording-toolbar.record",
      defaultValue: "Record",
      comment: "Recording toolbar primary action button title"
    )
    static func startRecordingAs(_ mode: String) -> String {
      format(
        "recording-toolbar.start-recording-as",
        defaultValue: "Start recording as %@",
        comment: "Accessibility label for recording button. %@ is the output mode name.",
        mode
      )
    }

    static let startRecordingHint = string(
      "recording-toolbar.start-recording-hint",
      defaultValue: "Begins screen recording with current settings",
      comment: "Accessibility hint for recording button"
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
    static let failedTitle = string(
      "recording.failed-title",
      defaultValue: "Recording Failed",
      comment: "Alert title shown when starting or running a recording fails"
    )
    static let screenshotFailedTitle = string(
      "recording.screenshot-failed-title",
      defaultValue: "Screenshot Failed",
      comment: "Alert title shown when taking a screenshot during recording fails"
    )
    static let saveLocationAccessRequiredTitle = string(
      "recording.save-location-access-required-title",
      defaultValue: "Save Location Access Required",
      comment: "Alert title shown when save location access is missing"
    )
    static let saveLocationAccessRequiredMessage = string(
      "recording.save-location-access-required-message",
      defaultValue: "Lite Screen needs a save folder permission to continue. Please choose a save folder in Preferences → General.",
      comment: "Alert message shown when save location access is missing"
    )
    static let chooseSaveLocationMessage = string(
      "recording.choose-save-location-message",
      defaultValue: "Choose where Lite Screen should save screenshots and recordings",
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
      defaultValue: "Lite Screen bundled your diagnostic logs into one file. Drag the file below to the report page.",
      comment: "Alert message shown when presenting a problem report dialog with a log bundle"
    )
    static let alertMessageNoLogBundle = string(
      "crash-report.alert-message-no-log-bundle",
      defaultValue: "Lite Screen could not prepare a diagnostic log bundle. You can still open the report page and describe the problem.",
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
      defaultValue: "Choose where Lite Screen should save screenshots and recordings",
      comment: "Open panel message shown when Lite Screen asks the user to grant access to a save folder"
    )
    nonisolated static let grantAccessPrompt = string(
      "file-access.grant-access-prompt",
      defaultValue: "Grant Access",
      comment: "Open panel prompt shown when Lite Screen asks the user to grant folder access"
    )
    nonisolated static let chooseFolderPrompt = string(
      "file-access.choose-folder-prompt",
      defaultValue: "Choose Folder",
      comment: "Open panel prompt shown when Lite Screen asks the user to choose a folder"
    )
    nonisolated static let desktopPicturesAccessMessage = string(
      "file-access.desktop-pictures-access-message",
      defaultValue: "Select the Desktop Pictures folder to grant access",
      comment: "Open panel message shown when Lite Screen asks for access to the system Desktop Pictures folder"
    )
    static let bookmarkSaveFailedTitle = string(
      "file-access.bookmark-save-failed-title",
      defaultValue: "Folder Access Not Granted",
      comment: "Alert title when security-scoped bookmark persistence fails"
    )
    static let bookmarkSaveFailedMessage = string(
      "file-access.bookmark-save-failed-message",
      defaultValue: "Lite Screen could not persist access to this folder. Please choose the folder again and confirm permission.",
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
    static let cropTool = string(
      "annotate.tool.crop",
      defaultValue: "Crop",
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
    static let watermarkTool = string(
      "annotate.tool.watermark",
      defaultValue: "Watermark",
      comment: "Annotation tool display name"
    )
    static let pencilTool = string(
      "annotate.tool.pencil",
      defaultValue: "Pencil",
      comment: "Annotation tool display name"
    )
    static let mockupTool = string(
      "annotate.tool.mockup",
      defaultValue: "Mockup",
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
      comment: "Error shown when Lite Screen cannot save a screenshot because folder access has not been granted"
    )
    nonisolated static let unableToCaptureSelectedArea = string(
      "screen-capture.unable-to-capture-selected-area",
      defaultValue: "Unable to capture the selected area.",
      comment: "Error shown when Lite Screen cannot capture the selected screenshot area"
    )
    nonisolated static let failedToCropCapturedImage = string(
      "screen-capture.failed-to-crop-captured-image",
      defaultValue: "Failed to crop the captured image",
      comment: "Error shown when Lite Screen captures an image but fails to crop it to the selected area"
    )
    nonisolated static func couldNotCreateDirectory(_ message: String) -> String {
      format(
        "screen-capture.could-not-create-directory",
        defaultValue: "Could not create the save folder: %@",
        comment: "Error shown when Lite Screen cannot create the selected save folder. %@ is the underlying filesystem error.",
        message
      )
    }

    nonisolated static let webpEncodingFailed = string(
      "screen-capture.webp-encoding-failed",
      defaultValue: "WebP encoding failed",
      comment: "Error shown when Lite Screen cannot encode a screenshot as WebP"
    )
    nonisolated static let couldNotCreateImageDestination = string(
      "screen-capture.could-not-create-image-destination",
      defaultValue: "Could not create the image destination",
      comment: "Error shown when Lite Screen cannot create an image writer for the screenshot"
    )
    nonisolated static let failedToWriteImageToDisk = string(
      "screen-capture.failed-to-write-image-to-disk",
      defaultValue: "Failed to write the image to disk",
      comment: "Error shown when Lite Screen fails while writing a screenshot to disk"
    )
    nonisolated static func fileWriteVerificationFailed(_ fileName: String) -> String {
      format(
        "screen-capture.file-write-verification-failed",
        defaultValue: "File write verification failed for %@",
        comment: "Error shown when Lite Screen writes a screenshot file but cannot verify it afterward. %@ is the file name.",
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
      comment: "Error shown when Lite Screen cannot convert a captured stream frame into an image"
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
    static let extractingContent = string(
      "ocr.extracting-content",
      defaultValue: "Extracting content...",
      comment: "Progress toast shown while OCR is extracting text or QR content from the selected area"
    )
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
      defaultValue: "QR code detected, but Lite Screen can only copy text-based QR content.",
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
    static let cannotReadSource = string(
      "gif.cannot-read-source",
      defaultValue: "Cannot read GIF file",
      comment: "Error shown when a GIF source file cannot be read"
    )
    static let noFramesInGIF = string(
      "gif.no-frames-in-gif",
      defaultValue: "GIF contains no frames",
      comment: "Error shown when a GIF file contains no frames"
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
    static let finalizeResizedFailed = string(
      "gif.finalize-resized-failed",
      defaultValue: "Failed to finalize resized GIF",
      comment: "Error shown when a resized GIF cannot be finalized"
    )
  }

  enum ForegroundCutout {
    static let unsupportedOS = string(
      "foreground-cutout.unsupported-os",
      defaultValue: "Background cutout requires macOS 14 or newer.",
      comment: "Error shown when foreground cutout is unavailable on the current macOS version"
    )
    static let noSubjectDetected = string(
      "foreground-cutout.no-subject-detected",
      defaultValue: "No foreground subject was detected in the selected area.",
      comment: "Error shown when no foreground subject can be detected for background removal"
    )
    static let noSubjectDetectedTryTighterArea = string(
      "foreground-cutout.no-subject-detected-try-tighter-area",
      defaultValue: "No subject detected. Try selecting a tighter area around the subject.",
      comment: "Toast shown when background removal cannot find a subject and the user should tighten the selection"
    )
    static func cutoutFailed(_ message: String) -> String {
      format(
        "foreground-cutout.cutout-failed",
        defaultValue: "Background cutout failed: %@",
        comment: "Error shown when background removal fails. %@ is the lower-level error message.",
        message
      )
    }

    static let imageConversionFailed = string(
      "foreground-cutout.image-conversion-failed",
      defaultValue: "Unable to convert cutout result to image.",
      comment: "Error shown when the cutout result cannot be converted back to an image"
    )
    static let unableToProcessImageTryAgain = string(
      "foreground-cutout.unable-to-process-image-try-again",
      defaultValue: "Unable to process the cutout image. Please try again.",
      comment: "Toast shown when background removal fails while processing the cutout image"
    )
    static let genericFailure = string(
      "foreground-cutout.generic-failure",
      defaultValue: "Background cutout failed. Please try again.",
      comment: "Generic toast shown when background removal fails for an unknown reason"
    )
  }

  enum CaptureStorage {
    static let empty = string(
      "capture-storage.empty",
      defaultValue: "Empty",
      comment: "Label shown when the capture cache is empty"
    )
    static let operationInProgress = string(
      "capture-storage.operation-in-progress",
      defaultValue: "Cannot clear cache while a capture or recording is in progress.",
      comment: "Error shown when cache cleanup is attempted while a capture or recording is active"
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
      defaultValue: "Lite Screen couldn't lock a savable stitched image yet. You can keep capturing, try Done again, or Cancel.",
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
      defaultValue: "Auto Scroll needs Accessibility permission. Enable Lite Screen in System Settings > Privacy & Security > Accessibility.",
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
      defaultValue: "Mixed scroll directions detected. Keep one direction so Lite Screen can align.",
      comment: "Status shown when mixed scroll directions are detected during scrolling capture"
    )
    static let couldntCaptureLastFrame = string(
      "scrolling-capture-status.couldnt-capture-last-frame",
      defaultValue: "Couldn't capture the last frame. Lite Screen will save the current stitched result.",
      comment: "Status shown when the final scrolling capture frame cannot be captured"
    )
    static let unableToCaptureArea = string(
      "scrolling-capture-status.unable-to-capture-area",
      defaultValue: "Unable to capture the selected area.",
      comment: "Status shown when the selected scrolling capture area cannot be captured"
    )
    static let couldntRefreshLastFrame = string(
      "scrolling-capture-status.couldnt-refresh-last-frame",
      defaultValue: "Couldn't refresh the last frame. Lite Screen will save the current stitched result.",
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
      defaultValue: "Alignment paused. Slow down and keep one direction so Lite Screen can recover.",
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
      defaultValue: "Finalizing the current capture. Lite Screen is locking the latest stitched result before saving.",
      comment: "Status shown when the scrolling capture result is being finalized"
    )
    static func finalizingFrames(_ count: Int) -> String {
      format(
        "scrolling-capture-status.finalizing-frames",
        defaultValue: "Locking the current capture. Lite Screen is sealing %d stitched frames before saving.",
        comment: "Status shown while finalizing a scrolling capture with stitched frames. %d is the number of stitched frames.",
        count
      )
    }

    static let finalizingNoNewContent = string(
      "scrolling-capture-status.finalizing-no-new-content",
      defaultValue: "No new content was detected. Lite Screen is saving the current stitched result.",
      comment: "Status shown while finalizing a scrolling capture after reaching the end of content"
    )
    static let finalizingCouldntAlignLastFrame = string(
      "scrolling-capture-status.finalizing-couldnt-align-last-frame",
      defaultValue: "Couldn't align the last frame cleanly. Lite Screen will save the current stitched result.",
      comment: "Status shown while finalizing when the last frame could not be aligned"
    )
    static let finalizingHeightLimitReached = string(
      "scrolling-capture-status.finalizing-height-limit-reached",
      defaultValue: "Height limit reached. Lite Screen is saving the current stitched result.",
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
        defaultValue: "Install Lite Screen in /Applications before granting permissions. Current path: %@",
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
    static let floatingPanelSection = string(
      "preferences-history.floating-panel-section",
      defaultValue: "Floating Panel",
      comment: "History settings section title for floating panel"
    )
    static let floatingPanelTitle = string(
      "preferences-history.floating-panel-title",
      defaultValue: "Enable Floating Panel",
      comment: "History settings toggle for floating panel"
    )
    static let floatingPanelDescription = string(
      "preferences-history.floating-panel-description",
      defaultValue: "Show a floating panel for quick access to recent captures",
      comment: "History settings description for floating panel"
    )
    static let toggleModeShortcutTitle = string(
      "preferences-history.toggle-mode-shortcut-title",
      defaultValue: "Toggle Mode Shortcut",
      comment: "History settings title for toggle mode shortcut"
    )
    static let toggleModeShortcutDescription = string(
      "preferences-history.toggle-mode-shortcut-description",
      defaultValue: "Toggle between floating and expanded modes when the panel is active",
      comment: "History settings description for toggle mode shortcut"
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
    static let defaultFilterAll = string(
      "preferences-history.default-filter-all",
      defaultValue: "All",
      comment: "History settings default filter option for all capture types"
    )
    static let defaultFilterScreenshots = string(
      "preferences-history.default-filter-screenshots",
      defaultValue: "Screenshots",
      comment: "History settings default filter option for screenshots"
    )
    static let defaultFilterVideos = string(
      "preferences-history.default-filter-videos",
      defaultValue: "Videos",
      comment: "History settings default filter option for videos"
    )
    static let defaultFilterGifs = string(
      "preferences-history.default-filter-gifs",
      defaultValue: "GIFs",
      comment: "History settings default filter option for GIFs"
    )
    static let maxItemsTitle = string(
      "preferences-history.max-items-title",
      defaultValue: "Max Displayed Items",
      comment: "History settings title for max displayed items"
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
    static let maxItemsDescription = string(
      "preferences-history.max-items-description",
      defaultValue: "Maximum number of items shown in the floating panel",
      comment: "History settings description for max displayed items"
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
    static let captureStorageTitle = string(
      "preferences-history.capture-storage-title",
      defaultValue: "Capture Storage",
      comment: "History settings title for local capture storage"
    )
    static let openCaptureStorageButton = string(
      "preferences-history.open-capture-storage-button",
      defaultValue: "Open Folder",
      comment: "History settings button for opening local capture storage in Finder"
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
      defaultValue: "This will move all capture files to Trash and remove them from Clipboard History. This action cannot be undone in Lite Screen.",
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
    static let glass = string(
      "history-background-style.glass",
      defaultValue: "Glass",
      comment: "History background style option"
    )
    static let gradient = string(
      "history-background-style.gradient",
      defaultValue: "Gradient",
      comment: "History background style option"
    )
  }

  enum WhatsNew {
    static let title = string(
      "whats-new.title",
      defaultValue: "What's new in Lite Screen",
      comment: "Welcome screen title"
    )
    static func desc(_ version: String) -> String {
      format(
        "whats-new.desc",
        defaultValue: "Discover the latest features in version %@.",
        comment: "Welcome screen description",
        version
      )
    }

    static let notarizationTitle = string(
      "whats-new.notarization.title",
      defaultValue: "Apple Notarization",
      comment: "Notarization feature title"
    )
    static let notarizationDesc = string(
      "whats-new.notarization.desc",
      defaultValue: "Lite Screen is now officially registered with the Apple Developer Program and certified by Apple, bypassing Gatekeeper's protections for a secure launch.",
      comment: "Notarization feature description"
    )
  }
}
