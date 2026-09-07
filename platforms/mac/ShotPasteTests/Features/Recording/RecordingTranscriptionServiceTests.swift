import Foundation
@testable import ShotPaste
import XCTest

final class RecordingTranscriptionServiceTests: XCTestCase {
  @MainActor
  func testConfigurationRequiresVerifiedCloudAccount() throws {
    let name = "ShotPaste-test-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("legacy-model", forKey: PreferencesKeys.recordingTranscriptionModelID)
    XCTAssertNil(RecordingTranscriptionConfiguration.current(defaults: defaults))
    try VolcengineCloudAccounts.update(VolcengineCloudAccount(), defaults: defaults)
    XCTAssertNil(RecordingTranscriptionConfiguration.current(defaults: defaults))
  }
  func testAutoLanguageIsDetectionAndAllExposedLanguagesAreSupported() {
    XCTAssertNil(AudioRecordingLanguage.auto.fileASRLanguage)
    for language in AudioRecordingLanguage.allCases where language != .auto {
      XCTAssertTrue(VolcengineFileASRProtocol.languages.contains(language.fileASRLanguage!))
    }
  }

  @MainActor
  func testCompletedRecordingUsesItsSelectedOptionsAfterNextRecordingChangesDefaults() throws {
    let suiteName = "ShotPaste-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keys = try VolcengineCloudCredentials(speechKey: "fixture-speech", accessKey: "fixture-access", secretKey: "fixture-secret")
    var account = try VolcengineCloudAccounts.save(keys, defaults: defaults)
    account.initialized = true; account.verified = true
    try VolcengineCloudAccounts.update(account, defaults: defaults)
    var first = OneShotRecordingOptions.current(defaults: defaults)
    first.automaticTranscription = true
    first.automaticAI = true
    first.transcriptionLanguage = .ja
    first.saveTranscriptionPreferences(defaults: defaults)
    var next = first
    next.automaticTranscription = false
    next.automaticAI = false
    next.transcriptionLanguage = .en
    next.saveTranscriptionPreferences(defaults: defaults)

    XCTAssertFalse(defaults.bool(forKey: PreferencesKeys.recordingTranscriptionEnabled))
    XCTAssertEqual(RecordingTranscriptionConfiguration.current(for: first, defaults: defaults)?.sourceLanguage, .ja)
    XCTAssertTrue(first.shouldProcessTranscriptWithAI)
    XCTAssertNil(RecordingTranscriptionConfiguration.current(for: next, defaults: defaults))
    first.outputMode = .gif
    XCTAssertNil(RecordingTranscriptionConfiguration.current(for: first, defaults: defaults))
    first.outputMode = .video; first.capturesSystemAudio = false; first.capturesMicrophone = false
    XCTAssertNil(RecordingTranscriptionConfiguration.current(for: first, defaults: defaults))
    first.capturesMicrophone = true
    account.verified = false
    try VolcengineCloudAccounts.update(account, defaults: defaults)
    XCTAssertNil(RecordingTranscriptionConfiguration.current(for: first, defaults: defaults))
  }
  func testTimestampExportPreservesAbsoluteTimes() {
    let transcript = RecordingTranscript(text: "sample", segments: [.init(text: "sample", startTime: 3601.25, duration: 1.5)])
    XCTAssertEqual(transcript.timedText, "[01:00:01.250 → 01:00:02.750] sample")
  }
  func testHTTPAndBusinessErrorsRemainRedacted() {
    XCTAssertFalse(VolcengineCloudFailure(http: 403, code: "secret/path?key=value").localizedDescription.contains("secret"))
    XCTAssertTrue(VolcengineCloudFailure(http: 429).retryable)
    XCTAssertFalse(VolcengineCloudFailure(http: 403).retryable)
  }
  func testRetryAfterSecondsAndDates() {
    let now = Date(timeIntervalSince1970: 0)
    let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429,
      httpVersion: nil, headerFields: ["Retry-After": "65"])!
    XCTAssertEqual(VolcengineCloudJobs.retryDate(response, now: now), now.addingTimeInterval(65))
  }
  func testImportedStorageRejectsBusinessBucketAndForeignPrefix() {
    XCTAssertThrowsError(try VolcengineCloudAccount(existingBucket: "business", prefix: "transcription/v1/123456789abc/"))
    XCTAssertThrowsError(try VolcengineCloudAccount(existingBucket: "shotpaste-tmp-test-debug", prefix: "private/business/"))
  }
}
