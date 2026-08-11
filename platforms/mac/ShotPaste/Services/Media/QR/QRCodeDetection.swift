//
//  QRCodeDetection.swift
//  ShotPaste
//
//  Normalized QR detection output from Vision barcode scanning.
//

import CoreGraphics
import Foundation

nonisolated struct QRCodeDetection: Equatable, Sendable {
  let payload: String
  let boundingBox: CGRect
  let classification: QRPayloadClassification
}

nonisolated struct QRCodeDetectionResult: Equatable, Sendable {
  let detections: [QRCodeDetection]
  let unsupportedPayloadCount: Int

  var hasCopyablePayloads: Bool {
    !detections.isEmpty
  }

  static let empty = QRCodeDetectionResult(detections: [], unsupportedPayloadCount: 0)
}
