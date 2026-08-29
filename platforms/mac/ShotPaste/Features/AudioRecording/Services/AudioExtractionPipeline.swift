//
//  AudioExtractionPipeline.swift
//  ShotPaste
//
//  Streaming MOV -> AAC extraction for audio-adapter sessions.
//

import AVFoundation
import CryptoKit
import Foundation

nonisolated struct AudioAdapterExtractionOutput: Equatable, Sendable {
  let role: AudioAdapterTrackRole
  let relativePath: String
  let url: URL
  let durationSeconds: Double
  let audioTrackCount: Int
  let checksum: String
}

nonisolated struct AudioAdapterExtractionResult: Equatable, Sendable {
  let mixed: AudioAdapterExtractionOutput
  let system: AudioAdapterExtractionOutput?
  let microphone: AudioAdapterExtractionOutput?
  let sourceDurationSeconds: Double
  let segmentCount: Int
  let manifestPersistenceSucceeded: Bool
  let canDeleteInternalVideo: Bool

  var outputs: [AudioAdapterExtractionOutput] {
    [mixed, system, microphone].compactMap { $0 }
  }
}

nonisolated enum AudioExtractionPipelineError: LocalizedError, Equatable {
  case noAudioSources
  case missingCaptureFile(String)
  case unsafeCapturePath(String)
  case unsafeOutputPath(String)
  case invalidTrackCount(expected: Int, actual: Int)
  case trackRoleMismatch
  case invalidDuration(String)
  case segmentOverlap(String)
  case duplicateSequence(Int)
  case cannotCreateCompositionTrack
  case cannotAddReaderOutput(String)
  case cannotAddWriterInput(String)
  case readerStartFailed(String)
  case writerStartFailed(String)
  case sampleAppendFailed(String)
  case readerFailed(String)
  case writerFailed(String)
  case extractionTimedOut(String)
  case extractionCancelled
  case outputValidationFailed(String)
  case finalDurationMismatch(path: String, expected: Double, actual: Double)
  case manifestPersistenceFailed

  var errorDescription: String? {
    switch self {
    case .noAudioSources:
      "The audio adapter session has no selected audio source."
    case .missingCaptureFile:
      "The audio adapter capture file is missing."
    case .unsafeCapturePath:
      "The audio adapter capture path is unsafe."
    case .unsafeOutputPath:
      "The audio adapter final output path is unsafe."
    case .invalidTrackCount:
      "The audio adapter capture has an unexpected number of audio tracks."
    case .trackRoleMismatch:
      "The audio adapter capture track roles do not match the manifest."
    case .invalidDuration:
      "The audio adapter capture duration is invalid."
    case .segmentOverlap:
      "The audio adapter segments overlap on the session timeline."
    case .duplicateSequence:
      "The audio adapter contains a duplicate segment sequence."
    case .cannotCreateCompositionTrack:
      "The audio adapter composition track could not be created."
    case .cannotAddReaderOutput:
      "The audio adapter reader output could not be added."
    case .cannotAddWriterInput:
      "The audio adapter writer input could not be added."
    case .readerStartFailed:
      "The audio adapter reader could not start."
    case .writerStartFailed:
      "The audio adapter writer could not start."
    case .sampleAppendFailed:
      "The audio adapter sample could not be appended."
    case .readerFailed:
      "The audio adapter reader failed."
    case .writerFailed:
      "The audio adapter writer failed."
    case .extractionTimedOut:
      "The audio adapter extraction timed out."
    case .extractionCancelled:
      "The audio adapter extraction was cancelled."
    case .outputValidationFailed:
      "The extracted audio output failed validation."
    case .finalDurationMismatch:
      "The extracted audio output duration is inconsistent with its source."
    case .manifestPersistenceFailed:
      "The extracted audio result could not be persisted."
    }
  }
}

private final class AudioExtractionCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

/// Shared state for reader, writer, timer, and cancellation callbacks.  AVF
/// callbacks run on different queues, so even an apparently harmless error
/// slot must be protected.  The completion signal is also owned here to make
/// exactly-once signalling explicit.
private final class AudioExtractionPumpState: @unchecked Sendable {
  private let lock = NSLock()
  private var firstError: Error?
  private var didSignal = false

