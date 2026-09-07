import Foundation
@testable import ShotPaste
import XCTest

@MainActor
final class VolcengineCloudAccountsTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "ShotPaste-cloud-credentials-test-\(UUID())"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil
    super.tearDown()
  }

  private func credentials(_ suffix: String = "one") throws -> VolcengineCloudCredentials {
    try .init(speechKey: "fixture-speech-\(suffix)", accessKey: "fixture-access-\(suffix)",
              secretKey: "fixture-secret-\(suffix)")
  }

  func testCredentialsReloadFromLocalPreferencesAndAreIsolatedBetweenDomains() throws {
    let keys = try credentials()
    let profile = try VolcengineCloudAccounts.save(keys, defaults: defaults)
    let reopened = UserDefaults(suiteName: suite)!
    XCTAssertEqual(try VolcengineCloudAccounts.credentials(for: profile.id, defaults: reopened), keys)
    XCTAssertEqual(VolcengineCloudAccounts.current(defaults: reopened), profile)
    let otherSuite = suite + ".release"
    let otherDefaults = UserDefaults(suiteName: otherSuite)!
    defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
    XCTAssertNil(VolcengineCloudAccounts.current(defaults: otherDefaults))
    XCTAssertThrowsError(try VolcengineCloudAccounts.credentials(for: profile.id, defaults: otherDefaults))
    let metadata = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
    for secret in [keys.speechKey, keys.accessKey, keys.secretKey] {
      XCTAssertFalse(metadata.contains(secret))
    }
  }

  func testRepeatedSaveKeepsVerificationAndOptInsButCannotReplaceInFlightCredentials() throws {
    let keys = try credentials()
    var profile = try VolcengineCloudAccounts.save(keys, defaults: defaults)
    profile.initialized = true; profile.verified = true
    try VolcengineCloudAccounts.update(profile, defaults: defaults)
    defaults.set(true, forKey: PreferencesKeys.recordingTranscriptionEnabled)
    defaults.set(true, forKey: PreferencesKeys.audioRecordingAutomaticTranscription)
    XCTAssertEqual(try VolcengineCloudAccounts.save(keys, account: profile, defaults: defaults), profile)
    XCTAssertTrue(defaults.bool(forKey: PreferencesKeys.recordingTranscriptionEnabled))
    XCTAssertTrue(defaults.bool(forKey: PreferencesKeys.audioRecordingAutomaticTranscription))
    XCTAssertThrowsError(try VolcengineCloudAccounts.save(credentials("two"), account: profile, defaults: defaults))
    XCTAssertEqual(try VolcengineCloudAccounts.credentials(for: profile.id, defaults: defaults), keys)
    XCTAssertEqual(VolcengineCloudAccounts.current(defaults: defaults), profile)
  }

  func testSwitchRetainsOriginalCredentialsUntilCleanupAndLeasesFinish() throws {
    let originalKeys = try credentials()
    let original = try VolcengineCloudAccounts.save(originalKeys, defaults: defaults)
    let current = try VolcengineCloudAccounts.save(credentials("two"), defaults: defaults)
    XCTAssertFalse(defaults.bool(forKey: PreferencesKeys.recordingTranscriptionEnabled))
    XCTAssertFalse(defaults.bool(forKey: PreferencesKeys.audioRecordingAutomaticTranscription))
    VolcengineCloudAccounts.pruneRetired(excluding: [original.id], defaults: defaults)
    XCTAssertEqual(try VolcengineCloudAccounts.acquire(original.id, defaults: defaults), originalKeys)
    VolcengineCloudAccounts.pruneRetired(excluding: [], defaults: defaults)
    XCTAssertEqual(try VolcengineCloudAccounts.credentials(for: original.id, defaults: defaults), originalKeys)
    VolcengineCloudAccounts.release(original.id)
    VolcengineCloudAccounts.pruneRetired(excluding: [], defaults: defaults)
    XCTAssertThrowsError(try VolcengineCloudAccounts.credentials(for: original.id, defaults: defaults))
    XCTAssertNoThrow(try VolcengineCloudAccounts.credentials(for: current.id, defaults: defaults))
    _ = try VolcengineCloudAccounts.acquire(current.id, defaults: defaults)
    XCTAssertThrowsError(try VolcengineCloudAccounts.removeCurrent(defaults: defaults))
    VolcengineCloudAccounts.release(current.id)
    try VolcengineCloudAccounts.removeCurrent(defaults: defaults)
    XCTAssertNil(VolcengineCloudAccounts.current(defaults: defaults))
    XCTAssertThrowsError(try VolcengineCloudAccounts.credentials(for: current.id, defaults: defaults))
  }

  func testMissingOrInvalidLocalCredentialsCannotEnableAnOldVerifiedProfile() throws {
    var profile = VolcengineCloudAccount()
    profile.initialized = true; profile.verified = true
    try VolcengineCloudAccounts.update(profile, defaults: defaults)
    XCTAssertNil(RecordingTranscriptionConfiguration.current(defaults: defaults))
    defaults.set(Data("invalid".utf8), forKey: VolcengineCloudAccounts.credentialsKeyPrefix + profile.id.uuidString)
    XCTAssertNil(RecordingTranscriptionConfiguration.current(defaults: defaults))
    defaults.set(Data(#"{"speechKey":"key","accessKey":"access","secretKey":"bad\nheader"}"#.utf8),
                 forKey: VolcengineCloudAccounts.credentialsKeyPrefix + profile.id.uuidString)
    XCTAssertThrowsError(try VolcengineCloudAccounts.credentials(for: profile.id, defaults: defaults))
    try VolcengineCloudAccounts.save(credentials(), account: profile, defaults: defaults)
    XCTAssertEqual(RecordingTranscriptionConfiguration.current(defaults: defaults)?.account.id, profile.id)
  }

  func testPartialCredentialEditsPreserveUntouchedKeysAndRejectInvalidDrafts() throws {
    let saved = try credentials()
    let updated = try VolcengineCloudCredentials.resolving(speechKey: " new-key ", accessKey: "", secretKey: "  ", saved: saved)
    XCTAssertEqual(updated.speechKey, "new-key")
    XCTAssertEqual(updated.accessKey, saved.accessKey)
    XCTAssertEqual(updated.secretKey, saved.secretKey)
    XCTAssertThrowsError(try VolcengineCloudCredentials.resolving(speechKey: "key", accessKey: "", secretKey: "", saved: nil))
    XCTAssertThrowsError(try VolcengineCloudCredentials.resolving(speechKey: "bad\nkey", accessKey: "", secretKey: "", saved: saved))
    XCTAssertEqual(try VolcengineCloudCredentials.resolving(speechKey: "", accessKey: "", secretKey: "", saved: saved), saved)
  }

  func testSpeechCredentialRotationReusesStorageButRequiresNewVerification() {
    var original = VolcengineCloudAccount()
    original.initialized = true; original.verified = true
    let replacement = VolcengineCloudAccount(replacingCredentialsFor: original)
    XCTAssertNotEqual(replacement.id, original.id)
    XCTAssertEqual(replacement.bucket, original.bucket)
    XCTAssertEqual(replacement.prefix, original.prefix)
    XCTAssertTrue(replacement.initialized)
    XCTAssertFalse(replacement.verified)
  }
}
