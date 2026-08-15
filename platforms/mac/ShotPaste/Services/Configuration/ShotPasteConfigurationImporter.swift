//
//  ShotPasteConfigurationImporter.swift
//  ShotPaste
//
//  Applies validated TOML config to ShotPaste stores.
//

import AppKit
import Foundation

@MainActor
enum ShotPasteConfigurationImporter {
  private struct PreparedImport {
    let issues: [ShotPasteConfigurationIssue]
    let mutations: [() -> Void]
  }

  static func importTOML(_ source: String, defaults: UserDefaults = .standard) -> ShotPasteConfigurationImportResult {
    let preparedImport = prepareImport(source, defaults: defaults)

    guard !preparedImport.issues.contains(where: { $0.severity == .error }) else {
      return ShotPasteConfigurationImportResult(appliedChangeCount: 0, issues: preparedImport.issues)
    }

    preparedImport.mutations.forEach { $0() }
    KeyboardShortcutManager.shared.refreshShortcutRegistration()

    return ShotPasteConfigurationImportResult(
      appliedChangeCount: preparedImport.mutations.count,
      issues: preparedImport.issues
    )
  }

  private static func prepareImport(_ source: String, defaults: UserDefaults) -> PreparedImport {
    let document: SimpleTOMLDocument
    do {
      document = try SimpleTOMLParser.parse(source)
    } catch {
      return PreparedImport(
        issues: [ShotPasteConfigurationIssue(severity: .error, message: error.localizedDescription)],
        mutations: []
      )
    }

    var reader = ShotPasteConfigurationReader(document: document)
    var mutations: [() -> Void] = []

    validateSchema(&reader)
    collectGeneral(&reader, defaults: defaults, mutations: &mutations)
    collectCapture(&reader, defaults: defaults, mutations: &mutations)
    collectRecording(&reader, defaults: defaults, mutations: &mutations)
    collectQuickAccess(&reader, mutations: &mutations)
    collectHistory(&reader, defaults: defaults, mutations: &mutations)
    collectAgent(&reader, defaults: defaults, mutations: &mutations)
    collectShortcuts(&reader, mutations: &mutations)

    return PreparedImport(issues: reader.issues, mutations: mutations)
  }

  private static func validateSchema(_ reader: inout ShotPasteConfigurationReader) {
    guard let schemaVersion = reader.int("schema_version") else { return }
    if schemaVersion != 1 {
      reader.error("Unsupported schema_version \(schemaVersion). ShotPaste currently supports schema_version 1.")
    }
  }

