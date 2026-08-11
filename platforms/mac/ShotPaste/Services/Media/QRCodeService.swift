//
//  QRCodeService.swift
//  ShotPaste
//
//  Provides local QR payload extraction using Vision barcode detection.
//

import CoreGraphics
import Foundation
import Vision

final nonisolated class QRCodeService: Sendable {
  static let shared = QRCodeService()

  private init() {}

  func detect(in image: CGImage) async throws -> QRCodeDetectionResult {
    try await withCheckedThrowingContinuation { continuation in
      var hasResumed = false

      func resumeOnce(with result: Result<QRCodeDetectionResult, Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(with: result)
      }

      let request = VNDetectBarcodesRequest { request, error in
        if let error {
          resumeOnce(with: .failure(error))
          return
        }

        guard let observations = request.results as? [VNBarcodeObservation] else {
          resumeOnce(with: .success(.empty))
          return
        }

        var unsupportedPayloadCount = 0
        let detections = observations.compactMap { observation -> QRCodeDetection? in
          guard observation.symbology == .qr else { return nil }
          guard let payload = observation.payloadStringValue else {
            unsupportedPayloadCount += 1
            return nil
          }

          let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmedPayload.isEmpty else { return nil }

          return QRCodeDetection(
            payload: payload,
            boundingBox: observation.boundingBox,
            classification: QRPayloadClassifier.classify(payload)
          )
        }

        let orderedDetections = Self.sortInReadingOrder(Self.deduplicate(detections))
        let result = QRCodeDetectionResult(
          detections: orderedDetections,
          unsupportedPayloadCount: unsupportedPayloadCount
        )

        resumeOnce(with: .success(result))
      }

      request.symbologies = [.qr]

      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      do {
        try handler.perform([request])
      } catch {
        resumeOnce(with: .failure(error))
      }
    }
  }

  private static func deduplicate(_ detections: [QRCodeDetection]) -> [QRCodeDetection] {
    var seen = Set<String>()
    var unique: [QRCodeDetection] = []

    for detection in detections {
      if seen.insert(detection.payload).inserted {
        unique.append(detection)
      }
    }

    return unique
  }

  private static func sortInReadingOrder(_ detections: [QRCodeDetection]) -> [QRCodeDetection] {
    detections.sorted { lhs, rhs in
      let verticalDelta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
      let rowTolerance = max(lhs.boundingBox.height, rhs.boundingBox.height) * 0.6
      if verticalDelta > rowTolerance {
        return lhs.boundingBox.maxY > rhs.boundingBox.maxY
      }
      return lhs.boundingBox.minX < rhs.boundingBox.minX
    }
  }
}
