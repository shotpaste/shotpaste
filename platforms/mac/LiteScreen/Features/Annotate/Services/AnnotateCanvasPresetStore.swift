//
//  AnnotateCanvasPresetStore.swift
//  LiteScreen
//
//  Persistence for annotate canvas presets
//

import Foundation

@MainActor
final class AnnotateCanvasPresetStore {
  static let shared = AnnotateCanvasPresetStore()

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    encoder.outputFormatting = []
  }

  func loadPresets() -> [AnnotateCanvasPreset] {
    guard let data = defaults.data(forKey: PreferencesKeys.annotateCanvasPresets) else {
      return []
    }

    do {
      let decoded = try decoder.decode([AnnotateCanvasPreset].self, from: data)
      return decoded.sorted(by: { $0.updatedAt > $1.updatedAt })
    } catch {
      defaults.removeObject(forKey: PreferencesKeys.annotateCanvasPresets)
      return []
    }
  }

  func savePresets(_ presets: [AnnotateCanvasPreset]) {
    do {
      let data = try encoder.encode(presets)
      defaults.set(data, forKey: PreferencesKeys.annotateCanvasPresets)
      pruneDefaultPresetIfNeeded(validPresetIds: Set(presets.map(\.id)))
    } catch {
      print("Failed to save annotate canvas presets: \(error.localizedDescription)")
    }
  }

  func loadDefaultPresetId(validating presets: [AnnotateCanvasPreset]) -> UUID? {
    guard let id = loadDefaultPresetId() else { return nil }
    guard presets.contains(where: { $0.id == id }) else {
      clearDefaultPresetId()
      return nil
    }
    return id
  }

  func saveDefaultPresetId(_ id: UUID?) {
    guard let id else {
      clearDefaultPresetId()
      return
    }
    defaults.set(id.uuidString, forKey: PreferencesKeys.annotateDefaultCanvasPresetId)
  }

  func clearDefaultPresetId() {
    defaults.removeObject(forKey: PreferencesKeys.annotateDefaultCanvasPresetId)
  }

  private func loadDefaultPresetId() -> UUID? {
    guard let rawValue = defaults.string(forKey: PreferencesKeys.annotateDefaultCanvasPresetId) else {
      return nil
    }

    guard let id = UUID(uuidString: rawValue) else {
      clearDefaultPresetId()
      return nil
    }

    return id
  }

  private func pruneDefaultPresetIfNeeded(validPresetIds: Set<UUID>) {
    guard let id = loadDefaultPresetId(),
          validPresetIds.contains(id) == false else { return }
    clearDefaultPresetId()
  }
}
