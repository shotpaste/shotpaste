//
//  AgentAnnotationOverlay.swift
//  ShotPaste
//
//  Multi-display frozen overlay for the Agent Mode anchor + intent workflow.
//  It renders an already-captured clean snapshot, so its own UI can never be
//  burned into the model observation.
//

import AppKit
import Carbon.HIToolbox
import Combine
import CoreGraphics
import SwiftUI

struct AgentIntentCaptureSelection: Equatable {
  let displayID: CGDirectDisplayID
  let anchor: AgentNormalizedPoint
  let prompt: String
}

struct AgentAnnotationDisplay: Identifiable {
  let displayID: CGDirectDisplayID
  let screenFrame: CGRect
  let backdropImage: NSImage

  var id: CGDirectDisplayID {
    displayID
  }
}

enum AgentPromptPlacement {
  static func origin(
    anchor: CGPoint,
    containerSize: CGSize,
    panelSize: CGSize,
    margin: CGFloat = 14,
    gap: CGFloat = 18
  ) -> CGPoint {
    var x = anchor.x + gap
    var y = anchor.y + gap
    if x + panelSize.width + margin > containerSize.width {
      x = anchor.x - panelSize.width - gap
    }
    if y + panelSize.height + margin > containerSize.height {
      y = anchor.y - panelSize.height - gap
    }
    return CGPoint(
      x: min(max(x, margin), max(margin, containerSize.width - panelSize.width - margin)),
      y: min(max(y, margin), max(margin, containerSize.height - panelSize.height - margin))
    )
  }
}

@MainActor
final class AgentAnnotationOverlayCoordinator {
  static let shared = AgentAnnotationOverlayCoordinator()

  private var activeWindows: [AgentAnnotationPanel] = []
  private var activeSession: AgentAnnotationSession?
  private var previouslyActiveApplication: NSRunningApplication?

  var isActive: Bool {
    activeSession != nil || !activeWindows.isEmpty
  }

  func start(
    screens: [NSScreen],
    snapshots: [CGDirectDisplayID: FrozenDisplaySnapshot],
    preferredDisplayID: CGDirectDisplayID,
    onSubmit: @escaping (AgentIntentCaptureSelection) -> Void,
    onCancel: @escaping () -> Void
  ) {
    closeActiveWindows(restoreApplication: true)
    let displays = screens.compactMap { screen -> AgentAnnotationDisplay? in
      guard let displayID = screen.displayID,
            let snapshot = snapshots[displayID]
      else { return nil }
      return AgentAnnotationDisplay(
        displayID: displayID,
        screenFrame: screen.frame,
        backdropImage: NSImage(cgImage: snapshot.image, size: screen.frame.size)
      )
    }
    guard !displays.isEmpty else {
      onCancel()
      return
    }

    previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)
    let session = AgentAnnotationSession(
      onFocusDisplay: { [weak self] displayID in
        self?.activeWindows.first(where: { $0.displayID == displayID })?.makeKey()
      },
      onSubmit: { [weak self] selection in
        self?.closeActiveWindows(restoreApplication: true)
        onSubmit(selection)
      },
      onCancel: { [weak self] in
        self?.closeActiveWindows(restoreApplication: true)
        onCancel()
      }
    )
    activeSession = session

    let windows = displays.map { AgentAnnotationPanel(display: $0, session: session) }
    activeWindows = windows
    for window in windows {
      window.onClose = { [weak self, weak window] in
        guard let self, let window else { return }
        activeWindows.removeAll { $0 === window }
      }
      window.orderFrontRegardless()
    }
    let preferredWindow = windows.first { $0.displayID == preferredDisplayID } ?? windows.first
    preferredWindow?.makeKey()
  }

  func cancelActiveSession() {
    activeSession?.cancel()
  }

  private func closeActiveWindows(restoreApplication: Bool) {
    activeSession = nil
    let windows = activeWindows
    activeWindows.removeAll()
    windows.forEach { $0.close() }
    if restoreApplication {
      previouslyActiveApplication?.activate(options: [])
    }
    previouslyActiveApplication = nil
  }
}

