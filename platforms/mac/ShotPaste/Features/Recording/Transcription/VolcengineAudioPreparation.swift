import AVFoundation
import CryptoKit
import Foundation

nonisolated enum VolcengineAudioPreparation {
  static let maximumBytes = 256 * 1_024 * 1_024
  static let maximumDuration = 4.0 * 3600
  struct Part: Sendable { let url: URL; let duration: Double; let temporary: Bool }

  static func checksum(_ url: URL) throws -> String {
    let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard url.isFileURL, attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
      throw RecordingTranscriptionError.invalidRecording
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty {
      try Task.checkCancellation()
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func duration(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
      throw RecordingTranscriptionError.noAudioTrack
    }
    let seconds = try await asset.load(.duration).seconds
    guard seconds.isFinite, seconds > 0 else { throw RecordingTranscriptionError.invalidRecording }
    return seconds
  }

  static func prepare(_ url: URL, start: Double, totalDuration: Double,
                      maximumPartDuration: Double = maximumDuration) async throws -> Part {
    guard maximumPartDuration.isFinite, maximumPartDuration > 0, maximumPartDuration <= maximumDuration else {
      throw RecordingTranscriptionError.invalidRecording
    }
    let asset = AVURLAsset(url: url)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0 else { throw RecordingTranscriptionError.invalidRecording }
    if start == 0, totalDuration <= maximumPartDuration, size <= maximumBytes,
       url.pathExtension.lowercased() == "m4a",
       try await asset.loadTracks(withMediaType: .video).isEmpty {
      return Part(url: url, duration: totalDuration, temporary: false)
    }
    var length = min(maximumPartDuration, totalDuration - start)
    for _ in 0..<12 {
      try Task.checkCancellation()
      if start + length < totalDuration {
        length = try await quietBoundary(asset, start: start, length: length)
      }
      let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ShotPaste-ASR-\(UUID()).m4a")
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw RecordingTranscriptionError.audioDecodeFailed
      }
      exporter.outputURL = destination
      exporter.outputFileType = .m4a
      exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: length, preferredTimescale: 600))
      let box = ExportBox(exporter)
      await withTaskCancellationHandler { await box.exporter.export() }
        onCancel: { box.exporter.cancelExport() }
      if Task.isCancelled || exporter.status != .completed {
        try? FileManager.default.removeItem(at: destination)
        try Task.checkCancellation()
        throw RecordingTranscriptionError.audioDecodeFailed
      }
      let actual = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if actual > 0, actual <= maximumBytes {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return Part(url: destination, duration: length, temporary: true)
      }
      try? FileManager.default.removeItem(at: destination)
      length /= 2
    }
    throw RecordingTranscriptionError.audioTooLong
  }

  /// Prefer the quietest 100 ms in the final 30 seconds before the hard cap.
  /// No overlap, and offsets use this exact boundary for every source part.
  private static func quietBoundary(_ asset: AVAsset, start: Double, length: Double) async throws -> Double {
    let window = min(30, length / 4)
    let windowStart = start + length - window
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000,
      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
    reader.timeRange = CMTimeRange(start: CMTime(seconds: windowStart, preferredTimescale: 600),
                                   duration: CMTime(seconds: window, preferredTimescale: 600))
    guard reader.canAdd(output) else { throw RecordingTranscriptionError.audioDecodeFailed }
    reader.add(output)
    guard reader.startReading() else { throw RecordingTranscriptionError.audioDecodeFailed }
    defer { reader.cancelReading() }
    var count = 0, groupCount = 0
    var energy = 0.0, minimum = Double.infinity, boundary = length
    while let buffer = output.copyNextSampleBuffer() {
      try Task.checkCancellation()
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      var data = Data(count: CMBlockBufferGetDataLength(block))
      let status = data.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else { throw RecordingTranscriptionError.audioDecodeFailed }
      data.withUnsafeBytes { bytes in
        for offset in stride(from: 0, to: bytes.count - 3, by: 4) {
          let value = Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
          energy += value * value
          groupCount += 1; count += 1
          if groupCount == 800 {
            if energy < minimum { minimum = energy; boundary = length - window + Double(count - 400) / 8000 }
            groupCount = 0; energy = 0
          }
        }
      }
    }
    guard reader.status == .completed else { throw RecordingTranscriptionError.audioDecodeFailed }
    return boundary
  }
  private final class ExportBox: @unchecked Sendable {
    let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
  }
}
