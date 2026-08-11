//
//  PreferencesQuickAccessActionDragPayload.swift
//  ShotPaste
//
//  Plain-text drag payload for Quick Access action placement.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
  static let quickAccessAction = UTType("com.ahtcfg24.shotpaste.quick-access-action") ?? .text
  static let quickAccessReorder = UTType("com.ahtcfg24.shotpaste.quick-access-reorder") ?? .text
}

struct QuickAccessActionDragPayload {
  enum Source: Equatable {
    case actionList
    case preview(slot: QuickAccessActionSlot)
    case swipePreview(direction: QuickAccessSwipeDirection)
  }

  static let typeIdentifiers = [UTType.quickAccessAction]

  private static let marker = "com.ahtcfg24.shotpaste.quick-access-action"

  let action: QuickAccessActionKind
  let source: Source

  static func itemProvider(action: QuickAccessActionKind, source: Source) -> NSItemProvider {
    let provider = NSItemProvider()
    if let data = Self(action: action, source: source).encoded.data(using: .utf8) {
      provider
        .registerDataRepresentation(forTypeIdentifier: UTType.quickAccessAction.identifier,
                                    visibility: .all) { completion in
          completion(data, nil)
          return nil
        }
    }
    return provider
  }

  static func load(from providers: [NSItemProvider], completion: @escaping (QuickAccessActionDragPayload) -> Void) {
    guard let provider = providers
      .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.quickAccessAction.identifier) }) else {
      return
    }

    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.quickAccessAction.identifier) { data, _ in
      guard let data,
            let text = String(data: data, encoding: .utf8),
            let payload = Self.parse(text) else {
        return
      }

      Task { @MainActor in
        completion(payload)
      }
    }
  }

  private var encoded: String {
    switch source {
    case .actionList:
      "\(Self.marker)|list|\(action.rawValue)"
    case .preview(let slot):
      "\(Self.marker)|preview|\(slot.rawValue)|\(action.rawValue)"
    case .swipePreview(let direction):
      "\(Self.marker)|swipe|\(direction.rawValue)|\(action.rawValue)"
    }
  }

  private static func parse(_ text: String) -> QuickAccessActionDragPayload? {
    let parts = text.split(separator: "|").map(String.init)
    guard parts.first == marker else { return nil }

    if parts.count == 3,
       parts[1] == "list",
       let action = QuickAccessActionKind(rawValue: parts[2]) {
      return QuickAccessActionDragPayload(action: action, source: .actionList)
    }

    if parts.count == 4,
       parts[1] == "preview",
       let slot = QuickAccessActionSlot(rawValue: parts[2]),
       let action = QuickAccessActionKind(rawValue: parts[3]) {
      return QuickAccessActionDragPayload(action: action, source: .preview(slot: slot))
    }

    if parts.count == 4,
       parts[1] == "swipe",
       let direction = QuickAccessSwipeDirection(rawValue: parts[2]),
       let action = QuickAccessActionKind(rawValue: parts[3]) {
      return QuickAccessActionDragPayload(action: action, source: .swipePreview(direction: direction))
    }

    return nil
  }
}