@MainActor
final class AgentAnnotationSession: ObservableObject {
  @Published private(set) var selectedDisplayID: CGDirectDisplayID?
  @Published private(set) var anchor: AgentNormalizedPoint?
  @Published var prompt = ""
  @Published private(set) var focusGeneration = 0

  private let onFocusDisplay: (CGDirectDisplayID) -> Void
  private let onSubmit: (AgentIntentCaptureSelection) -> Void
  private let onCancel: () -> Void
  private var didFinish = false

  init(
    onFocusDisplay: @escaping (CGDirectDisplayID) -> Void,
    onSubmit: @escaping (AgentIntentCaptureSelection) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onFocusDisplay = onFocusDisplay
    self.onSubmit = onSubmit
    self.onCancel = onCancel
  }

  func selectAnchor(
    displayID: CGDirectDisplayID,
    location: CGPoint,
    displaySize: CGSize
  ) {
    guard !didFinish,
          selectedDisplayID == nil,
          displaySize.width > 0,
          displaySize.height > 0
    else { return }
    selectedDisplayID = displayID
    anchor = AgentNormalizedPoint(
      x: Double(min(max(location.x / displaySize.width, 0), 1)),
      y: Double(min(max(location.y / displaySize.height, 0), 1))
    )
    focusGeneration += 1
    onFocusDisplay(displayID)
  }

  func submit() {
    guard !didFinish,
          let selectedDisplayID,
          let anchor,
          anchor.isValid
    else { return }
    let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPrompt.isEmpty else {
      NSSound.beep()
      return
    }
    didFinish = true
    onSubmit(AgentIntentCaptureSelection(
      displayID: selectedDisplayID,
      anchor: anchor,
      prompt: normalizedPrompt
    ))
  }

  func cancel() {
    guard !didFinish else { return }
    didFinish = true
    onCancel()
  }
}

final class AgentAnnotationPanel: NSPanel {
  var onClose: (() -> Void)?
  let displayID: CGDirectDisplayID

  private let session: AgentAnnotationSession
  private var didNotifyClose = false

  init(display: AgentAnnotationDisplay, session: AgentAnnotationSession) {
    displayID = display.displayID
    self.session = session
    super.init(
      contentRect: display.screenFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    isOpaque = true
    backgroundColor = .black
    level = .screenSaver
    ignoresMouseEvents = false
    acceptsMouseMovedEvents = true
    isReleasedWhenClosed = false
    hasShadow = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    animationBehavior = .none
    becomesKeyOnlyIfNeeded = false
    isMovable = false
    isMovableByWindowBackground = false
    minSize = display.screenFrame.size
    maxSize = display.screenFrame.size

    if let appearance = ThemeManager.shared.nsAppearance {
      self.appearance = appearance
    }

    contentView = AgentAnnotationHostingView(rootView: AnyView(
      AgentAnnotationRootView(session: session, display: display)
        .preferredColorScheme(ThemeManager.shared.systemAppearance)
    ))
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      session.cancel()
      return
    }
    super.keyDown(with: event)
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
    minSize = frameRect.size
    maxSize = frameRect.size
    super.setFrame(frameRect, display: displayFlag)
  }

  override func close() {
    super.close()
    guard !didNotifyClose else { return }
    didNotifyClose = true
    onClose?()
  }
}

private final class AgentAnnotationHostingView: NSHostingView<AnyView> {
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }
}

private struct AgentAnnotationRootView: View {
  @ObservedObject var session: AgentAnnotationSession
  let display: AgentAnnotationDisplay

  private let promptSize = CGSize(width: 390, height: 174)

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Image(nsImage: display.backdropImage)
          .resizable()
          .frame(width: geometry.size.width, height: geometry.size.height)
          .contentShape(Rectangle())
          .gesture(anchorGesture(in: geometry.size))

        Color.black.opacity(session.selectedDisplayID == nil ? 0.08 : 0.15)
          .allowsHitTesting(false)

