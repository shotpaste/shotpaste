//
//  TinyRegionRecordingAdapter.swift
//  ShotPaste
//
//  Captures a 32x32 physical-pixel, bottom-left region while an audio adapter
//  session is active.  This deliberately has no One Shot or UI dependency.
//

import AVFoundation
import AppKit
import Foundation

/// Stable metadata contract written by the capture core to each audio track.
/// Track array order is deliberately not part of this contract: AVFoundation
/// is free to enumerate tracks in a different order after a stop/reload.
nonisolated struct AudioAdapterTrackMetadata: Equatable, Sendable {
  let identifier: String
  let value: String
}

nonisolated struct AudioAdapterTrackDescriptor: Equatable, Sendable {
  let trackID: Int32
  let metadata: [AudioAdapterTrackMetadata]
}

nonisolated enum AudioAdapterTrackRoleMetadataContract {
  static let key = "com.ahtcfg24.shotpaste.audio-role"
  static let identifier = "mdta/\(key)"

  static func role(
    from metadata: [AudioAdapterTrackMetadata]
  ) -> AudioAdapterTrackRole? {
    let values = metadata.compactMap { item -> String? in
      guard item.identifier == key
        || item.identifier == identifier
        || item.identifier.hasSuffix("/\(key)") else {
        return nil
      }
      return item.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard values.count == 1 else { return nil }
    switch values[0] {
    case AudioAdapterTrackRole.system.rawValue:
      return .system
    case AudioAdapterTrackRole.microphone.rawValue:
      return .microphone
    default:
      // `mixed` and arbitrary values are never valid capture-track roles.
      return nil
    }
  }

  static func mapping(
    for descriptors: [AudioAdapterTrackDescriptor],
    expectedRoles: [AudioAdapterTrackRole]
  ) -> [AudioAdapterTrackRole: Int32]? {
    guard !descriptors.isEmpty,
          !expectedRoles.isEmpty,
          descriptors.allSatisfy({ $0.trackID > 0 }) else { return nil }
    var result: [AudioAdapterTrackRole: Int32] = [:]
    for descriptor in descriptors {
      guard let role = role(from: descriptor.metadata),
            expectedRoles.contains(role),
            result[role] == nil else {
        return nil
      }
      result[role] = descriptor.trackID
    }
    guard !result.isEmpty,
          Set(result.keys).isSubset(of: Set(expectedRoles)),
          Set(result.values).count == result.count else {
      return nil
    }
    return result
  }
}

@MainActor
protocol AudioAdapterRecordingControlling: AnyObject {
  func prepare(
    purpose: RecordingPurpose,
    rect: CGRect,
    capturesSystemAudio: Bool,
    capturesMicrophone: Bool,
    microphoneDeviceID: String?,
    outputDirectory: URL
  ) async throws

  func start() async throws
  func pause()
  func resume()
  func stop() async -> URL?
  func cancel() async
}

/// The production bridge.  The capture Agent can replace the implementation
/// of this bridge with the manager's purpose-aware overload while preserving
/// the adapter and its tests.  Until then, the current manager API still keeps
/// the output and processing files inside the session directory.
@MainActor
final class ScreenRecordingManagerAudioAdapterController: AudioAdapterRecordingControlling {
  private let manager: ScreenRecordingManager

  init(manager: ScreenRecordingManager? = nil) {
    self.manager = manager ?? ScreenRecordingManager.shared
  }

  func prepare(
    purpose: RecordingPurpose,
    rect: CGRect,
    capturesSystemAudio: Bool,
    capturesMicrophone: Bool,
    microphoneDeviceID: String?,
    outputDirectory: URL
  ) async throws {
    try await manager.prepareRecording(
      rect: rect,
      format: .mov,
      quality: .low,
      fps: 1,
      captureSystemAudio: capturesSystemAudio,
      captureMicrophone: capturesMicrophone,
      microphoneDeviceID: microphoneDeviceID,
      showCursor: false,
      saveDirectory: outputDirectory,
      processingDirectory: outputDirectory,
      fileName: "capture",
      excludeDesktopIcons: false,
      excludeDesktopWidgets: false,
      excludeOwnApplication: true,
      excludedWindowIDs: [],
      context: .empty,
      purpose: purpose
    )
  }

  func start() async throws {
    try await manager.startRecording()
  }

  func pause() {
    manager.pauseRecording()
  }

  func resume() {
    manager.resumeRecording()
  }

  func stop() async -> URL? {
    await manager.stopRecording()
  }

  func cancel() async {
    _ = await manager.cancelRecording()
  }
}

nonisolated enum TinyRegionRecordingAdapterError: LocalizedError, Equatable {
  case noMainScreen
  case invalidScaleFactor
  case screenTooSmall
  case noActiveSession
  case invalidSessionStage(AudioAdapterSessionStage)
  case invalidCaptureOutput
  case audioTrackContractMismatch
  case segmentRecoveryCancelled

  var errorDescription: String? {
    switch self {
    case .noMainScreen:
      "No main screen is available for the audio adapter."
    case .invalidScaleFactor:
      "The screen backing scale factor is invalid."
    case .screenTooSmall:
      "The screen is too small for the audio adapter region."
    case .noActiveSession:
      "The audio adapter has no active session."
    case .invalidSessionStage:
      "The audio adapter session is not in a capture state."
    case .invalidCaptureOutput:
      "The audio adapter did not return a private MOV capture."
    case .audioTrackContractMismatch:
      "The audio adapter capture did not satisfy its audio-track contract."
    case .segmentRecoveryCancelled:
      "The audio adapter display recovery was cancelled."
    }
  }
}

@MainActor
final class TinyRegionRecordingAdapter {
  struct Configuration: Equatable, Sendable {
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var microphoneDeviceID: String?

    init(
      capturesSystemAudio: Bool,
      capturesMicrophone: Bool,
      microphoneDeviceID: String? = nil
    ) {
      self.capturesSystemAudio = capturesSystemAudio
      self.capturesMicrophone = capturesMicrophone
      self.microphoneDeviceID = microphoneDeviceID
    }

    var sourceSelection: AudioAdapterAudioSourceSelection {
      switch (capturesSystemAudio, capturesMicrophone) {
      case (true, true): .systemAndMicrophone
      case (true, false): .system
      case (false, true): .microphone
      case (false, false): .none
      }
    }
  }

  private let store: AudioAdapterSessionStore
  private let recordingController: AudioAdapterRecordingControlling
  private let screenProvider: () -> NSScreen?
  private(set) var session: AudioAdapterSession?
  private(set) var configuration: Configuration?
  private var segmentRecoveryGeneration: UInt64 = 0

  init(
    store: AudioAdapterSessionStore = AudioAdapterSessionStore(),
    recordingController: AudioAdapterRecordingControlling? = nil,
    screenProvider: @escaping () -> NSScreen? = { NSScreen.main ?? NSScreen.screens.first }
  ) {
    self.store = store
    self.recordingController = recordingController ?? ScreenRecordingManagerAudioAdapterController()
    self.screenProvider = screenProvider
  }

  /// The exact rectangle in points for an arbitrary screen frame.  The origin
  /// may be negative on a secondary display; no conversion through the main
  /// display's coordinate space is performed.
  static func recordingRect(
    in screenFrame: CGRect,
    backingScaleFactor: CGFloat
  ) throws -> CGRect {
    guard backingScaleFactor.isFinite, backingScaleFactor > 0 else {
      throw TinyRegionRecordingAdapterError.invalidScaleFactor
    }

    let physicalInset: CGFloat = 8
    let physicalSize: CGFloat = 32
    let inset = physicalInset / backingScaleFactor
    let size = physicalSize / backingScaleFactor
    guard screenFrame.width >= size + inset * 2,
          screenFrame.height >= size + inset * 2 else {
      throw TinyRegionRecordingAdapterError.screenTooSmall
    }

    // The screen frame is already in global AppKit points.  Adding the inset
    // to minX/minY therefore works for both positive and negative displays.
    return CGRect(
      x: screenFrame.minX + inset,
      y: screenFrame.minY + inset,
      width: size,
      height: size
    )
  }

  static func recordingRect(for screen: NSScreen) throws -> CGRect {
    try recordingRect(in: screen.frame, backingScaleFactor: screen.backingScaleFactor)
  }

  static func currentMainScreenRecordingRect() throws -> CGRect {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else {
      throw TinyRegionRecordingAdapterError.noMainScreen
    }
    return try recordingRect(for: screen)
  }

  func prepare(configuration: Configuration) async throws -> AudioAdapterSession {
    guard let screen = screenProvider() else {
      throw TinyRegionRecordingAdapterError.noMainScreen
    }
    let rect = try Self.recordingRect(for: screen)
    let selection = configuration.sourceSelection
    let created = try store.createSession(selectedAudioSources: selection)
    session = created
    self.configuration = configuration

    do {
      _ = try store.transition(sessionID: created.sessionID, to: .preparing)
      try await recordingController.prepare(
        purpose: .audioAdapter,
        rect: rect,
        capturesSystemAudio: configuration.capturesSystemAudio,
        capturesMicrophone: configuration.capturesMicrophone,
        microphoneDeviceID: configuration.microphoneDeviceID,
        outputDirectory: created.directoryURL
      )
      let prepared = try store.load(sessionID: created.sessionID)
      session = prepared
      return prepared
    } catch {
      let message = "capture preparation failed"
      if let failed = try? store.recordRecoveryError(
        sessionID: created.sessionID,
        code: "prepare_failed",
        message: message,
        recoverable: true,
        terminal: false
      ) {
        session = failed
      }
      throw error
    }
  }

  func start() async throws {
    let active = try requireSession()
    guard active.manifest.stage == .preparing else {
      throw TinyRegionRecordingAdapterError.invalidSessionStage(active.manifest.stage)
    }
    do {
      try await recordingController.start()
      session = try store.transition(sessionID: active.sessionID, to: .recording)
    } catch {
      // A provider may have allocated writer resources before reporting a
      // start error.  Cancellation is idempotent and keeps any partial MOV
      // available for diagnosis while making recovery's durable state clear.
      await recordingController.cancel()
      if let failed = try? store.recordRecoveryError(
        sessionID: active.sessionID,
        code: "capture_start_failed",
        message: "audio adapter start failed; provider was cancelled",
        recoverable: true,
        terminal: false
      ) {
        session = failed
      }
      throw error
    }
  }

  func pause() throws {
    let active = try requireSession()
    guard active.manifest.stage == .recording else {
      throw TinyRegionRecordingAdapterError.invalidSessionStage(active.manifest.stage)
    }
    recordingController.pause()
    session = try store.transition(sessionID: active.sessionID, to: .paused)
  }

  func resume() throws {
    let active = try requireSession()
    guard active.manifest.stage == .paused else {
      throw TinyRegionRecordingAdapterError.invalidSessionStage(active.manifest.stage)
    }
    recordingController.resume()
    session = try store.transition(sessionID: active.sessionID, to: .recording)
  }

  @discardableResult
  func stop() async throws -> URL? {
    let active = try requireSession()
    guard active.manifest.stage == .recording || active.manifest.stage == .paused else {
      throw TinyRegionRecordingAdapterError.invalidSessionStage(active.manifest.stage)
    }
    session = try store.transition(sessionID: active.sessionID, to: .stopping)
    let url = await recordingController.stop()
    guard let url else {
      try markStopFailure(sessionID: active.sessionID, code: "capture_stop_failed")
      return nil
    }

    do {
      let current = try store.load(sessionID: active.sessionID)
      let segmentID = current.manifest.segments.last(where: { $0.durationSeconds == nil })?.id
      guard let relativePath = relativePath(of: url, in: current.directoryURL),
            AudioAdapterSessionManifest.isCaptureRelativePath(relativePath),
            AudioAdapterSessionStorePathChecks.isRegularFile(
              at: url.standardizedFileURL,
              fileManager: .default
            ) else {
        throw TinyRegionRecordingAdapterError.invalidCaptureOutput
      }

      let asset = AVURLAsset(url: url.standardizedFileURL)
      let tracks = asset.tracks(withMediaType: .audio)
      let expectedRoles = AudioAdapterTrackRole.roles(
        for: current.manifest.selectedAudioSources
      )
      let descriptors = try await Self.trackDescriptors(for: tracks)
      guard let mapping = AudioAdapterTrackRoleMetadataContract.mapping(
        for: descriptors,
        expectedRoles: expectedRoles
      ) else {
        throw TinyRegionRecordingAdapterError.audioTrackContractMismatch
      }
      let duration = asset.duration.seconds
      guard duration.isFinite, duration > 0 else {
        throw TinyRegionRecordingAdapterError.invalidCaptureOutput
      }

      let updated = try store.recordCaptureOutput(
        sessionID: active.sessionID,
        relativePath: relativePath,
        durationSeconds: duration,
        trackIDsByRole: mapping,
        segmentID: segmentID
      )
      session = updated
      return url
    } catch {
      try markStopFailure(sessionID: active.sessionID, code: "capture_stop_failed")
      throw error
    }
  }

  /// Finish the current display segment and start one more segment under the
  /// same durable session. The adapter owns the segment boundary; the
  /// Coordinator remains responsible for the user-visible state and timeout.
  /// No UI/window manipulation is performed here.
  @discardableResult
  func beginNextSegment() async throws -> AudioAdapterSession {
    let active = try requireSession()
    guard active.manifest.stage == .recording || active.manifest.stage == .paused else {
      throw TinyRegionRecordingAdapterError.invalidSessionStage(active.manifest.stage)
    }

    let wasPaused = active.manifest.stage == .paused
    segmentRecoveryGeneration &+= 1
    let recoveryGeneration = segmentRecoveryGeneration
    session = try store.transition(sessionID: active.sessionID, to: .stopping)
    let completedURL = await recordingController.stop()
    try ensureCurrentRecoveryGeneration(recoveryGeneration)
    guard let completedURL else {
      try markStopFailure(sessionID: active.sessionID, code: "segment_stop_failed")
      throw TinyRegionRecordingAdapterError.invalidCaptureOutput
    }

    do {
      var current = try store.load(sessionID: active.sessionID)
      let completed = try await validatedCaptureOutput(
        completedURL,
        session: current
      )
      try ensureCurrentRecoveryGeneration(recoveryGeneration)
      let segmentID = current.manifest.segments.last(where: { $0.durationSeconds == nil })?.id
      current = try store.recordCaptureOutput(
        sessionID: active.sessionID,
        relativePath: completed.relativePath,
        durationSeconds: completed.duration,
        trackIDsByRole: completed.trackIDsByRole,
        segmentID: segmentID
      )

      let nextSequence = (current.manifest.segments.map(\.sequence).max() ?? -1) + 1
      let timelineStart = current.manifest.segments.map {
        $0.timelineStartSeconds + ($0.durationSeconds ?? 0)
      }.max() ?? 0
      // The manager's unique-file naming convention will resolve this to the
      // next available capture-N.mov. `stop()` rebases the placeholder to the
      // actual URL before recording the segment result.
      let placeholder = "capture-\(nextSequence).mov"
      current = try store.appendSegment(
        sessionID: active.sessionID,
        capturePath: placeholder,
        sequence: nextSequence,
        timelineStartSeconds: timelineStart,
        trackRoles: current.manifest.trackRoles
      )
      try ensureCurrentRecoveryGeneration(recoveryGeneration)
      _ = try store.update(sessionID: active.sessionID) { manifest in
        manifest.internalPaths.capture = placeholder
      }

      // The existing Store state machine has no public segment-cycle edge.
      // Traverse the checked recoverable edge rather than mutating stage in a
      // broad closure; no gate is opened and the MOVs remain recoverable.
      _ = try store.transition(sessionID: active.sessionID, to: .failed)
      _ = try store.transition(sessionID: active.sessionID, to: .preparing)

      guard let screen = screenProvider() else {
        throw TinyRegionRecordingAdapterError.noMainScreen
      }
      let rect = try Self.recordingRect(for: screen)
      let configuration = self.configuration ?? Configuration(
        capturesSystemAudio: current.manifest.selectedAudioSources.capturesSystemAudio,
        capturesMicrophone: current.manifest.selectedAudioSources.capturesMicrophone
      )
      try await recordingController.prepare(
        purpose: .audioAdapter,
        rect: rect,
        capturesSystemAudio: configuration.capturesSystemAudio,
        capturesMicrophone: configuration.capturesMicrophone,
        microphoneDeviceID: configuration.microphoneDeviceID,
        outputDirectory: current.directoryURL
      )
      try await recordingController.start()
      try ensureCurrentRecoveryGeneration(recoveryGeneration)
      session = try store.transition(sessionID: active.sessionID, to: .recording)
      if wasPaused {
        // Keep the media boundary paused if the display change happened while
        // the user had paused. The controller has already anchored its first
        // frame; pause now affects only subsequent input.
        recordingController.pause()
        session = try store.transition(sessionID: active.sessionID, to: .paused)
      }
      return session!
    } catch {
      _ = try? store.recordRecoveryError(
        sessionID: active.sessionID,
        code: "segment_recovery_failed",
        message: "audio adapter display segment recovery failed",
        recoverable: true,
        terminal: false
      )
      throw error
    }
  }

  /// Cancels an in-flight display recovery without discarding already-bound
  /// segments. The generation guard makes a late non-cooperative callback
  /// stale before it can mutate the manifest.
  func abortDisplayRecovery() async {
    segmentRecoveryGeneration &+= 1
    await recordingController.cancel()
    guard let active = session, !active.manifest.stage.isTerminal else { return }
    session = try? store.abortDisplayRecovery(sessionID: active.sessionID)
  }

  func cancel() async throws {
    let active = try requireSession()
    guard !active.manifest.stage.isTerminal else { return }
    await recordingController.cancel()
    session = try store.transition(sessionID: active.sessionID, to: .cancelled)
  }

  private func requireSession() throws -> AudioAdapterSession {
    guard let session else { throw TinyRegionRecordingAdapterError.noActiveSession }
    return session
  }

  private func ensureCurrentRecoveryGeneration(_ generation: UInt64) throws {
    guard generation == segmentRecoveryGeneration else {
      throw TinyRegionRecordingAdapterError.segmentRecoveryCancelled
    }
  }

  private func relativePath(of url: URL, in directory: URL) -> String? {
    let root = directory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return nil }
    let relativePath = String(path.dropFirst(root.count + 1))
    guard AudioAdapterSessionManifest.isCaptureRelativePath(relativePath),
          !AudioAdapterSessionStorePathChecks.hasSymlinkComponent(
            root: directory.standardizedFileURL,
            relativePath: relativePath,
            fileManager: .default
          ) else {
      return nil
    }
    return relativePath
  }

  private func markStopFailure(sessionID: UUID, code: String) throws {
    guard let failed = try? store.recordRecoveryError(
      sessionID: sessionID,
      code: code,
      message: "audio adapter stop did not produce a valid MOV",
      recoverable: true,
      terminal: false
    ) else { return }
    session = failed
  }

  private struct ValidatedCaptureOutput {
    let relativePath: String
    let duration: Double
    let trackIDsByRole: [AudioAdapterTrackRole: Int32]
  }

  private func validatedCaptureOutput(
    _ url: URL,
    session: AudioAdapterSession
  ) async throws -> ValidatedCaptureOutput {
    guard let relativePath = relativePath(of: url, in: session.directoryURL),
          AudioAdapterSessionManifest.isCaptureRelativePath(relativePath),
          AudioAdapterSessionStorePathChecks.isRegularFile(
            at: url.standardizedFileURL,
            fileManager: .default
          ) else {
      throw TinyRegionRecordingAdapterError.invalidCaptureOutput
    }

    let asset = AVURLAsset(url: url.standardizedFileURL)
    let tracks = asset.tracks(withMediaType: .audio)
    let expectedRoles = AudioAdapterTrackRole.roles(
      for: session.manifest.selectedAudioSources
    )
    let descriptors = try await Self.trackDescriptors(for: tracks)
    guard let mapping = AudioAdapterTrackRoleMetadataContract.mapping(
      for: descriptors,
      expectedRoles: expectedRoles
    ) else {
      throw TinyRegionRecordingAdapterError.audioTrackContractMismatch
    }
    let duration = asset.duration.seconds
    guard duration.isFinite, duration > 0 else {
      throw TinyRegionRecordingAdapterError.invalidCaptureOutput
    }
    return ValidatedCaptureOutput(
      relativePath: relativePath,
      duration: duration,
      trackIDsByRole: mapping
    )
  }

  private static func trackDescriptors(
    for tracks: [AVAssetTrack]
  ) async throws -> [AudioAdapterTrackDescriptor] {
    var descriptors: [AudioAdapterTrackDescriptor] = []
    descriptors.reserveCapacity(tracks.count)
    for track in tracks {
      let items = try await track.load(.metadata)
      var metadata: [AudioAdapterTrackMetadata] = []
      metadata.reserveCapacity(items.count)
      for item in items {
        guard let identifier = item.identifier?.rawValue,
              let value = try? await item.load(.stringValue) else {
          continue
        }
        metadata.append(AudioAdapterTrackMetadata(identifier: identifier, value: value))
      }
      descriptors.append(
        AudioAdapterTrackDescriptor(trackID: track.trackID, metadata: metadata)
      )
    }
    return descriptors
  }
}
