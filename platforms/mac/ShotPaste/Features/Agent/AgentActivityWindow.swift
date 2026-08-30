//
//  AgentActivityWindow.swift
//  ShotPaste
//
//  Persistent, translucent Agent activity HUD. It shows the auditable action
//  trail rather than private model reasoning, and remains excluded from Agent
//  observations with the rest of ShotPaste's own windows.
//

import AppKit
import CoreGraphics
import SwiftUI

enum AgentActivityPanelPlacement {
  static let panelSize = CGSize(width: 390, height: 440)
  static let margin: CGFloat = 22

  static func frame(
    visibleFrame: CGRect,
    panelSize: CGSize = panelSize
  ) -> CGRect {
    let width = min(panelSize.width, max(1, visibleFrame.width - margin * 2))
    let height = min(panelSize.height, max(1, visibleFrame.height - margin * 2))
    return CGRect(
      x: visibleFrame.maxX - width - margin,
      y: visibleFrame.maxY - height - margin,
      width: width,
      height: height
    )
  }
}

@MainActor
final class AgentActivityWindowController {
  static let shared = AgentActivityWindowController()

  private var panel: AgentActivityPanel?
  private var targetDisplayID: CGDirectDisplayID?

  private init() {}

  var isVisible: Bool {
    panel?.isVisible == true
  }

  func show(
    coordinator: AgentSessionCoordinator,
    displayID: CGDirectDisplayID
  ) {
    targetDisplayID = displayID
    let panel = panel ?? makePanel(coordinator: coordinator)
    self.panel = panel
    position(panel, displayID: displayID)
    present(panel)
    DiagnosticLogger.shared.log(.info, .agent, "Agent activity window shown")
  }

  func showLast(coordinator: AgentSessionCoordinator) {
    guard coordinator.hasTrajectory || coordinator.isActive else { return }
    let panel = panel ?? makePanel(coordinator: coordinator)
    self.panel = panel
    if !panel.isVisible {
      position(panel, displayID: targetDisplayID)
    }
    present(panel)
    DiagnosticLogger.shared.log(.info, .agent, "Agent activity window restored")
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    DiagnosticLogger.shared.log(.info, .agent, "Agent activity window hidden")
  }

  func shutdown() {
    panel?.close()
    panel = nil
    targetDisplayID = nil
  }

  private func makePanel(coordinator: AgentSessionCoordinator) -> AgentActivityPanel {
    let panel = AgentActivityPanel(
      contentRect: CGRect(origin: .zero, size: AgentActivityPanelPlacement.panelSize)
    )
    let view = AgentActivityHUDView(
      coordinator: coordinator,
      onHide: { [weak self] in self?.hide() },
      onResume: { coordinator.resume() },
      onStop: { AgentModeController.shared.stopImmediately() }
    )
    let hostingView = AgentActivityHostingView(rootView: view)
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    panel.contentView = hostingView
    return panel
  }

  private func position(
    _ panel: NSPanel,
    displayID: CGDirectDisplayID?
  ) {
    let screen = displayID.flatMap { requestedID in
      NSScreen.screens.first { $0.displayID == requestedID }
    } ?? screenContainingMouse() ?? NSScreen.main
    guard let screen else { return }
    panel.setFrame(
      AgentActivityPanelPlacement.frame(visibleFrame: screen.visibleFrame),
      display: false
    )
  }

  private func present(_ panel: NSPanel) {
    guard !panel.isVisible else {
      panel.orderFrontRegardless()
      return
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      panel.animator().alphaValue = 1
    }
  }

  private func screenContainingMouse() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
  }
}

private final class AgentActivityPanel: NSPanel {
  init(contentRect: CGRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    level = .statusBar
    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    hidesOnDeactivate = false
    isMovable = true
    isMovableByWindowBackground = true
    becomesKeyOnlyIfNeeded = true
    worksWhenModal = true
    animationBehavior = .utilityWindow
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

private final class AgentActivityHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }
}

