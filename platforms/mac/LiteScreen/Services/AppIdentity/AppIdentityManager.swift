//
//  AppIdentityManager.swift
//  LiteScreen
//
//  Tracks bundle identity health for permission-sensitive release builds.
//

import Combine
import Foundation
import Security

enum AppBundleIdentity {
  #if DEBUG
    static let expected = "com.ahtcfg24.litescreen.debug"
  #else
    static let expected = "com.ahtcfg24.litescreen"
  #endif
}

enum AppIdentityIssue: Equatable, Hashable {
  case unexpectedBundleIdentifier(String?)
  case invalidBundleSignature
  case outsideApplications(URL)
  case quarantined

  var description: String {
    switch self {
    case .unexpectedBundleIdentifier(let bundleIdentifier):
      let currentIdentifier = bundleIdentifier ?? "missing"
      return L10n.AppIdentity.unexpectedBundleIdentifier(currentIdentifier)
    case .invalidBundleSignature:
      return L10n.AppIdentity.invalidSignature
    case .outsideApplications(let bundleURL):
      return L10n.AppIdentity.outsideApplications(bundleURL.path)
    case .quarantined:
      return L10n.AppIdentity.quarantined
    }
  }
}

struct AppIdentityHealth: Equatable {
  let bundleURL: URL
  let issues: [AppIdentityIssue]

  var isHealthy: Bool {
    issues.isEmpty
  }

  var summary: String {
    if issues.isEmpty {
      return L10n.AppIdentity.healthy
    }

    return issues.map(\.description).joined(separator: " ")
  }
}

@MainActor
final class AppIdentityManager: ObservableObject {
  static let shared = AppIdentityManager()

  @Published private(set) var health = AppIdentityHealth(
    bundleURL: Bundle.main.bundleURL,
    issues: []
  )

  private init() {
    refresh()
  }

  func refresh() {
    health = Self.evaluate()
  }

  private static func evaluate() -> AppIdentityHealth {
    let bundleURL = Bundle.main.bundleURL.standardizedFileURL
    var issues: [AppIdentityIssue] = []
    let quarantined = isQuarantined(bundleURL)

    if Bundle.main.bundleIdentifier != AppBundleIdentity.expected {
      issues.append(.unexpectedBundleIdentifier(Bundle.main.bundleIdentifier))
    }

    // Quarantine flag check: Only flag as an issue if the app is running from
    // outside standard Applications folders. Homebrew Cask upgrades (`brew upgrade`)
    // use command-line `mv`/`cp` which preserves the quarantine xattr even after
    // the app is placed in /Applications. Since the app is Apple Notarized, macOS
    // Gatekeeper handles the quarantine-to-clearance flow automatically on first
    // launch. Flagging quarantine inside /Applications would be a false positive
    // that blocks permissions after every Cask upgrade (see issue #337).
    if quarantined {
      let homePath = NSHomeDirectory()
      let isInsideApplications =
        bundleURL.path.hasPrefix("/Applications/")
          || bundleURL.path.hasPrefix("\(homePath)/Applications/")
      if !isInsideApplications {
        issues.append(.outsideApplications(bundleURL))
        issues.append(.quarantined)
      }
    }

    // Permission-sensitive Debug and Release builds both require a structurally
    // valid, stable signature. Skipping this check in Debug hides ad-hoc builds
    // whose designated requirement changes whenever the executable changes.
    if !hasValidBundleSignature(bundleURL) {
      issues.append(.invalidBundleSignature)
    }

    return AppIdentityHealth(bundleURL: bundleURL, issues: issues)
  }

  private static func isQuarantined(_ bundleURL: URL) -> Bool {
    let values = try? bundleURL.resourceValues(forKeys: [.quarantinePropertiesKey])
    return values?.quarantineProperties != nil
  }

  private static func hasValidBundleSignature(_ bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      return false
    }

    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    let verifyStatus = SecStaticCodeCheckValidity(staticCode, flags, nil)
    return verifyStatus == errSecSuccess
  }
}
