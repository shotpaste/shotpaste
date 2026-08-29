//
//  RecordingTranscriptionService.swift
//  ShotPaste
//
//  Converts a completed recording's audio track to the PCM format required by
//  Volcengine simultaneous interpretation, then collects the source transcript.
//

import AVFoundation
import Foundation
import Security

nonisolated enum RecordingTranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
  case chinese = "zh"
  case english = "en"

  var id: String {
    rawValue
  }

  var targetLanguageCode: String {
    switch self {
    case .chinese: "en"
    case .english: "zh"
    }
  }

  var displayName: String {
    switch self {
    case .chinese: L10n.RecordingTranscription.chinese
    case .english: L10n.RecordingTranscription.english
    }
  }
}

nonisolated struct RecordingTranscriptionConfiguration: Sendable, Equatable {
  let apiKey: String
  let modelID: String
  let sourceLanguage: RecordingTranscriptionLanguage

  init?(apiKey: String, modelID: String, sourceLanguage: RecordingTranscriptionLanguage) {
    let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !normalizedKey.isEmpty,
      !normalizedModel.isEmpty,
      normalizedKey.count <= 4_096,
      normalizedModel.count <= 512,
      !normalizedKey.contains(where: \.isNewline),
      !normalizedModel.contains(where: \.isNewline)
    else { return nil }

    self.apiKey = normalizedKey
    self.modelID = normalizedModel
    self.sourceLanguage = sourceLanguage
  }

  @MainActor
  static func current(
    defaults: UserDefaults = .standard,
    credentialStore: RecordingTranscriptionCredentialStore = .shared
  ) -> RecordingTranscriptionConfiguration? {
    let modelID = defaults.string(forKey: PreferencesKeys.recordingTranscriptionModelID) ?? ""
    let languageRaw = defaults.string(forKey: PreferencesKeys.recordingTranscriptionSourceLanguage) ?? "zh"
    let language = RecordingTranscriptionLanguage(rawValue: languageRaw) ?? .chinese
    return RecordingTranscriptionConfiguration(
      apiKey: credentialStore.loadAPIKey(),
      modelID: modelID,
      sourceLanguage: language
    )
  }
}

nonisolated struct RecordingTranscript: Sendable, Equatable {
  let text: String
}

nonisolated enum RecordingTranscriptionError: LocalizedError, Equatable {
  case invalidConfiguration
  case invalidRecording
  case noAudioTrack
  case audioTooLong
  case audioDecodeFailed
  case connectionFailed
  case service(code: String, message: String)
  case invalidResponse
  case responseTooLarge
  case emptyTranscript
  case timeout

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      L10n.RecordingTranscription.invalidConfiguration
    case .invalidRecording:
      L10n.RecordingTranscription.invalidRecording
    case .noAudioTrack:
      L10n.RecordingTranscription.noAudioTrack
    case .audioTooLong:
      L10n.RecordingTranscription.audioTooLong
    case .audioDecodeFailed:
      L10n.RecordingTranscription.audioDecodeFailed
    case .connectionFailed:
      L10n.RecordingTranscription.connectionFailed
    case let .service(code, message):
      L10n.RecordingTranscription.serviceError(code, message)
    case .invalidResponse:
      L10n.RecordingTranscription.invalidResponse
    case .responseTooLarge:
      L10n.RecordingTranscription.responseTooLarge
    case .emptyTranscript:
      L10n.RecordingTranscription.emptyTranscript
    case .timeout:
      L10n.RecordingTranscription.timeout
    }
  }
}

final nonisolated class RecordingTranscriptionCredentialStore: @unchecked Sendable {
  static let shared = RecordingTranscriptionCredentialStore()

  private let lock = NSLock()
  private let service: String
  private let account = "volcengine-api-key"

  init(service: String = "\(AppVariant.current.bundleIdentifier).recording-transcription") {
    self.service = service
  }

  func loadAPIKey() -> String {
    lock.lock()
    defer { lock.unlock() }

    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnData: true,
    ]
    var result: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { return "" }
    return value
  }

  func saveAPIKey(_ value: String) throws {
    lock.lock()
    defer { lock.unlock() }

    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]

    if normalized.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainFailure(status: status)
      }
      return
    }

    let data = Data(normalized.utf8)
    let updateStatus = SecItemUpdate(
      query as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainFailure(status: updateStatus)
    }

    var item = query
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainFailure(status: addStatus)
    }
  }

  private struct KeychainFailure: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
  }
}

