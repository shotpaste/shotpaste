import Foundation

nonisolated struct VolcengineCloudFailure: LocalizedError, Sendable {
  let http: Int
  let code: String
  var retryable: Bool { http == 429 || http >= 500 }
  var errorDescription: String? {
    if http == 200 && code == "20000003" { return L10n.RecordingTranscription.emptyTranscript }
    let message: String
    switch http {
    case 401, 403: message = L10n.CloudTranscription.permission
    case 402: message = L10n.CloudTranscription.quota
    case 404: message = L10n.CloudTranscription.uncertain
    default: message = L10n.CloudTranscription.cloudError
    }
    return "\(message) (\(http)/\(code))"
  }
  init(http: Int, code: String = "unknown") {
    self.http = http
    self.code = code.count <= 64 && code.utf8.allSatisfy({
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
    }) ? code : "redacted"
  }
}
