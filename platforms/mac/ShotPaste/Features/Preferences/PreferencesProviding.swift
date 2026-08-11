//
//  PreferencesProviding.swift
//  ShotPaste
//
//  Protocol extracted from PreferencesManager for DI.
//

import Foundation

@MainActor
protocol PreferencesProviding {
  func setAction(_ action: AfterCaptureAction, for type: CaptureType, enabled: Bool)
  func isActionEnabled(_ action: AfterCaptureAction, for type: CaptureType) -> Bool
}

extension PreferencesManager: PreferencesProviding {}
