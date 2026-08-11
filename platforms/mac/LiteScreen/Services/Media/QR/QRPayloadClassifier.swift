//
//  QRPayloadClassifier.swift
//  LiteScreen
//
//  Classifies QR payloads for diagnostics only. No side effects are attached to
//  any payload type; capture remains copy-only.
//

import Foundation

nonisolated enum QRPayloadClassification: Equatable, Sendable {
  case plainText
  case webURL(scheme: String, host: String?)
  case urlScheme(String)

  var diagnosticName: String {
    switch self {
    case .plainText:
      "plain-text"
    case .webURL(let scheme, _):
      "web-url-\(scheme)"
    case .urlScheme(let scheme):
      "scheme-\(scheme)"
    }
  }
}

nonisolated enum QRPayloadClassifier {
  static func classify(_ payload: String) -> QRPayloadClassification {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      !scheme.isEmpty
    else {
      return .plainText
    }

    if scheme == "https" || scheme == "http" {
      return .webURL(scheme: scheme, host: components.host?.lowercased())
    }

    return .urlScheme(scheme)
  }
}
