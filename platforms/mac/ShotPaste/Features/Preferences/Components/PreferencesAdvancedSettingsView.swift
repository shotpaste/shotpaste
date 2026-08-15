//
//  PreferencesAdvancedSettingsView.swift
//  ShotPaste
//
//  Minimal advanced preferences: reset and diagnostic logs.
//

import AppKit
import SwiftUI

struct AdvancedSettingsView: View {
  @AppStorage(PreferencesKeys.diagnosticsEnabled) private var diagnosticsEnabled = true
  @AppStorage(PreferencesKeys.diagnosticsRetentionDays) private var diagnosticsRetentionDays =
    LogCleanupScheduler.defaultRetentionDays

  @State private var isRestoreConfirmationPresented = false
  @State private var isLegalNoticesPresented = false
  @State private var logSizeText = L10n.PreferencesAdvanced.calculating

  var body: some View {
    Form {
      Section {
        SettingRow(
          icon: "arrow.counterclockwise.circle",
          title: L10n.PreferencesAdvanced.restoreDefaultsTitle,
          description: L10n.PreferencesAdvanced.restoreDefaultsDescription
        ) {
          Button(L10n.PreferencesAdvanced.restoreDefaultsButton, role: .destructive) {
            isRestoreConfirmationPresented = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }

      Section(L10n.PreferencesAdvanced.diagnosticsSection) {
        SettingRow(
          icon: "doc.text.magnifyingglass",
          title: L10n.PreferencesAdvanced.diagnosticLoggingTitle,
          description: L10n.PreferencesAdvanced.diagnosticLoggingDescription
        ) {
          Toggle("", isOn: $diagnosticsEnabled)
            .labelsHidden()
        }

        SettingRow(
          icon: "calendar.badge.clock",
          title: L10n.PreferencesAdvanced.logRetentionTitle,
          description: L10n.PreferencesAdvanced.logRetentionDescription(diagnosticsRetentionDays)
        ) {
          HStack(spacing: 8) {
            Text("\(diagnosticsRetentionDays)d")
              .frame(width: 36, alignment: .trailing)
              .monospacedDigit()
              .foregroundColor(.secondary)
            Stepper("", value: $diagnosticsRetentionDays, in: LogCleanupScheduler.retentionDaysRange)
              .labelsHidden()
          }
          .frame(width: 120, alignment: .trailing)
        }

        SettingRow(
          icon: "folder",
          title: L10n.PreferencesAdvanced.logFilesTitle,
          description: logSizeText
        ) {
          Button(L10n.PreferencesAdvanced.openFolderButton) {
            revealLogFolder()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }

      Section(L10n.PreferencesAdvanced.legalSection) {
        SettingRow(
          icon: "doc.text",
          title: L10n.PreferencesAdvanced.licensesTitle,
          description: L10n.PreferencesAdvanced.licensesDescription
        ) {
          Button(L10n.Common.open) {
            isLegalNoticesPresented = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: updateLogSize)
    .onChange(of: diagnosticsRetentionDays) { _ in
      LogCleanupScheduler.shared.performCleanupNow()
      updateLogSize()
    }
    .alert(
      L10n.PreferencesAdvanced.restoreDefaultsConfirmationTitle,
      isPresented: $isRestoreConfirmationPresented
    ) {
      Button(L10n.Common.cancel, role: .cancel) {}
      Button(L10n.PreferencesAdvanced.restoreDefaultsConfirmButton, role: .destructive) {
        performRestoreDefaults()
      }
    } message: {
      Text(L10n.PreferencesAdvanced.restoreDefaultsConfirmationMessage)
    }
    .sheet(isPresented: $isLegalNoticesPresented) {
      LegalNoticesView()
    }
  }

  private func performRestoreDefaults() {
    let result = ShotPasteConfigurationImporter.importTOML(
      ShotPasteConfigurationDefaultDocument.toml()
    )
    if result.hasErrors {
      showNotice(L10n.PreferencesAdvanced.restoreDefaultsFailed, style: .error)
    } else {
      showNotice(L10n.PreferencesAdvanced.restoreDefaultsSucceeded, style: .success)
    }
  }

  private func revealLogFolder() {
    let directory = DiagnosticLogger.shared.logDirectoryURL
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directory.path)
  }

  private func updateLogSize() {
    let directory = DiagnosticLogger.shared.logDirectoryURL
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey]
    ) else {
      logSizeText = L10n.PreferencesAdvanced.noLogs
      return
    }

    let totalBytes = files.reduce(Int64.zero) { partial, file in
      let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
      return partial + Int64(size ?? 0)
    }
    logSizeText = totalBytes == 0
      ? L10n.PreferencesAdvanced.noLogs
      : ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
  }

  private func showNotice(_ message: String, style: AppToastStyle) {
    AppToastManager.shared.show(
      message: message,
      style: style,
      duration: style == .success ? 2.4 : 4.0
    )
  }
}
