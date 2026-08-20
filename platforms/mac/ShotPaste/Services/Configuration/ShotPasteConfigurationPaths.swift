//
//  ShotPasteConfigurationPaths.swift
//  ShotPaste
//
//  Path helpers for user-managed configuration files.
//

import Darwin
import Foundation

nonisolated enum ShotPasteConfigurationPaths {
  static var userHomeDirectory: URL {
    if let accountHomeDirectory {
      return accountHomeDirectory
    }

    return FileManager.default.homeDirectoryForCurrentUser
  }

  static var suggestedConfigURL: URL {
    suggestedConfigURL(homeDirectory: userHomeDirectory, variant: .current)
  }

  static var suggestedConfigDirectoryURL: URL {
    suggestedConfigDirectoryURL(homeDirectory: userHomeDirectory, variant: .current)
  }

  static func expandedUserPath(_ path: String) -> String {
    expandedUserPath(path, homeDirectory: userHomeDirectory)
  }

  static func suggestedConfigURL(
    homeDirectory: URL,
    variant: AppVariant = .current
  ) -> URL {
    suggestedConfigDirectoryURL(homeDirectory: homeDirectory, variant: variant)
      .appendingPathComponent("config.toml")
  }

  static func suggestedConfigDirectoryURL(
    homeDirectory: URL,
    variant: AppVariant = .current
  ) -> URL {
    AppDataLocations.configurationDirectory(in: homeDirectory, variant: variant)
  }

  static func expandedUserPath(_ path: String, homeDirectory: URL) -> String {
    guard path.hasPrefix("~/") else { return path }
    return homeDirectory
      .appendingPathComponent(String(path.dropFirst(2)))
      .path
  }

  private static var accountHomeDirectory: URL? {
    guard
      let passwd = getpwuid(getuid()),
      let home = passwd.pointee.pw_dir
    else {
      return nil
    }

    let path = String(cString: home)
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
}
