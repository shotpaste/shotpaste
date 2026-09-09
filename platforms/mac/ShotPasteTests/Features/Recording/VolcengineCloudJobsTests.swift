import Foundation
@testable import ShotPaste
import XCTest

private actor CloudFixtureTransport: VolcengineCloudTransport {
  enum Mode { case success, lostSubmit, deleteFails, forbidden, forbiddenOnce, pendingThenSuccess }
  let mode: Mode
  private var calls: [String] = []
  private var exists = false
  private var queries = 0
  private var checksum = ""
  private var submissionIDs: [String] = []
  init(_ mode: Mode) { self.mode = mode }
  func history() -> [String] { calls }
  func submittedIDs() -> [String] { submissionIDs }
  func send(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
    let method = request.httpMethod!, url = request.url!
    calls.append(method + " " + url.path)
    var status = 200, code: String? = nil
    var data = Data(), headers: [String: String] = [:]
    if url.host == "openspeech.bytedance.com" {
      code = "20000000"
      if url.path.hasSuffix("submit") {
        submissionIDs.append(request.value(forHTTPHeaderField: "X-Api-Request-Id") ?? "")
        if mode == .lostSubmit { throw RecordingTranscriptionError.connectionFailed }
        if mode == .forbidden || (mode == .forbiddenOnce && submissionIDs.count == 1) { status = 403; code = "45000030" }
        data = Data("{}".utf8)
      } else {
        queries += 1
        if mode == .pendingThenSuccess && queries == 1 { code = "20000002" }
        else { data = Data(#"{"audio_info":{"duration":6312},"result":{"text":"fixture","utterances":[{"text":"fixture","start_time":440,"end_time":5920}]}}"#.utf8) }
      }
    } else if method == "PUT" {
      exists = true; checksum = request.value(forHTTPHeaderField: "x-tos-meta-sha256") ?? ""
    } else if method == "DELETE" {
      if mode == .deleteFails { status = 403 } else { exists = false; status = 204 }
    } else if method == "HEAD" && url.path != "/" {
      status = exists ? 200 : 404
      headers["x-tos-meta-sha256"] = checksum
    }
    if let code { headers["X-Api-Status-Code"] = code }
    return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
  }
}

final class VolcengineCloudJobsTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CloudJobTests-\(UUID())")
  }
  private func credentials() throws -> VolcengineCloudCredentials {
    try .init(speechKey: "fixture-speech", accessKey: "fixture-ak", secretKey: "fixture-sk")
  }
  func testLostSubmitResponseQueriesOriginalTaskAndNeverResubmits() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.lostSubmit)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    let account = VolcengineCloudAccount()
    let result = try await jobs.transcribe(audio: Data("audio".utf8), account: account, credentials: credentials(), language: nil)
    XCTAssertEqual(result.text, "fixture")
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 1)
    XCTAssertEqual(calls.filter { $0.hasSuffix("/query") }.count, 1)
    let records = await jobs.jobs()
    XCTAssertEqual(records.first?.stage, .transcriptReady)
    XCTAssertEqual(records.first?.cleanup, .cleaned)
    let receipt = try Data(contentsOf: FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!)
    for secret in ["fixture-speech", "fixture-ak", "fixture-sk", "https://", "Authorization"] {
      XCTAssertFalse(String(decoding: receipt, as: UTF8.self).contains(secret))
    }
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).contains { $0.pathExtension == "m4a" })
  }
  func testPersistedRawResultSurvivesFailedDeletionAndNewActor() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.deleteFails)
    let account = VolcengineCloudAccount(), data = Data("audio".utf8)
    let first = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    _ = try await first.transcribe(audio: data, account: account, credentials: credentials(), language: nil)
    let second = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    let result = try await second.transcribe(audio: data, account: account, credentials: credentials(), language: nil)
    XCTAssertEqual(result.text, "fixture")
    let records = await second.jobs()
    XCTAssertEqual(records.first?.cleanup, .pending)
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 1)
  }
  func testPermissionDenialDoesNotPollOrRetryAndCleansObject() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.forbidden)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    do {
      _ = try await jobs.transcribe(audio: Data("audio".utf8), account: .init(), credentials: credentials(), language: nil)
      XCTFail("Expected permission failure")
    } catch { XCTAssertEqual((error as? VolcengineCloudFailure)?.http, 403) }
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/query") }.count, 0)
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 1)
    let records = await jobs.jobs()
    XCTAssertEqual(records.first?.stage, .failed)
    XCTAssertEqual(records.first?.cleanup, .cleaned)
  }
  func testPendingResponseDoesNotPersistPartialTranscript() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.pendingThenSuccess)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    _ = try await jobs.transcribe(audio: Data("audio".utf8), account: .init(), credentials: credentials(), language: nil)
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/query") }.count, 2)
  }
  func testCancellationRetainsReceiptAndDeletesUploadedCopy() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.success)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in throw CancellationError() })
    do {
      _ = try await jobs.transcribe(audio: Data("audio".utf8), account: .init(), credentials: credentials(), language: nil)
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    let records = await jobs.jobs()
    XCTAssertEqual(records.first?.stage, .cancelled)
    XCTAssertEqual(records.first?.cleanup, .cleaned)
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/query") }.count, 0)
  }
  func testDuplicateInvocationUsesSavedResultWithoutNetwork() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.success)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    let account = VolcengineCloudAccount()
    _ = try await jobs.transcribe(audio: Data("first-encode".utf8), account: account, credentials: credentials(), language: nil, sourceID: "same-original-and-offset")
    _ = try await jobs.transcribe(audio: Data("second-encode".utf8), account: account, credentials: credentials(), language: nil, sourceID: "same-original-and-offset")
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 1)
  }

  func testRestartWithSubmittingReceiptOnlyQueriesWithoutLocalAudio() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let account = VolcengineCloudAccount()
    let source = "original-recording-offset"
    let reference = VolcengineTOSSigner.sha256(Data("\(account.id)|\(source)|auto".utf8))
    var receipt = VolcengineCloudJob(id: UUID(), account: account, sourceChecksum: "old-encoding",
      language: nil, requestID: UUID())
    receipt.stage = .submitting; receipt.cleanup = .pending
    try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent(reference + ".json"))
    let fixture = CloudFixtureTransport(.success)
    let restored = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    _ = try await restored.transcribe(audio: Data("new-encoding".utf8), account: account,
      credentials: credentials(), language: nil, sourceID: source)
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 0)
    XCTAssertEqual(calls.filter { $0.hasPrefix("PUT ") }.count, 0)
    XCTAssertEqual(calls.filter { $0.hasSuffix("/query") }.count, 1)
    let records = await restored.jobs()
    XCTAssertEqual(records.first?.requestID, receipt.requestID)
  }
  func testSimultaneousDuplicateClicksShareOneSubmission() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.success)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    let account = VolcengineCloudAccount(), keys = try credentials(), data = Data("audio".utf8)
    async let first = jobs.transcribe(audio: data, account: account, credentials: keys, language: nil)
    async let second = jobs.transcribe(audio: data, account: account, credentials: keys, language: nil)
    let (a, b) = try await (first, second)
    XCTAssertEqual(a.text, b.text)
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 1)
  }

  func testRepeatedConnectionTestsExerciseFreshUploadSubmissionAndCleanup() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.success)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    let account = VolcengineCloudAccount(), keys = try credentials(), sample = Data("public-sample".utf8)
    try await VolcengineCloudVerification.verifyPreparedAudio(sample, account: account, credentials: keys, jobs: jobs)
    try await VolcengineCloudVerification.verifyPreparedAudio(sample, account: account, credentials: keys, jobs: jobs)
    let calls = await fixture.history()
    XCTAssertEqual(calls.filter { $0.hasSuffix("/submit") }.count, 2)
    XCTAssertEqual(calls.filter { $0.hasPrefix("PUT ") }.count, 2)
    XCTAssertEqual(calls.filter { $0.hasPrefix("DELETE ") }.count, 2)
    let receipts = await jobs.jobs()
    XCTAssertEqual(Set(receipts.map(\.requestID)).count, 2)
    XCTAssertTrue(receipts.allSatisfy { $0.cleanup == .cleaned && $0.parentWorkID == nil })
  }

  func testConnectionTestDoesNotSucceedUntilItsCloudCopyIsDeleted() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.deleteFails)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    do {
      try await VolcengineCloudVerification.verifyPreparedAudio(Data("public-sample".utf8),
        account: .init(), credentials: credentials(), jobs: jobs)
      XCTFail("An undeleted sample does not verify the complete workflow")
    } catch { XCTAssertEqual(error as? RecordingTranscriptionError, .connectionFailed) }
    let receipts = await jobs.jobs()
    XCTAssertEqual(receipts.first?.cleanup, .pending)
    XCTAssertEqual(receipts.first?.transcript?.text, "fixture")
  }

  @MainActor
  func testConfirmedResubmissionCreatesNewRequestAndArchivesFailedReceipt() async throws {
    let root = root(); defer { try? FileManager.default.removeItem(at: root) }
    let fixture = CloudFixtureTransport(.forbiddenOnce)
    let jobs = VolcengineCloudJobs(root: root, http: fixture, wait: { _ in })
    let account = VolcengineCloudAccount(), keys = try credentials(), data = Data("audio".utf8)
    let key = VolcengineCloudAccounts.credentialsKeyPrefix + account.id.uuidString
    UserDefaults.standard.set(try JSONEncoder().encode(keys), forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }
    do {
      _ = try await jobs.transcribe(audio: data, account: account, credentials: keys, language: nil, parentWorkID: "parent")
      XCTFail("Expected first submission to fail")
    } catch {}
    let failedJobs = await jobs.jobs()
    let failed = try XCTUnwrap(failedJobs.first)
    do {
      _ = try await jobs.transcribe(audio: data, account: account, credentials: keys, language: nil)
      XCTFail("Ordinary resume must not submit again")
    } catch {}
    let before = await fixture.submittedIDs()
    XCTAssertEqual(before.count, 1)
    try await jobs.resubmit(failed.id)
    let requests = await fixture.submittedIDs()
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(Set(requests).count, 2)
    let current = await jobs.jobs()
    XCTAssertEqual(current.count, 1)
    XCTAssertEqual(current.first?.stage, .transcriptReady)
    XCTAssertEqual(current.first?.parentWorkID, "parent")
    let receipts = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(VolcengineCloudJob.self, from: Data(contentsOf: $0)) }
    XCTAssertEqual(receipts.first(where: { $0.archived == true })?.requestID, failed.requestID)
  }

}
