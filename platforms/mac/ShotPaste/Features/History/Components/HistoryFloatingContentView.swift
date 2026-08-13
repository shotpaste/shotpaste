//
//  HistoryFloatingContentView.swift
//  ShotPaste
//
//  SwiftUI content for the floating history panel
//

import Combine
import SwiftUI

struct HistoryFloatingContentView: View {
  @ObservedObject var manager: HistoryFloatingManager
  @ObservedObject private var themeManager = ThemeManager.shared
  @ObservedObject private var store = CaptureHistoryStore.shared
  @AppStorage(PreferencesKeys.historyBackgroundStyle) private var backgroundStyle: HistoryBackgroundStyle =
    .defaultStyle
  @Environment(\.colorScheme) private var colorScheme

  @State private var selectedId: UUID? = nil
  @State private var expandedSelectedIds: Set<UUID> = []
  @State private var expandedLastSelectedId: UUID?
  @State private var isExpandedGridReady = false
  @State private var expandedGridWarmupTask: Task<Void, Never>?
  @StateObject private var scrollController = HistoryScrollController()
  @StateObject private var searchViewModel: HistorySearchViewModel

  init(manager: HistoryFloatingManager) {
    self.manager = manager
    _searchViewModel = StateObject(wrappedValue: HistorySearchViewModel(
      searchTextPublisher: manager.$searchText.eraseToAnyPublisher(),
      selectedFilterPublisher: manager.$expandedFilter.eraseToAnyPublisher(),
      selectedTimeFilterPublisher: manager.$expandedTimeFilter.eraseToAnyPublisher()
    ))
  }

  private var expandedRecords: [CaptureHistoryRecord] {
    searchViewModel.filteredRecords
  }

  private var activeRecords: [CaptureHistoryRecord] {
    expandedRecords
  }

  private var activeRecordIDs: [UUID] {
    activeRecords.map(\.id)
  }

  private var expandedRecordIDs: [UUID] {
    expandedRecords.map(\.id)
  }

  private var expandedSelectedRecords: [CaptureHistoryRecord] {
    expandedRecords.filter { expandedSelectedIds.contains($0.id) }
  }

  private var basePanelSize: CGSize {
    HistoryFloatingLayout.basePanelSize
  }

  private var resolvedPanelScale: CGFloat {
    HistoryFloatingLayout.effectiveScale(
      for: manager.panelScale,
      on: ScreenUtility.activeScreen()
    )
  }

  private var scaledPanelSize: CGSize {
    HistoryFloatingLayout.panelSize(
      for: manager.panelScale,
      on: ScreenUtility.activeScreen()
    )
  }

  var body: some View {
    expandedContent
      .frame(width: basePanelSize.width, height: basePanelSize.height)
      .background(HistoryBackdropView(style: backgroundStyle))
      .overlay(panelBorder)
      .scaleEffect(resolvedPanelScale)
      .frame(width: scaledPanelSize.width, height: scaledPanelSize.height)
      .preferredColorScheme(themeManager.systemAppearance)
      .onAppear {
        syncSelectionIfNeeded()
        syncExpandedGridPresentation()
      }
      .onDisappear {
        expandedGridWarmupTask?.cancel()
      }
      .onChange(of: activeRecordIDs) { _ in
        syncSelectionIfNeeded()
      }
      .onChange(of: expandedRecordIDs) { _ in
        pruneExpandedSelection()
        prefetchExpandedThumbnailsIfNeeded()
      }
      .onReceive(NotificationCenter.default.publisher(for: .historyCopySelection)) { notification in
        guard notification.object is HistoryFloatingPanel else { return }
        copySelectedRecord()
      }
      .onReceive(NotificationCenter.default.publisher(for: .historyActivateSelection)) { notification in
        guard notification.object is HistoryFloatingPanel else { return }
        openSelectedRecord()
      }
      .onReceive(NotificationCenter.default.publisher(for: .historyDeleteSelection)) { notification in
        guard notification.object is HistoryFloatingPanel else { return }
        deleteSelectedRecords()
      }
      .onReceive(NotificationCenter.default.publisher(for: .historySelectAll)) { notification in
        guard notification.object is HistoryFloatingPanel else { return }
        selectAllExpandedRecords()
      }
      .onReceive(NotificationCenter.default.publisher(for: .historyMoveSelection)) { notification in
        guard notification.object is HistoryFloatingPanel,
              let move = notification.userInfo?["move"] as? HistorySelectionMove else { return }
        moveSelection(move)
      }
  }

