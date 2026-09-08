// Recording formats, media encoding and capture lifecycle contracts.

import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Video Format

enum VideoFormat: String, CaseIterable, Codable {
  case mov
  case mp4

  var fileType: AVFileType {
    switch self {
    case .mov: .mov
    case .mp4: .mp4
    }
  }

  var fileExtension: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .mov: "MOV"
    case .mp4: "MP4"
    }
  }
}

// MARK: - Video Quality

enum VideoQuality: String, CaseIterable, Codable {
  case high
  case medium
  case low

  /// Bits-per-pixel-per-frame target for screen content.
  /// Effective bitrate = width * height * fps * bitsPerPixelPerFrame, then clamped.
  var bitsPerPixelPerFrame: Double {
    switch self {
    case .high: 0.20
    case .medium: 0.13
    case .low: 0.08
    }
  }

  /// Floor bitrate (bps) to keep UI/text legible for each preset.
  var minBitrate: Int {
    switch self {
    case .high: 2_500_000
    case .medium: 1_600_000
    case .low: 1_000_000
    }
  }

  /// Cap bitrate (bps) to avoid encoder pressure and editor lag spikes.
  var maxBitrate: Int {
    switch self {
    case .high: 60_000_000
    case .medium: 35_000_000
    case .low: 20_000_000
    }
  }

  /// H.264 profile per preset.
  var h264ProfileLevel: String {
    switch self {
    case .high: AVVideoProfileLevelH264HighAutoLevel
    case .medium: AVVideoProfileLevelH264MainAutoLevel
    case .low: AVVideoProfileLevelH264BaselineAutoLevel
    }
  }

  var displayName: String {
    switch self {
    case .high: L10n.RecordingToolbar.qualityHigh
    case .medium: L10n.RecordingToolbar.qualityMedium
    case .low: L10n.RecordingToolbar.qualityLow
    }
  }
}

/// Identifies the owner of a recording session without changing the existing
/// screen-recording defaults. The audio adapter uses a deliberately tiny,
/// deterministic video stream as a clock/compatibility carrier for its audio
/// tracks; it is not a user-facing screen recording.
nonisolated enum RecordingPurpose: Equatable, Sendable {
  case screenVideo
  case audioAdapter
}

/// Metadata-only notification payload for an unexpected SCStream retirement.
/// Consumers should call `stopRecording()` to finish and preserve the writer
/// output; the capture core never discards the file as part of this signal.
nonisolated struct RecordingStreamFailureEvent: Sendable, Equatable {
  static let userInfoKey = "recordingStreamFailureEvent"

  let generation: UInt64
  let purpose: RecordingPurpose
  let wasFirstVideoFrameReady: Bool
  let wasCapturing: Bool
  let errorType: String
  /// True when the adapter had already atomically entered its active-start
  /// boundary.  Such a failure is recoverable by the coordinator through
  /// `stopRecording()` and must not be mistaken for a healthy capture.
  let wasAdapterStartClaimed: Bool

  init(
    generation: UInt64,
    purpose: RecordingPurpose,
    wasFirstVideoFrameReady: Bool,
    wasCapturing: Bool,
    errorType: String,
    wasAdapterStartClaimed: Bool = false
  ) {
    self.generation = generation
    self.purpose = purpose
    self.wasFirstVideoFrameReady = wasFirstVideoFrameReady
    self.wasCapturing = wasCapturing
    self.errorType = errorType
    self.wasAdapterStartClaimed = wasAdapterStartClaimed
  }
}

nonisolated struct RecordingStreamFailureGateObservation: Sendable, Equatable {
  let wasAdapterStartClaimed: Bool
}

extension Notification.Name {
  static let recordingStreamDidFail = Notification.Name("ShotPaste.recordingStreamDidFail")
}

