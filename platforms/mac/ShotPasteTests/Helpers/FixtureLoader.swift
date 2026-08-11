//
//  FixtureLoader.swift
//  ShotPasteTests
//
//  Loads test fixture files from the test bundle.
//

import Foundation

enum FixtureLoader {
  private static var fixturesDirectory: URL {
    let testBundle = Bundle(for: FixtureLoaderClass.self)
    return testBundle.bundleURL
      .deletingLastPathComponent()
      .appendingPathComponent("ShotPasteTests", isDirectory: true)
      .appendingPathComponent("Fixtures", isDirectory: true)
  }

  static func url(for path: String) -> URL {
    fixturesDirectory.appendingPathComponent(path)
  }

  static func data(for path: String) throws -> Data {
    try Data(contentsOf: url(for: path))
  }

  static func string(for path: String) throws -> String {
    try String(contentsOf: url(for: path), encoding: .utf8)
  }
}

private final class FixtureLoaderClass {}
