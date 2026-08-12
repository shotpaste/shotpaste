//
//  PreferencesView.swift
//  ShotPaste
//
//  Root preferences window with tabbed interface
//

import SwiftUI

struct PreferencesView: View {
  @ObservedObject private var themeManager = ThemeManager.shared
  @ObservedObject private var navigationState = PreferencesNavigationState.shared

  var body: some View {
    TabView(selection: $navigationState.selectedTab) {
      LazyView(GeneralSettingsView())
        .tabItem { Label(L10n.Preferences.generalTab, systemImage: "gearshape.fill") }
        .tag(PreferencesTab.general)

      LazyView(CaptureSettingsView())
        .tabItem { Label(L10n.Preferences.captureTab, systemImage: "camera.fill") }
        .tag(PreferencesTab.capture)

      LazyView(QuickAccessSettingsView())
        .tabItem { Label(L10n.Preferences.quickAccessTab, systemImage: "square.stack.fill") }
        .tag(PreferencesTab.quickAccess)

      LazyView(HistorySettingsView())
        .tabItem { Label(L10n.Preferences.historyTab, systemImage: "clock.arrow.circlepath") }
        .tag(PreferencesTab.history)

      LazyView(AgentSettingsView())
        .tabItem { Label(L10n.Agent.tabTitle, systemImage: "cursorarrow.motionlines") }
        .tag(PreferencesTab.agent)

      LazyView(ShortcutsSettingsView())
        .tabItem { Label(L10n.Preferences.shortcutsTab, systemImage: "keyboard.fill") }
        .tag(PreferencesTab.shortcuts)

      LazyView(PermissionsSettingsView())
        .tabItem { Label(L10n.Preferences.permissionsTab, systemImage: "lock.shield.fill") }
        .tag(PreferencesTab.permissions)

      LazyView(AdvancedSettingsView())
        .tabItem { Label(L10n.Preferences.advancedTab, systemImage: "slider.horizontal.3") }
        .tag(PreferencesTab.advanced)
    }
    .frame(
      minWidth: 700,
      idealWidth: 780,
      maxWidth: 960,
      minHeight: 520,
      idealHeight: 600,
      maxHeight: 760
    )
  }
}

#Preview {
  PreferencesView()
}