        if session.selectedDisplayID == nil {
          AgentAnchorInstructionView()
            .position(x: geometry.size.width / 2, y: 52)
        }

        if session.selectedDisplayID == display.displayID,
           let anchor = session.anchor {
          let anchorPoint = CGPoint(
            x: CGFloat(anchor.x) * geometry.size.width,
            y: CGFloat(anchor.y) * geometry.size.height
          )
          AgentAnchorGlyph()
            .position(anchorPoint)

          AgentPromptBubble(
            prompt: $session.prompt,
            focusGeneration: session.focusGeneration,
            onSubmit: session.submit,
            onCancel: session.cancel
          )
          .frame(width: promptSize.width, height: promptSize.height)
          .position(promptCenter(anchor: anchorPoint, containerSize: geometry.size))
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }

  private func anchorGesture(in displaySize: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onEnded { value in
        session.selectAnchor(
          displayID: display.displayID,
          location: value.location,
          displaySize: displaySize
        )
      }
  }

  private func promptCenter(anchor: CGPoint, containerSize: CGSize) -> CGPoint {
    let origin = AgentPromptPlacement.origin(
      anchor: anchor,
      containerSize: containerSize,
      panelSize: promptSize
    )
    return CGPoint(x: origin.x + promptSize.width / 2, y: origin.y + promptSize.height / 2)
  }
}

private struct AgentAnchorInstructionView: View {
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "cursorarrow.click.2")
      Text(L10n.Agent.clickAnywherePrompt)
        .font(.system(size: 13, weight: .medium))
    }
    .foregroundColor(.white)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.black.opacity(0.72), in: Capsule())
    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
  }
}

private struct AgentAnchorGlyph: View {
  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.white, lineWidth: 2)
        .frame(width: 28, height: 28)
      Circle()
        .fill(Color.purple)
        .frame(width: 16, height: 16)
      Circle()
        .fill(Color.white)
        .frame(width: 5, height: 5)
    }
    .shadow(color: .black.opacity(0.65), radius: 5, y: 2)
    .allowsHitTesting(false)
  }
}

private struct AgentPromptBubble: View {
  @Binding var prompt: String
  let focusGeneration: Int
  let onSubmit: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "sparkles")
          .foregroundStyle(.purple)
        Text(L10n.Agent.intentPromptTitle)
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }

      AgentPromptTextEditor(
        text: $prompt,
        focusGeneration: focusGeneration,
        onSubmit: onSubmit,
        onCancel: onCancel
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      HStack {
        Text(L10n.Agent.intentPromptHint)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Spacer()
        Button(L10n.Agent.runAction, action: onSubmit)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .tint(.purple)
      }
    }
    .padding(13)
    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
  }
}

private struct AgentPromptTextEditor: NSViewRepresentable {
  @Binding var text: String
  let focusGeneration: Int
  let onSubmit: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    let textView = AgentPromptNSTextView()
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.font = .systemFont(ofSize: 13)
    textView.textContainerInset = NSSize(width: 8, height: 7)
    textView.backgroundColor = .clear
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    textView.string = text
    textView.onSubmit = onSubmit
    textView.onCancel = onCancel
    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? AgentPromptNSTextView else { return }
    if textView.string != text {
      textView.string = text
    }
    textView.onSubmit = onSubmit
    textView.onCancel = onCancel
    if context.coordinator.lastFocusGeneration != focusGeneration {
      context.coordinator.lastFocusGeneration = focusGeneration
      DispatchQueue.main.async {
        textView.window?.makeFirstResponder(textView)
      }
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    weak var textView: NSTextView?
    var lastFocusGeneration = -1

    init(text: Binding<String>) {
      self.text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}

private final class AgentPromptNSTextView: NSTextView {
  var onSubmit: (() -> Void)?
  var onCancel: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == UInt16(kVK_Escape) {
      onCancel?()
      return
    }
    if event.keyCode == UInt16(kVK_Return),
       !event.modifierFlags.contains(.shift) {
      onSubmit?()
      return
    }
    super.keyDown(with: event)
  }
}
