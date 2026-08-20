//
//  ScrollingCapturePreviewWindow.swift
//  ShotPaste
//
//  Floating, non-interactive preview rail for scrolling capture sessions.
//

import AppKit
import Combine
import QuartzCore

final class ScrollingCapturePreviewWindow: NSPanel {
  private var anchorRect: CGRect
  private let model: ScrollingCaptureSessionModel
  private let imageView = ScrollingCapturePreviewImageView()
  private var modelObservation: AnyCancellable?

  init(anchorRect: CGRect, model: ScrollingCaptureSessionModel) {
    self.anchorRect = anchorRect
    self.model = model

    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    isOpaque = false
    backgroundColor = .clear
    sharingType = .none
    hasShadow = true
    hidesOnDeactivate = false
    ignoresMouseEvents = true
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 2
    imageView.layer?.masksToBounds = true
    imageView.layer?.borderWidth = 1
    imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
    contentView = imageView

    modelObservation = Publishers.CombineLatest(
      model.$previewImage,
      model.$livePreviewImage
    ).sink { [weak self] _, _ in
      if Thread.isMainThread {
        self?.updateLayout()
      } else {
        DispatchQueue.main.async {
          self?.updateLayout()
        }
      }
    }

    updateLayout()
  }

  func updateAnchorRect(_ rect: CGRect) {
    anchorRect = rect
    updateLayout()
  }

  private func updateLayout() {
    guard let image = model.activePreviewImage else {
      alphaValue = 0
      return
    }
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRect) }) ?? NSScreen.main else {
      return
    }

    let size = ScrollingCapturePreviewLayout.previewSize(
      for: image,
      anchorRect: anchorRect,
      visibleFrame: screen.visibleFrame
    )
    guard size.width > 0, size.height > 0 else { return }

    imageView.update(image: image, scaling: .fit)
    let targetFrame = positionedFrame(near: anchorRect, size: size, visibleFrame: screen.visibleFrame)
    if alphaValue == 0 || frame.isEmpty || Self.framesAreVisuallyEqual(frame, targetFrame) {
      setFrame(targetFrame, display: true)
    } else {
      NSAnimationContext.runAnimationGroup { context in
        // Stay within roughly one 30 fps preview interval so repeated updates
        // do not leave the window perpetually chasing an old target frame.
        context.duration = 0.035
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().setFrame(targetFrame, display: true)
      }
    }
    alphaValue = 1
  }

  private func positionedFrame(
    near rect: CGRect,
    size: CGSize,
    visibleFrame: CGRect
  ) -> CGRect {
    let preferredX = rect.maxX + ScrollingCapturePreviewLayout.anchorGap
    let fallbackX = rect.minX - size.width - ScrollingCapturePreviewLayout.anchorGap
    let x = preferredX + size.width <= visibleFrame.maxX - ScrollingCapturePreviewLayout.screenInset
      ? preferredX
      : max(visibleFrame.minX + ScrollingCapturePreviewLayout.screenInset, fallbackX)
    let y = min(
      max(visibleFrame.minY + ScrollingCapturePreviewLayout.screenInset, rect.minY),
      visibleFrame.maxY - size.height - ScrollingCapturePreviewLayout.screenInset
    )
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
  }

  private static func framesAreVisuallyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 0.5
      && abs(lhs.minY - rhs.minY) < 0.5
      && abs(lhs.width - rhs.width) < 0.5
      && abs(lhs.height - rhs.height) < 0.5
  }

  override var canBecomeKey: Bool {
    false
  }

  override var canBecomeMain: Bool {
    false
  }
}
