import Foundation

/// Public account metadata; task records must never include credentials.
nonisolated struct VolcengineCloudAccount: Codable, Equatable, Sendable {
  let id: UUID
  let installationID: UUID
  let bucket: String
  var importedPrefix: String?
  var initialized = false
  var verified = false
  var prefix: String { importedPrefix ?? "transcription/v1/\(installationID.uuidString.lowercased())/" }

  init() {
    id = UUID()
    installationID = UUID()
    bucket = "shotpaste-tmp-\(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased())-\(AppVariant.current == .debug ? "debug" : "release")"
  }
  init(existingBucket: String, prefix: String) throws {
    guard existingBucket.range(of: #"^shotpaste-tmp-[a-z0-9-]{3,48}$"#, options: .regularExpression) != nil,
          prefix.range(of: #"^transcription/v1/[a-z0-9-]{12,36}/$"#, options: .regularExpression) != nil else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    id = UUID(); installationID = UUID(); bucket = existingBucket; importedPrefix = prefix
  }

  init(replacingCredentialsFor account: Self) {
    id = UUID()
    installationID = account.installationID
    bucket = account.bucket
    importedPrefix = account.importedPrefix
    initialized = account.initialized
  }

}

/// Stored only in local preferences, like the LLM API key; never export to a job or diagnostics.
nonisolated struct VolcengineCloudCredentials: Codable, Equatable, Sendable {
  let speechKey: String
  let accessKey: String
  let secretKey: String

  init(speechKey: String, accessKey: String, secretKey: String) throws {
    let values = [speechKey, accessKey, secretKey].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard values.allSatisfy(VolcengineTOSSigner.validCredential) else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    self.speechKey = values[0]
    self.accessKey = values[1]
    self.secretKey = values[2]
  }

  var signer: VolcengineTOSSigner {
    get throws { try VolcengineTOSSigner(accessKey: accessKey, secretKey: secretKey) }
  }

  static func resolving(speechKey: String, accessKey: String, secretKey: String,
                        saved: Self?) throws -> Self {
    func value(_ draft: String, _ previous: String?) -> String {
      let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? previous ?? "" : trimmed
    }
    return try Self(speechKey: value(speechKey, saved?.speechKey),
                    accessKey: value(accessKey, saved?.accessKey),
                    secretKey: value(secretKey, saved?.secretKey))
  }
}

@MainActor
enum VolcengineCloudAccounts {
  private static var leases: [UUID: Int] = [:]
  static let preferencesKey = "recordingTranscriptionCloudAccountV1"
  static let credentialsKeyPrefix = "recordingTranscriptionCloudCredentialsV1."

  static func current(defaults: UserDefaults = .standard) -> VolcengineCloudAccount? {
    guard let data = defaults.data(forKey: preferencesKey) else { return nil }
    return try? JSONDecoder().decode(VolcengineCloudAccount.self, from: data)
  }

  static func acquire(_ id: UUID, defaults: UserDefaults = .standard) throws -> VolcengineCloudCredentials {
    let value = try credentials(for: id, defaults: defaults)
    leases[id, default: 0] += 1
    return value
  }
  static func release(_ id: UUID) {
    leases[id] = max(0, (leases[id] ?? 0) - 1)
  }

  static func credentials(for id: UUID, defaults: UserDefaults = .standard) throws -> VolcengineCloudCredentials {
    guard let data = defaults.data(forKey: credentialsKeyPrefix + id.uuidString),
          let value = try? JSONDecoder().decode(VolcengineCloudCredentials.self, from: data),
          let validated = try? VolcengineCloudCredentials(speechKey: value.speechKey,
            accessKey: value.accessKey, secretKey: value.secretKey) else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    return validated
  }

  static func save(_ credentials: VolcengineCloudCredentials, account: VolcengineCloudAccount = .init(), defaults: UserDefaults = .standard) throws -> VolcengineCloudAccount {
    let old = current(defaults: defaults)
    // Never change credentials underneath an in-flight job using this profile.
    if let existing = try? self.credentials(for: account.id, defaults: defaults) {
      guard existing == credentials else { throw RecordingTranscriptionError.invalidConfiguration }
      if let old, old.id == account.id { return old }
    }
    let data = try JSONEncoder().encode(credentials)
    let accountData = try JSONEncoder().encode(account)
    // UserDefaults is isolated by the Debug/Release bundle identity. Old local
    // profiles remain available until their own jobs and cloud cleanup finish.
    defaults.set(data, forKey: credentialsKeyPrefix + account.id.uuidString)
    defaults.set(accountData, forKey: preferencesKey)
    if let old, old.id != account.id {
      var retired = defaults.stringArray(forKey: preferencesKey + ".retired") ?? []
      if !retired.contains(old.id.uuidString) { retired.append(old.id.uuidString) }
      defaults.set(retired, forKey: preferencesKey + ".retired")
    }
    defaults.set(false, forKey: PreferencesKeys.recordingTranscriptionEnabled)
    defaults.set(false, forKey: PreferencesKeys.audioRecordingAutomaticTranscription)
    return account
  }

  static func pruneRetired(excluding retained: Set<UUID>, defaults: UserDefaults = .standard) {
    let retired = defaults.stringArray(forKey: preferencesKey + ".retired") ?? []
    var remaining: [String] = []
    for raw in retired {
      guard let id = UUID(uuidString: raw), !retained.contains(id), (leases[id] ?? 0) == 0, current(defaults: defaults)?.id != id else {
        remaining.append(raw); continue
      }
      defaults.removeObject(forKey: credentialsKeyPrefix + id.uuidString)
    }
    defaults.set(remaining, forKey: preferencesKey + ".retired")
  }

  static func removeCurrent(defaults: UserDefaults = .standard) throws {
    guard let account = current(defaults: defaults) else { return }
    guard (leases[account.id] ?? 0) == 0 else { throw RecordingTranscriptionError.invalidConfiguration }
    defaults.removeObject(forKey: credentialsKeyPrefix + account.id.uuidString)
    defaults.removeObject(forKey: preferencesKey)
    defaults.set(false, forKey: PreferencesKeys.recordingTranscriptionEnabled)
    defaults.set(false, forKey: PreferencesKeys.audioRecordingAutomaticTranscription)
  }

  static func update(_ account: VolcengineCloudAccount, defaults: UserDefaults = .standard) throws {
    defaults.set(try JSONEncoder().encode(account), forKey: preferencesKey)
  }
}

nonisolated struct VolcengineTOSClient: Sendable {
  let signer: VolcengineTOSSigner
  private let http: any VolcengineCloudTransport
  init(signer: VolcengineTOSSigner, http: any VolcengineCloudTransport = VolcengineCloudHTTP()) {
    self.signer = signer; self.http = http
  }

  private func send(_ request: URLRequest, statuses: Set<Int> = [200, 204]) async throws -> Data {
    let (data, response) = try await http.send(request, maximumBytes: 1_048_576)
    guard statuses.contains(response.statusCode) else { throw VolcengineCloudFailure(http: response.statusCode) }
    return data
  }

  func initialize(_ account: VolcengineCloudAccount) async throws {
    // The generated name is persisted before explicit initialization. A retry
    // may find this same bucket, but still verifies private/versioning state.
    let head = try signer.request(method: "HEAD", bucket: account.bucket)
    let (_, existing) = try await http.send(head)
    if existing.statusCode == 404 {
      _ = try await send(signer.request(method: "PUT", bucket: account.bucket,
        headers: ["x-tos-acl": "private", "x-tos-storage-class": "STANDARD", "x-tos-az-redundancy": "single-az"]))
    } else if existing.statusCode != 200 {
      throw VolcengineCloudFailure(http: existing.statusCode)
    }
    try await checkStorage(account)
    let (currentData, currentResponse) = try await http.send(signer.request(method: "GET", bucket: account.bucket, query: ["lifecycle": ""]))
    var rules: [[String: Any]] = []
    if currentResponse.statusCode == 200 {
      guard let object = try JSONSerialization.jsonObject(with: currentData) as? [String: Any],
            let existingRules = object["Rules"] as? [[String: Any]] else { throw RecordingTranscriptionError.invalidResponse }
      rules = existingRules
    } else if currentResponse.statusCode != 404 {
      throw RecordingTranscriptionError.connectionFailed
    }
    // An imported bucket may already have the exact cleanup rule. TOS rejects
    // overlapping expiration rules for the same prefix; reuse that rule without
    // modifying unrelated rules or weakening the required cleanup policy.
    if rules.contains(where: { Self.hasRequiredCleanup($0, prefix: account.prefix) }) { return }
    let ruleID = "shotpaste-\(account.installationID.uuidString.lowercased())"
    if let old = rules.first(where: { $0["ID"] as? String == ruleID }), old["Prefix"] as? String != account.prefix {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    rules.removeAll { $0["ID"] as? String == ruleID }
    rules.append(["ID": ruleID, "Prefix": account.prefix, "Status": "Enabled", "Expiration": ["Days": 2],
                  "AbortIncompleteMultipartUpload": ["DaysAfterInitiation": 2]])
    let body = try JSONSerialization.data(withJSONObject: ["Rules": rules])
    _ = try await send(signer.request(method: "PUT", bucket: account.bucket, query: ["lifecycle": ""],
      headers: ["content-type": "application/json"], body: body))
    let verified = try await send(signer.request(method: "GET", bucket: account.bucket, query: ["lifecycle": ""]))
    guard let object = try JSONSerialization.jsonObject(with: verified) as? [String: Any],
          let returned = object["Rules"] as? [[String: Any]],
          let rule = returned.first(where: { $0["ID"] as? String == ruleID }),
          rule["Prefix"] as? String == account.prefix, rule["Status"] as? String == "Enabled",
          (rule["Expiration"] as? [String: Any])?["Days"] as? Int == 2,
          (rule["AbortIncompleteMultipartUpload"] as? [String: Any])?["DaysAfterInitiation"] as? Int == 2
    else { throw RecordingTranscriptionError.invalidResponse }
  }

  static func hasRequiredCleanup(_ rule: [String: Any], prefix: String) -> Bool {
    rule["Prefix"] as? String == prefix && rule["Status"] as? String == "Enabled"
      && (rule["Expiration"] as? [String: Any])?["Days"] as? Int == 2
      && (rule["AbortIncompleteMultipartUpload"] as? [String: Any])?["DaysAfterInitiation"] as? Int == 2
  }

  func checkStorage(_ account: VolcengineCloudAccount) async throws {
    let (data, response) = try await http.send(signer.request(method: "HEAD", bucket: account.bucket))
    _ = data
    guard response.statusCode == 200 else { throw VolcengineCloudFailure(http: response.statusCode) }
    guard response.value(forHTTPHeaderField: "x-tos-bucket-region") == "cn-beijing",
          response.value(forHTTPHeaderField: "x-tos-storage-class") == "STANDARD" else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    let aclData = try await send(signer.request(method: "GET", bucket: account.bucket, query: ["acl": ""]))
    guard let acl = try JSONSerialization.jsonObject(with: aclData) as? [String: Any],
          let owner = (acl["Owner"] as? [String: Any])?["ID"] as? String,
          let grants = acl["Grants"] as? [[String: Any]], !grants.isEmpty, grants.allSatisfy({ grant in
            guard let grantee = grant["Grantee"] as? [String: Any] else { return false }
            return grantee["Type"] as? String == "CanonicalUser" && grantee["ID"] as? String == owner
          }) else { throw RecordingTranscriptionError.invalidConfiguration }
    let version = try await send(signer.request(method: "GET", bucket: account.bucket, query: ["versioning": ""]))
    guard let object = try JSONSerialization.jsonObject(with: version) as? [String: Any],
          object["Status"] == nil || ["", "Disabled"].contains(object["Status"] as? String ?? "invalid") else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
  }

  func upload(_ data: Data, account: VolcengineCloudAccount, key: String,
              progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
    guard key.hasPrefix(account.prefix), !data.isEmpty, data.count <= 256 * 1_024 * 1_024 else {
      throw RecordingTranscriptionError.invalidRecording
    }
    let uploader: any VolcengineCloudTransport = http is VolcengineCloudHTTP ? VolcengineCloudHTTP(progress: progress) : http
    let (_, response) = try await uploader.send(signer.request(method: "PUT", bucket: account.bucket, key: key,
      headers: ["content-type": "audio/mp4", "x-tos-forbid-overwrite": "true",
                "x-tos-meta-sha256": VolcengineTOSSigner.sha256(data)], body: data))
    guard response.statusCode == 200 else { throw VolcengineCloudFailure(http: response.statusCode) }
  }

  func delete(account: VolcengineCloudAccount, key: String) async throws {
    guard key.hasPrefix(account.prefix) else { throw RecordingTranscriptionError.invalidConfiguration }
    _ = try await send(signer.request(method: "DELETE", bucket: account.bucket, key: key))
    let (_, response) = try await http.send(signer.request(method: "HEAD", bucket: account.bucket, key: key))
    guard response.statusCode == 404 else { throw RecordingTranscriptionError.invalidResponse }
    _ = try await send(signer.request(method: "HEAD", bucket: account.bucket))
  }
}
