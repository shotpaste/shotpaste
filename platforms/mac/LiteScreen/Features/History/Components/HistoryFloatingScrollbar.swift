//
//  HistoryFloatingScrollbar.swift
//  LiteScreen
//
//  Custom vertical scrollbar overlay for the expanded floating history grid.
//  Auto-hides when idle; thin, elegant thumb with transparent track.
//

import SwiftUI

struct HistoryFloatingScrollbar: View {
  @ObservedObject var controller: HistoryScrollController
  @Environment(\.colorScheme) private var colorScheme
  var scale: CGFloat = 1.0

  @State private var isHovering = false
  @State private var isDragging = false
  @State private var dragStartOffset: CGFloat = 0
  @State private var isScrolling = false
  @State private var scrollHideTask: Task<Void, Never>?

  private let trackWidth: CGFloat = 10
  private let thumbWidth: CGFloat = 4
  private let thumbMinHeight: CGFloat = 40
  private let hideDelay: UInt64 = 800_000_000

  private var isVisible: Bool {
    controller.isScrollable && (isHovering || isDragging || isScrolling)
  }

  private var thumbHeight: CGFloat {
    guard controller.visibleHeight > 0, controller.contentHeight > 0 else {
      return thumbMinHeight
    }
    let ratio = controller.visibleHeight / controller.contentHeight
    return max(controller.visibleHeight * ratio, thumbMinHeight)
  }

  private var thumbOffset: CGFloat {
    guard controller.maxOffset > 0 else { return 0 }
    let trackHeight = controller.visibleHeight - thumbHeight
    let progress = controller.offset / controller.maxOffset
    return progress * trackHeight
  }

  private var thumbColor: Color {
    let baseOpacity: CGFloat = isDragging
      ? (colorScheme == .dark ? 0.45 : 0.35)
      : (isHovering ? (colorScheme == .dark ? 0.35 : 0.28) : (colorScheme == .dark ? 0.28 : 0.22))
    return colorScheme == .dark
      ? Color.white.opacity(baseOpacity)
      : Color.black.opacity(baseOpacity)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topTrailing) {
        // Invisible track area for hover detection
        Rectangle()
          .fill(Color.clear)
          .frame(width: trackWidth)
          .contentShape(Rectangle())
          .onHover { hovering in
            isHovering = hovering
            if !hovering {
              startScrollHideTimer()
            }
          }

        // Thumb
        RoundedRectangle(cornerRadius: thumbWidth / 2, style: .continuous)
          .fill(thumbColor)
          .frame(width: thumbWidth, height: thumbHeight)
          .offset(y: thumbOffset)
          .allowsHitTesting(true)
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
              .onChanged { value in
                if !isDragging {
                  isDragging = true
                  dragStartOffset = controller.offset
                }

                let deltaY = value.translation.height / max(scale, 0.01)
                let trackHeight = controller.visibleHeight - thumbHeight
                guard trackHeight > 0 else { return }
                let scrollRatio = deltaY / trackHeight
                let targetOffset = dragStartOffset + (scrollRatio * controller.maxOffset)
                controller.scrollTo(offset: targetOffset)
              }
              .onEnded { _ in
                isDragging = false
                startScrollHideTimer()
              }
          )
      }
      .frame(width: trackWidth, height: geometry.size.height)
    }
    .frame(width: trackWidth)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.22), value: isVisible)
    .animation(.easeInOut(duration: 0.15), value: thumbColor)
    .allowsHitTesting(isVisible)
    .onChange(of: controller.offset) { _ in
      isScrolling = true
      startScrollHideTimer()
    }
  }

  private func startScrollHideTimer() {
    scrollHideTask?.cancel()
    scrollHideTask = Task {
      try? await Task.sleep(nanoseconds: hideDelay)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        if !isHovering, !isDragging {
          isScrolling = false
        }
      }
    }
  }
}
