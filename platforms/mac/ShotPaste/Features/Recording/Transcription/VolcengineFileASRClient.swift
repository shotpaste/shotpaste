import Foundation

nonisolated struct VolcengineFileTranscript: Codable, Equatable, Sendable {
  struct Utterance: Codable, Equatable, Sendable {
    let text: String
    let startMilliseconds: Int
    let endMilliseconds: Int
    /// Scoped to one submitted part, never an identity across parts or tracks.
    let speaker: String?
  }
  let text: String
  let durationMilliseconds: Int
  var requestID: UUID?
  var providerVersion: String?
  let utterances: [Utterance]
}

nonisolated enum VolcengineFileASRProtocol {
  static let resourceID = "volc.seedasr.auc"
  static let baseURL = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/"
  static let maximumResponseBytes = 16 * 1_024 * 1_024
  static let languages: Set<String> = ["zh-CN", "en-US", "ja-JP", "id-ID", "es-MX", "pt-BR", "de-DE", "fr-FR", "ko-KR", "fil-PH", "ms-MY", "th-TH", "ar-SA", "it-IT", "bn-BD", "el-GR", "nl-NL", "ru-RU", "tr-TR", "vi-VN", "pl-PL", "ne-NP", "uk-UA", "yue-CN"]

  enum QueryResult: Equatable, Sendable {
    case pending
    case completed(VolcengineFileTranscript)
  }

  static func request(apiKey: String, requestID: UUID, audioURL: URL? = nil,
                      language: String? = nil) throws -> URLRequest {
    guard VolcengineTOSSigner.validCredential(apiKey), language == nil || languages.contains(language!) else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    var body: [String: Any] = [:]
    if let audioURL {
      guard audioURL.scheme == "https", audioURL.port == nil,
            audioURL.user == nil, audioURL.password == nil, audioURL.fragment == nil,
            let host = audioURL.host, host.hasSuffix(".tos-cn-beijing.volces.com"),
            host.hasPrefix("shotpaste-tmp-"), audioURL.path.hasPrefix("/transcription/v1/")
      else { throw RecordingTranscriptionError.invalidConfiguration }
      var audio: [String: Any] = ["url": audioURL.absoluteString, "format": "m4a"]
      if let language { audio["language"] = language }
      body = ["audio": audio, "request": ["model_name": "bigmodel", "show_utterances": true,
               "enable_auto_lang": language == nil, "enable_itn": true, "enable_punc": true,
               "enable_speaker_info": language == nil || language == "zh-CN"]]
    }
    var request = URLRequest(url: URL(string: baseURL + (audioURL == nil ? "query" : "submit"))!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
    request.setValue(requestID.uuidString.lowercased(), forHTTPHeaderField: "X-Api-Request-Id")
    request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  static func status(_ response: HTTPURLResponse) throws -> String {
    guard response.statusCode == 200 else { throw VolcengineCloudFailure(http: response.statusCode, code: response.value(forHTTPHeaderField: "X-Api-Status-Code") ?? "unknown") }
    guard let code = response.value(forHTTPHeaderField: "X-Api-Status-Code"),
          code.count == 8, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
      throw RecordingTranscriptionError.invalidResponse
    }
    return code
  }

  static func submittedTaskID(_ data: Data, response: HTTPURLResponse) throws -> UUID? {
    let code = try status(response)
    guard code == "20000000" else { throw VolcengineCloudFailure(http: 200, code: code) }
    guard data.count <= maximumResponseBytes else { throw RecordingTranscriptionError.responseTooLarge }
    struct Receipt: Decodable { let task_id: UUID? }
    do { return try JSONDecoder().decode(Receipt.self, from: data).task_id }
    catch { throw RecordingTranscriptionError.invalidResponse }
  }

  static func queryResult(_ data: Data, response: HTTPURLResponse) throws -> QueryResult {
    let code = try status(response)
    if ["20000001", "20000002"].contains(code) { return .pending }
    guard code == "20000000" else { throw VolcengineCloudFailure(http: 200, code: code) }
    guard data.count <= maximumResponseBytes else { throw RecordingTranscriptionError.responseTooLarge }
    struct Body: Decodable {
      struct Audio: Decodable { let duration: Int }
      struct Result: Decodable {
        struct Utterance: Decodable {
          struct Additions: Decodable { let speaker: String? }
          let text: String
          let start_time: Int
          let end_time: Int
          let additions: Additions?
        }
        let text: String
        let utterances: [Utterance]
      }
      let audio_info: Audio
      let result: Result
    }
    let body: Body
    do { body = try JSONDecoder().decode(Body.self, from: data) }
    catch { throw RecordingTranscriptionError.invalidResponse }
    let duration = body.audio_info.duration
    guard duration > 0, duration <= 18_000_000,
          !body.result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !body.result.utterances.isEmpty else { throw RecordingTranscriptionError.emptyTranscript }
    var previousStart = -1
    let utterances = try body.result.utterances.map { utterance in
      guard !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            utterance.start_time >= 0, utterance.start_time >= previousStart,
            utterance.end_time > utterance.start_time, utterance.end_time <= duration,
            utterance.additions?.speaker == nil ||
              utterance.additions!.speaker!.range(of: #"^[0-9]{1,8}$"#, options: .regularExpression) != nil
      else { throw RecordingTranscriptionError.invalidResponse }
      previousStart = utterance.start_time
      return VolcengineFileTranscript.Utterance(text: utterance.text,
        startMilliseconds: utterance.start_time, endMilliseconds: utterance.end_time,
        speaker: utterance.additions?.speaker)
    }
    return .completed(VolcengineFileTranscript(text: body.result.text,
      durationMilliseconds: duration, utterances: utterances))
  }
}

nonisolated protocol VolcengineCloudTransport: Sendable {
  func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}
nonisolated extension VolcengineCloudTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await send(request, maximumBytes: VolcengineFileASRProtocol.maximumResponseBytes)
  }
}

/// Credentials must never follow an HTTP redirect, including to another official host.
final nonisolated class VolcengineCloudHTTP: NSObject, URLSessionTaskDelegate, VolcengineCloudTransport, @unchecked Sendable {
  private let progress: @Sendable (Int64, Int64) -> Void
  init(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) {
    self.progress = progress
    super.init()
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    progress(totalBytesSent, totalBytesExpectedToSend)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func send(_ request: URLRequest, maximumBytes: Int = VolcengineFileASRProtocol.maximumResponseBytes) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse else { throw RecordingTranscriptionError.invalidResponse }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < maximumBytes else { throw RecordingTranscriptionError.responseTooLarge }
        data.append(byte)
      }
      return (data, response)
    } catch is CancellationError { throw CancellationError() }
    catch let error as RecordingTranscriptionError { throw error }
    catch let error as VolcengineCloudFailure { throw error }
    catch {
      if Task.isCancelled { throw CancellationError() }
      throw RecordingTranscriptionError.connectionFailed
    }
  }
}