  private var panelShape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: HistoryFloatingLayout.baseCornerRadius,
      style: .continuous
    )
  }

  private var panelBorder: some View {
    panelShape
      .strokeBorder(
        colorScheme == .dark
          ? Color.white.opacity(0.1)
          : Color.white.opacity(0.72),
        lineWidth: 1
      )
  }

  // MARK: - History Grid

  private var expandedContent: some View {
    ZStack(alignment: .bottom) {
      VStack(spacing: 18) {
        expandedHeader

        if expandedRecords.isEmpty {
          expandedEmptyState
        } else if isExpandedGridReady {
          expandedGrid
        } else {
          expandedGridPlaceholder
        }
      }

      if !expandedSelectedRecords.isEmpty {
        expandedSelectionBar
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 20)
  }

  private var expandedHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      expandedTypeFilters
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)

      expandedSearchBar

      expandedTrailingControls
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var expandedTypeFilters: some View {
    HStack(spacing: 8) {
      ForEach(Array(captureTypeFilters.enumerated()), id: \.offset) { _, filter in
        selectionPill(
          title: filter.title,
          isSelected: manager.expandedFilter == filter.type,
          count: nil,
          horizontalPadding: 12,
          verticalPadding: 8,
          fontSize: 11,
          minWidth: expandedTypeFilterMinWidth(for: filter.type),
          action: {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
              manager.expandedFilter = filter.type
            }
          }
        )
      }
    }
  }

  private var expandedSearchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.secondary.opacity(0.9))

      TextField(L10n.PreferencesHistory.searchCaptures, text: $manager.searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium))

      if !manager.searchText.isEmpty {
        Button(action: { manager.searchText = "" }) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.8))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .frame(width: 238)
    .background(chromeSurfaceFill, in: Capsule())
    .overlay(
      Capsule()
        .stroke(chromeSurfaceBorder, lineWidth: 1)
    )
    .shadow(color: chromeSurfaceShadow, radius: 7, x: 0, y: 3)
  }

  private var expandedTimeFilterMenu: some View {
    Picker(selection: $manager.expandedTimeFilter) {
      ForEach(HistoryFloatingTimeFilter.allCases) { filter in
        Text(filter.title).tag(filter)
      }
    } label: {
      Image(systemName: "calendar")
    }
    .pickerStyle(.menu)
    .controlSize(.small)
    .frame(minWidth: 108)
    .help(manager.expandedTimeFilter.title)
    .accessibilityLabel(manager.expandedTimeFilter.title)
  }

  private var expandedTrailingControls: some View {
    HStack(spacing: 8) {
      expandedTimeFilterMenu
      expandedControls
    }
  }

  private var expandedControls: some View {
    HStack(spacing: 6) {
      controlButton(
        systemName: manager.keepsOpen ? "pin.fill" : "pin",
        help: manager.keepsOpen
          ? L10n.PreferencesHistory.stopKeepingOpen
          : L10n.PreferencesHistory.keepOpen,
        size: 34,
        isSelected: manager.keepsOpen,
        action: { manager.keepsOpen.toggle() }
      )

      controlButton(
        systemName: "trash",
        help: L10n.PreferencesHistory.clearHistoryButton,
        size: 34,
        isDestructive: true,
        action: clearAllHistory
      )
      .disabled(store.records.isEmpty)
      .opacity(store.records.isEmpty ? 0.45 : 1)

      controlButton(
        systemName: "xmark",
        help: L10n.Common.close,
        size: 34,
        action: manager.hide
      )
    }
  }

  private var expandedSelectionBar: some View {
    HStack(spacing: 10) {
      Label(
        L10n.PreferencesHistory.selectedCaptures(expandedSelectedRecords.count),
        systemImage: "checkmark.circle.fill"
      )
      .font(.system(size: 11, weight: .semibold))
      .foregroundColor(.primary.opacity(0.84))

      if expandedSelectedRecords.count < expandedRecords.count {
        selectionControlButton(
          title: L10n.PreferencesHistory.selectAll,
          systemName: "checkmark.circle",
          action: selectAllExpandedRecords
        )
      }

      selectionControlButton(
        title: L10n.PreferencesHistory.clearSelection,
        systemName: "xmark.circle",
        action: clearExpandedSelection
      )

      selectionControlButton(
        title: L10n.Common.deleteAction,
        systemName: "trash",
        isDestructive: true,
        action: deleteSelectedRecords
      )
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.ultraThinMaterial, in: Capsule())
    .background(selectionBarTint, in: Capsule())
    .overlay(
      Capsule()
        .stroke(selectionBarBorder, lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.14), radius: 18, x: 0, y: 8)
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.bottom, 4)
    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
  }

  private var expandedGrid: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: false) {
        LazyVGrid(columns: expandedColumns, spacing: 12) {
          ForEach(expandedRecords) { record in
            HistoryExpandedCaptureCardView(
              record: record,
              isSelected: expandedSelectedIds.contains(record.id),
              backgroundStyle: backgroundStyle,
              onTap: {
                selectExpandedRecord(record)
              }
            )
            .equatable()
            .id(record.id)
            .contextMenu {
              HistoryContextMenu(record: record)
            }
          }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 88)

        HistoryScrollViewReader(controller: scrollController)
          .frame(height: 0)
      }
      .onChange(of: selectedId) { selectedId in
        guard let selectedId else { return }
        withAnimation(.easeOut(duration: 0.16)) {
          proxy.scrollTo(selectedId, anchor: .center)
        }
      }
      .overlay(
        HistoryFloatingScrollbar(controller: scrollController, scale: resolvedPanelScale)
          .padding(.trailing, 2),
        alignment: .trailing
      )
    }
  }

  private var expandedGridPlaceholder: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVGrid(columns: expandedColumns, spacing: 12) {
        ForEach(0 ..< 8, id: \.self) { _ in
          VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .fill(placeholderFill)
              .aspectRatio(16 / 10, contentMode: .fit)

            VStack(alignment: .leading, spacing: 7) {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(placeholderFill)
                .frame(height: 12)

              HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .fill(placeholderFill)
                  .frame(width: 96, height: 10)
              }
            }
          }
          .padding(10)
          .background(placeholderCardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .stroke(placeholderStroke, lineWidth: 1)
          )
          .redacted(reason: .placeholder)
        }
      }
      .padding(.horizontal, 6)
      .padding(.top, 4)
      .padding(.bottom, 14)
    }
  }

  private var expandedColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12, alignment: .top),
      count: 4
    )
  }

  private var expandedEmptyState: some View {
    HistoryEmptyStateView(
      filter: manager.expandedFilter,
      hasSearch: !manager.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    .padding(.horizontal, 160)
    .padding(.bottom, 6)
  }

  // MARK: - Styling

  private var captureTypeFilters: [(title: String, type: CaptureHistoryCategory?)] {
    [
      (L10n.PreferencesHistory.defaultFilterScreenshots, .screenshot),
      (L10n.Actions.scrollingCapture, .scrollingScreenshot),
      (L10n.CaptureKind.recording, .recording),
      (L10n.OneShot.clipboard, .clipboard),
    ]
  }

  private var selectedFilterBackground: AnyShapeStyle {
    AnyShapeStyle(
      LinearGradient(
        colors: [
          Color.accentColor.opacity(colorScheme == .dark ? 0.95 : 0.98),
          Color.accentColor.opacity(colorScheme == .dark ? 0.82 : 0.9),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  private var chromeSurfaceFill: AnyShapeStyle {
    if backgroundStyle == .solid {
      return colorScheme == .dark
        ? AnyShapeStyle(Color.white.opacity(0.07))
        : AnyShapeStyle(Color.white.opacity(0.76))
    }

    return colorScheme == .dark
      ? AnyShapeStyle(Color.white.opacity(0.07))
      : AnyShapeStyle(Color.white.opacity(0.52))
  }

  private var chromeSurfaceBorder: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.64)
  }

  private var chromeSurfaceShadow: Color {
    Color.black.opacity(colorScheme == .dark ? 0.18 : 0.07)
  }

  private var selectionBarTint: Color {
    colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.42)
  }

  private var selectionBarBorder: Color {
    colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.7)
  }

  private var unselectedPillBackground: AnyShapeStyle {
    colorScheme == .dark
      ? AnyShapeStyle(Color.white.opacity(0.08))
      : AnyShapeStyle(Color.black.opacity(0.05))
  }

  private var pillCountBackground: Color {
    colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.84)
  }

  private var controlButtonBackground: AnyShapeStyle {
    colorScheme == .dark
      ? AnyShapeStyle(Color.white.opacity(0.08))
      : AnyShapeStyle(Color.white.opacity(0.72))
  }

  private var placeholderFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
  }

  private var placeholderCardFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.64)
  }

  private var placeholderStroke: Color {
    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
  }

  // MARK: - Helpers

  private func selectionPill(
    title: String,
    isSelected: Bool,
    count: Int?,
    horizontalPadding: CGFloat = 12,
    verticalPadding: CGFloat = 7,
    fontSize: CGFloat = 12,
    minWidth: CGFloat? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text(title)
          .font(.system(size: fontSize, weight: .semibold))
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)

        if let count {
          Text("\(count)")
            .font(.system(size: max(fontSize - 2, 9), weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(pillCountBackground.opacity(isSelected ? 0.18 : 1), in: Capsule())
        }
      }
      .foregroundColor(isSelected ? .white : .primary.opacity(0.82))
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(minWidth: minWidth)
      .background(isSelected ? selectedFilterBackground : unselectedPillBackground)
      .overlay(
        Capsule()
          .stroke(
            isSelected
              ? Color.white.opacity(0.08)
              : chromeSurfaceBorder.opacity(colorScheme == .dark ? 0.45 : 0.7),
            lineWidth: 1
          )
      )
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func controlButton(
    systemName: String,
    help: String,
    size: CGFloat = 30,
    isSelected: Bool = false,
    isDestructive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: size <= 34 ? 10.5 : 11, weight: .semibold))
        .frame(width: size, height: size)
        .background(
          isSelected
            ? AnyShapeStyle(Color.accentColor.opacity(0.22))
            : controlButtonBackground
        )
        .foregroundColor(
          isDestructive
            ? Color.red
            : isSelected ? Color.accentColor : Color.primary.opacity(0.86)
        )
        .clipShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func selectionControlButton(
    title: String,
    systemName: String,
    isDestructive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(role: isDestructive ? .destructive : nil, action: action) {
      Label(title, systemImage: systemName)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .buttonStyle(.plain)
    .foregroundColor(isDestructive ? .red : .primary.opacity(0.82))
  }

  private func syncSelectionIfNeeded() {
    guard !activeRecords.isEmpty else {
      selectedId = nil
      return
    }

    guard let selectedId, activeRecords.contains(where: { $0.id == selectedId }) else {
      selectedId = activeRecords.first?.id
      return
    }
  }

  private func selectExpandedRecord(_ record: CaptureHistoryRecord) {
    let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if flags.contains(.shift), let expandedLastSelectedId,
       let startIndex = expandedRecords.firstIndex(where: { $0.id == expandedLastSelectedId }),
       let endIndex = expandedRecords.firstIndex(where: { $0.id == record.id }) {
      let range = min(startIndex, endIndex) ... max(startIndex, endIndex)
      expandedSelectedIds.formUnion(expandedRecords[range].map(\.id))
    } else if flags.contains(.command) {
      if expandedSelectedIds.contains(record.id) {
        expandedSelectedIds.remove(record.id)
      } else {
        expandedSelectedIds.insert(record.id)
      }
      expandedLastSelectedId = record.id
    } else if flags.contains(.shift) {
      expandedSelectedIds.insert(record.id)
      expandedLastSelectedId = record.id
    } else {
      expandedSelectedIds = [record.id]
      expandedLastSelectedId = record.id
    }

    selectedId = record.id
    manager.focusPanel()
  }

  private func selectAllExpandedRecords() {
    expandedSelectedIds = Set(expandedRecords.map(\.id))
    expandedLastSelectedId = expandedRecords.last?.id
  }

  private func moveSelection(_ move: HistorySelectionMove) {
    guard !activeRecords.isEmpty else { return }
    let currentIndex = selectedId.flatMap { id in
      activeRecords.firstIndex(where: { $0.id == id })
    } ?? 0

    guard let newIndex = HistorySelectionNavigation.destinationIndex(
      from: currentIndex,
      move: move,
      itemCount: activeRecords.count,
      columnCount: 4
    ) else { return }
    let record = activeRecords[newIndex]
    selectedId = record.id
    expandedSelectedIds = [record.id]
    expandedLastSelectedId = record.id
  }

  private func clearExpandedSelection() {
    expandedSelectedIds.removeAll()
    expandedLastSelectedId = nil
  }

  private func pruneExpandedSelection() {
    let visibleIds = Set(expandedRecordIDs)
    expandedSelectedIds.formIntersection(visibleIds)

    if let expandedLastSelectedId, !visibleIds.contains(expandedLastSelectedId) {
      self.expandedLastSelectedId = expandedSelectedIds.first
    }
  }

  private func copySelectedRecord() {
    if !expandedSelectedRecords.isEmpty {
      HistoryWindowController.shared.copyToClipboard(expandedSelectedRecords)
      return
    }

    guard let selectedId,
          let record = activeRecords.first(where: { $0.id == selectedId })
    else { return }

    HistoryWindowController.shared.copyToClipboard([record])
  }

  private func openSelectedRecord() {
    if expandedSelectedRecords.count == 1, let record = expandedSelectedRecords.first {
      HistoryWindowController.shared.openItem(record)
      return
    }

    if expandedSelectedRecords.count > 1 {
      return
    }

    guard let selectedId,
          let record = activeRecords.first(where: { $0.id == selectedId })
    else { return }

    HistoryWindowController.shared.openItem(record)
  }

  private func deleteSelectedRecords() {
    let records = expandedSelectedRecords.isEmpty
      ? activeRecords.filter { $0.id == selectedId }
      : expandedSelectedRecords

    HistoryWindowController.shared.deleteRecords(
      records,
      asksConfirmation: true
    ) { result in
      guard result.deletedCount > 0 else { return }
      clearExpandedSelection()
      syncSelectionIfNeeded()
    }
  }

  private func clearAllHistory() {
    HistoryWindowController.shared.clearAllRecords { result in
      guard result.deletedCount > 0 else { return }
      clearExpandedSelection()
      syncSelectionIfNeeded()
    }
  }

  private func expandedTypeFilterMinWidth(for filter: CaptureHistoryCategory?) -> CGFloat {
    switch filter {
    case .screenshot:
      108
    case .scrollingScreenshot:
      96
    case .recording:
      94
    case .clipboard:
      88
    case nil:
      62
    }
  }

  private func prefetchExpandedThumbnailsIfNeeded() {
    guard !expandedRecords.isEmpty else { return }
    HistoryThumbnailGenerator.shared.preloadThumbnails(for: Array(expandedRecords.prefix(10)))
  }

  private func syncExpandedGridPresentation() {
    expandedGridWarmupTask?.cancel()

    prefetchExpandedThumbnailsIfNeeded()

    guard !expandedRecords.isEmpty else {
      isExpandedGridReady = true
      return
    }

    isExpandedGridReady = false
    expandedGridWarmupTask = Task {
      try? await Task.sleep(nanoseconds: 140_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        isExpandedGridReady = true
      }
    }
  }
}
