//
//  ScrollingCaptureFrameSource.swift
//  ShotPaste
//
//  Region-scoped ScreenCaptureKit stream used for low-latency scrolling preview.
//

import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScrollingCaptureFrameSource: NSObject {
  private let sampleQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.scrolling-capture.preview-stream",
    qos: .userInteractive
  )
  private let minimumPublishInterval: TimeInterval
  private let stationaryHeartbeatInterval: TimeInterval = 0.25
  private let ciContext: CIContext

  private var stream: SCStream?
  private nonisolated(unsafe) var lastPublishedAt: TimeInterval = 0
  private nonisolated(unsafe) var lastPublishedSignature: UInt64?
  private nonisolated(unsafe) var lastPublishedImage: CGImage?
  private nonisolated(unsafe) var lastStationaryHeartbeatAt: TimeInterval = 0
  private nonisolated(unsafe) var nextSequenceNumber = 0
  private var onFrame: ((ScrollingCaptureFrame) -> Void)?
  private var onFailure: ((String) -> Void)?

  init(previewFPS: Int = 30) {
    minimumPublishInterval = 1.0 / Double(max(1, previewFPS))
    ciContext = CIContext(options: [.cacheIntermediates: false])
  }

  @MainActor
  func start(
    with context: ScreenCaptureManager.PreparedAreaCaptureContext,
    frameHandler: @escaping (ScrollingCaptureFrame) -> Void,
    failureHandler: @escaping (String) -> Void
  ) async throws {
    stop()

    onFrame = frameHandler
    onFailure = failureHandler
    lastPublishedAt = 0
    lastPublishedSignature = nil
    lastPublishedImage = nil
    lastStationaryHeartbeatAt = 0
    nextSequenceNumber = 0

    let configuration = ScreenCaptureManager.shared.makeAreaStreamConfiguration(
      from: context,
      maximumFrameRate: 30,
      showsCursor: false
    )
    let stream = SCStream(filter: context.contentFilter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
    self.stream = stream
    try await stream.startCapture()
  }

  @MainActor
  func stop() {
    let activeStream = stream
    stream = nil
    onFrame = nil
    onFailure = nil

    guard let activeStream else { return }

    do {
      try activeStream.removeStreamOutput(self, type: .screen)
    } catch {
      // Best-effort teardown: stream may already be winding down.
    }

    Task.detached(priority: .userInitiated) {
      do {
        try await activeStream.stopCapture()
      } catch {
        // Best-effort teardown: stream may already be stopped.
      }
    }
  }
}

extension ScrollingCaptureFrameSource: SCStreamOutput {
  nonisolated func stream(
    _: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    autoreleasepool {
      guard type == .screen, sampleBuffer.isValid else { return }
      guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

      if
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
          sampleBuffer,
          createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusRaw = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: statusRaw),
        status != .complete {
        return
      }

      let now = ProcessInfo.processInfo.systemUptime
      guard now - lastPublishedAt >= minimumPublishInterval else { return }
      let signature = Self.sampledSignature(of: pixelBuffer)
      if let signature, signature == lastPublishedSignature {
        guard
          now - lastStationaryHeartbeatAt >= stationaryHeartbeatInterval,
          let lastPublishedImage
        else { return }
        lastStationaryHeartbeatAt = now
        nextSequenceNumber += 1
        let heartbeat = ScrollingCaptureFrame(
          sequenceNumber: nextSequenceNumber,
          image: lastPublishedImage,
          capturedAt: now,
          motionScore: 0
        )
        DispatchQueue.main.async { [weak self] in
          self?.onFrame?(heartbeat)
        }
        return
      }

      let imageRect = CGRect(
        x: 0,
        y: 0,
        width: CVPixelBufferGetWidth(pixelBuffer),
        height: CVPixelBufferGetHeight(pixelBuffer)
      )
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      guard let cgImage = ciContext.createCGImage(ciImage, from: imageRect) else {
        return
      }

      lastPublishedAt = now
      lastPublishedSignature = signature
      lastPublishedImage = cgImage
      lastStationaryHeartbeatAt = now
      nextSequenceNumber += 1
      let frame = ScrollingCaptureFrame(
        sequenceNumber: nextSequenceNumber,
        image: cgImage,
        capturedAt: now,
        motionScore: nil
      )
      DispatchQueue.main.async { [weak self] in
        self?.onFrame?(frame)
      }
    }
  }

  /// Hashes a small grid directly from the IOSurface-backed BGRA buffer before
  /// creating a CGImage. Static frames avoid image conversion; only a sparse
  /// heartbeat reuses the last image so boundary detection can still converge.
  nonisolated static func sampledSignature(of pixelBuffer: CVPixelBuffer) -> UInt64? {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
      return nil
    }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let rawBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }

    let base = rawBase.assumingMemoryBound(to: UInt8.self)
    let rowSampleCount = min(24, height)
    let columnSampleCount = min(32, width)
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    hash = (hash ^ UInt64(width)) &* 0x0000_0100_0000_01b3
    hash = (hash ^ UInt64(height)) &* 0x0000_0100_0000_01b3

    for rowSample in 0 ..< rowSampleCount {
      let y = rowSampleCount == 1 ? 0 : rowSample * (height - 1) / (rowSampleCount - 1)
      let row = base + y * bytesPerRow
      for columnSample in 0 ..< columnSampleCount {
        let x = columnSampleCount == 1 ? 0 : columnSample * (width - 1) / (columnSampleCount - 1)
        let pixel = row + x * 4
        // Alpha is always opaque for ScreenCaptureKit and adds no signal.
        hash = (hash ^ UInt64(pixel[0])) &* 0x0000_0100_0000_01b3
        hash = (hash ^ UInt64(pixel[1])) &* 0x0000_0100_0000_01b3
        hash = (hash ^ UInt64(pixel[2])) &* 0x0000_0100_0000_01b3
      }
    }
    return hash
  }
}

extension ScrollingCaptureFrameSource: SCStreamDelegate {
  nonisolated func stream(_: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.onFailure?(error.localizedDescription)
    }
  }
}