private struct AgentActivityHUDView: View {
  @ObservedObject var coordinator: AgentSessionCoordinator
  let onHide: () -> Void
  let onResume: () -> Void
  let onStop: () -> Void

  var body: some View {
    ZStack {
      AgentActivityVisualEffect()
      VStack(spacing: 0) {
        header
        Divider().opacity(0.55)
        taskCard
        statusCard
        trajectoryHeader
        trajectory
        footer
      }
      .padding(14)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    .frame(minWidth: 320, minHeight: 360)
  }

  private var header: some View {
    HStack(spacing: 9) {
      Image(systemName: "cursorarrow.motionlines")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.purple)
      Text(L10n.Agent.activityTitle)
        .font(.system(size: 14, weight: .semibold))
      if coordinator.phase.isRunning {
        Text(L10n.Agent.activityLive)
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.purple, in: Capsule())
      }
      Spacer()
      Button(action: onHide) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 24, height: 24)
          .background(Color.primary.opacity(0.08), in: Circle())
      }
      .buttonStyle(.plain)
      .help(L10n.Agent.hideActivity)
    }
    .padding(.bottom, 10)
  }

  private var taskCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.Agent.activityTask)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Text(coordinator.taskSummary ?? L10n.Agent.activityWaitingForTask)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(10)
    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    .padding(.top, 10)
  }

  private var statusCard: some View {
    HStack(alignment: .top, spacing: 9) {
      statusIndicator
        .frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(displayStatus)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(statusColor)
          .lineLimit(3)
        if coordinator.isActive {
          Text(L10n.Agent.activityInputPauseHint)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 9)
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if coordinator.phase.isRunning, coordinator.phase != .paused {
      ProgressView()
        .controlSize(.small)
        .tint(.purple)
    } else {
      Image(systemName: statusSymbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(statusColor)
    }
  }

  private var trajectoryHeader: some View {
    HStack {
      Text(L10n.Agent.activityTimeline)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(coordinator.trajectoryEvents.count)")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
    .padding(.bottom, 6)
  }

  private var trajectory: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 9) {
          if coordinator.trajectoryEvents.isEmpty {
            Text(L10n.Agent.activityNoEvents)
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.vertical, 24)
          } else {
            ForEach(Array(coordinator.trajectoryEvents.enumerated()), id: \.offset) { index, event in
              AgentActivityEventRow(event: event)
                .id(index)
            }
          }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
      }
      .frame(maxHeight: .infinity)
      .onAppear {
        scrollToLatest(proxy)
      }
      .onChange(of: coordinator.trajectoryEvents.count) { _ in
        scrollToLatest(proxy)
      }
    }
    .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Text(L10n.Agent.activityAuditNote)
        .font(.system(size: 8.5))
        .foregroundStyle(.tertiary)
        .lineLimit(2)
      Spacer(minLength: 6)
      if coordinator.canResume {
        Button(L10n.Agent.resumeAgent, action: onResume)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .tint(.purple)
      }
      if coordinator.isActive {
        Button(L10n.Agent.activityStop, action: onStop)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .foregroundStyle(.red)
      }
    }
    .padding(.top, 10)
  }

  private var displayStatus: String {
    guard let lastEvent = coordinator.trajectoryEvents.last else {
      return coordinator.statusMessage
    }
    switch lastEvent.kind {
    case .stopped:
      return L10n.Agent.stoppedStatus
    default:
      return coordinator.statusMessage
    }
  }

  private var statusSymbol: String {
    switch coordinator.phase {
    case .paused:
      "pause.circle.fill"
    case .completed:
      "checkmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    default:
      coordinator.trajectoryEvents.last?.kind == .stopped
        ? "stop.circle.fill"
        : "circle.fill"
    }
  }

  private var statusColor: Color {
    switch coordinator.phase {
    case .paused:
      .orange
    case .completed:
      .green
    case .failed:
      .red
    default:
      coordinator.trajectoryEvents.last?.kind == .stopped ? .secondary : .purple
    }
  }

  private func scrollToLatest(_ proxy: ScrollViewProxy) {
    guard !coordinator.trajectoryEvents.isEmpty else { return }
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.16)) {
        proxy.scrollTo(coordinator.trajectoryEvents.count - 1, anchor: .bottom)
      }
    }
  }
}