nonisolated enum VolcengineTranscriptionProtocol {
  static let serviceName = "clasi"
  static let baseURL = "wss://ark-beta.cn-beijing.volces.com/api/v3/realtime"
  static let pcmBytesPerCommit = 3_200
  static let commitIntervalNanoseconds: UInt64 = 100_000_000
  static let maximumMessageBytes = 1_048_576
  static let maximumTranscriptCharacters = 16_000_000

  struct ServerEvent: Equatable {
    let type: String
    let delta: String?
    let speakerChange: Bool
    let errorCode: String?
    let errorMessage: String?
  }

  static func endpointURL(modelID: String) -> URL? {
    guard var components = URLComponents(string: baseURL) else { return nil }
    components.queryItems = [
      URLQueryItem(name: "service", value: serviceName),
      URLQueryItem(name: "model", value: modelID),
    ]
    return components.url
  }

  static func sessionUpdateData(configuration: RecordingTranscriptionConfiguration) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "event_id": eventID(),
      "type": "session.update",
      "session": [
        "input_audio_format": "pcm16",
        "modalities": ["text"],
        "speaker_detection": ["enable_speaker_change_detection": true],
        "input_audio_translation": [
          "source_language": configuration.sourceLanguage.rawValue,
          "target_language": configuration.sourceLanguage.targetLanguageCode,
        ],
      ],
    ])
  }

  static func audioCommitData(_ pcmData: Data) throws -> Data {
    guard !pcmData.isEmpty, pcmData.count <= pcmBytesPerCommit else {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    return try JSONSerialization.data(withJSONObject: [
      "event_id": eventID(),
      "type": "input_audio.commit",
      "audio": pcmData.base64EncodedString(),
    ])
  }

  static func audioDoneData() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "event_id": eventID(),
      "type": "input_audio.done",
    ])
  }

  static func parseServerEvent(_ data: Data) throws -> ServerEvent {
    guard data.count <= maximumMessageBytes else {
      throw RecordingTranscriptionError.responseTooLarge
    }
    guard
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      throw RecordingTranscriptionError.invalidResponse
    }

    let error = object["error"] as? [String: Any]
    return ServerEvent(
      type: type,
      delta: object["delta"] as? String,
      speakerChange: object["speaker_change"] as? Bool ?? false,
      errorCode: error?["code"] as? String,
      errorMessage: error?["message"] as? String
    )
  }

  private static func eventID() -> String {
    "event_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
  }
}

