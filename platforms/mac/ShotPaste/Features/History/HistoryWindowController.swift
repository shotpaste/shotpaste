//
//  HistoryWindowController.swift
//  ShotPaste
//
//  Manages the capture history browser window lifecycle
//

import AppKit

extension Notification.Name {
  static let historyCopySelection = Notification.Name("historyCopySelection")
  static let historyActivateSelection = Notification.Name("historyActivateSelection")
  static let historyDeleteSelection = Notification.Name("historyDeleteSelection")
  static let historySelectAll = Notification.Name("historySelectAll")
  static let historyMoveSelection = Notification.Name("historyMoveSelection")
}

enum HistorySelectionMove {
  case left
  case right
  case up
  case down
}

enum HistorySelectionNavigation {
  static func destinationIndex(
    from currentIndex: Int,
    move: HistorySelectionMove,
    itemCount: Int,
    columnCount: Int
  ) -> Int? {
    guard itemCount > 0 else { return nil }
    let safeColumnCount = max(columnCount, 1)
    let delta: Int = switch move {
    case .left: -1
    case .right: 1
    case .up: -safeColumnCount
    case .down: safeColumnCount
    }
    return min(max(currentIndex + delta, 0), itemCount - 1)
  }
}

struct HistoryDeletionResult: Equatable {
  let requestedCount: Int
  let deletedCount: Int
  let failedCount: Int
}

final class HistoryWindow: NSWindow {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else {
      return super.performKeyEquivalent(with: event)
    }

    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if event.keyCode == 8, flags == .command {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }

      NotificationCenter.default.post(name: .historyCopySelection, object: self)
      return true
    }

    if event.keyCode == 0, flags == .command {
      if isTextInputActive {
        return super.performKeyEquivalent(with: event)
      }

      NotificationCenter.default.post(name: .historySelectAll, object: self)
      return true
    }

    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if !isTextInputActive, flags.isEmpty, [51, 117].contains(event.keyCode) {
      NotificationCenter.default.post(name: .historyDeleteSelection, object: self)
      return
    }

    super.keyDown(with: event)
  }

  private var isTextInputActive: Bool {
    guard let responder = firstResponder else { return false }
    return responder is NSTextView || responder is NSTextField
  }
}

/// Manages the capture history browser window
@MainActor
final class HistoryWindowController {
  static let shared = HistoryWindowController()

  private init() {}

  func showWindow() {
    DiagnosticLogger.shared.log(.info, .history, "History window requested")
    HistoryFloatingManager.shared.showDefaultHistory()
    NSApp.activate(ignoringOtherApps: true)
  }

  func hideWindow() {
    DiagnosticLogger.shared.log(.debug, .history, "History window hide requested")
    HistoryFloatingManager.shared.hide()
  }

  func copyToClipboard(_ records: [CaptureHistoryRecord]) {
    let existingRecords = records.filter(\.fileExists)
    guard !existingRecords.isEmpty else {
      DiagnosticLogger.shared.log(
        .warning,
        .clipboard,
        "History clipboard copy skipped; no existing files",
        context: ["requestedCount": "\(records.count)"]
      )
      return
    }

    if existingRecords.count == 1, let record = existingRecords.first {
      switch record.captureType {
      case .screenshot, .gif:
        ClipboardHelper.copyImage(from: record.fileURL)
      case .video:
        ClipboardHelper.copyMediaFile(from: record.fileURL)
      case .text:
        ClipboardHelper.copyText(record.textContent ?? "")
      case .file:
        ClipboardHelper.copyFileURLs([record.fileURL])
      }
    } else {
      ClipboardHelper.copyFileURLs(existingRecords.map(\.fileURL))
    }

    AppToastManager.shared.show(
      message: L10n.Common.copiedToClipboard,
      style: .success,
      duration: 1.6,
      variant: .compact
    )
    DiagnosticLogger.shared.log(
      .info,
      .clipboard,
      "History copied selection to clipboard",
      context: [
        "requestedCount": "\(records.count)",
        "copiedCount": "\(existingRecords.count)",
        "multiItem": existingRecords.count > 1 ? "true" : "false",
      ]
    )
  }

  func openItem(_ record: CaptureHistoryRecord) {
    guard record.fileExists else {
      DiagnosticLogger.shared.log(
        .warning,
        .history,
        "History open skipped; file missing",
        context: ["fileName": record.fileName, "type": record.captureType.rawValue]
      )
      return
    }

    HistoryFloatingManager.shared.hide()

    if record.captureType == .text || record.captureType == .file {
      NSWorkspace.shared.open(record.fileURL)
      return
    }

    Task { @MainActor in
      guard let item = await QuickAccessManager.shared.restoreHistoryItem(record) else {
        return
      }

      switch record.captureType {
      case .text, .file:
        break
      case .screenshot:
        DiagnosticLogger.shared.log(
          .info,
          .history,
          "History opening screenshot in default application",
          context: ["fileName": record.fileName, "itemId": item.id.uuidString]
        )
        NSWorkspace.shared.open(record.fileURL)
      case .video, .gif:
        DiagnosticLogger.shared.log(
          .info,
          .history,
          "History opening media through quick access",
          context: [
            "fileName": record.fileName,
            "type": record.captureType.rawValue,
            "itemId": item.id.uuidString,
          ]
        )
        NSWorkspace.shared.open(record.fileURL)
      }
    }
  }

