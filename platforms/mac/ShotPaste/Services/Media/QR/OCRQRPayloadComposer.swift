//
//  OCRQRPayloadComposer.swift
//  ShotPaste
//
//  Builds the plain-text clipboard payload for OCR text plus QR content.
//

import Foundation

enum OCRQRPayloadComposer {
  static func compose(
    recognizedText: String?,
    qrDetections: [QRCodeDetection],
    qrSectionTitle: String
  ) -> String? {
    let text = recognizedText?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""

    let qrPayloads = uniquePayloads(from: qrDetections)
      .filter { payload in
        !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      .filter { payload in
        text.isEmpty || !text.contains(payload)
      }

    if text.isEmpty {
      guard !qrPayloads.isEmpty else { return nil }
      return qrPayloads.count == 1 ? qrPayloads[0] : "\(qrSectionTitle):\n\(qrPayloads.joined(separator: "\n"))"
    }

    guard !qrPayloads.isEmpty else { return text }
    return "\(text)\n\n\(qrSectionTitle):\n\(qrPayloads.joined(separator: "\n"))"
  }

  private static func uniquePayloads(from detections: [QRCodeDetection]) -> [String] {
    var seen = Set<String>()
    var payloads: [String] = []

    for detection in detections {
      if seen.insert(detection.payload).inserted {
        payloads.append(detection.payload)
      }
    }

    return payloads
  }
}