final nonisolated class VolcengineRecordingTranscriptionService: @unchecked Sendable {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func transcribe(
    recordingURL: URL,
    configuration: RecordingTranscriptionConfiguration
  ) async throws -> RecordingTranscript {
    let audioDuration = try await inspectAudio(at: recordingURL)
    guard let endpoint = VolcengineTranscriptionProtocol.endpointURL(modelID: configuration.modelID) else {
      throw RecordingTranscriptionError.invalidConfiguration
    }

    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 30
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    let socket = session.webSocketTask(with: request)
    socket.resume()
    defer { socket.cancel(with: .goingAway, reason: nil) }

    do {
      try await sendJSON(
        VolcengineTranscriptionProtocol.sessionUpdateData(configuration: configuration),
        over: socket
      )
      try await withTimeout(seconds: 30, socket: socket) {
        try await self.waitForSessionUpdate(on: socket)
      }

      let transcript = try await exchangeAudio(
        at: recordingURL,
        over: socket,
        timeout: max(90, audioDuration + 90)
      )
      socket.cancel(with: .normalClosure, reason: nil)
      return RecordingTranscript(text: transcript)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as RecordingTranscriptionError {
      throw error
    } catch {
      throw RecordingTranscriptionError.connectionFailed
    }
  }

  private func inspectAudio(at recordingURL: URL) async throws -> TimeInterval {
    guard recordingURL.isFileURL, FileManager.default.isReadableFile(atPath: recordingURL.path) else {
      throw RecordingTranscriptionError.invalidRecording
    }
    let resourceValues = try? recordingURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard resourceValues?.isRegularFile == true, (resourceValues?.fileSize ?? 0) > 0 else {
      throw RecordingTranscriptionError.invalidRecording
    }

    let asset = AVURLAsset(url: recordingURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard !audioTracks.isEmpty else {
      throw RecordingTranscriptionError.noAudioTrack
    }
    let duration = await CMTimeGetSeconds(try asset.load(.duration))
    guard duration.isFinite, duration > 0 else {
      throw RecordingTranscriptionError.invalidRecording
    }
    guard duration <= 7_200 else {
      throw RecordingTranscriptionError.audioTooLong
    }
    return duration
  }

  private func waitForSessionUpdate(on socket: URLSessionWebSocketTask) async throws {
    while true {
      let event = try await receiveEvent(on: socket)
      switch event.type {
      case "session.updated":
        return
      case "error":
        throw serviceError(from: event)
      default:
        continue
      }
    }
  }

  private func receiveTranscript(on socket: URLSessionWebSocketTask) async throws -> String {
    var text = ""
    var characterCount = 0
    while true {
      try Task.checkCancellation()
      let event = try await receiveEvent(on: socket)
      switch event.type {
      case "response.input_audio_transcription.delta":
        guard let delta = event.delta, !delta.isEmpty else { continue }
        if event.speakerChange, !text.isEmpty, !text.hasSuffix("\n") {
          guard characterCount < VolcengineTranscriptionProtocol.maximumTranscriptCharacters else {
            throw RecordingTranscriptionError.responseTooLarge
          }
          text.append("\n")
          characterCount += 1
        }
        let deltaCount = delta.count
        guard characterCount <= VolcengineTranscriptionProtocol.maximumTranscriptCharacters - deltaCount else {
          throw RecordingTranscriptionError.responseTooLarge
        }
        text.append(delta)
        characterCount += deltaCount
      case "response.done":
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
          throw RecordingTranscriptionError.emptyTranscript
        }
        return result
      case "error":
        throw serviceError(from: event)
      default:
        continue
      }
    }
  }

  private enum TransferResult: Sendable {
    case senderFinished
    case transcript(String)
  }

  private func exchangeAudio(
    at recordingURL: URL,
    over socket: URLSessionWebSocketTask,
    timeout: TimeInterval
  ) async throws -> String {
    try await withThrowingTaskGroup(of: TransferResult.self) { group in
      group.addTask {
        try await self.sendAudio(at: recordingURL, over: socket)
        return .senderFinished
      }
      group.addTask {
        await .transcript(try self.receiveTranscript(on: socket))
      }
      group.addTask {
        let nanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        socket.cancel(with: .goingAway, reason: nil)
        throw RecordingTranscriptionError.timeout
      }

      var senderFinished = false
      var transcript: String?
      do {
        while let result = try await group.next() {
          switch result {
          case .senderFinished:
            senderFinished = true
          case .transcript(let value):
            transcript = value
          }
          if senderFinished, let transcript {
            group.cancelAll()
            return transcript
          }
        }
      } catch {
        socket.cancel(with: .goingAway, reason: nil)
        group.cancelAll()
        throw error
      }
      throw RecordingTranscriptionError.connectionFailed
    }
  }

  private func sendAudio(at recordingURL: URL, over socket: URLSessionWebSocketTask) async throws {
    let asset = AVURLAsset(url: recordingURL)
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw RecordingTranscriptionError.noAudioTrack
    }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    let output = AVAssetReaderTrackOutput(
      track: audioTrack,
      outputSettings: [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    reader.add(output)
    guard reader.startReading() else {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    defer { reader.cancelReading() }

    var bufferedPCM = Data()
    var sentAnyAudio = false
    while reader.status == .reading {
      try Task.checkCancellation()
      if let sample = output.copyNextSampleBuffer() {
        bufferedPCM.append(try copyPCMData(from: sample))
      } else if reader.status == .reading {
        await Task.yield()
      }

      while bufferedPCM.count >= VolcengineTranscriptionProtocol.pcmBytesPerCommit {
        let chunk = Data(bufferedPCM.prefix(VolcengineTranscriptionProtocol.pcmBytesPerCommit))
        bufferedPCM.removeFirst(VolcengineTranscriptionProtocol.pcmBytesPerCommit)
        try await sendJSON(VolcengineTranscriptionProtocol.audioCommitData(chunk), over: socket)
        sentAnyAudio = true
        try await Task.sleep(nanoseconds: VolcengineTranscriptionProtocol.commitIntervalNanoseconds)
      }
    }

    guard reader.status == .completed else {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    if !bufferedPCM.isEmpty {
      try await sendJSON(VolcengineTranscriptionProtocol.audioCommitData(bufferedPCM), over: socket)
      sentAnyAudio = true
    }
    guard sentAnyAudio else {
      throw RecordingTranscriptionError.noAudioTrack
    }
    try await sendJSON(VolcengineTranscriptionProtocol.audioDoneData(), over: socket)
  }

  private func copyPCMData(from sampleBuffer: CMSampleBuffer) throws -> Data {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    guard length > 0 else { return Data() }
    var data = Data(count: length)
    let status = data.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(
        blockBuffer,
        atOffset: 0,
        dataLength: length,
        destination: baseAddress
      )
    }
    guard status == kCMBlockBufferNoErr else {
      throw RecordingTranscriptionError.audioDecodeFailed
    }
    return data
  }

  private func receiveEvent(on socket: URLSessionWebSocketTask) async throws
    -> VolcengineTranscriptionProtocol.ServerEvent {
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .data(let value):
      data = value
    case .string(let value):
      guard let valueData = value.data(using: .utf8) else {
        throw RecordingTranscriptionError.invalidResponse
      }
      data = valueData
    @unknown default:
      throw RecordingTranscriptionError.invalidResponse
    }
    return try VolcengineTranscriptionProtocol.parseServerEvent(data)
  }

  private func sendJSON(_ data: Data, over socket: URLSessionWebSocketTask) async throws {
    guard let message = String(data: data, encoding: .utf8) else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    try await socket.send(.string(message))
  }

  private func serviceError(from event: VolcengineTranscriptionProtocol.ServerEvent)
    -> RecordingTranscriptionError {
    let code = String((event.errorCode ?? "UnknownError").prefix(128))
    let message = String((event.errorMessage ?? L10n.RecordingTranscription.connectionFailed).prefix(1_024))
    return .service(code: code, message: message)
  }

  private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    socket: URLSessionWebSocketTask,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        let nanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        socket.cancel(with: .goingAway, reason: nil)
        throw RecordingTranscriptionError.timeout
      }
      do {
        guard let result = try await group.next() else {
          throw RecordingTranscriptionError.timeout
        }
        group.cancelAll()
        return result
      } catch {
        socket.cancel(with: .goingAway, reason: nil)
        group.cancelAll()
        throw error
      }
    }
  }
}
