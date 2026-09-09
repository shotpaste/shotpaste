//
//  AudioAssetValidator.swift
//  ShotPaste
//
//  Shared asynchronous validation for audio files entering user-visible
//  surfaces or post-capture actions.
//

import AVFoundation
import Foundation

/// A rejection reason that is safe to expose to callers without including any
/// media contents or AVFoundation error text in diagnostics.
enum AudioAssetValidationRejection: String, Equatable, Sendable {
  case notFileURL
  case unsupportedFormat
  case fileMissing
  case notRegularFile
  case fileNotReadable
  case emptyFile
  case assetUnreadable
  case noAudioTrack
  case invalidDuration
  case containsVideoTrack
  case unsupportedContainer
}

/// The metadata needed by audio post-processing and Quick Access. Counts are
/// returned even for a rejected asset when AVFoundation was able to load them,
/// which lets callers and tests explain a rejection without inspecting media.
struct AudioAssetValidationResult: Equatable, Sendable {
  let duration: TimeInterval?
  let audioTrackCount: Int
  let videoTrackCount: Int
  let rejection: AudioAssetValidationRejection?

  var isValid: Bool {
    rejection == nil
  }
}

/// Performs the single acceptance check used by audio history, Quick Access,
/// clipboard routing, and transcription eligibility.
enum AudioAssetValidator {
  static func validate(url: URL) async -> AudioAssetValidationResult {
    guard url.isFileURL else {
      return rejected(.notFileURL)
    }

    // Keep the extension policy as a cheap early filter. Container and track
    // checks below remain authoritative, so a video renamed to .m4a cannot
    // pass this gate.
    guard CaptureHistoryAudioURLPolicy.accepts(url) else {
      return rejected(.unsupportedFormat)
    }

    // Security-scoped URLs must stay in scope while both file attributes and
    // AVFoundation metadata are read. Only the short scope acquisition hops to
    // the main actor; all media metadata work is asynchronous below it.
    let scopedAccess = await MainActor.run {
      SandboxFileAccessManager.shared.beginAccessingURL(url)
    }
    defer { scopedAccess.stop() }

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      return rejected(.fileMissing)
    }

    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      return rejected(.fileNotReadable)
    }

    guard let fileType = attributes[.type] as? FileAttributeType,
          fileType == .typeRegular
    else {
      return rejected(.notRegularFile)
    }

    guard fileManager.isReadableFile(atPath: url.path) else {
      return rejected(.fileNotReadable)
    }

    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 0 else {
      return rejected(.emptyFile)
    }

    let asset = AVURLAsset(url: url)
    do {
      // Loading the duration and both track lists is the AVAsset readability
      // check. AVFoundation performs the potentially expensive container
      // parsing asynchronously; no synchronous media read occurs on main.
      let loadedDuration = try await asset.load(.duration)
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      let duration = CMTimeGetSeconds(loadedDuration)

      if videoTracks.count > 0 {
        return rejected(
          .containsVideoTrack,
          duration: duration,
          audioTrackCount: audioTracks.count,
          videoTrackCount: videoTracks.count
        )
      }

      if audioTracks.isEmpty {
        return rejected(
          .noAudioTrack,
          duration: duration,
          audioTrackCount: 0,
          videoTrackCount: videoTracks.count
        )
      }

      guard loadedDuration.isValid,
            loadedDuration.isNumeric,
            duration.isFinite,
            duration > 0
      else {
        return rejected(
          .invalidDuration,
          duration: duration,
          audioTrackCount: audioTracks.count,
          videoTrackCount: videoTracks.count
        )
      }

      // AVFoundation's regular/readable, duration, audio-track and
      // video-track checks above are the acceptance gate. The file-type box
      // is only an additional guard for an explicitly QuickTime-branded
      // audio-only MOV that has been renamed to `.m4a`; generic ISO-BMFF
      // brands such as `mp42` and `isom` are valid audio-only containers.
      let fileTypeBox: ISOFileTypeBox?
      do {
        fileTypeBox = try readFileTypeBox(from: url, fileSize: byteCount)
      } catch {
        return rejected(
          .fileNotReadable,
          duration: duration,
          audioTrackCount: audioTracks.count,
          videoTrackCount: videoTracks.count
        )
      }

      if fileTypeBox?.containsQuickTimeBrand == true {
        return rejected(
          .unsupportedContainer,
          duration: duration,
          audioTrackCount: audioTracks.count,
          videoTrackCount: videoTracks.count
        )
      }

      return AudioAssetValidationResult(
        duration: duration,
        audioTrackCount: audioTracks.count,
        videoTrackCount: videoTracks.count,
        rejection: nil
      )
    } catch {
      return rejected(.assetUnreadable)
    }
  }

  private static func rejected(
    _ rejection: AudioAssetValidationRejection,
    duration: TimeInterval? = nil,
    audioTrackCount: Int = 0,
    videoTrackCount: Int = 0
  ) -> AudioAssetValidationResult {
    AudioAssetValidationResult(
      duration: duration,
      audioTrackCount: audioTrackCount,
      videoTrackCount: videoTrackCount,
      rejection: rejection
    )
  }

  private struct ISOFileTypeBox {
    let majorBrand: String
    let compatibleBrands: [String]

    var containsQuickTimeBrand: Bool {
      majorBrand == "qt  " || compatibleBrands.contains("qt  ")
    }
  }

  /// Reads one complete ISO-BMFF `ftyp` box without treating a short prefix
  /// as authoritative. A malformed/non-ISO header is represented by `nil`;
  /// AVFoundation remains the source of truth for supported audio formats.
  private static func readFileTypeBox(from url: URL, fileSize: Int64) throws -> ISOFileTypeBox? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let prefix = try handle.read(upToCount: 16) ?? Data()
    let prefixBytes = [UInt8](prefix)
    guard prefixBytes.count >= 8,
          String(decoding: prefixBytes[4 ..< 8], as: UTF8.self) == "ftyp"
    else {
      return nil
    }

    let size32 = UInt32(prefixBytes[0]) << 24
      | UInt32(prefixBytes[1]) << 16
      | UInt32(prefixBytes[2]) << 8
      | UInt32(prefixBytes[3])
    let headerLength: Int
    let boxSize: UInt64
    switch size32 {
    case 0:
      // A zero-sized ftyp extends to EOF and therefore has no independently
      // bounded compatible-brand list to inspect.
      return nil
    case 1:
      guard prefixBytes.count >= 16 else { return nil }
      boxSize = UInt64(prefixBytes[8]) << 56
        | UInt64(prefixBytes[9]) << 48
        | UInt64(prefixBytes[10]) << 40
        | UInt64(prefixBytes[11]) << 32
        | UInt64(prefixBytes[12]) << 24
        | UInt64(prefixBytes[13]) << 16
        | UInt64(prefixBytes[14]) << 8
        | UInt64(prefixBytes[15])
      headerLength = 16
    default:
      boxSize = UInt64(size32)
      headerLength = 8
    }

    let minimumBoxSize = UInt64(headerLength + 8) // major brand + minor version
    guard boxSize >= minimumBoxSize,
          boxSize <= UInt64(max(fileSize, 0)),
          boxSize <= UInt64(Int.max)
    else {
      return nil
    }

    try handle.seek(toOffset: 0)
    let box = try handle.read(upToCount: Int(boxSize)) ?? Data()
    guard box.count == Int(boxSize) else { return nil }
    let bytes = [UInt8](box)
    let compatibleStart = headerLength + 8
    guard bytes.count >= compatibleStart,
          (bytes.count - compatibleStart).isMultiple(of: 4)
    else {
      return nil
    }

    func brand(at offset: Int) -> String {
      String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
    }

    var compatibleBrands: [String] = []
    compatibleBrands.reserveCapacity((bytes.count - compatibleStart) / 4)
    for offset in stride(from: compatibleStart, to: bytes.count, by: 4) {
      compatibleBrands.append(brand(at: offset))
    }
    return ISOFileTypeBox(
      majorBrand: brand(at: headerLength),
      compatibleBrands: compatibleBrands
    )
  }
}