  private static func collectGeneral(
    _ reader: inout ShotPasteConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    if let language = reader.string("general", "language") {
      let normalized = language == "system" ? "" : AppLanguageManager.normalizedLanguageIdentifier(from: language)
      if normalized == nil, language != "system" {
        reader.error("general.language must be system or a supported language identifier")
      } else {
        mutations.append { AppLanguageManager.shared.selectLanguage(normalized ?? "") }
      }
    }
    if let appearance = reader.string("general", "appearance") {
      guard let mode = appearanceMode(from: appearance) else {
        reader.error("general.appearance must be system, light, or dark")
        return
      }
      mutations.append { ThemeManager.shared.preferredAppearance = mode }
    }
    collectBool(&reader, "general", "play_sounds", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.playSounds)
    }
    collectBool(&reader, "general", "url_scheme_enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.urlSchemeEnabled)
    }
    collectBool(&reader, "general", "mcp_server_enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.mcpServerEnabled)
    }
    collectInt(
      &reader,
      "general",
      "mcp_server_port",
      range: ShotPasteMCPServer.allowedPortRange,
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.mcpServerPort)
    }
    collectBool(&reader, "general", "show_menu_bar_icon", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.showMenuBarIcon)
      if defaults == UserDefaults.standard {
        AppStatusBarController.shared.setMenuBarIconVisible($0)
      }
    }
    if let startAtLogin = reader.bool("general", "start_at_login") {
      mutations.append { LoginItemManager.setEnabled(startAtLogin) }
    }
    if let exportLocation = reader.string("general", "export_location") {
      mutations.append { defaults.set(expandedPath(exportLocation), forKey: PreferencesKeys.exportLocation) }
    }
    collectBool(&reader, "diagnostics", "enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.diagnosticsEnabled)
    }
    collectInt(
      &reader,
      "diagnostics",
      "retention_days",
      range: LogCleanupScheduler.retentionDaysRange,
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.diagnosticsRetentionDays)
    }
  }

  private static func collectCapture(
    _ reader: inout ShotPasteConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    collectBool(&reader, "capture", "hide_desktop_icons", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.hideDesktopIcons)
    }
    collectBool(&reader, "capture", "hide_desktop_widgets", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.hideDesktopWidgets)
    }
    collectString(&reader, "capture", "naming", "screenshot_template", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotFileNameTemplate)
    }
    collectString(&reader, "capture", "naming", "recording_template", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingFileNameTemplate)
    }
    if let format = reader.string("capture", "screenshot", "format") {
      guard ImageFormatOption(rawValue: format) != nil else {
        reader.error("capture.screenshot.format must be png, jpeg, or webp")
        return
      }
      mutations.append { defaults.set(format, forKey: PreferencesKeys.screenshotFormat) }
    }
    collectBool(&reader, "capture", "screenshot", "include_shotpaste", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotIncludeOwnApp)
    }
    collectBool(&reader, "capture", "screenshot", "show_cursor", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotShowCursor)
    }
    collectBool(&reader, "capture", "screenshot", "magnifier_enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotMagnifierEnabled)
    }
    collectInt(&reader, "capture", "screenshot", "magnifier_zoom", range: 1 ... 20, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotMagnifierZoom)
    }
    collectEnumString(
      &reader,
      "capture", "screenshot", "color_space",
      allowed: ["auto", "srgb", "displayP3"],
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.screenshotColorSpace)
    }
    collectInt(&reader, "capture", "screenshot", "lossy_quality", range: 1 ... 100, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotLossyQuality)
    }
    collectBool(&reader, "capture", "screenshot", "success_notification", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.screenshotSuccessNotificationEnabled)
    }
    collectBool(&reader, "capture", "scrolling", "show_hints", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.scrollingCaptureShowHints)
    }
    collectBool(&reader, "capture", "ocr", "success_notification", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.ocrSuccessNotificationEnabled)
    }
    collectBool(&reader, "capture", "ocr", "link_detection", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.ocrLinkDetectionEnabled)
    }
    collectEnumString(
      &reader,
      "capture", "ocr", "language",
      allowed: ["auto"] + AppLanguageOption.supported.map(\.identifier),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.ocrRecognitionLanguage)
    }
    collectAfterCapture(&reader, type: .screenshot, mutations: &mutations)
    collectAfterCapture(&reader, type: .recording, mutations: &mutations)
  }

  private static func collectRecording(
    _ reader: inout ShotPasteConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    collectEnumString(
      &reader,
      "recording",
      "format",
      allowed: VideoFormat.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingFormat)
    }
    collectEnumString(
      &reader,
      "recording",
      "quality",
      allowed: VideoQuality.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingQuality)
    }
    collectInt(&reader, "recording", "fps", range: 1 ... 120, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingFPS)
    }
    collectEnumString(
      &reader,
      "recording", "video_codec",
      allowed: ["h264", "hevc"],
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingVideoCodec)
    }
    collectInt(&reader, "recording", "gif_fps", range: 5 ... 30, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingGIFFPS)
    }
    collectEnumString(
      &reader,
      "recording",
      "output_mode",
      allowed: RecordingOutputMode.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingOutputMode)
    }
    collectBool(&reader, "recording", "capture_system_audio", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingCaptureAudio)
    }
    collectBool(&reader, "recording", "capture_microphone", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingCaptureMicrophone)
    }
    collectDouble(&reader, "recording", "system_audio_volume", range: 0 ... 1, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingSystemAudioVolume)
    }
    collectDouble(&reader, "recording", "microphone_volume", range: 0 ... 1, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingMicrophoneVolume)
    }
    collectString(&reader, "recording", "microphone_device_id", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingMicrophoneDeviceID)
    }
    collectBool(&reader, "recording", "include_shotpaste", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingIncludeOwnApp)
    }
    collectBool(&reader, "recording", "show_cursor", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingShowCursor)
    }
    collectBool(&reader, "recording", "dim_non_selected_area", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingDimNonSelectedArea)
    }
    collectBool(&reader, "recording", "highlight_clicks", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingHighlightClicks)
    }
    collectBool(&reader, "recording", "show_keystrokes", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingShowKeystrokes)
    }
    collectDouble(&reader, "recording", "mouse_highlight", "size", range: 12 ... 192, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.mouseHighlightSize)
    }
    collectDouble(
      &reader,
      "recording",
      "mouse_highlight",
      "animation_duration",
      range: 0.1 ... 3,
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.mouseHighlightAnimationDuration)
    }
    collectColor(
      &reader,
      path: ["recording", "mouse_highlight", "left_color"],
      defaultsKey: PreferencesKeys.mouseHighlightLeftColor,
      defaults: defaults,
      mutations: &mutations
    )
    collectColor(
      &reader,
      path: ["recording", "mouse_highlight", "right_color"],
      defaultsKey: PreferencesKeys.mouseHighlightRightColor,
      defaults: defaults,
      mutations: &mutations
    )
    collectDouble(&reader, "recording", "mouse_highlight", "opacity", range: 0 ... 1, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.mouseHighlightOpacity)
    }
    collectInt(&reader, "recording", "mouse_highlight", "ripple_count", range: 1 ... 6, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.mouseHighlightRippleCount)
    }
    collectDouble(&reader, "recording", "keystrokes", "font_size", range: 10 ... 72, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.keystrokeFontSize)
    }
    collectEnumString(
      &reader,
      "recording",
      "keystrokes",
      "position",
      allowed: KeystrokeOverlayPosition.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.keystrokePosition)
    }
    collectDouble(&reader, "recording", "keystrokes", "display_duration", range: 0.25 ... 10, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.keystrokeDisplayDuration)
    }
    collectEnumString(
      &reader,
      "recording", "keystrokes", "visibility",
      allowed: KeystrokeOverlayVisibility.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.keystrokeVisibility)
    }

    collectColor(
      &reader,
      path: ["recording", "annotation", "color"],
      defaultsKey: PreferencesKeys.recordingAnnotationColor,
      defaults: defaults,
      mutations: &mutations
    )
    collectDouble(&reader, "recording", "annotation", "width", range: 1 ... 20, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationWidth)
    }
    collectEnumString(
      &reader,
      "recording", "annotation", "clear_mode",
      allowed: ["manual", "afterSeconds", "maximumCount"],
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationClearMode)
    }
    collectDouble(&reader, "recording", "annotation", "clear_seconds", range: 1 ... 300, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationClearSeconds)
    }
    collectInt(&reader, "recording", "annotation", "max_count", range: 1 ... 100, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationMaxCount)
    }
    collectBool(&reader, "recording", "annotation", "fade_enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationFadeEnabled)
    }
    collectDouble(&reader, "recording", "annotation", "fade_duration", range: 0.05 ... 3, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationFadeDuration)
    }
    collectEnumString(
      &reader,
      "recording", "annotation", "temporary_modifier",
      allowed: RecordingAnnotationTemporaryModifier.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationTemporaryModifier)
    }
    collectEnumString(
      &reader,
      "recording", "annotation", "temporary_clear_mode",
      allowed: ["manual", "afterSeconds", "maximumCount"],
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.recordingAnnotationTemporaryClearMode)
    }
  }

  private static func collectQuickAccess(
    _ reader: inout ShotPasteConfigurationReader,
    mutations: inout [() -> Void]
  ) {
    let manager = QuickAccessManager.shared
    collectBool(&reader, "quick_access", "enabled", mutations: &mutations) { manager.isEnabled = $0 }
    if let position = reader.string("quick_access", "position") {
      guard let value = QuickAccessPosition(rawValue: position) else {
        reader.error("quick_access.position is invalid")
        return
      }
      mutations.append { manager.position = value }
    }
    collectBool(&reader, "quick_access", "auto_dismiss", mutations: &mutations) { manager.autoDismissEnabled = $0 }
    collectDouble(&reader, "quick_access", "auto_dismiss_delay", range: 3 ... 30, mutations: &mutations) {
      manager.autoDismissDelay = $0
    }
    collectBool(&reader, "quick_access", "pause_countdown_on_hover", mutations: &mutations) {
      manager.pauseCountdownOnHover = $0
    }
    collectDouble(&reader, "quick_access", "overlay_scale", range: 0.75 ... 1.5, mutations: &mutations) {
      manager.overlayScale = $0
    }
    collectBool(&reader, "quick_access", "drag_drop", mutations: &mutations) { manager.dragDropEnabled = $0 }
    collectBool(&reader, "quick_access", "two_finger_swipe_to_dismiss", mutations: &mutations) {
      manager.twoFingerSwipeToDismissEnabled = $0
    }
    collectDouble(&reader, "quick_access", "swipe_sensitivity", range: 0.5 ... 3.0, mutations: &mutations) {
      manager.swipeSensitivity = $0
    }

    if let swipeModeStr = reader.string("quick_access", "trackpad_swipe_mode") {
      guard let mode = QuickAccessTrackpadSwipeMode(rawValue: swipeModeStr) else {
        reader.error("quick_access.trackpad_swipe_mode must be natural or inverted")
        return
      }
      mutations.append {
        QuickAccessTrackpadSwipeModeStore.shared.setMode(mode)
      }
    }

    if let actionStr = reader.string("quick_access", "swipe_left_action") {
      if actionStr == "none" {
        mutations.append {
          QuickAccessSwipeActionStore.shared.setAction(.left, action: nil)
        }
      } else if let action = QuickAccessActionKind(rawValue: actionStr) {
        mutations.append {
          QuickAccessSwipeActionStore.shared.setAction(.left, action: action)
        }
      } else {
        reader.error("quick_access.swipe_left_action is invalid")
      }
    }

    if let actionStr = reader.string("quick_access", "swipe_right_action") {
      if actionStr == "none" {
        mutations.append {
          QuickAccessSwipeActionStore.shared.setAction(.right, action: nil)
        }
      } else if let action = QuickAccessActionKind(rawValue: actionStr) {
        mutations.append {
          QuickAccessSwipeActionStore.shared.setAction(.right, action: action)
        }
      } else {
        reader.error("quick_access.swipe_right_action is invalid")
      }
    }

    collectBool(&reader, "quick_access", "hide_card_when_window_open", mutations: &mutations) {
      manager.hideCardWhenWindowOpen = $0
    }

    if let styleStr = reader.string("quick_access", "animation_style") {
      guard let style = QuickAccessAnimationStyle(rawValue: styleStr) else {
        reader.error("quick_access.animation_style must be slide or scale")
        return
      }
      mutations.append {
        manager.animationStyle = style
      }
    }

    let order = reader.stringArray("quick_access", "actions_order")?.compactMap(QuickAccessActionKind.init(rawValue:))
    let enabled = reader.stringArray("quick_access", "enabled_actions")?
      .compactMap(QuickAccessActionKind.init(rawValue:))
    let slots = quickAccessSlots(from: &reader)
    if order != nil || enabled != nil || slots != nil {
      mutations.append {
        QuickAccessActionConfigurationStore.shared.applyConfiguration(
          order: order,
          enabledActions: enabled.map(Set.init),
          slotAssignments: slots
        )
      }
    }
  }

  private static func collectHistory(
    _ reader: inout ShotPasteConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    collectBool(&reader, "history", "enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.historyEnabled)
    }
    collectBool(&reader, "history", "media_clipboard_enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.mediaClipboardEnabled)
    }
    collectInt(&reader, "history", "retention_days", range: 0 ... 90, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.historyRetentionDays)
    }
    collectInt(&reader, "history", "max_count", range: 0 ... 1000, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.historyMaxCount)
    }
    collectEnumString(
      &reader,
      "history",
      "background_style",
      allowed: HistoryBackgroundStyle.allCases.map(\.rawValue),
      mutations: &mutations
    ) {
      defaults.set($0, forKey: PreferencesKeys.historyBackgroundStyle)
    }
    let manager = HistoryFloatingManager.shared
    collectEnumString(
      &reader,
      "history",
      "floating",
      "position",
      allowed: ["topCenter", "bottomCenter", "center"],
      mutations: &mutations
    ) {
      manager.position = HistoryPanelPosition(rawValue: $0) ?? .topCenter
    }
    if let filter = reader.string("history", "floating", "default_filter") {
      let value = CaptureHistoryCategory(rawValue: filter)
      if value == nil {
        reader.error("history.floating.default_filter is invalid")
      } else {
        mutations.append { manager.defaultFilter = value }
      }
    }
    collectDouble(
      &reader,
      "history",
      "floating",
      "scale",
      range: HistoryFloatingLayout.scaleRange,
      mutations: &mutations
    ) {
      manager.panelScale = $0
    }
  }

  private static func collectAfterCapture(
    _ reader: inout ShotPasteConfigurationReader,
    type: CaptureType,
    mutations: inout [() -> Void]
  ) {
    let mapping: [(String, AfterCaptureAction)] = [
      ("save", .save),
      ("quick_access", .showQuickAccess),
      ("copy_file", .copyFile),
    ]

    for (key, action) in mapping {
      collectBool(&reader, "capture", "after", type.rawValue, key, mutations: &mutations) {
        PreferencesManager.shared.setAction(action, for: type, enabled: $0)
      }
    }
  }

  private static func collectAgent(
    _ reader: inout ShotPasteConfigurationReader,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    let currentProtocol = AgentProviderConfiguration.current(defaults: defaults).apiProtocol
    var importedProtocol: AgentProviderAPIProtocol?
    if let rawProtocol = reader.string("agent", "api_protocol") {
      if let value = AgentProviderAPIProtocol(rawValue: rawProtocol) {
        importedProtocol = value
      } else {
        reader
          .error(
            "agent.api_protocol must be one of: \(AgentProviderAPIProtocol.allCases.map(\.rawValue).joined(separator: ", "))"
          )
      }
    }
    let effectiveProtocol = importedProtocol ?? currentProtocol

    if let enabled = reader.bool("agent", "enabled") {
      mutations.append {
        defaults.set(enabled, forKey: PreferencesKeys.agentModeEnabled)
        if defaults == .standard {
          AgentModeController.shared.setEnabled(enabled)
        }
      }
    }
    let importedEndpoint = reader.string("agent", "endpoint")
    if let endpoint = importedEndpoint {
      let candidate = AgentProviderConfiguration(
        endpoint: endpoint,
        model: AgentProviderConfiguration.defaultModel(for: effectiveProtocol),
        thinkingEnabled: true,
        sendsImages: true,
        maxActions: 30,
        apiProtocol: effectiveProtocol
      )
      if candidate.endpointURL == nil {
        reader.error("agent.endpoint must be HTTPS, or HTTP on localhost")
      } else {
        mutations.append { defaults.set(endpoint, forKey: PreferencesKeys.agentProviderEndpoint) }
      }
    }
    let importedModel = reader.string("agent", "model")
    if let model = importedModel {
      if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reader.error("agent.model must not be empty")
      } else {
        mutations.append { defaults.set(model, forKey: PreferencesKeys.agentProviderModel) }
      }
    }
    if let importedProtocol {
      mutations.append {
        let oldProtocol = defaults.string(forKey: PreferencesKeys.agentProviderProtocol)
          .flatMap(AgentProviderAPIProtocol.init(rawValue:)) ?? .openAICompatible
        let endpoint = defaults.string(forKey: PreferencesKeys.agentProviderEndpoint)
          ?? AgentProviderConfiguration.defaultEndpoint(for: oldProtocol)
        let model = defaults.string(forKey: PreferencesKeys.agentProviderModel)
          ?? AgentProviderConfiguration.defaultModel(for: oldProtocol)
        let values = AgentProviderConfiguration.connectionValues(
          switchingFrom: oldProtocol,
          to: importedProtocol,
          endpoint: endpoint,
          model: model
        )
        if importedEndpoint == nil {
          defaults.set(values.endpoint, forKey: PreferencesKeys.agentProviderEndpoint)
        }
        if importedModel == nil {
          defaults.set(values.model, forKey: PreferencesKeys.agentProviderModel)
        }
        defaults.set(importedProtocol.rawValue, forKey: PreferencesKeys.agentProviderProtocol)
      }
    }
    collectBool(&reader, "agent", "thinking_enabled", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.agentThinkingEnabled)
    }
    collectBool(&reader, "agent", "send_images", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.agentProviderSendsImages)
    }
    collectInt(&reader, "agent", "max_actions", range: 1 ... 100, mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.agentMaxActions)
    }
    collectBool(&reader, "agent", "retain_screenshots", mutations: &mutations) {
      defaults.set($0, forKey: PreferencesKeys.agentScreenshotRetentionEnabled)
    }
  }

  private static func collectBool(
    _ reader: inout ShotPasteConfigurationReader,
    _ path: String...,
    mutations: inout [() -> Void],
    apply: @escaping (Bool) -> Void
  ) {
    guard let value = reader.bool(path) else { return }
    mutations.append { apply(value) }
  }

  private static func collectColor(
    _ reader: inout ShotPasteConfigurationReader,
    path: [String],
    defaultsKey: String,
    defaults: UserDefaults,
    mutations: inout [() -> Void]
  ) {
    guard let colorHex = reader.string(path) else { return }
    guard let color = ShotPasteConfigurationColor.color(from: colorHex),
          let data = try? NSKeyedArchiver.archivedData(
            withRootObject: color,
            requiringSecureCoding: true
          ) else {
      reader.error("\(path.joined(separator: ".")) must be #RRGGBB or #RRGGBBAA")
      return
    }
    mutations.append { defaults.set(data, forKey: defaultsKey) }
  }

  private static func collectString(
    _ reader: inout ShotPasteConfigurationReader,
    _ path: String...,
    mutations: inout [() -> Void],
    apply: @escaping (String) -> Void
  ) {
    guard let value = reader.string(path) else { return }
    mutations.append { apply(value) }
  }

  private static func collectEnumString(
    _ reader: inout ShotPasteConfigurationReader,
    _ path: String...,
    allowed: [String],
    mutations: inout [() -> Void],
    apply: @escaping (String) -> Void
  ) {
    guard let value = reader.string(path) else { return }
    guard allowed.contains(value) else {
      reader.error("\(path.joined(separator: ".")) must be one of: \(allowed.joined(separator: ", "))")
      return
    }
    mutations.append { apply(value) }
  }

  private static func collectInt(
    _ reader: inout ShotPasteConfigurationReader,
    _ path: String...,
    range: ClosedRange<Int>,
    mutations: inout [() -> Void],
    apply: @escaping (Int) -> Void
  ) {
    guard let value = reader.int(path) else { return }
    guard range.contains(value) else {
      reader.error("\(path.joined(separator: ".")) must be in \(range.lowerBound)...\(range.upperBound)")
      return
    }
    mutations.append { apply(value) }
  }

  private static func collectDouble(
    _ reader: inout ShotPasteConfigurationReader,
    _ path: String...,
    range: ClosedRange<Double>,
    mutations: inout [() -> Void],
    apply: @escaping (Double) -> Void
  ) {
    guard let value = reader.double(path) else { return }
    guard range.contains(value) else {
      reader.error("\(path.joined(separator: ".")) must be in \(range.lowerBound)...\(range.upperBound)")
      return
    }
    mutations.append { apply(value) }
  }

  private static func appearanceMode(from value: String) -> AppearanceMode? {
    switch value.lowercased() {
    case "system": .system
    case "light": .light
    case "dark": .dark
    default: AppearanceMode(rawValue: value)
    }
  }

  private static func expandedPath(_ path: String) -> String {
    ShotPasteConfigurationPaths.expandedUserPath(path)
  }
}
