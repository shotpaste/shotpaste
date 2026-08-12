//
//  AppUpdateService.swift
//  ShotPaste
//
//  Reads the latest stable macOS GitHub Release without downloading or installing it.
//

import Foundation

struct AppReleaseVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int

  init?(_ rawValue: String) {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.first == "v" || value.first == "V" {
      value.removeFirst()
    }

    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3 else { return nil }

    var numbers: [Int] = []
    for component in components {
      guard
        !component.isEmpty,
        component.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        component == "0" || component.first != "0",
        let number = Int(component)
      else {
        return nil
      }
      numbers.append(number)
    }

    major = numbers[0]
    minor = numbers[1]
    patch = numbers[2]
  }

  var description: String {
    "\(major).\(minor).\(patch)"
  }

  static func < (lhs: AppReleaseVersion, rhs: AppReleaseVersion) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }
    if lhs.minor != rhs.minor {
      return lhs.minor < rhs.minor
    }
    return lhs.patch < rhs.patch
  }
}

struct AppRelease: Equatable, Sendable {
  let version: AppReleaseVersion
  let pageURL: URL
}

enum AppUpdateCheckResult: Equatable, Sendable {
  case upToDate(currentVersion: AppReleaseVersion, latestRelease: AppRelease)
  case updateAvailable(currentVersion: AppReleaseVersion, latestRelease: AppRelease)
}

enum AppUpdateCheckError: Error, Equatable {
  case invalidCurrentVersion
  case invalidResponse
  case unsuccessfulStatusCode(Int)
  case invalidRelease
}

struct AppUpdateService {
  static let releasesAPIURL = URL(
    string: "https://api.github.com/repos/shotpaste/shotpaste/releases?per_page=100"
  )!
  static let platformTagPrefix = "macos-v"

  private let session: any URLSessionProtocol
  private let currentVersionProvider: @Sendable () -> String?

  init(
    session: any URLSessionProtocol = URLSession.shared,
    currentVersionProvider: @escaping @Sendable () -> String? = {
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
  ) {
    self.session = session
    self.currentVersionProvider = currentVersionProvider
  }

  var currentVersionString: String {
    currentVersionProvider() ?? "—"
  }

  func checkForUpdates() async throws -> AppUpdateCheckResult {
    guard let currentVersion = AppReleaseVersion(currentVersionString) else {
      throw AppUpdateCheckError.invalidCurrentVersion
    }

    var request = URLRequest(
      url: Self.releasesAPIURL,
      cachePolicy: .reloadRevalidatingCacheData,
      timeoutInterval: 15
    )
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("ShotPaste/\(currentVersion)", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw AppUpdateCheckError.invalidResponse
    }
    guard (200 ..< 300).contains(response.statusCode) else {
      throw AppUpdateCheckError.unsuccessfulStatusCode(response.statusCode)
    }

    let payloads: [GitHubReleasePayload]
    do {
      payloads = try JSONDecoder().decode([GitHubReleasePayload].self, from: data)
    } catch {
      throw AppUpdateCheckError.invalidRelease
    }

    guard let release = payloads.compactMap(Self.macOSRelease).max(by: {
      $0.version < $1.version
    }) else {
      throw AppUpdateCheckError.invalidRelease
    }

    if release.version > currentVersion {
      return .updateAvailable(currentVersion: currentVersion, latestRelease: release)
    }
    return .upToDate(currentVersion: currentVersion, latestRelease: release)
  }

  private static func macOSRelease(from payload: GitHubReleasePayload) -> AppRelease? {
    guard
      !payload.draft,
      !payload.prerelease,
      payload.tagName.hasPrefix(platformTagPrefix),
      let version = AppReleaseVersion(String(payload.tagName.dropFirst(platformTagPrefix.count))),
      payload.assets.contains(where: {
        $0.name == "ShotPaste-v\(version)-macOS-arm64.dmg"
      }),
      isTrustedReleasePageURL(payload.htmlURL)
    else {
      return nil
    }

    return AppRelease(version: version, pageURL: payload.htmlURL)
  }

  private static func isTrustedReleasePageURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == "github.com"
      && url.path.lowercased().hasPrefix("/shotpaste/shotpaste/releases/")
  }
}

private struct GitHubReleasePayload: Decodable {
  let tagName: String
  let htmlURL: URL
  let draft: Bool
  let prerelease: Bool
  let assets: [GitHubReleaseAssetPayload]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case draft
    case prerelease
    case assets
  }
}

private struct GitHubReleaseAssetPayload: Decodable {
  let name: String
}