/// Pure constants and settings for the tiny audio-adapter video track.
/// Keeping this separate from the user quality presets prevents a 32x32, 1 FPS
/// stream from inheriting the normal screen recorder's megabit floor.
nonisolated enum AudioAdapterCaptureCore {
  static let outputWidth = 32
  static let outputHeight = 32
  static let frameRate = 1
  static let minimumVideoBitrate = 32_000
  static let maximumVideoBitrate = 64_000
  static let videoBitrate = 48_000
  static let firstVideoFrameTimeout: TimeInterval = 2

  static func effectiveFormat(for requested: VideoFormat, purpose: RecordingPurpose) -> VideoFormat {
    purpose == .audioAdapter ? .mov : requested
  }

  static func acceptsVideoDimensions(width: Int, height: Int) -> Bool {
    width == outputWidth && height == outputHeight
  }

  /// The fixed mid-range bitrate is intentional: the adapter's video is a
  /// stable low-cost carrier, not content whose quality should track the
  /// selected screen-recording preset.
  static func videoBitrate(width _: Int, height _: Int, fps _: Int) -> Int {
    min(max(videoBitrate, minimumVideoBitrate), maximumVideoBitrate)
  }

  static func makeVideoSettings() -> [String: Any] {
    RecordingVideoEncodingSettings.makeVideoSettings(
      width: outputWidth,
      height: outputHeight,
      fps: frameRate,
      quality: .low,
      codec: .h264,
      bitrate: videoBitrate(width: outputWidth, height: outputHeight, fps: frameRate)
    )
  }
}

enum RecordingVideoEncodingSettings {
  static func calculatedBitrate(
    width: Int,
    height: Int,
    fps: Int,
    quality: VideoQuality,
    codec: AVVideoCodecType
  ) -> Int {
    let base = Double(width) * Double(height) * Double(fps) * quality.bitsPerPixelPerFrame
    let codecAdjusted = codec == .hevc ? base * 0.90 : base
    let clamped = min(max(codecAdjusted, Double(quality.minBitrate)), Double(quality.maxBitrate))
    return Int(clamped.rounded())
  }

  static func makeVideoSettings(
    width: Int,
    height: Int,
    fps: Int,
    quality: VideoQuality,
    codec: AVVideoCodecType,
    bitrate: Int
  ) -> [String: Any] {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: fps,
    ]

    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = quality.h264ProfileLevel
    }

    let colorProperties: [String: Any] = [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    return [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
      AVVideoColorPropertiesKey: colorProperties,
    ]
  }
}

nonisolated enum RecordingAudioEncodingSettings {
  static let sampleRate = 48_000
  static let channelCount = 2
  static let systemAudioBitrate = 128_000
  static let microphoneAudioBitrate = 128_000
  static let mixedAudioBitrate = 192_000

  static func makeSystemAudioSettings() -> [String: Any] {
    makeStereoAACSettings(bitrate: systemAudioBitrate)
  }

  static func makeMicrophoneAudioSettings() -> [String: Any] {
    makeStereoAACSettings(bitrate: microphoneAudioBitrate)
  }

  static func makeMixedAudioSettings() -> [String: Any] {
    makeStereoAACSettings(bitrate: mixedAudioBitrate)
  }

  /// LPCM settings for the microphone `AVCaptureAudioDataOutput`.
  ///
  /// Forces AVFoundation to resample the mic to `sampleRate` (48 kHz) at the capture
  /// source, mirroring system audio's `SCStreamConfiguration.sampleRate = 48000`. Without
  /// this, `AVCaptureAudioDataOutput` emits the device-native rate (Bluetooth/HFP mics
  /// negotiate ~16 kHz); appending those buffers unmodified to the 48 kHz AAC writer input
  /// produces spectral imaging above 8 kHz — the piercing artifact.
  ///
  /// `AVNumberOfChannelsKey` is intentionally omitted: the mic stays native mono and the
  /// writer's AAC encoder upmixes mono→stereo exactly as before, so output layout is unchanged.
  static func makeMicrophoneCaptureLPCMSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func makeStereoAACSettings(bitrate: Int) -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVEncoderBitRateKey: bitrate,
      AVChannelLayoutKey: stereoChannelLayoutData(),
    ]
  }

  private static func stereoChannelLayoutData() -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
  }
}

