//
//  RecordingAnnotationState.swift
//  ShotPaste
//
//  Lightweight state for annotations during screen recording
//  Supports per-tool auto-clear (time-based and count-based)
//

import AppKit
import Combine
import SwiftUI

// MARK: - Auto-Clear Mode

enum AnnotationClearMode: Equatable, Hashable {
  case persist
  case timeBased(seconds: Double)
  case countBased(count: Int)

  var displayName: String {
    switch self {
    case .persist: L10n.RecordingAnnotation.persist
    case .timeBased(let s): "\(Int(s))s"
    case .countBased(let c): L10n.RecordingAnnotation.lastCount(c)
    }
  }
}

// MARK: - Annotation Entry (wraps AnnotationItem with lifecycle metadata)

struct RecordingAnnotationEntry: Identifiable, Equatable {
  let id: UUID
  var item: AnnotationItem
  let createdAt: Date
  let createdByTool: AnnotationToolType
  let clearMode: AnnotationClearMode
  var opacity: Double = 1.0

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.opacity == rhs.opacity
  }
}

// MARK: - Recording Annotation State

@MainActor
final class RecordingAnnotationState: ObservableObject {
  @Published var annotations: [RecordingAnnotationEntry] = []
  @Published var selectedTool: AnnotationToolType = .selection
  @Published var selectedAnnotationId: UUID?
  @Published var strokeColor: Color
  @Published var strokeWidth: CGFloat
  @Published var isAnnotationEnabled: Bool = false {
    didSet {
      if !isAnnotationEnabled {
        selectedTool = .selection
      }
    }
  }

  @Published var toolClearModes: [AnnotationToolType: AnnotationClearMode] = [:]

  private let defaults: UserDefaults
  private var cleanupTimer: Timer?
  private var cancellables = Set<AnyCancellable>()
  private let fadeEnabled: Bool
  private let fadeDuration: Double
  private let temporaryModifier: RecordingAnnotationTemporaryModifier
  private let temporaryClearMode: AnnotationClearMode

  static let availableTools: [AnnotationToolType] = [
    .selection, .rectangle, .oval, .arrow, .line, .pencil, .highlighter,
  ]

