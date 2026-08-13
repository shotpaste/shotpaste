//
//  PermissionResetService.swift
//  ShotPaste
//
//  Resets only the macOS privacy decisions that ShotPaste can request again.
//

import Foundation

nonisolated struct PermissionResetReport: Sendable, Equatable {
  struct Failure: Sendable, Equatable {
    let service: String
    let terminationStatus: Int32
  }

  let failures: [Failure]

  var succeeded: Bool {
    failures.isEmpty
  }
}

nonisolated enum PermissionResetService {
  static let managedServices = ["ScreenCapture", "Microphone", "Accessibility"]

  static func commandArguments(bundleIdentifier: String) -> [[String]] {
    managedServices.map { ["reset", $0, bundleIdentifier] }
  }

  static func resetAll(bundleIdentifier: String) async -> PermissionResetReport {
    await Task.detached(priority: .userInitiated) {
      var failures: [PermissionResetReport.Failure] = []
      for arguments in commandArguments(bundleIdentifier: bundleIdentifier) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
          try process.run()
          process.waitUntilExit()
          if process.terminationStatus != 0 {
            failures.append(.init(
              service: arguments[1],
              terminationStatus: process.terminationStatus
            ))
          }
        } catch {
          failures.append(.init(service: arguments[1], terminationStatus: -1))
        }
      }
      return PermissionResetReport(failures: failures)
    }.value
  }
}

extension PermissionResetReport {
  func succeeded(for service: String) -> Bool {
    !failures.contains { $0.service == service }
  }
}