/// Track-level role metadata shared by the capture writer and the audio
/// adapter's AVAsset reader.  The role is carried by the track itself so
/// extraction never depends on AVFoundation's track enumeration order.
nonisolated enum RecordingAudioTrackRoleMetadata {
  static let key = AudioAdapterTrackRoleMetadataContract.key
  static let identifier = AudioAdapterTrackRoleMetadataContract.identifier
  static let dataType = kCMMetadataBaseDataType_UTF8 as String

  enum Error: Swift.Error, Equatable {
    case unsupportedRole(String)
    case invalidMetadata
  }

  /// Creates one QuickTime metadata item for a supported capture role.
  /// `.mixed` is intentionally rejected because it is an output of the
  /// adapter pipeline, not one of the independent capture tracks.
  static func items(for role: AudioAdapterTrackRole) throws -> [AVMetadataItem] {
    guard role == .system || role == .microphone else {
      throw Error.unsupportedRole(role.rawValue)
    }

    let item = AVMutableMetadataItem()
    // Set both the canonical identifier and its key-space/key representation.
    // AVAssetWriter uses the latter when serializing a custom mdta entry, while
    // AVAssetTrack.load(.metadata) exposes the former after MOV reload.
    item.identifier = AVMetadataIdentifier(identifier)
    item.keySpace = .quickTimeMetadata
    item.key = key as NSString
    item.value = role.rawValue as NSString
    item.dataType = dataType

    let result: [AVMetadataItem] = [item]
    try validate(result, expectedRole: role)
    return result
  }

  /// String overload used at boundaries where a role came from persisted or
  /// external data. Unknown values and `.mixed` are rejected before creating
  /// a metadata item.
  static func items(for roleValue: String) throws -> [AVMetadataItem] {
    let normalized = roleValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let role = AudioAdapterTrackRole(rawValue: normalized),
          role == .system || role == .microphone else {
      throw Error.unsupportedRole(roleValue)
    }
    return try items(for: role)
  }

  /// Validates the exact metadata shape accepted by the audio adapter. In
  /// addition to checking the identifier/value pair, this rejects duplicate
  /// identifiers or values so a malformed track cannot be interpreted as two
  /// competing roles.
  static func validate(
    _ items: [AVMetadataItem],
    expectedRole: AudioAdapterTrackRole? = nil
  ) throws {
    guard !items.isEmpty else {
      throw Error.invalidMetadata
    }

    let identifiers = items.compactMap { $0.identifier?.rawValue }
    let values = items.compactMap { stringValue($0.value) }
    guard identifiers.count == items.count,
          values.count == items.count,
          Set(identifiers).count == identifiers.count,
          Set(values).count == values.count,
          items.allSatisfy({ item in
            item.identifier == AVMetadataIdentifier(identifier)
              && item.keySpace == .quickTimeMetadata
              && (item.key as? String) == key
              && item.dataType == dataType
          }),
          let value = values.first,
          (value == AudioAdapterTrackRole.system.rawValue
            || value == AudioAdapterTrackRole.microphone.rawValue),
          expectedRole.map({ value == $0.rawValue }) ?? true else {
      throw Error.invalidMetadata
    }
  }

  static func isValid(
    _ items: [AVMetadataItem],
    expectedRole: AudioAdapterTrackRole? = nil
  ) -> Bool {
    (try? validate(items, expectedRole: expectedRole)) != nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    if let value = value as? String {
      return value
    }
    if let value = value as? NSString {
      return value as String
    }
    return nil
  }
}