  static let clearModePresets: [AnnotationClearMode] = [
    .persist,
    .timeBased(seconds: 3),
    .timeBased(seconds: 5),
    .timeBased(seconds: 10),
    .countBased(count: 3),
    .countBased(count: 5),
    .countBased(count: 10),
  ]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let annotationColor = RecordingOverlayColorPreferences.color(
      forKey: PreferencesKeys.recordingAnnotationColor,
      default: RecordingAnnotationPreferences.defaultColor,
      defaults: defaults
    )
    strokeColor = Color(nsColor: annotationColor)
    strokeWidth = CGFloat(
      defaults.object(forKey: PreferencesKeys.recordingAnnotationWidth) as? Double
        ?? RecordingAnnotationPreferences.defaultWidth
    )
    let defaultMode = RecordingAnnotationPreferences.clearMode(
      rawValue: defaults.string(forKey: PreferencesKeys.recordingAnnotationClearMode) ?? "manual",
      seconds: defaults.object(forKey: PreferencesKeys.recordingAnnotationClearSeconds) as? Double
        ?? RecordingAnnotationPreferences.defaultClearSeconds,
      count: defaults.object(forKey: PreferencesKeys.recordingAnnotationMaxCount) as? Int
        ?? RecordingAnnotationPreferences.defaultMaxCount
    )
    toolClearModes = Self.loadToolClearModes(
      defaults: defaults,
      fallback: defaultMode
    )
    fadeEnabled = defaults.object(forKey: PreferencesKeys.recordingAnnotationFadeEnabled) as? Bool ?? true
    fadeDuration = min(
      max(defaults.object(forKey: PreferencesKeys.recordingAnnotationFadeDuration) as? Double ?? 0.35, 0.05),
      3.0
    )
    temporaryModifier = RecordingAnnotationTemporaryModifier(
      rawValue: defaults.string(forKey: PreferencesKeys.recordingAnnotationTemporaryModifier) ?? "shift"
    ) ?? .shift
    temporaryClearMode = RecordingAnnotationPreferences.clearMode(
      rawValue: defaults.string(forKey: PreferencesKeys.recordingAnnotationTemporaryClearMode) ?? "manual",
      seconds: defaults.object(forKey: PreferencesKeys.recordingAnnotationClearSeconds) as? Double
        ?? RecordingAnnotationPreferences.defaultClearSeconds,
      count: defaults.object(forKey: PreferencesKeys.recordingAnnotationMaxCount) as? Int
        ?? RecordingAnnotationPreferences.defaultMaxCount
    )
    $toolClearModes
      .dropFirst()
      .sink { [weak self] modes in
        self?.persistToolClearModes(modes)
      }
      .store(in: &cancellables)
  }

  func clearMode(for tool: AnnotationToolType) -> AnnotationClearMode {
    toolClearModes[tool] ?? .persist
  }

  // MARK: - Annotation Management

  func appendAnnotation(
    _ item: AnnotationItem,
    tool: AnnotationToolType,
    temporaryOverride: AnnotationClearMode? = nil
  ) {
    let entryClearMode = temporaryOverride ?? clearMode(for: tool)
    let entry = RecordingAnnotationEntry(
      id: item.id,
      item: item,
      createdAt: Date(),
      createdByTool: tool,
      clearMode: entryClearMode
    )
    annotations.append(entry)
    enforceCountLimit(for: tool, mode: entryClearMode)
  }

  func temporaryClearMode(for modifierFlags: NSEvent.ModifierFlags) -> AnnotationClearMode? {
    temporaryModifier.matches(modifierFlags) ? temporaryClearMode : nil
  }

  func clearAll() {
    annotations.removeAll()
    selectedAnnotationId = nil
  }

  func deleteSelected() {
    guard let selectedId = selectedAnnotationId else { return }
    annotations.removeAll { $0.id == selectedId }
    selectedAnnotationId = nil
  }

  // MARK: - Cleanup Timer

  func startCleanupTimer() {
    cleanupTimer?.invalidate()
    cleanupTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.removeExpired()
      }
    }
  }

  func stopCleanupTimer() {
    cleanupTimer?.invalidate()
    cleanupTimer = nil
  }

  // MARK: - Private Cleanup

  private func removeExpired() {
    let now = Date()
    var changed = false

    annotations = annotations.compactMap { entry in
      guard case .timeBased(let seconds) = entry.clearMode else { return entry }

      let elapsed = now.timeIntervalSince(entry.createdAt)
      let effectiveFadeDuration = fadeEnabled ? min(fadeDuration, seconds) : 0
      let fadeStart = seconds - effectiveFadeDuration

      if elapsed >= seconds {
        changed = true
        return nil // Remove
      } else if effectiveFadeDuration > 0, elapsed >= fadeStart {
        var fading = entry
        fading.opacity = max(0, 1.0 - (elapsed - fadeStart) / effectiveFadeDuration)
        changed = true
        return fading
      }
      return entry
    }

    if changed {
      objectWillChange.send()
    }
  }

  private func enforceCountLimit(for tool: AnnotationToolType, mode: AnnotationClearMode) {
    guard case .countBased(let maxCount) = mode else { return }

    let toolEntries = annotations.filter { $0.createdByTool == tool }
    guard toolEntries.count > maxCount else { return }

    let excess = toolEntries.count - maxCount
    let idsToRemove = Set(toolEntries.prefix(excess).map(\.id))
    annotations.removeAll { idsToRemove.contains($0.id) }
  }

  private func persistToolClearModes(_ modes: [AnnotationToolType: AnnotationClearMode]) {
    for (tool, mode) in modes {
      defaults.set(
        Self.storedValue(for: mode),
        forKey: Self.toolPolicyKey(for: tool)
      )
    }
  }

  private static func loadToolClearModes(
    defaults: UserDefaults,
    fallback: AnnotationClearMode
  ) -> [AnnotationToolType: AnnotationClearMode] {
    var modes = Dictionary(uniqueKeysWithValues: availableTools.map { ($0, fallback) })
    for tool in availableTools {
      guard let stored = defaults.string(forKey: toolPolicyKey(for: tool)),
            let mode = storedClearMode(from: stored) else { continue }
      modes[tool] = mode
    }
    return modes
  }

  private static func toolPolicyKey(for tool: AnnotationToolType) -> String {
    "\(PreferencesKeys.recordingAnnotationToolPolicies).\(tool.rawValue)"
  }

  private static func storedValue(for clearMode: AnnotationClearMode) -> String {
    switch clearMode {
    case .persist:
      "manual"
    case .timeBased(let seconds):
      "afterSeconds:\(seconds)"
    case .countBased(let count):
      "maximumCount:\(count)"
    }
  }

  private static func storedClearMode(from value: String) -> AnnotationClearMode? {
    let components = value.split(separator: ":", maxSplits: 1).map(String.init)
    switch components.first {
    case "manual":
      return .persist
    case "afterSeconds":
      guard components.count == 2, let seconds = Double(components[1]) else { return nil }
      return RecordingAnnotationPreferences.clearMode(
        rawValue: "afterSeconds",
        seconds: seconds,
        count: RecordingAnnotationPreferences.defaultMaxCount
      )
    case "maximumCount":
      guard components.count == 2, let count = Int(components[1]) else { return nil }
      return RecordingAnnotationPreferences.clearMode(
        rawValue: "maximumCount",
        seconds: RecordingAnnotationPreferences.defaultClearSeconds,
        count: count
      )
    default:
      return nil
    }
  }
}

enum RecordingAnnotationTemporaryModifier: String, CaseIterable, Identifiable {
  case shift
  case control
  case option
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .shift: "Shift"
    case .control: "Control"
    case .option: "Option"
    case .none: "Off"
    }
  }

  func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
    switch self {
    case .shift: flags.contains(.shift)
    case .control: flags.contains(.control)
    case .option: flags.contains(.option)
    case .none: false
    }
  }
}

enum RecordingAnnotationPreferences {
  static let defaultColor = NSColor(
    srgbRed: 124.0 / 255.0,
    green: 58.0 / 255.0,
    blue: 237.0 / 255.0,
    alpha: 1.0
  )
  static let defaultWidth = 4.0
  static let defaultClearSeconds = 5.0
  static let defaultMaxCount = 12

  static func clearMode(rawValue: String, seconds: Double, count: Int) -> AnnotationClearMode {
    switch rawValue.lowercased() {
    case "afterseconds", "timebased":
      .timeBased(seconds: min(max(seconds, 1), 300))
    case "maximumcount", "countbased":
      .countBased(count: min(max(count, 1), 100))
    default:
      .persist
    }
  }
}
