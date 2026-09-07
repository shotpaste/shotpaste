import Foundation
@testable import ShotPaste
import XCTest

final class VolcengineFileASRTests: XCTestCase {
  func testExistingCleanupRuleRequiresExactPrefixAndBothExpirationPolicies() {
    let rule: [String: Any] = ["ID": "existing-poc", "Prefix": "transcription/v1/test/",
      "Status": "Enabled", "Expiration": ["Days": 2],
      "AbortIncompleteMultipartUpload": ["DaysAfterInitiation": 2]]
    XCTAssertTrue(VolcengineTOSClient.hasRequiredCleanup(rule, prefix: "transcription/v1/test/"))
    XCTAssertFalse(VolcengineTOSClient.hasRequiredCleanup(rule, prefix: "transcription/v1/other/"))
    var disabled = rule; disabled["Status"] = "Disabled"
    XCTAssertFalse(VolcengineTOSClient.hasRequiredCleanup(disabled, prefix: "transcription/v1/test/"))
    var missingAbort = rule; missingAbort.removeValue(forKey: "AbortIncompleteMultipartUpload")
    XCTAssertFalse(VolcengineTOSClient.hasRequiredCleanup(missingAbort, prefix: "transcription/v1/test/"))
  }

  func testSilentAudioResultReportsNoSpeechWithoutRetrying() {
    XCTAssertThrowsError(try VolcengineFileASRProtocol.queryResult(Data("{}".utf8), response: response("20000003"))) { error in
      guard let failure = error as? VolcengineCloudFailure else { return XCTFail("Expected provider status") }
      XCTAssertEqual(failure.code, "20000003")
      XCTAssertFalse(failure.retryable)
      XCTAssertEqual(failure.errorDescription, L10n.RecordingTranscription.emptyTranscript)
    }
  }

  private let date = ISO8601DateFormatter().date(from: "2026-09-06T00:00:00Z")!
  private let bucket = "shotpaste-tmp-fixture-debug"
  private let key = "transcription/v1/test/part.m4a"

