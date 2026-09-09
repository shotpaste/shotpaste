import SwiftUI

struct RecordingTranscriptionSettingsSection: View {
  @State private var speechKey = ""
  @State private var accessKey = ""
  @State private var secretKey = ""
  @State private var useExistingStorage = false
  @State private var existingBucket = ""
  @State private var existingPrefix = ""
  @State private var account: VolcengineCloudAccount?
  @State private var savedCredentials: VolcengineCloudCredentials?
  @State private var message = ""
  @State private var failed = false
  @State private var busy = false

  private var isReady: Bool { account?.initialized == true && account?.verified == true && savedCredentials != nil }
  private var statusTitle: String {
    isReady ? L10n.CloudTranscription.ready : savedCredentials == nil
      ? L10n.CloudTranscription.notConfigured : L10n.CloudTranscription.saved
  }
  private var resolvedCredentials: VolcengineCloudCredentials? {
    try? .resolving(speechKey: speechKey, accessKey: accessKey, secretKey: secretKey,
                   saved: savedCredentials)
  }
  private var storageIsUnchanged: Bool {
    guard let account else { return false }
    if !useExistingStorage { return account.importedPrefix == nil }
    return existingBucket.trimmingCharacters(in: .whitespacesAndNewlines) == account.bucket
      && existingPrefix.trimmingCharacters(in: .whitespacesAndNewlines) == account.prefix
  }
  private var hasChanges: Bool {
    savedCredentials == nil || resolvedCredentials != savedCredentials || !storageIsUnchanged
  }
  private var canSave: Bool {
    resolvedCredentials != nil && (!useExistingStorage ||
      (try? VolcengineCloudAccount(existingBucket: existingBucket.trimmingCharacters(in: .whitespacesAndNewlines),
                                   prefix: existingPrefix.trimmingCharacters(in: .whitespacesAndNewlines))) != nil)
  }

