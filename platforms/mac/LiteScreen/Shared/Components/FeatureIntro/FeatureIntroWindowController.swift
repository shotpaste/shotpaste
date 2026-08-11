import AppKit
import SwiftUI

@MainActor
public final class FeatureIntroWindowController: NSWindowController {
  public init(screens: [FeatureIntroScreen]) {
    let window = FeatureIntroWindow()
    super.init(window: window)

    let view = FeatureIntroView(screens: screens) { [weak self] in
      self?.close()
    }

    let hostingView = NSHostingView(rootView: view)
    hostingView.autoresizingMask = [.width, .height]

    window.contentView = hostingView
    window.center()
  }

  @available(*, unavailable)
  public required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func show() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private final class FeatureIntroWindow: NSWindow {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    isMovableByWindowBackground = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    animationBehavior = .alertPanel
  }

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    true
  }
}