  func record(error: Error) {
    lock.lock()
    if firstError == nil { firstError = error }
    lock.unlock()
  }

  func error() -> Error? {
    lock.lock()
    defer { lock.unlock() }
    return firstError
  }

  func signal(_ semaphore: DispatchSemaphore) {
    lock.lock()
    guard !didSignal else {
      lock.unlock()
      return
    }
    didSignal = true
    lock.unlock()
    semaphore.signal()
  }
}

/// Extracts each source through AVAssetReader/AVAssetWriter. Reader outputs
/// use bounded PCM buffers and writer inputs consume them incrementally; no
/// complete recording is loaded into memory.
nonisolated final class AudioExtractionPipeline: @unchecked Sendable {
  private let store: AudioAdapterSessionStore?
  private let fileManager: FileManager
  private let timeoutProvider: @Sendable (Double) -> TimeInterval
  private let cancellationCheck: @Sendable () -> Bool
  private let queue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.audio-adapter.extraction",
    qos: .utility
  )

  init(
    store: AudioAdapterSessionStore? = nil,
    fileManager: FileManager = .default,
    timeoutProvider: @escaping @Sendable (Double) -> TimeInterval = {
      let duration = max(0, $0)
      // Encoding time grows with the recording.  A fixed 180-second ceiling
      // incorrectly kills otherwise healthy long recordings.
      return max(5, duration * 4 + 10)
    },
    cancellationCheck: @escaping @Sendable () -> Bool = { false }
  ) {
    self.store = store
    self.fileManager = fileManager
    self.timeoutProvider = timeoutProvider
    self.cancellationCheck = cancellationCheck
  }

  /// Performs extraction for an already-loaded session. This overload does
  /// not change its manifest, allowing a coordinator to decide when the
  /// history/transcription task has been persisted.
  func extract(session: AudioAdapterSession) async throws -> AudioAdapterExtractionResult {
    let cancellationState = AudioExtractionCancellationState()
    let injectedCancellationCheck = cancellationCheck
    if Task.isCancelled || injectedCancellationCheck() {
      cancellationState.cancel()
      throw AudioExtractionPipelineError.extractionCancelled
    }
    let extracted = try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        let checkCancellation: @Sendable () -> Bool = {
          cancellationState.isCancelled || injectedCancellationCheck()
        }
        queue.async { [fileManager, timeoutProvider, checkCancellation] in
          do {
            let result = try Self.extractSynchronously(
              session: session,
              fileManager: fileManager,
              timeoutProvider: timeoutProvider,
              cancellationCheck: checkCancellation
            )
            continuation.resume(returning: result)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }, onCancel: {
      cancellationState.cancel()
    })
    do {
      for output in extracted.outputs {
        _ = try await Self.validateM4A(at: output.url)
      }
    } catch {
      for output in extracted.outputs {
        try? fileManager.removeItem(at: output.url)
      }
      throw error
    }
    return extracted
  }

  /// Durable convenience used by recovery. Successful output validation is
  /// persisted before the stage is advanced, but the deletion gate remains
  /// closed until history and transcription persistence are independently
  /// acknowledged.
  func extract(sessionID: UUID) async throws -> AudioAdapterExtractionResult {
    guard let store else { throw AudioExtractionPipelineError.manifestPersistenceFailed }
    let session = try store.load(sessionID: sessionID)

    if session.manifest.stage != .extracting {
      guard session.manifest.stage == .stopping || session.manifest.stage == .failed else {
        throw AudioExtractionPipelineError.manifestPersistenceFailed
      }
      _ = try store.transition(sessionID: sessionID, to: .extracting)
    }

    var extractedResult: AudioAdapterExtractionResult?
    do {
      let extracted = try await extract(session: try store.load(sessionID: sessionID))
      extractedResult = extracted
      _ = try store.update(sessionID: sessionID) { manifest in
        manifest.internalPaths.mixed = extracted.mixed.relativePath
        manifest.finalPaths.mixed = extracted.mixed.relativePath
        manifest.updateChecksum(extracted.mixed.checksum, for: extracted.mixed.relativePath)

        manifest.internalPaths.system = extracted.system?.relativePath
        manifest.finalPaths.system = extracted.system?.relativePath
        if let system = extracted.system {
          manifest.updateChecksum(system.checksum, for: system.relativePath)
        }
        manifest.internalPaths.microphone = extracted.microphone?.relativePath
        manifest.finalPaths.microphone = extracted.microphone?.relativePath
        if let microphone = extracted.microphone {
          manifest.updateChecksum(microphone.checksum, for: microphone.relativePath)
        }
        manifest.canDeleteInternalVideo = false
      }
      _ = try await store.markFinalAudioValidated(sessionID: sessionID)
      _ = try store.transition(sessionID: sessionID, to: .awaitingHistory)
      return AudioAdapterExtractionResult(
        mixed: extracted.mixed,
        system: extracted.system,
        microphone: extracted.microphone,
        sourceDurationSeconds: extracted.sourceDurationSeconds,
        segmentCount: extracted.segmentCount,
        manifestPersistenceSucceeded: true,
        canDeleteInternalVideo: false
      )
    } catch {
      // A successful encode followed by a manifest write failure must not
      // leave unregistered M4A files behind.  Source MOVs are intentionally
      // retained for retry/diagnosis.
      if let extractedResult {
        for output in extractedResult.outputs {
          try? fileManager.removeItem(at: output.url)
        }
      }
      if let current = try? store.load(sessionID: sessionID) {
        let isCancelled = (error as? AudioExtractionPipelineError) == .extractionCancelled
        _ = try? store.recordRecoveryError(
          sessionID: current.sessionID,
          code: Self.diagnosticCode(for: error),
          message: isCancelled
            ? "audio extraction was cancelled; source MOV retained"
            : "audio extraction failed",
          recoverable: !isCancelled,
          terminal: isCancelled
        )
      }
      throw error
    }
  }

  /// The authoritative final-output validator is asynchronous and shared with
  /// history/recovery/deletion.  The quick synchronous check below is only an
  /// early post-writer sanity check; it never opens a persistence gate.
  static func validateM4A(at url: URL) async throws -> (durationSeconds: Double, audioTrackCount: Int) {
    guard AudioAdapterSessionManifest.isFinalRelativePath(url.lastPathComponent),
          !AudioAdapterSessionStorePathChecks.isSymbolicLink(at: url, fileManager: .default) else {
      throw AudioExtractionPipelineError.outputValidationFailed("invalid m4a path")
    }
    let validation = await AudioAssetValidator.validate(url: url)
    guard validation.isValid,
          validation.videoTrackCount == 0,
          validation.audioTrackCount > 0,
          let duration = validation.duration,
          duration.isFinite,
          duration > 0 else {
      throw AudioExtractionPipelineError.outputValidationFailed("invalid m4a")
    }
    return (duration, validation.audioTrackCount)
  }

  private static func validateM4AQuick(
    at url: URL
  ) throws -> (durationSeconds: Double, audioTrackCount: Int) {
    guard AudioAdapterSessionManifest.isFinalRelativePath(url.lastPathComponent),
          AudioAdapterSessionStorePathChecks.isRegularFile(at: url, fileManager: .default) else {
      throw AudioExtractionPipelineError.outputValidationFailed("invalid m4a path")
    }
    let asset = AVURLAsset(url: url)
    let tracks = asset.tracks(withMediaType: .audio)
    let duration = asset.duration
    guard !tracks.isEmpty,
          duration.isNumeric,
          duration.seconds.isFinite,
          duration.seconds > 0 else {
      throw AudioExtractionPipelineError.outputValidationFailed("invalid m4a")
    }
    return (duration.seconds, tracks.count)
  }

  static func durationTolerance(for expectedDuration: Double) -> Double {
    AudioAdapterSessionDurationPolicy.tolerance(for: expectedDuration)
  }

  // MARK: - Streaming implementation

  private struct SegmentAsset {
    let segment: AudioAdapterCaptureSegment
    let asset: AVAsset
    let duration: CMTime
    let start: CMTime
    let tracksByRole: [AudioAdapterTrackRole: AVAssetTrack]
  }

  private struct OutputPlan {
    let role: AudioAdapterTrackRole
    let relativePath: String
    let track: AVAssetTrack?
  }

  private static func extractSynchronously(
    session: AudioAdapterSession,
    fileManager: FileManager,
    timeoutProvider: @Sendable (Double) -> TimeInterval,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) throws -> AudioAdapterExtractionResult {
    let requestedRoles = AudioAdapterTrackRole.roles(for: session.manifest.selectedAudioSources)
    let effectiveRoles = session.manifest.effectiveCapturedTrackRoles
    guard !requestedRoles.isEmpty, !effectiveRoles.isEmpty else {
      throw AudioExtractionPipelineError.noAudioSources
    }

    let segments = session.manifest.segments.sorted { $0.sequence < $1.sequence }
    guard !segments.isEmpty else {
      throw AudioExtractionPipelineError.missingCaptureFile("no segments")
    }
    let sequenceSet = Set(segments.map(\.sequence))
    guard sequenceSet.count == segments.count else {
      let duplicate = segments.map(\.sequence).first ?? -1
      throw AudioExtractionPipelineError.duplicateSequence(duplicate)
    }
    guard segments.allSatisfy({ $0.sequence >= 0 }) else {
      throw AudioExtractionPipelineError.duplicateSequence(-1)
    }

    let composition = AVMutableComposition()
    var compositionTracks: [AudioAdapterTrackRole: AVMutableCompositionTrack] = [:]
    var segmentAssets: [SegmentAsset] = []
    var previousEnd = CMTime.zero

    for segment in segments {
      guard AudioAdapterSessionManifest.isCaptureRelativePath(segment.capturePath) else {
        throw AudioExtractionPipelineError.unsafeCapturePath(segment.capturePath)
      }
      let captureURL = try session.url(for: segment.capturePath)
      guard AudioAdapterSessionStorePathChecks.isRegularFile(
        at: captureURL,
        fileManager: fileManager
      ) else {
        throw AudioExtractionPipelineError.missingCaptureFile(segment.capturePath)
      }

      let asset = AVURLAsset(url: captureURL)
      let tracks = asset.tracks(withMediaType: .audio)
      guard let durationSeconds = segment.durationSeconds,
            durationSeconds.isFinite,
            durationSeconds > 0 else {
        throw AudioExtractionPipelineError.invalidDuration(segment.capturePath)
      }
      let actualRoles = Set(segment.trackRoles)
      let mappedRoles = Set(segment.trackIDsByRole.keys)
      guard !actualRoles.isEmpty,
            actualRoles.isSubset(of: Set(requestedRoles)),
            mappedRoles == actualRoles,
            AudioAdapterSessionManifest.hasUniqueTrackIDs(segment.trackIDsByRole) else {
        throw AudioExtractionPipelineError.trackRoleMismatch
      }
      guard tracks.count == actualRoles.count else {
        throw AudioExtractionPipelineError.invalidTrackCount(
          expected: actualRoles.count,
          actual: tracks.count
        )
      }

      guard Set(tracks.map(\.trackID)).count == tracks.count else {
        throw AudioExtractionPipelineError.trackRoleMismatch
      }
      let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackID, $0) })
      let tracksByRole = try segment.trackRoles.reduce(into: [AudioAdapterTrackRole: AVAssetTrack]()) {
        result,
        role in
        guard let id = segment.trackIDsByRole[role],
              let sourceTrack = tracksByID[id] else {
          throw AudioExtractionPipelineError.trackRoleMismatch
        }
        result[role] = sourceTrack
      }

      let duration = asset.duration
      guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
        throw AudioExtractionPipelineError.invalidDuration(segment.capturePath)
      }
      if let expectedDuration = segment.durationSeconds,
         abs(expectedDuration - duration.seconds) > durationTolerance(for: expectedDuration) {
        throw AudioExtractionPipelineError.invalidDuration(segment.capturePath)
      }
      let start = CMTime(seconds: segment.timelineStartSeconds, preferredTimescale: 600)
      guard start.isNumeric, start >= .zero else {
        throw AudioExtractionPipelineError.invalidDuration(segment.capturePath)
      }
      let end = CMTimeAdd(start, duration)
      if !segmentAssets.isEmpty,
         start < previousEnd - CMTime(seconds: 0.001, preferredTimescale: 600) {
        throw AudioExtractionPipelineError.segmentOverlap(segment.capturePath)
      }
      previousEnd = max(previousEnd, end)

      for role in effectiveRoles {
        guard actualRoles.contains(role) else {
          // This role is absent from this segment. It is not part of the
          // effective intersection in a valid manifest; keep this guard
          // explicit so a malformed manifest cannot synthesize samples.
          throw AudioExtractionPipelineError.trackRoleMismatch
        }
        guard let sourceTrack = tracksByRole[role] else {
          throw AudioExtractionPipelineError.trackRoleMismatch
        }
        let sourceDuration = sourceTrack.timeRange.duration
        guard sourceDuration.isNumeric, sourceDuration.seconds > 0,
              abs(sourceDuration.seconds - duration.seconds)
                <= durationTolerance(for: duration.seconds) else {
          throw AudioExtractionPipelineError.invalidDuration(segment.capturePath)
        }
        let compositionTrack: AVMutableCompositionTrack
        if let existing = compositionTracks[role] {
          compositionTrack = existing
        } else {
          guard let newTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
          ) else {
            throw AudioExtractionPipelineError.cannotCreateCompositionTrack
          }
          compositionTracks[role] = newTrack
          compositionTrack = newTrack
        }
        try compositionTrack.insertTimeRange(
          sourceTrack.timeRange,
          of: sourceTrack,
          at: start
        )
      }
      segmentAssets.append(
        SegmentAsset(
          segment: segment,
          asset: asset,
          duration: duration,
          start: start,
          tracksByRole: tracksByRole
        )
      )
    }

    let totalDuration = previousEnd
    guard totalDuration.isNumeric, totalDuration.seconds > 0 else {
      throw AudioExtractionPipelineError.invalidDuration("composition")
    }
    let sourceDuration = segmentAssets.reduce(0.0) { $0 + $1.duration.seconds }

    // The product contract exposes only a mixed M4A for a single source. The
    // two role-specific files are produced only when both inputs are present.
    let outputSpecs: [OutputPlan] = [
      OutputPlan(
        role: .mixed,
        relativePath: session.manifest.finalPaths.mixed
          ?? session.manifest.internalPaths.mixed
          ?? "mixed.m4a",
        track: nil
      ),
    ] + (effectiveRoles.count == 2 ? effectiveRoles.map { role in
      OutputPlan(
        role: role,
        relativePath: finalPath(for: role, manifest: session.manifest),
        track: compositionTracks[role]
      )
    } : [])
    let captureURLs = try segmentAssets.map {
      try session.url(for: $0.segment.capturePath)
    }
    try validateOutputPlan(
      outputSpecs,
      session: session,
      captureURLs: captureURLs,
      fileManager: fileManager
    )

    var generatedURLs: [URL] = []
    var extracted: [AudioAdapterTrackRole: AudioAdapterExtractionOutput] = [:]
    do {
      for plan in outputSpecs {
        if cancellationCheck() {
          throw AudioExtractionPipelineError.extractionCancelled
        }
        let outputURL = try session.url(for: plan.relativePath)
        generatedURLs.append(outputURL)
        let outputDuration: Double
        if plan.role == .mixed {
          outputDuration = try writeMixed(
            composition: composition,
            tracks: effectiveRoles.compactMap { compositionTracks[$0] },
            duration: totalDuration,
            outputURL: outputURL,
            fileManager: fileManager,
            timeoutProvider: timeoutProvider,
            cancellationCheck: cancellationCheck
          )
        } else if let track = plan.track {
          outputDuration = try writeSingle(
            asset: composition,
            track: track,
            duration: totalDuration,
            outputURL: outputURL,
            fileManager: fileManager,
            timeoutProvider: timeoutProvider,
            cancellationCheck: cancellationCheck
          )
        } else {
          throw AudioExtractionPipelineError.trackRoleMismatch
        }

        let validation = try validateM4AQuick(at: outputURL)
        guard outputDuration > 0,
              abs(validation.durationSeconds - totalDuration.seconds)
                <= durationTolerance(for: totalDuration.seconds) else {
          throw AudioExtractionPipelineError.finalDurationMismatch(
            path: plan.relativePath,
            expected: totalDuration.seconds,
            actual: validation.durationSeconds
          )
        }
        let checksum = try checksum(of: outputURL)
        extracted[plan.role] = AudioAdapterExtractionOutput(
          role: plan.role,
          relativePath: plan.relativePath,
          url: outputURL,
          durationSeconds: validation.durationSeconds,
          audioTrackCount: validation.audioTrackCount,
          checksum: checksum
        )
      }
    } catch {
      // Only planned final outputs are removed. The source MOVs are never in
      // this list, even when a malformed manifest tried to alias one.
      for url in generatedURLs {
        try? fileManager.removeItem(at: url)
      }
      throw error
    }

    guard let mixed = extracted[.mixed] else {
      throw AudioExtractionPipelineError.outputValidationFailed("missing mixed output")
    }
    return AudioAdapterExtractionResult(
      mixed: mixed,
      system: extracted[.system],
      microphone: extracted[.microphone],
      sourceDurationSeconds: sourceDuration,
      segmentCount: segments.count,
      manifestPersistenceSucceeded: false,
      canDeleteInternalVideo: false
    )
  }

  private static func finalPath(
    for role: AudioAdapterTrackRole,
    manifest: AudioAdapterSessionManifest
  ) -> String {
    switch role {
    case .system:
      return manifest.finalPaths.system ?? manifest.internalPaths.system ?? "system.m4a"
    case .microphone:
      return manifest.finalPaths.microphone
        ?? manifest.internalPaths.microphone
        ?? "microphone.m4a"
    case .mixed:
      return manifest.finalPaths.mixed ?? manifest.internalPaths.mixed ?? "mixed.m4a"
    }
  }

  private static func validateOutputPlan(
    _ plans: [OutputPlan],
    session: AudioAdapterSession,
    captureURLs: [URL],
    fileManager: FileManager
  ) throws {
    var outputURLs: [URL] = []
    for plan in plans {
      guard AudioAdapterSessionManifest.isFinalRelativePath(plan.relativePath) else {
        throw AudioExtractionPipelineError.unsafeOutputPath(plan.relativePath)
      }
      let outputURL = try session.url(for: plan.relativePath)
      guard !AudioAdapterSessionStorePathChecks.hasSymlinkComponent(
        root: session.directoryURL.standardizedFileURL,
        relativePath: plan.relativePath,
        fileManager: fileManager
      ) else {
        throw AudioExtractionPipelineError.unsafeOutputPath(plan.relativePath)
      }
      if fileManager.fileExists(atPath: outputURL.path),
         !AudioAdapterSessionStorePathChecks.isRegularFile(at: outputURL, fileManager: fileManager) {
        throw AudioExtractionPipelineError.unsafeOutputPath(plan.relativePath)
      }
      outputURLs.append(outputURL)
    }
    guard Set(plans.map(\.relativePath)).count == plans.count else {
      throw AudioExtractionPipelineError.unsafeOutputPath("duplicate output")
    }
    let captureKeys = Set(captureURLs.map(fileIdentity))
    let outputKeys = Set(outputURLs.map(fileIdentity))
    guard captureKeys.isDisjoint(with: outputKeys) else {
      throw AudioExtractionPipelineError.unsafeOutputPath("capture/output overlap")
    }
  }

  private static func fileIdentity(_ url: URL) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return "missing:\(url.standardizedFileURL.path)"
    }
    let device = attributes[.systemNumber] as? NSNumber
    let inode = attributes[.systemFileNumber] as? NSNumber
    if let device, let inode { return "inode:\(device)-\(inode)" }
    return "path:\(url.standardizedFileURL.path)"
  }

  private static func readerAudioSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func writerAudioSettings(bitrate: Int) -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: bitrate,
      AVChannelLayoutKey: stereoChannelLayoutData(),
    ]
  }

  private static func stereoChannelLayoutData() -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
  }

  private static func writeMixed(
    composition: AVMutableComposition,
    tracks: [AVAssetTrack],
    duration: CMTime,
    outputURL: URL,
    fileManager: FileManager,
    timeoutProvider: @Sendable (Double) -> TimeInterval,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) throws -> Double {
    let mix = AVMutableAudioMix()
    let headroom: Float = tracks.count > 1 ? 0.5 : 1.0
    mix.inputParameters = tracks.map { track in
      let parameters = AVMutableAudioMixInputParameters(track: track)
      parameters.setVolume(headroom, at: .zero)
      return parameters
    }
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerAudioSettings())
    output.audioMix = mix
    return try write(
      asset: composition,
      output: output,
      duration: duration,
      outputURL: outputURL,
      bitrate: tracks.count > 1 ? 192_000 : 128_000,
      label: "mixed",
      fileManager: fileManager,
      timeoutProvider: timeoutProvider,
      cancellationCheck: cancellationCheck
    )
  }

  private static func writeSingle(
    asset: AVAsset,
    track: AVAssetTrack,
    duration: CMTime,
    outputURL: URL,
    fileManager: FileManager,
    timeoutProvider: @Sendable (Double) -> TimeInterval,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) throws -> Double {
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: readerAudioSettings())
    output.alwaysCopiesSampleData = false
    return try write(
      asset: asset,
      output: output,
      duration: duration,
      outputURL: outputURL,
      bitrate: 128_000,
      label: "source",
      fileManager: fileManager,
      timeoutProvider: timeoutProvider,
      cancellationCheck: cancellationCheck
    )
  }

  private static func write(
    asset: AVAsset,
    output: AVAssetReaderOutput,
    duration: CMTime,
    outputURL: URL,
    bitrate: Int,
    label: String,
    fileManager: FileManager,
    timeoutProvider: @Sendable (Double) -> TimeInterval,
    cancellationCheck: @escaping @Sendable () -> Bool
  ) throws -> Double {
    guard !AudioAdapterSessionStorePathChecks.isSymbolicLink(
      at: outputURL,
      fileManager: fileManager
    ) else {
      throw AudioExtractionPipelineError.unsafeOutputPath(outputURL.lastPathComponent)
    }
    try? fileManager.removeItem(at: outputURL)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: .zero, duration: duration)
    guard reader.canAdd(output) else {
      throw AudioExtractionPipelineError.cannotAddReaderOutput(label)
    }
    reader.add(output)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerAudioSettings(bitrate: bitrate))
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw AudioExtractionPipelineError.cannotAddWriterInput(label)
    }
    writer.add(input)

    guard writer.startWriting() else {
      throw AudioExtractionPipelineError.writerStartFailed("\(label): start")
    }
    let completion = DispatchSemaphore(value: 0)
    let state = AudioExtractionPumpState()
    let timeout = max(1, timeoutProvider(max(0, duration.seconds)))
    let teardownTimeout = min(max(timeout, 1), 10)

    func signalCompletion() {
      state.signal(completion)
    }

    func finishWriter(cancel: Bool) -> Bool {
      input.markAsFinished()
      if cancel {
        reader.cancelReading()
        writer.cancelWriting()
      }
      let finish = DispatchSemaphore(value: 0)
      writer.finishWriting { finish.signal() }
      return finish.wait(timeout: .now() + teardownTimeout) == .success
    }

    func fail(_ error: Error, cancelWriter: Bool = true) {
      state.record(error: error)
      reader.cancelReading()
      input.markAsFinished()
      if cancelWriter { writer.cancelWriting() }
      signalCompletion()
    }

    guard reader.startReading() else {
      fail(AudioExtractionPipelineError.readerStartFailed("\(label): start"))
      _ = finishWriter(cancel: true)
      throw AudioExtractionPipelineError.readerStartFailed("\(label): start")
    }
    writer.startSession(atSourceTime: .zero)

    let sampleQueue = DispatchQueue(
      label: "com.ahtcfg24.shotpaste.audio-adapter.samples.\(label)",
      qos: .utility
    )
    let monitor = DispatchSource.makeTimerSource(queue: sampleQueue)
    monitor.schedule(deadline: .now() + 0.05, repeating: 0.05)
    monitor.setEventHandler {
      if cancellationCheck() {
        fail(AudioExtractionPipelineError.extractionCancelled)
      } else if reader.status == .failed {
        fail(AudioExtractionPipelineError.readerFailed(
          "\(label): \(reader.error?.localizedDescription ?? "failed")"
        ))
      } else if writer.status == .failed {
        fail(AudioExtractionPipelineError.writerFailed(
          "\(label): \(writer.error?.localizedDescription ?? "failed")"
        ))
      }
    }
    monitor.resume()
    defer { monitor.cancel() }
    input.requestMediaDataWhenReady(on: sampleQueue) {
      while input.isReadyForMoreMediaData {
        if cancellationCheck() {
          fail(AudioExtractionPipelineError.extractionCancelled)
          return
        }
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
          if reader.status == .failed {
            fail(AudioExtractionPipelineError.readerFailed(
              "\(label): \(reader.error?.localizedDescription ?? "failed")"
            ))
          } else {
            input.markAsFinished()
            signalCompletion()
          }
          return
        }
        guard input.append(sampleBuffer) else {
          fail(AudioExtractionPipelineError.sampleAppendFailed(label))
          return
        }
      }
      if writer.status == .failed || reader.status == .failed {
        if reader.status == .failed {
          fail(AudioExtractionPipelineError.readerFailed(
            "\(label): \(reader.error?.localizedDescription ?? "failed")"
          ))
        } else {
          fail(AudioExtractionPipelineError.writerFailed(
            "\(label): \(writer.error?.localizedDescription ?? "failed")"
          ))
        }
      }
    }

    guard completion.wait(timeout: .now() + timeout) == .success else {
      fail(AudioExtractionPipelineError.extractionTimedOut(label))
      _ = finishWriter(cancel: true)
      throw AudioExtractionPipelineError.extractionTimedOut(label)
    }

    if let capturedError = state.error() {
      _ = finishWriter(cancel: true)
      throw capturedError
    }
    if cancellationCheck() {
      let error = AudioExtractionPipelineError.extractionCancelled
      state.record(error: error)
      _ = finishWriter(cancel: true)
      throw error
    }
    if reader.status == .failed {
      let error = AudioExtractionPipelineError.readerFailed(
        "\(label): \(reader.error?.localizedDescription ?? "failed")"
      )
      state.record(error: error)
      _ = finishWriter(cancel: true)
      throw error
    }
    if reader.status == .cancelled {
      let error = AudioExtractionPipelineError.readerFailed("\(label): cancelled")
      state.record(error: error)
      _ = finishWriter(cancel: true)
      throw error
    }

    guard finishWriter(cancel: false) else {
      writer.cancelWriting()
      _ = finishWriter(cancel: true)
      throw AudioExtractionPipelineError.extractionTimedOut("\(label): finish")
    }
    guard writer.status == .completed else {
      throw AudioExtractionPipelineError.writerFailed(
        "\(label): \(writer.error?.localizedDescription ?? "failed")"
      )
    }
    return duration.seconds
  }

  private static func checksum(of url: URL) throws -> String {
    guard let input = InputStream(url: url) else {
      throw AudioExtractionPipelineError.outputValidationFailed("checksum")
    }
    input.open()
    defer { input.close() }

    var hasher = SHA256()
    let bufferSize = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while input.hasBytesAvailable {
      let count = input.read(&buffer, maxLength: buffer.count)
      if count < 0 {
        throw AudioExtractionPipelineError.outputValidationFailed(
          "checksum: \(input.streamError?.localizedDescription ?? "read failed")"
        )
      }
      if count == 0 {
        if let error = input.streamError {
          throw AudioExtractionPipelineError.outputValidationFailed(
            "checksum: \(error.localizedDescription)"
          )
        }
        break
      }
      hasher.update(data: Data(buffer[0 ..< count]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func diagnosticCode(for error: Error) -> String {
    guard let error = error as? AudioExtractionPipelineError else {
      return "extraction_failed"
    }
    switch error {
    case .missingCaptureFile:
      return "missing_capture"
    case .invalidTrackCount:
      return "invalid_track_count"
    case .trackRoleMismatch:
      return "track_role_mismatch"
    case .invalidDuration, .finalDurationMismatch:
      return "invalid_duration"
    case .segmentOverlap:
      return "segment_overlap"
    case .duplicateSequence:
      return "duplicate_sequence"
    case .unsafeCapturePath, .unsafeOutputPath:
      return "path_invariant"
    case .extractionTimedOut:
      return "extraction_timeout"
    case .extractionCancelled:
      return "extraction_cancelled"
    case .outputValidationFailed:
      return "output_validation"
    default:
      return "extraction_failed"
    }
  }
}
