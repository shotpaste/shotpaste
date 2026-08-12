//
//  PreferencesGeneralSettingsView.swift
//  ShotPaste
//
//  General preferences tab with startup, appearance, storage, updates, and help
//

import SwiftUI

struct GeneralSettingsView: View {
  @AppStorage(PreferencesKeys.playSounds) private var playSounds = true
  @AppStorage(PreferencesKeys.urlSchemeEnabled) private var urlSchemeEnabled = true
  @AppStorage(PreferencesKeys.showMenuBarIcon) private var showMenuBarIcon = true
  @AppStorage(PreferencesKeys.exportLocation) private var exportLocation = ""
  @AppStorage(PreferencesKeys.checkForUpdatesAutomatically) private var checkForUpdatesAutomatically = true
  @Environment(\.openWindow) private var openWindow
  @ObservedObject private var themeManager = ThemeManager.shared
  @ObservedObject private var updateManager = AppUpdateManager.shared

  @State private var startAtLogin = LoginItemManager.isEnabled
  private let fileAccessManager = SandboxFileAccessManager.shared

  var body: some View {
    Form {
      Section(L10n.PreferencesGeneral.startupSection) {
        SettingRow(
          icon: "power.circle",
          title: L10n.PreferencesGeneral.startAtLoginTitle,
          description: L10n.PreferencesGeneral.startAtLoginDescription
        ) {
          Toggle("", isOn: $startAtLogin)
            .labelsHidden()
            .onChange(of: startAtLogin) { newValue in
              LoginItemManager.setEnabled(newValue)
            }
        }

        SettingRow(
          icon: "speaker.wave.2",
          title: L10n.PreferencesGeneral.playSoundsTitle,
          description: L10n.PreferencesGeneral.playSoundsDescription
        ) {
          Toggle("", isOn: $playSounds)
            .labelsHidden()
        }

        SettingRow(
          icon: "menubar.rectangle",
          title: L10n.PreferencesGeneral.menuBarIconTitle,
          description: L10n.PreferencesGeneral.menuBarIconDescription
        ) {
          Toggle("", isOn: $showMenuBarIcon)
            .labelsHidden()
            .onChange(of: showMenuBarIcon) { newValue in
              AppStatusBarController.shared.setMenuBarIconVisible(newValue)
            }
        }
      }

      Section(L10n.PreferencesGeneral.appearanceSection) {
        PreferencesLanguageSettingRow()

        SettingRow(
          icon: "circle.lefthalf.filled",
          title: L10n.PreferencesGeneral.themeTitle,
          description: L10n.PreferencesGeneral.themeDescription
        ) {
          AppearanceModePicker(selection: $themeManager.preferredAppearance)
        }
      }

      Section(L10n.PreferencesGeneral.storageSection) {
        SettingRow(
          icon: "folder.fill",
          title: L10n.PreferencesGeneral.saveLocationTitle,
          description: exportLocationDisplay
        ) {
          Button(L10n.PreferencesGeneral.chooseButton) {
            chooseExportLocation()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }

      Section("Automation") {
        SettingRow(
          icon: "link",
          title: "URL Scheme",
          description: "Allow shotpaste:// links to start One Shot, capture, recording, history, and settings actions."
        ) {
          Toggle("", isOn: $urlSchemeEnabled)
            .labelsHidden()
        }
      }

      Section(L10n.PreferencesGeneral.updatesSection) {
        SettingRow(
          icon: "arrow.triangle.2.circlepath",
          title: L10n.PreferencesGeneral.checkAutomaticallyTitle,
          description: L10n.PreferencesGeneral.checkAutomaticallyDescription
        ) {
          Toggle("", isOn: $checkForUpdatesAutomatically)
            .labelsHidden()
        }

        SettingRow(
          icon: "shippingbox.and.arrow.backward",
          title: L10n.PreferencesGeneral.updateCheckButton,
          description: updateStatusDescription
        ) {
          updateAction
        }
      }

      Section(L10n.PreferencesGeneral.helpSection) {
        SettingRow(
          icon: "exclamationmark.bubble",
          title: L10n.PreferencesGeneral.reportIssueTitle,
          description: L10n.PreferencesGeneral.reportIssueDescription(bugReportDisplayAddress)
        ) {
          Button(L10n.PreferencesGeneral.openReportPageButton) {
            openBugReportPage()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      startAtLogin = LoginItemManager.isEnabled
      initializeExportLocation()
    }
  }

  // MARK: - Helpers

  private var updateStatusDescription: String {
    switch updateManager.state {
    case let .idle(currentVersion):
      "\(L10n.PreferencesGeneral.updateCurrentVersion): \(currentVersion)"
    case .checking:
      L10n.PreferencesGeneral.updateChecking
    case let .upToDate(version):
      "\(L10n.PreferencesGeneral.updateUpToDate) · v\(version)"
    case let .updateAvailable(_, release):
      "\(L10n.PreferencesGeneral.updateAvailable) · v\(release.version)"
    case let .failed(currentVersion):
      "\(L10n.PreferencesGeneral.updateCheckFailed) \(L10n.PreferencesGeneral.updateCurrentVersion): \(currentVersion)"
    }
  }

  @ViewBuilder
  private var updateAction: some View {
    switch updateManager.state {
    case .checking:
      ProgressView()
        .controlSize(.small)
    case .updateAvailable:
      Button(L10n.PreferencesGeneral.updateOpenGitHubButton) {
        updateManager.openAvailableRelease()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    default:
      Button(L10n.PreferencesGeneral.updateCheckButton) {
        updateManager.checkManually()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private var exportLocationDisplay: String {
    if exportLocation.isEmpty {
      return L10n.PreferencesGeneral.defaultSaveLocation
    }

    let folderName = URL(fileURLWithPath: exportLocation).lastPathComponent
    if fileAccessManager.hasPersistedExportPermission {
      return folderName
    }

    return L10n.PreferencesGeneral.accessNotGranted(folderName)
  }

  private func initializeExportLocation() {
    fileAccessManager.ensureExportLocationInitialized()
    exportLocation = fileAccessManager.exportLocationPath
  }

  private func chooseExportLocation() {
    if let url = fileAccessManager.chooseExportDirectory(
      message: L10n.PreferencesGeneral.chooseSaveLocationMessage,
      prompt: L10n.PreferencesGeneral.saveHereButton,
      directoryURL: fileAccessManager.resolvedExportDirectoryURL()
    ) {
      exportLocation = url.path
    }
  }

  // MARK: - Help

  private var bugReportDisplayAddress: String {
    CrashReportService.bugReportURL.absoluteString.replacingOccurrences(of: "https://", with: "")
  }

  private func openBugReportPage() {
    NSWorkspace.shared.open(CrashReportService.bugReportURL)
  }
}

#Preview {
  GeneralSettingsView()
    .frame(width: 600, height: 500)
}
