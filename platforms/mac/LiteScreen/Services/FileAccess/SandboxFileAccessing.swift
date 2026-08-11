//
//  SandboxFileAccessing.swift
//  LiteScreen
//
//  Protocol extracted from SandboxFileAccessManager for DI.
//

import Foundation

protocol SandboxFileAccessing {
  func resolvedExportDirectoryURL() -> URL
  func beginAccessingURL(_ targetURL: URL) -> SandboxFileAccessManager.ScopedAccess
}

extension SandboxFileAccessManager: SandboxFileAccessing {}
