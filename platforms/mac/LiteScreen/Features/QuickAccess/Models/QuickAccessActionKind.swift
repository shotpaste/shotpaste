//
//  QuickAccessActionKind.swift
//  LiteScreen
//
//  Stable action identifiers for Quick Access card customization.
//

import Foundation

enum QuickAccessActionDisplayStyle: String, Codable {
  case primary
  case corner
}

enum QuickAccessActionSurface: Equatable {
  case overlay
  case contextMenu
}

enum QuickAccessActionSlot: String, CaseIterable, Codable, Hashable, Identifiable {
  case centerTop
  case centerBottom
  case topTrailing
  case topLeading
  case bottomLeading
  case bottomTrailing

  var id: String {
    rawValue
  }

  static let centerSlots: [QuickAccessActionSlot] = [
    .centerTop,
    .centerBottom,
  ]

  static let cornerSlots: [QuickAccessActionSlot] = [
    .topTrailing,
    .topLeading,
    .bottomLeading,
    .bottomTrailing,
  ]

  static let defaultAssignments: [QuickAccessActionSlot: QuickAccessActionKind] = [
    .centerTop: .copy,
    .centerBottom: .saveOrOpen,
    .topTrailing: .dismiss,
    .topLeading: .delete,
    .bottomTrailing: .pinToScreen,
  ]

  var isCenterSlot: Bool {
    Self.centerSlots.contains(self)
  }

  var settingsTitle: String {
    switch self {
    case .centerTop:
      L10n.PreferencesQuickAccess.slotCenterTop
    case .centerBottom:
      L10n.PreferencesQuickAccess.slotCenterBottom
    case .topTrailing:
      L10n.PreferencesQuickAccess.slotTopRight
    case .topLeading:
      L10n.PreferencesQuickAccess.slotTopLeft
    case .bottomLeading:
      L10n.PreferencesQuickAccess.slotBottomLeft
    case .bottomTrailing:
      L10n.PreferencesQuickAccess.slotBottomRight
    }
  }
}

enum QuickAccessActionKind: String, CaseIterable, Codable, Hashable, Identifiable {
  case copy
  case saveOrOpen
  case dismiss
  case delete
  case pinToScreen

  var id: String {
    rawValue
  }

  static let defaultOrder: [QuickAccessActionKind] = [
    .copy,
    .saveOrOpen,
    .dismiss,
    .delete,
    .pinToScreen,
  ]

  static let defaultEnabledActions = Set(defaultOrder)

  var displayStyle: QuickAccessActionDisplayStyle {
    switch self {
    case .copy, .saveOrOpen:
      .primary
    case .dismiss, .delete, .pinToScreen:
      .corner
    }
  }

  var settingsTitle: String {
    switch self {
    case .copy:
      L10n.Common.copy
    case .saveOrOpen:
      L10n.PreferencesQuickAccess.saveOrOpenAction
    case .dismiss:
      L10n.Common.close
    case .delete:
      L10n.Common.deleteAction
    case .pinToScreen:
      L10n.PreferencesQuickAccess.pinToScreenAction
    }
  }

  var settingsPlacementTitle: String {
    switch displayStyle {
    case .primary:
      L10n.PreferencesQuickAccess.primaryActionBadge
    case .corner:
      L10n.PreferencesQuickAccess.cornerActionBadge
    }
  }

  var isContextMenuDestructiveGroup: Bool {
    switch self {
    case .dismiss, .delete:
      true
    case .copy, .saveOrOpen, .pinToScreen:
      false
    }
  }

  static func contextMenuOrder(from actions: [QuickAccessActionKind]) -> [QuickAccessActionKind] {
    let regularActions = actions.filter { !$0.isContextMenuDestructiveGroup }
    let destructiveActions = actions.filter(\.isContextMenuDestructiveGroup)
    return regularActions + destructiveActions
  }

  var systemImage: String {
    switch self {
    case .copy:
      "doc.on.doc"
    case .saveOrOpen:
      "square.and.arrow.down"
    case .dismiss:
      "xmark"
    case .delete:
      "trash"
    case .pinToScreen:
      "pin"
    }
  }
}