  var body: some View {
    Section(L10n.CloudTranscription.title) {
      SettingRow(icon: "waveform", title: L10n.CloudTranscription.accountTitle,
                 description: L10n.CloudTranscription.credentialsNote) {
        Label(statusTitle,
              systemImage: isReady ? "checkmark.circle.fill" : "circle.dashed")
          .font(.caption)
          .foregroundStyle(isReady ? Color.green : Color.secondary)
          .accessibilityValue(statusTitle)
          .accessibilityIdentifier("ai-transcription-status")
      }

      credentialRow(L10n.CloudTranscription.speechKey, text: $speechKey, saved: savedCredentials?.speechKey,
                    identifier: "ai-transcription-speech-key")
      credentialRow(L10n.CloudTranscription.accessKey, text: $accessKey, saved: savedCredentials?.accessKey,
                    identifier: "ai-transcription-access-key")
      credentialRow(L10n.CloudTranscription.secretKey, text: $secretKey, saved: savedCredentials?.secretKey,
                    identifier: "ai-transcription-secret-key")

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Button(hasChanges ? L10n.CloudTranscription.saveAndTest : L10n.CloudTranscription.testConnection) {
            perform { try await saveAndConnect() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(busy || !canSave)
          .accessibilityIdentifier("ai-transcription-connect")
          Button(L10n.Common.save) {
            perform {
              try saveCredentials()
              message = isReady ? L10n.CloudTranscription.ready : L10n.CloudTranscription.saved
            }
          }
          .disabled(busy || !canSave || !hasChanges)
          .accessibilityIdentifier("ai-transcription-save")
          if busy { ProgressView().controlSize(.small) }
        }
        Text(L10n.CloudTranscription.setupNote)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !message.isEmpty {
          Text(message).font(.caption)
            .foregroundStyle(failed ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier("ai-transcription-message")
        }
      }

      DisclosureGroup(L10n.CloudTranscription.advanced) {
        Toggle(L10n.CloudTranscription.existingStorage, isOn: $useExistingStorage)
          .accessibilityIdentifier("ai-transcription-existing-storage")
        if useExistingStorage {
          TextField(L10n.CloudTranscription.bucket, text: $existingBucket)
            .accessibilityLabel(L10n.CloudTranscription.bucket)
          TextField(L10n.CloudTranscription.prefix, text: $existingPrefix)
            .accessibilityLabel(L10n.CloudTranscription.prefix)
        }
        Text(L10n.CloudTranscription.storageNote)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !useExistingStorage, let account {
          LabeledContent(L10n.CloudTranscription.bucket, value: account.bucket)
          LabeledContent(L10n.CloudTranscription.prefix, value: account.prefix)
        }
        HStack {
          Link(L10n.CloudTranscription.console, destination: URL(string: "https://console.volcengine.com/speech/service")!)
          Link(L10n.CloudTranscription.storageConsole, destination: URL(string: "https://console.volcengine.com/tos/bucket")!)
          Spacer()
          Button(L10n.CloudTranscription.remove, role: .destructive) {
            perform { try await removeCredentials() }
          }.disabled(account == nil)
        }
      }
      .disabled(busy)
      .accessibilityIdentifier("ai-transcription-advanced")
    }
    .textFieldStyle(.roundedBorder)
    .onAppear(perform: loadAccount)
  }

  private func credentialRow(_ title: String, text: Binding<String>, saved: String?, identifier: String) -> some View {
    SettingRow(icon: "key", title: title, description: nil) {
      SecureField(AgentCredentialStore.maskedKey(saved) ?? L10n.CloudTranscription.keyPlaceholder, text: text)
        .labelsHidden()
        .frame(width: 300)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .disabled(busy)
    }
  }

  private func loadAccount() {
    account = VolcengineCloudAccounts.current()
    savedCredentials = account.flatMap { try? VolcengineCloudAccounts.credentials(for: $0.id) }
    useExistingStorage = account?.importedPrefix != nil
    existingBucket = account?.bucket ?? ""
    existingPrefix = account?.prefix ?? ""
  }

  private func saveCredentials() throws {
    guard let credentials = resolvedCredentials else { throw RecordingTranscriptionError.invalidConfiguration }
    guard hasChanges else { return }
    let profile: VolcengineCloudAccount
    if storageIsUnchanged, let account, let savedCredentials,
       savedCredentials.accessKey == credentials.accessKey, savedCredentials.secretKey == credentials.secretKey {
      // A speech-key update can reuse initialized storage without replacing the
      // profile needed by previous jobs. New TOS credentials get new storage.
      profile = VolcengineCloudAccount(replacingCredentialsFor: account)
    } else if useExistingStorage {
      profile = try VolcengineCloudAccount(existingBucket: existingBucket.trimmingCharacters(in: .whitespacesAndNewlines),
                                           prefix: existingPrefix.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
      profile = VolcengineCloudAccount()
    }
    account = try VolcengineCloudAccounts.save(credentials, account: profile)
    savedCredentials = credentials
    speechKey = ""; accessKey = ""; secretKey = ""
    existingBucket = profile.bucket; existingPrefix = profile.prefix
  }

  private func saveAndConnect() async throws {
    try saveCredentials()
    guard var profile = account else { throw RecordingTranscriptionError.invalidConfiguration }
    // Persist each completed setup stage, so retry uses the same saved storage.
    profile.verified = false
    try VolcengineCloudAccounts.update(profile); account = profile
    if !profile.initialized {
      message = L10n.CloudTranscription.connecting
      let credentials = try VolcengineCloudAccounts.credentials(for: profile.id)
      try await VolcengineTOSClient(signer: credentials.signer).initialize(profile)
      profile.initialized = true
      try VolcengineCloudAccounts.update(profile); account = profile
    }
    message = L10n.CloudTranscription.testing
    try await VolcengineCloudVerification.run(account: profile)
    profile.verified = true
    try VolcengineCloudAccounts.update(profile); account = profile
    message = L10n.CloudTranscription.ready
  }

  private func removeCredentials() async throws {
    guard let account else { return }
    let works = await VolcengineRecordingWorkStore.shared.works()
    let jobs = await VolcengineCloudJobs.shared.jobs()
    let audioProfiles = AudioProcessingTaskStore().cloudProfilesToRetain()
    guard !audioProfiles.contains(account.id),
          !works.contains(where: { $0.configuration.account.id == account.id && [.running, .failed].contains($0.state) }),
          !jobs.contains(where: { $0.account.id == account.id && ($0.cleanup == .pending || ![.failed, .cancelled, .transcriptReady].contains($0.stage)) }) else {
      failed = true; message = L10n.CloudTranscription.pendingCleanup; return
    }
    try VolcengineCloudAccounts.removeCurrent()
    speechKey = ""; accessKey = ""; secretKey = ""
    loadAccount()
    message = ""
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true; failed = false; message = ""
    Task { @MainActor in
      defer { busy = false }
      do { try await operation() }
      catch {
        failed = true
        message = (error as? LocalizedError)?.errorDescription ?? L10n.CloudTranscription.cloudError
      }
    }
  }
}
