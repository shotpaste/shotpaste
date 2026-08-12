//
//  AgentInteractionTests.swift
//  ShotPasteTests
//

import CoreGraphics
@testable import ShotPaste
import XCTest

@MainActor
final class AgentInteractionTests: XCTestCase {
  func testPromptPlacementAvoidsBottomRightScreenEdge() {
    let origin = AgentPromptPlacement.origin(
      anchor: CGPoint(x: 990, y: 790),
      containerSize: CGSize(width: 1_000, height: 800),
      panelSize: CGSize(width: 390, height: 174)
    )

    XCTAssertGreaterThanOrEqual(origin.x, 14)
    XCTAssertGreaterThanOrEqual(origin.y, 14)
    XCTAssertLessThanOrEqual(origin.x + 390, 986)
    XCTAssertLessThanOrEqual(origin.y + 174, 786)
    XCTAssertLessThan(origin.x, 990)
    XCTAssertLessThan(origin.y, 790)
  }

  func testActivityPanelPlacementUsesTopRightVisibleFrameOnOffsetDisplay() {
    let visibleFrame = CGRect(x: -1_920, y: 40, width: 1_920, height: 1_040)
    let frame = AgentActivityPanelPlacement.frame(
      visibleFrame: visibleFrame,
      panelSize: CGSize(width: 390, height: 440)
    )

    XCTAssertEqual(frame.maxX, visibleFrame.maxX - AgentActivityPanelPlacement.margin)
    XCTAssertEqual(frame.maxY, visibleFrame.maxY - AgentActivityPanelPlacement.margin)
    XCTAssertTrue(visibleFrame.contains(frame))
  }

  func testActivityPresentationDoesNotRepeatTaskOrUserAnswerText() {
    let started = AgentActivityEventPresentation(event: AgentAuditEvent(
      kind: .sessionStarted,
      message: "private task text",
      metadata: ["application": "Editor"]
    ))
    let answered = AgentActivityEventPresentation(event: AgentAuditEvent(
      kind: .userResponse,
      message: "private answer text"
    ))

    XCTAssertEqual(started.detail, "Editor")
    XCTAssertFalse(started.detail?.contains("private task text") == true)
    XCTAssertNil(answered.detail)
  }

  func testActivityObservationPresentationShowsStructuredCounts() {
    let presentation = AgentActivityEventPresentation(event: AgentAuditEvent(
      kind: .observation,
      message: "Observed Editor",
      metadata: ["axElements": "12", "ocrLines": "34"]
    ))

    XCTAssertEqual(presentation.tone, .neutral)
    XCTAssertTrue(presentation.detail?.contains("12") == true)
    XCTAssertTrue(presentation.detail?.contains("34") == true)
  }

  func testInteractionLeaseIsExclusiveAndRequiresMatchingRelease() throws {
    let coordinator = InteractionLeaseCoordinator()
    let agentLease = try XCTUnwrap(coordinator.acquire(.agent))
    XCTAssertNil(coordinator.acquire(.oneShot))

    coordinator.release(InteractionLeaseCoordinator.Lease(id: UUID(), owner: .agent))
    XCTAssertEqual(coordinator.currentLease, agentLease)

    coordinator.release(agentLease)
    XCTAssertNil(coordinator.currentLease)
    XCTAssertNotNil(coordinator.acquire(.oneShot))
  }

  func testInteractionLeaseTransferRetainsIdentityAndChangesOwner() throws {
    let coordinator = InteractionLeaseCoordinator()
    let oneShotLease = try XCTUnwrap(coordinator.acquire(.oneShot))
    let recordingLease = try XCTUnwrap(coordinator.transfer(oneShotLease, to: .recording))

    XCTAssertEqual(recordingLease.id, oneShotLease.id)
    XCTAssertEqual(recordingLease.owner, .recording)
    XCTAssertEqual(coordinator.currentLease, recordingLease)
    coordinator.release(oneShotLease)
    XCTAssertEqual(coordinator.currentLease, recordingLease)
    coordinator.release(recordingLease)
    XCTAssertNil(coordinator.currentLease)
  }
}
