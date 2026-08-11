//
//  AnnotateCanvasPresetActionTests.swift
//  ShotPasteTests
//
//  Characterization tests for canvas preset CRUD (isolated UserDefaults) and
//  canvas effect apply/reset actions on AnnotateState. Preset persistence is
//  routed through an injected AnnotateCanvasPresetStore backed by an isolated
//  UserDefaults so tests never touch the global UserDefaults.
//

import AppKit
import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class AnnotateCanvasPresetActionTests: XCTestCase {
  // Keep AnnotateState alive for the test process; XCTest scope cleanup can
  // crash while deinitializing this MainActor app-level ObservableObject.
  private static var retainedAnnotateStates: [AnnotateState] = []
  private static var retainedCanvasPresetStores: [AnnotateCanvasPresetStore] = []
  private static var retainedUserDefaults: [UserDefaults] = []

  private func makeCanvasPresetStore() -> (AnnotateCanvasPresetStore, UserDefaults) {
    let defaults = UserDefaultsFactory.make()
    let store = AnnotateCanvasPresetStore(defaults: defaults)
    Self.retainedUserDefaults.append(defaults)
    Self.retainedCanvasPresetStores.append(store)
    return (store, defaults)
  }

  private func makeAnnotateState(
    store: AnnotateCanvasPresetStore,
    defaults: UserDefaults
  ) -> AnnotateState {
    let state = AnnotateState(
      image: NSImage(size: NSSize(width: 40, height: 40)),
      url: URL(fileURLWithPath: "/tmp/shotpaste-canvas-preset-tests.png"),
      defaults: defaults,
      canvasPresetStore: store
    )
    Self.retainedAnnotateStates.append(state)
    return state
  }

  private func makePayload(
    background: BackgroundStyle = .gradient(.bluePurple),
    padding: CGFloat = 40,
    shadowIntensity: CGFloat = 0.3,
    cornerRadius: CGFloat = 12
  ) -> AnnotateCanvasPresetPayload {
    AnnotateCanvasPresetPayload(
      backgroundStyle: CodableBackgroundStyle(from: background)!,
      padding: padding,
      shadowIntensity: shadowIntensity,
      cornerRadius: cornerRadius
    )
  }

  // MARK: - applyCanvasPreset

  func testApplyCanvasPresetSetsCanvasFieldsAndMarksUnsaved() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.hasUnsavedChanges = false

    let preset = AnnotateCanvasPreset(
      name: "Vivid",
      payload: makePayload(background: .gradient(.orangeRed), padding: 56, shadowIntensity: 0.42, cornerRadius: 20)
    )

    state.applyCanvasPreset(preset)

    XCTAssertEqual(state.backgroundStyle, .gradient(.orangeRed))
    XCTAssertEqual(state.padding, 56)
    XCTAssertEqual(state.shadowIntensity, 0.42)
    XCTAssertEqual(state.cornerRadius, 20)
    XCTAssertEqual(state.selectedCanvasPresetId, preset.id)
    XCTAssertFalse(state.isSelectedCanvasPresetDirty)
    XCTAssertTrue(state.hasUnsavedChanges)
  }

  func testApplyCanvasPresetWithoutMarkingUnsavedKeepsCleanState() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.hasUnsavedChanges = false

    let preset = AnnotateCanvasPreset(
      name: "Quiet",
      payload: makePayload(background: .gradient(.bluePurple), padding: 32, shadowIntensity: 0.2, cornerRadius: 8)
    )

    state.applyCanvasPreset(preset, marksUnsaved: false)

    XCTAssertEqual(state.padding, 32)
    XCTAssertEqual(state.selectedCanvasPresetId, preset.id)
    XCTAssertFalse(state.hasUnsavedChanges)
    XCTAssertTrue(state.isDefaultCanvasPresetAutoApplied)
  }

  // MARK: - saveCurrentCanvasAsPreset

  func testSaveCurrentCanvasAsPresetPersistsToIsolatedStore() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.backgroundStyle = .gradient(.orangeRed)
    state.padding = 48
    state.shadowIntensity = 0.35
    state.cornerRadius = 16

    let result = state.saveCurrentCanvasAsPreset(name: "Share Layout")

    XCTAssertEqual(result, .success)
    XCTAssertEqual(state.canvasPresets.count, 1)

    let persisted = store.loadPresets()
    XCTAssertEqual(persisted.count, 1)
    let saved = persisted.first
    XCTAssertEqual(saved?.name, "Share Layout")
    XCTAssertEqual(saved?.payload.padding, 48)
    XCTAssertEqual(saved?.payload.shadowIntensity, 0.35)
    XCTAssertEqual(saved?.payload.cornerRadius, 16)
    XCTAssertEqual(saved?.payload.backgroundStyle.toBackgroundStyle(), .gradient(.orangeRed))
    XCTAssertEqual(state.selectedCanvasPresetId, saved?.id)
  }

  func testSaveCurrentCanvasAsPresetRejectsBlankName() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)

    let result = state.saveCurrentCanvasAsPreset(name: "   ")

    XCTAssertEqual(result, .invalidName)
    XCTAssertTrue(state.canvasPresets.isEmpty)
    XCTAssertTrue(store.loadPresets().isEmpty)
  }

  func testSaveCurrentCanvasAsPresetLeavesGlobalUserDefaultsUntouched() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.backgroundStyle = .gradient(.bluePurple)
    state.padding = 24

    XCTAssertEqual(state.saveCurrentCanvasAsPreset(name: "Isolated"), .success)

    XCTAssertNotNil(defaults.data(forKey: PreferencesKeys.annotateCanvasPresets))
    XCTAssertNil(UserDefaults.standard.data(forKey: PreferencesKeys.annotateCanvasPresets))
  }

  // MARK: - updateSelectedCanvasPreset

  func testUpdateSelectedCanvasPresetPersistsMutatedPayload() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.backgroundStyle = .gradient(.bluePurple)
    state.padding = 20
    XCTAssertEqual(state.saveCurrentCanvasAsPreset(name: "Editable"), .success)
    let presetId = state.selectedCanvasPresetId

    state.padding = 72
    state.cornerRadius = 24
    let result = state.updateSelectedCanvasPreset()

    XCTAssertEqual(result, .success)
    XCTAssertFalse(state.isSelectedCanvasPresetDirty)

    let persisted = store.loadPresets().first(where: { $0.id == presetId })
    XCTAssertEqual(persisted?.payload.padding, 72)
    XCTAssertEqual(persisted?.payload.cornerRadius, 24)
  }

  func testUpdateSelectedCanvasPresetReturnsMissingSelectionWhenNoneSelected() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.selectedCanvasPresetId = nil

    XCTAssertEqual(state.updateSelectedCanvasPreset(), .missingSelection)
  }

  // MARK: - deleteCanvasPreset

  func testDeleteCanvasPresetRemovesFromStoreAndReturnsTrue() throws {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.backgroundStyle = .gradient(.orangeRed)
    state.padding = 30
    XCTAssertEqual(state.saveCurrentCanvasAsPreset(name: "Disposable"), .success)
    let presetId = try XCTUnwrap(state.selectedCanvasPresetId)

    let deleted = state.deleteCanvasPreset(id: presetId)

    XCTAssertTrue(deleted)
    XCTAssertTrue(state.canvasPresets.isEmpty)
    XCTAssertNil(state.selectedCanvasPresetId)
    XCTAssertTrue(store.loadPresets().isEmpty)
  }

  func testDeleteCanvasPresetWithUnknownIdReturnsFalse() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.padding = 18
    XCTAssertEqual(state.saveCurrentCanvasAsPreset(name: "Kept"), .success)

    let deleted = state.deleteCanvasPreset(id: UUID())

    XCTAssertFalse(deleted)
    XCTAssertEqual(state.canvasPresets.count, 1)
    XCTAssertEqual(store.loadPresets().count, 1)
  }

  // MARK: - Canvas effects apply / reset

  func testApplyCanvasEffectsSetsEffectFieldsFromSnapshot() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)

    let effects = AnnotationCanvasEffects(
      backgroundStyle: .gradient(.orangeRed),
      isBlurredBackgroundEnabled: false,
      blurredBackgroundEffect: .soft,
      padding: 64,
      inset: 6,
      autoBalance: false,
      shadowIntensity: 0.5,
      cornerRadius: 22,
      imageAlignment: .center,
      aspectRatio: .auto,
      aspectRatioOrientation: .horizontal
    )

    state.applyCanvasEffects(effects)

    XCTAssertEqual(state.backgroundStyle, .gradient(.orangeRed))
    XCTAssertEqual(state.padding, 64)
    XCTAssertEqual(state.inset, 6)
    XCTAssertFalse(state.autoBalance)
    XCTAssertEqual(state.shadowIntensity, 0.5)
    XCTAssertEqual(state.cornerRadius, 22)
    XCTAssertEqual(state.aspectRatio, .auto)
  }

  func testResetCanvasEffectsToNoneReturnsDefaults() {
    let (store, defaults) = makeCanvasPresetStore()
    let state = makeAnnotateState(store: store, defaults: defaults)
    state.backgroundStyle = .gradient(.bluePurple)
    state.padding = 80
    state.shadowIntensity = 0.6
    state.cornerRadius = 30
    state.aspectRatio = .auto
    state.selectedCanvasPresetId = UUID()

    state.resetCanvasEffectsToNone()

    XCTAssertEqual(state.backgroundStyle, .none)
    XCTAssertFalse(state.isBlurredBackgroundEnabled)
    XCTAssertEqual(state.blurredBackgroundEffect, .soft)
    XCTAssertEqual(state.padding, 0)
    XCTAssertEqual(state.shadowIntensity, 0)
    XCTAssertEqual(state.cornerRadius, 0)
    XCTAssertEqual(state.aspectRatio, .auto)
    XCTAssertNil(state.selectedCanvasPresetId)
    XCTAssertFalse(state.isSelectedCanvasPresetDirty)
    XCTAssertTrue(state.isNoneCanvasEffectsActive)
  }
}
