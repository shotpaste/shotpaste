//
//  InteractionLeaseCoordinator.swift
//  ShotPaste
//
//  Serializes full-screen interaction surfaces so Agent Mode, One Shot,
//  scrolling capture, and recording never compete for global input.
//

import Combine
import Foundation

@MainActor
final class InteractionLeaseCoordinator: ObservableObject {
  enum Owner: String, Equatable, Sendable {
    case agent
    case oneShot
    case scrollingCapture
    case recording
  }

  struct Lease: Equatable, Sendable {
    let id: UUID
    let owner: Owner
  }

  static let shared = InteractionLeaseCoordinator()

  @Published private(set) var currentLease: Lease?

  init() {}

  nonisolated deinit {}

  func acquire(_ owner: Owner) -> Lease? {
    guard currentLease == nil else { return nil }
    let lease = Lease(id: UUID(), owner: owner)
    currentLease = lease
    DiagnosticLogger.shared.log(
      .debug,
      .agent,
      "Interaction lease acquired",
      context: ["owner": owner.rawValue]
    )
    return lease
  }

  @discardableResult
  func transfer(_ lease: Lease, to owner: Owner) -> Lease? {
    guard currentLease == lease else { return nil }
    let transferred = Lease(id: lease.id, owner: owner)
    currentLease = transferred
    DiagnosticLogger.shared.log(
      .debug,
      .agent,
      "Interaction lease transferred",
      context: ["from": lease.owner.rawValue, "to": owner.rawValue]
    )
    return transferred
  }

  func release(_ lease: Lease) {
    guard currentLease == lease else { return }
    currentLease = nil
    DiagnosticLogger.shared.log(
      .debug,
      .agent,
      "Interaction lease released",
      context: ["owner": lease.owner.rawValue]
    )
  }
}
