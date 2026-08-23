//
//  PreferencesNavigationState.swift
//  ShotPaste
//
//  Shared navigation state for selecting Preferences tabs programmatically.
//

import Combine

enum PreferencesTab: Hashable {
  case general
  case capture
  case quickAccess
  case history
  case agent
  case shortcuts
  case permissions
  case advanced
}

enum PreferencesAgentAnchor: Hashable {
  case translation
}

@MainActor
final class PreferencesNavigationState: ObservableObject {
  static let shared = PreferencesNavigationState()

  @Published var selectedTab: PreferencesTab = .general
  @Published var agentAnchor: PreferencesAgentAnchor?

  func showAgentTranslation() {
    selectedTab = .agent
    agentAnchor = .translation
  }

  private init() {}
}
