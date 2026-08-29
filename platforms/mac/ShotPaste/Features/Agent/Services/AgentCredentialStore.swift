//
//  AgentCredentialStore.swift
//  ShotPaste
//
//  Resolves a user override ahead of the local default while keeping tokens out
//  of configuration exports, diagnostics, and audit events.
//

import Foundation

protocol AgentCredentialProviding: Sendable {
  func resolvedAPIKey() throws -> String?
}

struct AgentCredentialStore: AgentCredentialProviding, Sendable {
  static let shared = AgentCredentialStore()
  static let environmentVariableName = "SHOTPASTE_LLM_API_KEY"
  static let defaultAPIKey = "123456"

  private let defaults: UserDefaults
  private let storageKey: String
  private let environment: @Sendable () -> [String: String]

  init(
    defaults: UserDefaults = .standard,
    storageKey: String = PreferencesKeys.agentProviderAPIKey,
    environment: @escaping @Sendable () -> [String: String] = {
      ProcessInfo.processInfo.environment
    }
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
    self.environment = environment
  }

  func resolvedAPIKey() throws -> String? {
    if let key = storedAPIKey() {
      return key
    }
    return Self.normalizedKey(environment()[Self.environmentVariableName])
      ?? Self.defaultAPIKey
  }

  func maskedStoredAPIKey() -> String? {
    Self.maskedKey(storedAPIKey())
  }

  func saveAPIKey(_ rawKey: String) throws {
    guard let key = Self.normalizedKey(rawKey) else {
      throw AgentCredentialError.invalidKey
    }
    defaults.set(key, forKey: storageKey)
  }

  func deleteAPIKey() {
    defaults.removeObject(forKey: storageKey)
  }

  private func storedAPIKey() -> String? {
    Self.normalizedKey(defaults.string(forKey: storageKey))
  }

  nonisolated static func normalizedKey(_ rawValue: String?) -> String? {
    guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty,
          !value.contains(where: \.isWhitespace)
    else { return nil }
    return value
  }

  nonisolated static func maskedKey(_ rawValue: String?) -> String? {
    guard let key = normalizedKey(rawValue) else { return nil }
    guard key.count > 8 else {
      return String(repeating: "•", count: max(4, key.count))
    }
    return "\(key.prefix(3))••••••\(key.suffix(4))"
  }
}

enum AgentCredentialError: LocalizedError, Equatable {
  case invalidKey
  case shellImportFailed

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      "The API key is empty or contains whitespace."
    case .shellImportFailed:
      "SHOTPASTE_LLM_API_KEY could not be imported from the login shell."
    }
  }
}

enum AgentShellEnvironmentImporter {
  /// Explicit user action only. The shell output is returned directly to the
  /// caller for application-preferences storage and must never be logged.
  static func importLLMAPIKey() async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = [
        "-lic",
        "printf '\\036SHOTPASTE_LLM_KEY\\037%s\\036' \"${SHOTPASTE_LLM_API_KEY:-}\"",
      ]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice

      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw AgentCredentialError.shellImportFailed
      }

      guard let outputValue = String(data: data, encoding: .utf8),
            let markerRange = outputValue.range(of: "\u{001E}SHOTPASTE_LLM_KEY\u{001F}"),
            let endRange = outputValue.range(
              of: "\u{001E}",
              range: markerRange.upperBound ..< outputValue.endIndex
            ),
            let key = AgentCredentialStore.normalizedKey(
              String(outputValue[markerRange.upperBound ..< endRange.lowerBound])
            )
      else {
        throw AgentCredentialError.shellImportFailed
      }
      return key
    }.value
  }
}
