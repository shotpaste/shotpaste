//
//  UserDefaultsFactory.swift
//  ShotPasteTests
//
//  Creates isolated UserDefaults instances for tests.
//

import Foundation

enum UserDefaultsFactory {
  static func make(
    file _: StaticString = #filePath,
    line _: UInt = #line
  ) -> UserDefaults {
    let suiteName = "ShotPasteTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Failed to create UserDefaults with suiteName \(suiteName)")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