  @discardableResult
  func deleteRecords(
    _ records: [CaptureHistoryRecord],
    asksConfirmation: Bool,
    completion: ((HistoryDeletionResult) -> Void)? = nil
  ) -> Bool {
    let recordsToDelete = uniqueRecords(records)
    guard !recordsToDelete.isEmpty else { return false }

    if asksConfirmation {
      let isConfirmed = HistoryFloatingManager.shared.performModalInteraction {
        confirmDelete(records: recordsToDelete)
      }
      guard isConfirmed else {
        DiagnosticLogger.shared.log(
          .debug,
          .history,
          "History delete cancelled by user",
          context: ["recordCount": "\(recordsToDelete.count)"]
        )
        return false
      }
    }

    Task { @MainActor in
      var recyclableRecords: [CaptureHistoryRecord] = []
      var recordIDsReadyForRemoval: [UUID] = []

      for record in recordsToDelete {
        guard FileManager.default.fileExists(atPath: record.filePath) else {
          recordIDsReadyForRemoval.append(record.id)
          continue
        }

        let fileAccess = SandboxFileAccessManager.shared.beginAccessingURL(record.fileURL)
        let directoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(
          record.fileURL.deletingLastPathComponent()
        )
        let recycleError = await recycleFile(record.fileURL)
        fileAccess.stop()
        directoryAccess.stop()

        if let recycleError {
          DiagnosticLogger.shared.logError(
            .fileAccess,
            recycleError,
            "History recycle file failed",
            context: ["fileName": record.fileName]
          )
        } else {
          recyclableRecords.append(record)
          recordIDsReadyForRemoval.append(record.id)
        }
      }

      let removedCount = CaptureHistoryStore.shared.remove(ids: recordIDsReadyForRemoval)
      let failedCount = recordsToDelete.count - removedCount

      if removedCount > 0 {
        AppToastManager.shared.show(
          message: L10n.PreferencesHistory.deletedCaptures(removedCount),
          style: failedCount == 0 ? .success : .warning,
          duration: 1.7,
          variant: .compact
        )
      }
      if failedCount > 0 {
        AppToastManager.shared.show(
          message: L10n.PreferencesHistory.deleteFailed(failedCount),
          style: .error,
          duration: 4
        )
      }

      DiagnosticLogger.shared.log(
        failedCount == 0 ? .info : .warning,
        .history,
        "History deletion transaction completed",
        context: [
          "requestedCount": "\(recordsToDelete.count)",
          "removedCount": "\(removedCount)",
          "failedCount": "\(failedCount)",
          "recycledFileCount": "\(recyclableRecords.count)",
        ]
      )
      completion?(HistoryDeletionResult(
        requestedCount: recordsToDelete.count,
        deletedCount: removedCount,
        failedCount: failedCount
      ))
    }
    return true
  }

  @discardableResult
  func clearAllRecords(
    completion: ((HistoryDeletionResult) -> Void)? = nil
  ) -> Bool {
    let records = CaptureHistoryStore.shared.records
    guard !records.isEmpty else { return false }

    let isConfirmed = HistoryFloatingManager.shared.performModalInteraction {
      confirmClearAllHistory()
    }
    guard isConfirmed else {
      DiagnosticLogger.shared.log(
        .debug,
        .history,
        "Clear all history cancelled by user",
        context: ["recordCount": "\(records.count)"]
      )
      return false
    }

    return deleteRecords(records, asksConfirmation: false, completion: completion)
  }

  private func recycleFile(_ url: URL) async -> Error? {
    await withCheckedContinuation { continuation in
      NSWorkspace.shared.recycle([url]) { _, error in
        continuation.resume(returning: error)
      }
    }
  }

  private func uniqueRecords(_ records: [CaptureHistoryRecord]) -> [CaptureHistoryRecord] {
    var seenIds = Set<UUID>()
    return records.filter { record in
      seenIds.insert(record.id).inserted
    }
  }

  private func confirmDelete(records: [CaptureHistoryRecord]) -> Bool {
    let alert = NSAlert()
    alert.messageText = L10n.PreferencesHistory.deleteSelectedAlertTitle
    alert.informativeText = L10n.PreferencesHistory.deleteSelectedAlertMessage(records.count)
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.Common.moveToTrash)
    alert.addButton(withTitle: L10n.Common.cancel)

    return alert.runModal() == .alertFirstButtonReturn
  }

  private func confirmClearAllHistory() -> Bool {
    let alert = NSAlert()
    alert.messageText = L10n.PreferencesHistory.clearHistoryAlertTitle
    alert.informativeText = L10n.PreferencesHistory.clearHistoryAlertMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.PreferencesHistory.clearHistoryConfirm)
    alert.addButton(withTitle: L10n.Common.cancel)

    return alert.runModal() == .alertFirstButtonReturn
  }
}
