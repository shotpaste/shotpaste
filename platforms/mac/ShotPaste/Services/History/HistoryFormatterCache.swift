//
//  HistoryFormatterCache.swift
//  ShotPaste
//
//  Centralized, thread-safe formatter cache for History views and records
//

import Foundation

enum HistoryFormatterCache {
  static let relativeShort: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  static let recordDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  static let fileSize: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()
}
