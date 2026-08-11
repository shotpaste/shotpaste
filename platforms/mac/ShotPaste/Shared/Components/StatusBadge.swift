//
//  StatusBadge.swift
//  ShotPaste
//
//  Shared badge component for compact status and metadata indicators.
//

import SwiftUI

struct StatusBadge: View {
  enum Style {
    case pill
    case circle(size: CGFloat = 22)
  }

  struct Configuration {
    let label: String
    var systemImage: String?
    let tint: Color
    var style: Style = .pill
    var showsProgress = false
  }

  let configuration: Configuration

  init(configuration: Configuration) {
    self.configuration = configuration
  }

  init(
    label: String,
    systemImage: String? = nil,
    tint: Color,
    style: Style = .pill,
    showsProgress: Bool = false
  ) {
    configuration = Configuration(
      label: label,
      systemImage: systemImage,
      tint: tint,
      style: style,
      showsProgress: showsProgress
    )
  }

  var body: some View {
    switch configuration.style {
    case .pill:
      pillBadge
    case .circle(let size):
      circleBadge(size: size)
    }
  }

  private var pillBadge: some View {
    HStack(spacing: 5) {
      badgeSymbol

      Text(configuration.label)
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .foregroundStyle(configuration.tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(configuration.tint.opacity(0.12), in: Capsule())
    .overlay {
      Capsule()
        .stroke(configuration.tint.opacity(0.24), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(configuration.label)
  }

  private func circleBadge(size: CGFloat) -> some View {
    ZStack {
      Circle()
        .fill(configuration.tint.opacity(0.14))

      badgeSymbol
    }
    .foregroundStyle(configuration.tint)
    .frame(width: size, height: size)
    .overlay {
      Circle()
        .stroke(configuration.tint.opacity(0.28), lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(configuration.label)
  }

  @ViewBuilder
  private var badgeSymbol: some View {
    if configuration.showsProgress {
      ProgressView()
        .controlSize(.mini)
        .scaleEffect(0.72)
        .tint(configuration.tint)
        .frame(width: 12, height: 12)
    } else if let systemImage = configuration.systemImage {
      Image(systemName: systemImage)
        .font(.caption2.weight(.semibold))
    }
  }
}