  func testTOSHeaderSignatureMatchesOfficialSDK292() throws {
    let signer = try VolcengineTOSSigner(accessKey: "fixture-ak", secretKey: "fixture-sk")
    let request = try signer.request(method: "PUT", bucket: bucket, key: key,
      headers: ["content-type": "audio/mp4"], body: Data("hello".utf8), date: date)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
      "TOS4-HMAC-SHA256 Credential=fixture-ak/20260906/cn-beijing/tos/request, SignedHeaders=content-type;host;x-tos-content-sha256;x-tos-date, Signature=1954d66ac2961a650d13906cd5cc45f53b8a3591dcabed6b4ddbebc6984f7a14")
  }

  func testTOSPresignedGETMatchesOfficialSDK292() throws {
    let signer = try VolcengineTOSSigner(accessKey: "fixture-ak", secretKey: "fixture-sk")
    let url = try signer.signedGET(bucket: bucket, key: key, date: date)
    let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    XCTAssertEqual(query["X-Tos-Signature"], "1d7f41ad365d20f99329cab5de0d385cb6f2f47ad644a0354639c914a100ad20")
    XCTAssertEqual(query["X-Tos-Expires"], "86400")
    XCTAssertEqual(query["X-Tos-SignedHeaders"], "host")
    XCTAssertThrowsError(try signer.signedGET(bucket: bucket, key: key, expires: 86_401))
  }

  func testSigningRejectsHeaderInjectionAndNonApplicationResources() throws {
    XCTAssertThrowsError(try VolcengineTOSSigner(accessKey: "key\r\nx: y", secretKey: "secret"))
    let signer = try VolcengineTOSSigner(accessKey: "key", secretKey: "secret")
    XCTAssertThrowsError(try signer.endpoint(bucket: "unrelated-business-bucket"))
    XCTAssertThrowsError(try signer.endpoint(bucket: bucket, key: "transcription/v1/../secret"))
    XCTAssertThrowsError(try signer.request(method: "PUT", bucket: bucket, headers: ["x-tos-acl": "private\npublic"]))
    XCTAssertThrowsError(try signer.request(method: "PUT", bucket: bucket, headers: ["x-tos-bad\nname": "value"]))
    XCTAssertThrowsError(try signer.request(method: "GET\r\n", bucket: bucket))
    XCTAssertEqual(VolcengineTOSSigner.encode("文字 /+"), "%E6%96%87%E5%AD%97%20%2F%2B")
  }

  func testAutoLanguageAndQueryShape() throws {
    let signer = try VolcengineTOSSigner(accessKey: "key", secretKey: "secret")
    let url = try signer.signedGET(bucket: bucket, key: key)
    let id = UUID()
    let submit = try VolcengineFileASRProtocol.request(apiKey: "key", requestID: id, audioURL: url)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: submit.httpBody!) as? [String: Any])
    let audio = try XCTUnwrap(body["audio"] as? [String: Any])
    XCTAssertNil(audio["language"])
    XCTAssertEqual(audio["format"] as? String, "m4a")
    XCTAssertEqual((body["request"] as? [String: Any])?["enable_auto_lang"] as? Bool, true)
    XCTAssertEqual(submit.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.auc")
    let query = try VolcengineFileASRProtocol.request(apiKey: "key", requestID: id)
    XCTAssertEqual(String(data: query.httpBody!, encoding: .utf8), "{}")
    XCTAssertTrue(query.url!.path.hasSuffix("/query"))
    XCTAssertThrowsError(try VolcengineFileASRProtocol.request(apiKey: "key", requestID: id, audioURL: URL(string: "https://example.com/audio.m4a")!))
  }

  private func response(_ code: String = "20000000", http: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: VolcengineFileASRProtocol.baseURL)!, statusCode: http,
      httpVersion: "HTTP/1.1", headerFields: ["X-Api-Status-Code": code])!
  }

  func testSubmissionReceiptWithAndWithoutTaskID() throws {
    XCTAssertNil(try VolcengineFileASRProtocol.submittedTaskID(Data("{}".utf8), response: response()))
    let id = UUID()
    let body = try JSONSerialization.data(withJSONObject: ["task_id": id.uuidString])
    XCTAssertEqual(try VolcengineFileASRProtocol.submittedTaskID(body, response: response()), id)
    XCTAssertThrowsError(try VolcengineFileASRProtocol.submittedTaskID(body, response: response(http: 403)))
  }

  func testPendingIsNotSuccessAndRawServerMessagesAreNotErrors() throws {
    XCTAssertEqual(try VolcengineFileASRProtocol.queryResult(Data(), response: response("20000002")), .pending)
    XCTAssertThrowsError(try VolcengineFileASRProtocol.queryResult(Data("secret error".utf8), response: response("45000030"))) { error in
      XCTAssertFalse(error.localizedDescription.contains("secret error"))
    }
  }

  func testResultTimestampAndTypeValidation() throws {
    func body(start: Any, end: Any) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["audio_info": ["duration": 6312], "result": ["text": "test", "utterances": [
        ["text": "test", "start_time": start, "end_time": end, "additions": ["speaker": "1"]]
      ]]])
    }
    guard case let .completed(result) = try VolcengineFileASRProtocol.queryResult(body(start: 440, end: 5920), response: response()) else {
      return XCTFail("Expected final result")
    }
    XCTAssertEqual(result.utterances.first?.speaker, "1")
    XCTAssertEqual(result.durationMilliseconds, 6312)
    for pair: (Any, Any) in [(true, 900), (-1, 900), (900, 400), (440, 7000), ("440", 5920)] {
      XCTAssertThrowsError(try VolcengineFileASRProtocol.queryResult(body(start: pair.0, end: pair.1), response: response()))
    }
  }
  func testPersistedJobContainsReferencesAndRawTranscriptOnly() throws {
    let account = VolcengineCloudAccount()
    var job = VolcengineCloudJob(id: UUID(), account: account,
      sourceChecksum: String(repeating: "a", count: 64), language: nil, requestID: UUID())
    job.stage = .transcriptReady
    job.cleanup = .pending
    job.transcript = VolcengineFileTranscript(text: "fixture", durationMilliseconds: 900,
      utterances: [.init(text: "fixture", startMilliseconds: 0, endMilliseconds: 900, speaker: nil)])
    let data = try JSONEncoder().encode(job)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), Set(["id", "account", "sourceChecksum", "requestID", "stage", "cleanup", "pollAttempts", "transcript"]))
    let accountFields = try XCTUnwrap(fields["account"] as? [String: Any])
    XCTAssertEqual(Set(accountFields.keys), Set(["id", "installationID", "bucket", "initialized", "verified"]))
    let restored = try JSONDecoder().decode(VolcengineCloudJob.self, from: data)
    XCTAssertEqual(restored.requestID, job.requestID)
    XCTAssertEqual(restored.transcript, job.transcript)
    XCTAssertEqual(restored.cleanup, .pending)
    XCTAssertTrue(restored.objectKey.hasPrefix(account.prefix))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("https://"))
  }

  func testCredentialValidationAndProfilesStartUnverified() throws {
    let account = VolcengineCloudAccount()
    XCTAssertFalse(account.initialized)
    XCTAssertFalse(account.verified)
    XCTAssertNotEqual(account.id, VolcengineCloudAccount().id)
    XCTAssertTrue(account.bucket.hasPrefix("shotpaste-tmp-"))
    XCTAssertThrowsError(try VolcengineCloudCredentials(speechKey: "key", accessKey: "", secretKey: "secret"))
    XCTAssertThrowsError(try VolcengineCloudCredentials(speechKey: "key", accessKey: "access", secretKey: "bad\nheader"))
    let credentials = try VolcengineCloudCredentials(speechKey: " key ", accessKey: " access ", secretKey: " secret ")
    XCTAssertEqual(credentials.accessKey, "access")
  }

}
