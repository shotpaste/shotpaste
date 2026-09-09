//
//  QuickAccessManaging.swift
//  ShotPaste
//
//  Protocol extracted from QuickAccessManager for DI.
//

import Foundation

@MainActor
protocol QuickAccessManaging {
  @discardableResult
  func addScreenshot(url: URL) async -> QuickAccessItem?

  @discardableResult
  func addVideo(url: URL) async -> QuickAccessItem?

  /// Add an audio-only capture without routing it through video thumbnail
  /// generation. The default keeps lightweight test/dedicated conformers
  /// source-compatible until they opt into audio presentation.
  @discardableResult
  func addAudio(url: URL) async -> QuickAccessItem?

  func pinScreenshot(id: UUID)

  @discardableResult
  func pinScreenshot(url: URL) async -> QuickAccessItem?
}

extension QuickAccessManager: QuickAccessManaging {}

extension QuickAccessManaging {
  @discardableResult
  func addAudio(url _: URL) async -> QuickAccessItem? {
    nil
  }
}