private struct AgentActivityEventRow: View {
  let event: AgentAuditEvent

  private var presentation: AgentActivityEventPresentation {
    AgentActivityEventPresentation(event: event)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      ZStack {
        Circle()
          .fill(toneColor.opacity(0.14))
          .frame(width: 24, height: 24)
        Image(systemName: presentation.symbolName)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(toneColor)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(presentation.title)
            .font(.system(size: 11, weight: .semibold))
          Spacer()
          Text(event.timestamp, style: .time)
            .font(.system(size: 8.5, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        if let detail = presentation.detail, !detail.isEmpty {
          Text(detail)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
  }

  private var toneColor: Color {
    switch presentation.tone {
    case .neutral: .secondary
    case .active: .purple
    case .success: .green
    case .warning: .orange
    case .failure: .red
    }
  }
}

struct AgentActivityEventPresentation: Equatable {
  enum Tone: Equatable {
    case neutral
    case active
    case success
    case warning
    case failure
  }

  let title: String
  let detail: String?
  let symbolName: String
  let tone: Tone

  init(event: AgentAuditEvent) {
    switch event.kind {
    case .sessionStarted:
      title = L10n.Agent.activityEventStarted
      detail = event.metadata["application"]
      symbolName = "play.fill"
      tone = .active
    case .observation:
      title = L10n.Agent.activityEventObserved
      let accessibilityCount = Int(event.metadata["axElements"] ?? "") ?? 0
      let ocrCount = Int(event.metadata["ocrLines"] ?? "") ?? 0
      detail = L10n.Agent.activityObservationDetail(accessibilityCount, ocrCount)
      symbolName = "eye.fill"
      tone = .neutral
    case .modelDecision:
      title = L10n.Agent.activityEventPlanned
      detail = event.message
      symbolName = "brain.head.profile"
      tone = .active
    case .policyApproval:
      title = L10n.Agent.activityEventApproved
      detail = event.message
      symbolName = "checkmark.shield.fill"
      tone = .success
    case .policyDenial:
      title = L10n.Agent.activityEventDenied
      detail = event.message
      symbolName = "hand.raised.fill"
      tone = .warning
    case .actionResult:
      let succeeded = event.metadata["status"] == "success"
      title = succeeded
        ? L10n.Agent.activityEventActionSucceeded
        : L10n.Agent.activityEventActionFailed
      detail = event.message
      symbolName = succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
      tone = succeeded ? .success : .failure
    case .userResponse:
      title = L10n.Agent.activityEventUserAnswered
      detail = nil
      symbolName = "person.crop.circle.badge.checkmark"
      tone = .neutral
    case .paused:
      title = L10n.Agent.activityEventPaused
      detail = nil
      symbolName = "pause.fill"
      tone = .warning
    case .resumed:
      title = L10n.Agent.activityEventResumed
      detail = nil
      symbolName = "play.fill"
      tone = .active
    case .completed:
      title = L10n.Agent.activityEventCompleted
      detail = event.message
      symbolName = "checkmark.circle.fill"
      tone = .success
    case .failed:
      title = L10n.Agent.activityEventFailed
      detail = event.message
      symbolName = "exclamationmark.triangle.fill"
      tone = .failure
    case .stopped:
      title = L10n.Agent.activityEventStopped
      detail = nil
      symbolName = "stop.fill"
      tone = .neutral
    }
  }
}

private struct AgentActivityVisualEffect: NSViewRepresentable {
  func makeNSView(context _: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context _: Context) {
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
  }
}
