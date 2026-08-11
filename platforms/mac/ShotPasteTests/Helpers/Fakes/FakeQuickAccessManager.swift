//
//  FakeQuickAccessManager.swift
//  ShotPasteTests
//
//  Records QuickAccessManaging calls for assertion.
//

import AppKit
import Foundation
@testable import ShotPaste

@MainActor
final class FakeQuickAccessManager: QuickAccessManaging {
  private(set) var addedScreenshots: [URL] = []
  private(set) var addedVideos: [URL] = []
  private(set) var createdScreenshotItems: [QuickAccessItem] = []
  private(set) var createdVideoItems: [QuickAccessItem] = []
  private(set) var pinnedScreenshotIDs: [UUID] = []
  private(set) var pinnedScreenshotURLs: [URL] = []
  var onAddScreenshot: ((URL) -> Void)?
  var onAddVideo: ((URL) -> Void)?

  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem? {
    onAddScreenshot?(url)
    addedScreenshots.append(url)
    let item = QuickAccessItem(url: url, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
    createdScreenshotItems.append(item)
    return item
  }

  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem? {
    onAddVideo?(url)
    addedVideos.append(url)
    let item = QuickAccessItem(
      url: url,
      thumbnail: NSImage(size: NSSize(width: 1, height: 1)),
      duration: 0
    )
    createdVideoItems.append(item)
    return item
  }

  func pinScreenshot(id: UUID) {
    pinnedScreenshotIDs.append(id)
  }

  @discardableResult
  func pinScreenshot(url: URL) async -> QuickAccessItem? {
    pinnedScreenshotURLs.append(url)
    let item = QuickAccessItem(url: url, thumbnail: NSImage(size: NSSize(width: 1, height: 1)))
    createdScreenshotItems.append(item)
    return item
  }
}
