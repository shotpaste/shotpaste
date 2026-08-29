//
//  AudioHistoryMetadataLoader.swift
//  ShotPaste
//
//  Non-blocking metadata loading for audio history cards.
//

import Foundation

/// Loads audio metadata lazily so history rendering never waits on AVAsset I/O.
enum AudioHistoryMetadataLoader {
  /// Read duration asynchronously. AVFoundation performs the asset load off the
  /// caller's synchronous stack; callers can safely invoke this from SwiftUI's
  /// main-actor `.task` without blocking card layout or capture completion.
  static func duration(for url: URL) async -> TimeInterval? {
    let validation = await AudioAssetValidator.validate(url: url)
    return validation.isValid ? validation.duration : nil
  }
}
