import CryptoKit
import Foundation

/// TOS V4, checked against the official Python SDK 2.9.2 using synthetic keys.
/// This type never persists credentials, Authorization, or signed URLs.
nonisolated struct VolcengineTOSSigner: Sendable {
  let accessKey: String
  let secretKey: String
  let region: String

  init(accessKey: String, secretKey: String, region: String = "cn-beijing") throws {
    guard Self.validCredential(accessKey), Self.validCredential(secretKey),
          region == "cn-beijing" else { throw RecordingTranscriptionError.invalidConfiguration }
    self.accessKey = accessKey
    self.secretKey = secretKey
    self.region = region
  }

  static func validCredential(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096 && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func encode(_ value: String, allowSlash: Bool = false) -> String {
    value.utf8.map { byte in
      if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        || [45, 46, 95, 126].contains(byte) || (allowSlash && byte == 47) {
        return String(UnicodeScalar(byte))
      }
      return String(format: "%%%02X", byte)
    }.joined()
  }

  static func canonicalQuery(_ query: [String: String]) -> String {
    query.keys.sorted().map { "\(encode($0))=\(encode(query[$0]!))" }.joined(separator: "&")
  }

  func endpoint(bucket: String, key: String? = nil) throws -> URL {
    guard bucket.range(of: #"^shotpaste-tmp-[a-z0-9-]{3,48}$"#, options: .regularExpression) != nil,
          !bucket.hasSuffix("-"),
          key == nil || (key!.hasPrefix("transcription/v1/") && !key!.contains("..")
                         && !key!.contains("\\") && !key!.contains(where: { $0.isNewline }))
    else { throw RecordingTranscriptionError.invalidConfiguration }
    guard let url = URL(string: "https://\(bucket).tos-\(region).volces.com/\(Self.encode(key ?? "", allowSlash: true))")
    else { throw RecordingTranscriptionError.invalidConfiguration }
    return url
  }

  func request(method: String, bucket: String, key: String? = nil,
               query: [String: String] = [:], headers: [String: String] = [:],
               body: Data = Data(), date: Date = Date()) throws -> URLRequest {
    guard ["GET", "HEAD", "PUT", "DELETE"].contains(method.uppercased()) else {
      throw RecordingTranscriptionError.invalidConfiguration
    }
    let url = try endpoint(bucket: bucket, key: key)
    let timestamp = Self.timestamp(date)
    var signed = ["host": url.host!, "x-tos-date": timestamp,
                  "x-tos-content-sha256": Self.sha256(body)]
    for (key, value) in headers {
      let name = key.lowercased()
      guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
            (name == "content-type" || name.hasPrefix("x-tos-")),
            !["x-tos-date", "x-tos-content-sha256"].contains(name),
            !value.contains(where: { $0.isNewline }) else {
        throw RecordingTranscriptionError.invalidConfiguration
      }
      signed[name] = value
    }
    let keys = signed.keys.sorted()
    let canonical = [method.uppercased(), Self.encode(key.map { "/" + $0 } ?? "/", allowSlash: true),
                     Self.canonicalQuery(query), keys.map { "\($0):\(signed[$0]!)\n" }.joined(),
                     keys.joined(separator: ";"), Self.sha256(body)].joined(separator: "\n")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    if !query.isEmpty { components.percentEncodedQuery = Self.canonicalQuery(query) }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method.uppercased()
    request.httpBody = body.isEmpty ? nil : body
    request.timeoutInterval = 60
    for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("TOS4-HMAC-SHA256 Credential=\(accessKey)/\(scope(timestamp)), SignedHeaders=\(keys.joined(separator: ";")), Signature=\(signature(canonical, timestamp: timestamp))",
                     forHTTPHeaderField: "Authorization")
    return request
  }

  func signedGET(bucket: String, key: String, expires: Int = 86_400,
                 date: Date = Date()) throws -> URL {
    guard (1...86_400).contains(expires) else { throw RecordingTranscriptionError.invalidConfiguration }
    let url = try endpoint(bucket: bucket, key: key)
    let timestamp = Self.timestamp(date)
    var query = ["X-Tos-Algorithm": "TOS4-HMAC-SHA256", "X-Tos-Credential": "\(accessKey)/\(scope(timestamp))",
                 "X-Tos-Date": timestamp, "X-Tos-Expires": String(expires), "X-Tos-SignedHeaders": "host"]
    let canonical = ["GET", Self.encode("/" + key, allowSlash: true), Self.canonicalQuery(query),
                     "host:\(url.host!)\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
    query["X-Tos-Signature"] = signature(canonical, timestamp: timestamp)
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.percentEncodedQuery = Self.canonicalQuery(query)
    return components.url!
  }

  private func scope(_ timestamp: String) -> String { "\(timestamp.prefix(8))/\(region)/tos/request" }

  private func signature(_ canonical: String, timestamp: String) -> String {
    func hmac(_ key: Data, _ text: String) -> Data {
      Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
    }
    var key = hmac(Data(secretKey.utf8), String(timestamp.prefix(8)))
    for component in [region, "tos", "request"] { key = hmac(key, component) }
    let text = ["TOS4-HMAC-SHA256", timestamp, scope(timestamp), Self.sha256(Data(canonical.utf8))].joined(separator: "\n")
    return hmac(key, text).map { String(format: "%02x", $0) }.joined()
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }
}
