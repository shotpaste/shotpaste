//
//  ScrollingCaptureHUDWindow.swift
//  ShotPaste
//
//  Floating control HUD for scrolling capture sessions.
//

import AppKit
import Combine
import SwiftUI

final class ScrollingCaptureHUDWindow: NSPanel {
  private var anchorRect: CGRect
  private weak var model: ScrollingCaptureSessionModel?
  private var modelObservation: AnyCancellable?

  init(
    anchorRect: CGRect,
    model: ScrollingCaptureSessionModel,
    onStart: @escaping () -> Void,
    onDone: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.anchorRect = anchorRect
    self.model = model

    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    sharingType = .none
    hasShadow = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    contentView = NSHostingView(rootView: ScrollingCaptureHUDView(
      model: model,
      onStart: onStart,
      onDone: onDone,
      onCancel: onCancel
    ))

    modelObservation = model.$phase.sink { [weak self] _ in
      DispatchQueue.main.async {
        self?.refreshContentSize()
      }
    }

    refreshContentSize()
  }

  func updateAnchorRect(_ rect: CGRect) {
    anchorRect = rect
    refreshContentSize()
  }

  func refreshContentSize() {
    guard let contentView else { return }

    contentView.layoutSubtreeIfNeeded()
    let size = Self.resolvedContentSize(for: contentView.fittingSize)
    setContentSize(size)
    position(near: anchorRect, size: size)
  }

  nonisolated static func resolvedContentSize(for fittingSize: CGSize) -> CGSize {
    CGSize(
      width: max(44, fittingSize.width.rounded(.up)),
      height: max(44, fittingSize.height.rounded(.up))
    )
  }

  private func position(near rect: CGRect, size: CGSize) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
      return
    }

    let visible = screen.visibleFrame
    let preferredX = model?.phase == .ready
      ? rect.midX - size.width / 2
      : rect.maxX - size.width
    let x = min(max(visible.minX + 12, preferredX), visible.maxX - size.width - 12)
    let belowY = rect.minY - size.height - 12
    let y = belowY >= visible.minY + 12
      ? belowY
      : min(visible.maxY - size.height - 12, rect.maxY + 12)
    setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
  }

  override var canBecomeKey: Bool {
    false
  }

  override var canBecomeMain: Bool {
    false
  }
}

final class ScrollingCaptureAutoScrollWindow: NSPanel {
  private var anchorRect: CGRect
  private let model: ScrollingCaptureSessionModel
  private var modelObservation: AnyCancellable?

  init(
    anchorRect: CGRect,
    model: ScrollingCaptureSessionModel,
    onToggleAutoScroll: @escaping () -> Void
  ) {
    self.anchorRect = anchorRect
    self.model = model

    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    sharingType = .none
    hasShadow = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    contentView = NSHostingView(rootView: ScrollingCaptureAutoScrollView(
      model: model,
      onToggleAutoScroll: onToggleAutoScroll
    ))

    modelObservation = model.$phase.combineLatest(model.$isAutoScrolling).sink { [weak self] _ in
      DispatchQueue.main.async {
        self?.refreshContentSize()
      }
    }

    refreshContentSize()
  }

  func updateAnchorRect(_ rect: CGRect) {
    anchorRect = rect
    refreshContentSize()
  }

  func refreshContentSize() {
    guard let contentView else { return }

    contentView.layoutSubtreeIfNeeded()
    let fittingSize = contentView.fittingSize
    let size = CGSize(
      width: max(88, fittingSize.width.rounded(.up)),
      height: max(32, fittingSize.height.rounded(.up))
    )
    setContentSize(size)
    position(inside: anchorRect, size: size)
    alphaValue = model.phase == .capturing ? 1 : 0
  }

  private func position(inside rect: CGRect, size: CGSize) {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else {
      return
    }

    let visible = screen.visibleFrame
    let preferredX = rect.midX - size.width / 2
    let x = min(max(visible.minX + 12, preferredX), visible.maxX - size.width - 12)
    let preferredY = rect.minY + 14
    let upperY = max(
      visible.minY + 12,
      min(rect.maxY - size.height - 14, visible.maxY - size.height - 12)
    )
    let y = min(max(visible.minY + 12, preferredY), upperY)
    setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
  }

  override var canBecomeKey: Bool {
    false
  }

  override var canBecomeMain: Bool {
    false
  }
}
