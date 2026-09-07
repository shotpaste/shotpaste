import Foundation

nonisolated enum VolcengineCloudVerification {
  static func run(account: VolcengineCloudAccount) async throws {
    let credentials = try await VolcengineCloudAccounts.acquire(account.id)
    defer { Task { @MainActor in VolcengineCloudAccounts.release(account.id) } }
    try await VolcengineTOSClient(signer: credentials.signer).checkStorage(account)
    let url = URL(string: "https://lf3-static.bytednsdoc.com/obj/eden-cn/lm_hz_ihsph/ljhwZthlaukjlkulzlp/console/bigtts/zh_female_cancan_mars_bigtts.mp3")!
    let (data, response) = try await VolcengineCloudHTTP().send(URLRequest(url: url), maximumBytes: 2_000_000)
    guard response.statusCode == 200, !data.isEmpty else { throw RecordingTranscriptionError.connectionFailed }
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("ShotPaste-ASR-verify-\(UUID()).mp3")
    try data.write(to: local, options: .atomic)
    defer { try? FileManager.default.removeItem(at: local) }
    let duration = try await VolcengineAudioPreparation.duration(local)
    let part = try await VolcengineAudioPreparation.prepare(local, start: 0, totalDuration: duration)
    defer { if part.temporary { try? FileManager.default.removeItem(at: part.url) } }
    try await verifyPreparedAudio(Data(contentsOf: part.url), account: account, credentials: credentials)
  }

  /// Every explicit connection test exercises upload, recognition and deletion.
  /// A sample's checksum must not reuse an older recording receipt: provider
  /// query results expire, and cached text cannot prove current storage access.
  static func verifyPreparedAudio(_ audio: Data, account: VolcengineCloudAccount,
                                  credentials: VolcengineCloudCredentials,
                                  jobs: VolcengineCloudJobs = .shared) async throws {
    let result = try await jobs.transcribe(audio: audio, account: account, credentials: credentials,
      language: nil, sourceID: "verification-" + UUID().uuidString)
    guard !result.text.isEmpty else { throw RecordingTranscriptionError.emptyTranscript }
    guard let requestID = result.requestID,
          let receipt = await jobs.jobs().first(where: { $0.requestID == requestID }),
          receipt.cleanup == .cleaned else {
      throw RecordingTranscriptionError.connectionFailed
    }
  }
}
