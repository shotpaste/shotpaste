//
//  ScreenshotPresetAutoApplier.swift
//  ShotPaste
//
//  Applies the configured Annotate canvas preset to captured screenshots.
//

import AppKit
import Foundation

@MainActor
final class ScreenshotPresetAutoApplier {
  static let shared = ScreenshotPresetAutoApplier(
    presetStore: AnnotateCanvasPresetStore.shared,
    fileAccess: SandboxFileAccessManager.shared
  )

  private static let emptyCanvasPresetPayload = AnnotateCanvasPresetPayload(
    backgroundStyle: CodableBackgroundStyle(from: .none)!,
    isBlurredBackgroundEnabled: false,
    blurredBackgroundEffect: .soft,
    padding: 0,
    shadowIntensity: 0.3,
    cornerRadius: AnnotateCanvasDefaults.cornerRadius,
    aspectRatio: .auto,
    aspectRatioOrientation: .horizontal
  )

  private let presetStore: AnnotateCanvasPresetStore
  private let fileAccess: SandboxFileAccessManager

  init(presetStore: AnnotateCanvasPresetStore, fileAccess: SandboxFileAccessManager) {
    self.presetStore = presetStore
    self.fileAccess = fileAccess
  }

  convenience init(presetStore: AnnotateCanvasPresetStore) {
    self.init(presetStore: presetStore, fileAccess: SandboxFileAccessManager.shared)
  }

  /// Applies the default canvas preset directly to the captured file.
  ///
  /// The output is intentionally flattened; no editable annotation session is
  /// returned or persisted for a later reopen.
  @discardableResult
  func applyDefaultPresetIfNeeded(to url: URL) -> Bool {
    let presets = presetStore.loadPresets()
    guard let defaultPresetId = presetStore.loadDefaultPresetId(validating: presets),
          let preset = presets.first(where: { $0.id == defaultPresetId }) else {
      return false
    }

    guard FileManager.default.fileExists(atPath: url.path) else {
      DiagnosticLogger.shared.log(
        .warning,
        .annotate,
        "Screenshot preset auto-apply skipped; file missing",
        context: ["fileName": url.lastPathComponent]
      )
      return false
    }

    guard let sourceImage = AnnotateState.loadImageWithCorrectScale(from: url) else {
      DiagnosticLogger.shared.log(
        .warning,
        .annotate,
        "Screenshot preset auto-apply skipped; image load failed",
        context: ["fileName": url.lastPathComponent]
      )
      return false
    }

    let effects = Self.canvasEffects(from: preset.payload)

    guard Self.defaultPresetChangesCanvas(preset.payload) else {
      DiagnosticLogger.shared.log(
        .debug,
        .annotate,
        "Screenshot preset auto-apply skipped; preset leaves image unchanged",
        context: ["fileName": url.lastPathComponent, "preset": preset.name]
      )
      return false
    }

    guard let renderedImage = AnnotateExporter.renderCanvasEffects(sourceImage: sourceImage, effects: effects),
          let renderedData = AnnotateExporter.imageData(from: renderedImage, for: url.pathExtension) else {
      DiagnosticLogger.shared.log(
        .error,
        .annotate,
        "Screenshot preset auto-apply failed; render returned no data",
        context: ["fileName": url.lastPathComponent, "preset": preset.name]
      )
      return false
    }

    do {
      try fileAccess.withScopedAccess(to: url.deletingLastPathComponent()) {
        try renderedData.write(to: url, options: .atomic)
      }
    } catch {
      DiagnosticLogger.shared.logError(
        .annotate,
        error,
        "Screenshot preset auto-apply failed; write failed",
        context: ["fileName": url.lastPathComponent, "preset": preset.name]
      )
      return false
    }

    DiagnosticLogger.shared.log(
      .info,
      .annotate,
      "Screenshot preset auto-applied",
      context: ["fileName": url.lastPathComponent, "preset": preset.name]
    )

    return true
  }

  private static func defaultPresetChangesCanvas(_ payload: AnnotateCanvasPresetPayload) -> Bool {
    emptyCanvasPresetPayload.approximatelyEquals(payload) == false
  }

  private static func canvasEffects(from payload: AnnotateCanvasPresetPayload) -> AnnotationCanvasEffects {
    let backgroundStyle = payload.backgroundStyle.toBackgroundStyle()
    return AnnotationCanvasEffects(
      backgroundStyle: backgroundStyle,
      isBlurredBackgroundEnabled: payload.isBlurredBackgroundEnabled && backgroundStyle.supportsBlurredBackgroundEffect,
      blurredBackgroundEffect: payload.blurredBackgroundEffect,
      padding: payload.padding,
      inset: 0,
      autoBalance: true,
      shadowIntensity: payload.shadowIntensity,
      cornerRadius: payload.cornerRadius,
      imageAlignment: .center,
      aspectRatio: payload.aspectRatio,
      aspectRatioOrientation: payload.aspectRatioOrientation
    )
  }
}
