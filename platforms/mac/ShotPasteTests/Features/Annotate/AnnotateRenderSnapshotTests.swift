//
//  AnnotateRenderSnapshotTests.swift
//  ShotPasteTests
//
//  Tests for the snapshot-based off-main render path (save-and-close flow).
//

import AppKit
@testable import ShotPaste
import SwiftUI
import XCTest

@MainActor
final class AnnotateRenderSnapshotTests: XCTestCase {
  /// Keep AnnotateState alive for the test process; XCTest scope cleanup can
  /// crash while deinitializing this MainActor app-level ObservableObject.
  @MainActor private static var retainedStates: [AnnotateState] = []

  @MainActor
  private func makeState() -> AnnotateState {
    let state = AnnotateState()
    Self.retainedStates.append(state)
    return state
  }

  private func makeSourceImage(width: Int = 120, height: Int = 80) throws -> NSImage {
    let cgImage = try XCTUnwrap(TestImageFactory.solidColor(width: width, height: height))
    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }

  // MARK: - Snapshot equivalence

  /// The off-main snapshot render must produce byte-identical output to the
  /// legacy main-actor state render (file output must not change).
  func testSnapshotRender_matchesStateRender() async throws {
    let state = makeState()
    state.sourceImage = try makeSourceImage()
    state.annotations = [
      AnnotationItem(
        type: .rectangle,
        bounds: CGRect(x: 10, y: 10, width: 40, height: 30),
        properties: AnnotationProperties(strokeColor: .red, strokeWidth: 3)
      ),
      AnnotationItem(
        type: .text("Hi"),
        bounds: CGRect(x: 20, y: 40, width: 60, height: 20),
        properties: AnnotationProperties(fontSize: 14)
      ),
    ]

    let reference = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let renderedImage = await AnnotateExporter.renderFinalImage(snapshot: snapshot)
    let rendered = try XCTUnwrap(renderedImage)

    XCTAssertEqual(rendered.size, reference.size)
    XCTAssertEqual(rendered.tiffRepresentation, reference.tiffRepresentation)
  }

  /// Canvas effects (gradient background + padding) must flow through the snapshot.
  func testSnapshotRender_withCanvasEffects_matchesStateRender() async throws {
    let state = makeState()
    state.sourceImage = try makeSourceImage()
    state.backgroundStyle = .gradient(.pinkOrange)
    state.padding = 24
    state.cornerRadius = 8

    let reference = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())
    let renderedImage = await AnnotateExporter.renderFinalImage(snapshot: snapshot)
    let rendered = try XCTUnwrap(renderedImage)

    XCTAssertEqual(rendered.size, reference.size)
    XCTAssertEqual(rendered.tiffRepresentation, reference.tiffRepresentation)
  }

  // MARK: - Snapshot freezing

  /// Mutating state after the snapshot is taken must not change the render output
  /// (proves the snapshot is a frozen copy, not a live reference).
  func testSnapshot_isFrozenAgainstLaterStateMutation() async throws {
    let state = makeState()
    state.sourceImage = try makeSourceImage()
    state.annotations = [
      AnnotationItem(
        type: .rectangle,
        bounds: CGRect(x: 10, y: 10, width: 40, height: 30),
        properties: AnnotationProperties(strokeColor: .red, strokeWidth: 3)
      ),
    ]

    let reference = try XCTUnwrap(AnnotateExporter.renderFinalImage(state: state))
    let snapshot = try XCTUnwrap(state.makeRenderSnapshot())

    // Mutate live state after snapshotting
    state.annotations = []

    let renderedImage = await AnnotateExporter.renderFinalImage(snapshot: snapshot)
    let rendered = try XCTUnwrap(renderedImage)
    XCTAssertEqual(rendered.size, reference.size)
    XCTAssertEqual(rendered.tiffRepresentation, reference.tiffRepresentation)
  }

  // MARK: - cgScaleThumbnail

  func testCgScaleThumbnail_downscalesKeepingAspect() throws {
    let image = try makeSourceImage(width: 400, height: 200)
    let thumb = QuickAccessManager.cgScaleThumbnail(image, maxSize: 200)
    XCTAssertEqual(thumb.size.width, 200, accuracy: 1)
    XCTAssertEqual(thumb.size.height, 100, accuracy: 1)
  }

  func testCgScaleThumbnail_doesNotUpscale() throws {
    let image = try makeSourceImage(width: 100, height: 50)
    let thumb = QuickAccessManager.cgScaleThumbnail(image, maxSize: 200)
    XCTAssertEqual(thumb.size, image.size)
  }

  // MARK: - Save generation guard

  /// A stale (older-generation) async thumbnail push must be dropped so the
  /// last save always wins, even if its render finishes first.
  func testUpdateItemThumbnail_dropsStaleGeneration() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("capture.png")
    let image = try makeSourceImage()
    try XCTUnwrap(image.tiffRepresentation).write(to: fileURL)

    await QuickAccessManager.shared.addScreenshot(url: fileURL)
    guard let item = QuickAccessManager.shared.items.first(where: { $0.url == fileURL }) else {
      return XCTFail("Item was not added")
    }
    defer { QuickAccessManager.shared.removeItem(id: item.id) }

    let manager = QuickAccessManager.shared
    let gen1 = manager.nextThumbnailGeneration(for: item.id)
    let gen2 = manager.nextThumbnailGeneration(for: item.id)
    XCTAssertLessThan(gen1, gen2)

    let versionBefore = try XCTUnwrap(manager.items.first { $0.id == item.id }).thumbnailVersion

    // Stale push (older generation) must be dropped
    manager.updateItemThumbnail(id: item.id, thumbnail: image, fullResImage: nil, generation: gen1)
    let versionAfterStale = try XCTUnwrap(manager.items.first { $0.id == item.id }).thumbnailVersion
    XCTAssertEqual(versionAfterStale, versionBefore)

    // Current-generation push must be applied
    manager.updateItemThumbnail(id: item.id, thumbnail: image, fullResImage: nil, generation: gen2)
    let versionAfterFresh = try XCTUnwrap(manager.items.first { $0.id == item.id }).thumbnailVersion
    XCTAssertNotEqual(versionAfterFresh, versionBefore)
  }
}