enum RecordingAudioCompatibilityExporter {
  private final nonisolated class SamplePipe: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
      self.output = output
      self.input = input
    }
  }

  struct Result {
    let outputURL: URL
    let audioTrackCount: Int
    let didNormalize: Bool
    let audioSourceURL: URL?
  }

  enum ExportError: LocalizedError {
    case missingVideoTrack
    case cannotAddReaderOutput(String)
    case cannotAddWriterInput(String)
    case readerStartFailed(String)
    case writerStartFailed(String)
    case appendFailed(String)
    case readerFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
      switch self {
      case .missingVideoTrack:
        "Recording audio normalization requires a video track."
      case .cannotAddReaderOutput(let mediaType):
        "Cannot add \(mediaType) reader output."
      case .cannotAddWriterInput(let mediaType):
        "Cannot add \(mediaType) writer input."
      case .readerStartFailed(let message):
        "Audio normalization reader failed to start: \(message)"
      case .writerStartFailed(let message):
        "Audio normalization writer failed to start: \(message)"
      case .appendFailed(let mediaType):
        "Audio normalization failed while appending \(mediaType) samples."
      case .readerFailed(let message):
        "Audio normalization reader failed: \(message)"
      case .writerFailed(let message):
        "Audio normalization writer failed: \(message)"
      }
    }
  }

  static func requiresMixDown(audioTrackCount: Int) -> Bool {
    audioTrackCount > 1
  }

  static func mixdownInputVolume(audioTrackCount: Int) -> Float {
    guard audioTrackCount > 1 else { return 1.0 }
    return 1.0 / Float(audioTrackCount)
  }

  static func normalizeIfNeeded(
    at sourceURL: URL,
    fileType: AVFileType,
    preservesAudioSource: Bool = true,
    appliesMixdownHeadroom: Bool = false,
    audioTrackVolumes: [Float]? = nil
  ) async throws -> Result {
    let asset = AVURLAsset(url: sourceURL)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let requestedVolumes = normalizedVolumes(audioTrackVolumes, trackCount: audioTracks.count)
    let requiresVolumeAdjustment = audioTrackVolumes != nil && requestedVolumes.contains { abs($0 - 1.0) > 0.001 }
    guard requiresMixDown(audioTrackCount: audioTracks.count) || requiresVolumeAdjustment else {
      return Result(
        outputURL: sourceURL,
        audioTrackCount: audioTracks.count,
        didNormalize: false,
        audioSourceURL: nil
      )
    }

    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw ExportError.missingVideoTrack
    }

    let duration = try await asset.load(.duration)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let sourceFormatHint = try await videoTrack.load(.formatDescriptions).first
    let normalizedURL = normalizedTemporaryURL(for: sourceURL)
    let preservedSourceURL = preservesAudioSource ? preservedAudioSourceTemporaryURL(for: sourceURL) : nil
    let headroom = appliesMixdownHeadroom ? mixdownInputVolume(audioTrackCount: audioTracks.count) : 1.0
    let inputVolumes = requestedVolumes.map { min(max($0 * headroom, 0), 1) }

    do {
      try await writeNormalizedFile(
        asset: asset,
        videoTrack: videoTrack,
        audioTracks: audioTracks,
        duration: duration,
        preferredTransform: preferredTransform,
        sourceFormatHint: sourceFormatHint,
        outputURL: normalizedURL,
        fileType: fileType,
        audioInputVolumes: inputVolumes
      )
      if let preservedSourceURL {
        try? FileManager.default.removeItem(at: preservedSourceURL)
        try FileManager.default.copyItem(at: sourceURL, to: preservedSourceURL)
      }
      _ = try FileManager.default.replaceItemAt(
        sourceURL,
        withItemAt: normalizedURL,
        backupItemName: nil,
        options: []
      )
      return Result(
        outputURL: sourceURL,
        audioTrackCount: audioTracks.count,
        didNormalize: true,
        audioSourceURL: preservedSourceURL
      )
    } catch {
      try? FileManager.default.removeItem(at: normalizedURL)
      if let preservedSourceURL {
        try? FileManager.default.removeItem(at: preservedSourceURL)
      }
      throw error
    }
  }

  private static func normalizedVolumes(_ volumes: [Float]?, trackCount: Int) -> [Float] {
    guard trackCount > 0 else { return [] }
    guard let volumes else { return Array(repeating: 1.0, count: trackCount) }
    return (0 ..< trackCount).map { index in
      let value = index < volumes.count ? volumes[index] : 1.0
      return min(max(value, 0), 1)
    }
  }

  private static func normalizedTemporaryURL(for sourceURL: URL) -> URL {
    let directory = sourceURL.deletingLastPathComponent()
    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    let fileExtension = sourceURL.pathExtension
    return directory
      .appendingPathComponent(".\(baseName)-audio-compatible-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  private static func preservedAudioSourceTemporaryURL(for sourceURL: URL) -> URL {
    let directory = sourceURL.deletingLastPathComponent()
    let baseName = sourceURL.deletingPathExtension().lastPathComponent
    let fileExtension = sourceURL.pathExtension
    return directory
      .appendingPathComponent(".\(baseName)-audio-sources-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  private static func makeReaderAudioSettings() -> [String: Any] {
    [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: RecordingAudioEncodingSettings.sampleRate,
      AVNumberOfChannelsKey: RecordingAudioEncodingSettings.channelCount,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  private static func writeNormalizedFile(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    audioTracks: [AVAssetTrack],
    duration: CMTime,
    preferredTransform: CGAffineTransform,
    sourceFormatHint: CMFormatDescription?,
    outputURL: URL,
    fileType: AVFileType,
    audioInputVolumes: [Float]
  ) async throws {
    try? FileManager.default.removeItem(at: outputURL)

    try await withCheckedThrowingContinuation { continuation in
      let workerQueue = DispatchQueue(label: "com.ahtcfg24.shotpaste.recording.audio-compatibility", qos: .utility)
      workerQueue.async {
        do {
          try writeNormalizedFileSynchronously(
            asset: asset,
            videoTrack: videoTrack,
            audioTracks: audioTracks,
            duration: duration,
            preferredTransform: preferredTransform,
            sourceFormatHint: sourceFormatHint,
            outputURL: outputURL,
            fileType: fileType,
            audioInputVolumes: audioInputVolumes
          )
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func writeNormalizedFileSynchronously(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    audioTracks: [AVAssetTrack],
    duration: CMTime,
    preferredTransform: CGAffineTransform,
    sourceFormatHint: CMFormatDescription?,
    outputURL: URL,
    fileType: AVFileType,
    audioInputVolumes: [Float]
  ) throws {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: .zero, duration: duration)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
    writer.shouldOptimizeForNetworkUse = fileType == .mp4

    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else {
      throw ExportError.cannotAddReaderOutput("video")
    }
    reader.add(videoOutput)

    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: nil,
      sourceFormatHint: sourceFormatHint
    )
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = preferredTransform
    guard writer.canAdd(videoInput) else {
      throw ExportError.cannotAddWriterInput("video")
    }
    writer.add(videoInput)

    let audioOutput = AVAssetReaderAudioMixOutput(
      audioTracks: audioTracks,
      audioSettings: makeReaderAudioSettings()
    )
    audioOutput.audioMix = makeAudioMix(for: audioTracks, inputVolumes: audioInputVolumes)
    guard reader.canAdd(audioOutput) else {
      throw ExportError.cannotAddReaderOutput("audio")
    }
    reader.add(audioOutput)

    let audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: RecordingAudioEncodingSettings.makeMixedAudioSettings()
    )
    audioInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(audioInput) else {
      throw ExportError.cannotAddWriterInput("audio")
    }
    writer.add(audioInput)

    guard writer.startWriting() else {
      throw ExportError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
    }
    guard reader.startReading() else {
      writer.cancelWriting()
      throw ExportError.readerStartFailed(reader.error?.localizedDescription ?? "unknown")
    }

    writer.startSession(atSourceTime: .zero)
    try copySamples(
      reader: reader,
      writer: writer,
      outputsAndInputs: [
        ("video", videoOutput, videoInput),
        ("audio", audioOutput, audioInput),
      ]
    )

    if reader.status == .failed {
      throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown")
    }
    if reader.status == .cancelled {
      throw ExportError.readerFailed("cancelled")
    }

    let finishSemaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      finishSemaphore.signal()
    }
    finishSemaphore.wait()

    guard writer.status == .completed else {
      throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
    }
  }

  private static func makeAudioMix(for audioTracks: [AVAssetTrack], inputVolumes: [Float]) -> AVAudioMix {
    let mix = AVMutableAudioMix()
    mix.inputParameters = audioTracks.enumerated().map { index, track in
      let parameters = AVMutableAudioMixInputParameters(track: track)
      parameters.setVolume(index < inputVolumes.count ? inputVolumes[index] : 1.0, at: .zero)
      return parameters
    }
    return mix
  }

  private static func copySamples(
    reader: AVAssetReader,
    writer: AVAssetWriter,
    outputsAndInputs: [(String, AVAssetReaderOutput, AVAssetWriterInput)]
  ) throws {
    let group = DispatchGroup()
    let errorLock = NSLock()
    var firstError: Error?

    func recordError(_ error: Error) {
      errorLock.withLock {
        if firstError == nil {
          firstError = error
          reader.cancelReading()
          writer.cancelWriting()
        }
      }
    }

    for (label, output, input) in outputsAndInputs {
      group.enter()
      let queue = DispatchQueue(label: "com.ahtcfg24.shotpaste.recording.audio-compatibility.\(label)")
      let pipe = SamplePipe(output: output, input: input)
      var didFinish = false

      func finishInput() {
        if !didFinish {
          didFinish = true
          pipe.input.markAsFinished()
          group.leave()
        }
      }

      input.requestMediaDataWhenReady(on: queue) {
        while pipe.input.isReadyForMoreMediaData {
          if let sampleBuffer = pipe.output.copyNextSampleBuffer() {
            if !pipe.input.append(sampleBuffer) {
              recordError(ExportError.appendFailed(label))
              finishInput()
              return
            }
          } else {
            finishInput()
            return
          }
        }
      }
    }

    group.wait()

    if let firstError {
      throw firstError
    }
  }
}

// MARK: - Recording State

enum RecordingState: Equatable {
  case idle
  case preparing
  case recording
  case paused
  case stopping

  /// True when the recorder is mid-session and can be paused, resumed, or stopped.
  /// Used by the global pause/resume shortcut to decide whether to dispatch `togglePause()`.
  var isPauseResumeEligible: Bool {
    self == .recording || self == .paused
  }
}

/// The operation that owns asynchronous teardown for one capture generation.
/// Stop, cancel, and a failed start all use the same owner so no two paths can
/// remove a stream or touch the writer concurrently.
nonisolated enum RecordingTeardownOperation: Equatable, Sendable {
  case stop
  case cancel
  case startFailure
}

nonisolated struct RecordingTeardownOwner: Equatable, Sendable {
  let generation: UInt64
  let operation: RecordingTeardownOperation
}

/// Small lifecycle predicates shared by the manager's async paths and pure
/// tests.  Keeping the stale-task check as one policy prevents a failure path
/// from mutating the session before it discovers that its generation retired.
nonisolated enum RecordingCaptureLifecyclePolicy {
  static func canMutateCapturedGeneration(
    capturedGeneration: UInt64,
    currentGeneration: UInt64?,
    sessionGenerationIsCurrent: Bool
  ) -> Bool {
    currentGeneration == capturedGeneration && sessionGenerationIsCurrent
  }

  static func canEnterRecording(
    capturedGeneration: UInt64,
    currentGeneration: UInt64?,
    sessionGenerationIsCurrent: Bool,
    state: RecordingState,
    firstVideoFrameReady: Bool,
    streamFailed: Bool
  ) -> Bool {
    canMutateCapturedGeneration(
      capturedGeneration: capturedGeneration,
      currentGeneration: currentGeneration,
      sessionGenerationIsCurrent: sessionGenerationIsCurrent
    ) && state == .preparing && firstVideoFrameReady && !streamFailed
  }

  static func canClaimTeardown(
    capturedGeneration: UInt64,
    currentGeneration: UInt64?,
    state: RecordingState,
    owner: RecordingTeardownOwner?,
    operation: RecordingTeardownOperation
  ) -> Bool {
    guard currentGeneration == capturedGeneration, owner == nil else { return false }

    switch operation {
    case .stop:
      return state == .recording || state == .paused
    case .cancel:
      return state != .idle && state != .stopping
    case .startFailure:
      return state == .preparing
    }
  }

}

enum RecordingCancellationOutcome: Equatable {
  case disposed
  case noOutput
  case preserved(URL)

  var succeeded: Bool {
    switch self {
    case .disposed, .noOutput:
      true
    case .preserved:
      false
    }
  }
}

// MARK: - Recording Error

enum RecordingError: Error, LocalizedError {
  case permissionDenied
  case microphonePermissionDenied
  case noDisplayFound
  case setupFailed(String)
  case writeFailed(String)
  case cancelled
  case alreadyActive

  var errorDescription: String? {
    switch self {
    case .permissionDenied: L10n.Recording.screenPermissionDenied
    case .microphonePermissionDenied: L10n.Recording.microphonePermissionDenied
    case .noDisplayFound: L10n.Recording.noDisplayFound
    case .setupFailed(let msg): L10n.Recording.setupFailed(msg)
    case .writeFailed(let msg): L10n.Recording.writeFailed(msg)
    case .cancelled: L10n.Recording.cancelled
    case .alreadyActive: L10n.RecordingToolbar.recordingInProgress
    }
  }
}

/// Cross-queue identity gate for a recording capture.  The manager is
/// `@MainActor`, while SCStream and microphone callbacks arrive on dedicated
/// queues; keeping only opaque object identities here lets those callbacks
/// reject stale generations without touching main-actor state.
final nonisolated class RecordingCaptureGenerationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var nextGeneration: UInt64 = 0
  private var currentGeneration: UInt64?
  private var failedGenerations = Set<UInt64>()
  private var adapterStartClaimedGenerations = Set<UInt64>()
  private var streamGenerations: [ObjectIdentifier: UInt64] = [:]
  private var microphoneGenerations: [ObjectIdentifier: UInt64] = [:]

  func begin() -> UInt64 {
    lock.withLock {
      nextGeneration &+= 1
      currentGeneration = nextGeneration
      failedGenerations.removeAll()
      adapterStartClaimedGenerations.removeAll()
      streamGenerations.removeAll()
      microphoneGenerations.removeAll()
      return nextGeneration
    }
  }

  func current() -> UInt64? {
    lock.withLock { currentGeneration }
  }

  func isCurrent(_ generation: UInt64) -> Bool {
    lock.withLock { currentGeneration == generation }
  }

  func isHealthy(_ generation: UInt64) -> Bool {
    lock.withLock {
      currentGeneration == generation && !failedGenerations.contains(generation)
    }
  }

  /// Claim the adapter's final transition to user-visible recording.  The
  /// generation/health check and the one-shot claim are one locked operation:
  /// a didStop callback that wins first makes this return false, while a
  /// callback that arrives after a successful claim observes an active start.
  func claimAdapterRecordingStart(_ generation: UInt64) -> Bool {
    lock.withLock {
      guard currentGeneration == generation,
            !failedGenerations.contains(generation),
            !adapterStartClaimedGenerations.contains(generation)
      else {
        return false
      }
      adapterStartClaimedGenerations.insert(generation)
      return true
    }
  }

  func adapterRecordingStartWasClaimed(_ generation: UInt64) -> Bool {
    lock.withLock {
      currentGeneration == generation && adapterStartClaimedGenerations.contains(generation)
    }
  }

  /// A stream-stop callback reports whether the adapter start had already
  /// claimed the lifecycle transition.  The result is captured under the same
  /// lock as the failure mark so the event cannot misclassify the boundary.
  func markStreamFailed(_ generation: UInt64) -> RecordingStreamFailureGateObservation? {
    lock.withLock {
      guard currentGeneration == generation, !failedGenerations.contains(generation) else {
        return nil
      }
      failedGenerations.insert(generation)
      return RecordingStreamFailureGateObservation(
        wasAdapterStartClaimed: adapterStartClaimedGenerations.contains(generation)
      )
    }
  }

  func bind(stream: SCStream, generation: UInt64) {
    lock.withLock {
      guard currentGeneration == generation else { return }
      streamGenerations[ObjectIdentifier(stream)] = generation
    }
  }

  func bind(microphone: MicrophoneAudioCapturer, generation: UInt64) {
    lock.withLock {
      guard currentGeneration == generation else { return }
      microphoneGenerations[ObjectIdentifier(microphone)] = generation
    }
  }

  func generation(for stream: SCStream) -> UInt64? {
    lock.withLock {
      let generation = streamGenerations[ObjectIdentifier(stream)]
      return generation == currentGeneration ? generation : nil
    }
  }

  func generation(for microphone: MicrophoneAudioCapturer) -> UInt64? {
    lock.withLock {
      let generation = microphoneGenerations[ObjectIdentifier(microphone)]
      return generation == currentGeneration ? generation : nil
    }
  }

  func invalidate(_ generation: UInt64) {
    lock.withLock {
      guard currentGeneration == generation else { return }
      currentGeneration = nil
      failedGenerations.remove(generation)
      adapterStartClaimedGenerations.remove(generation)
      streamGenerations.removeAll()
      microphoneGenerations.removeAll()
    }
  }
}
