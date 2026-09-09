//
//  HistoryContextMenu.swift
//  ShotPaste
//
//  Context menu for history items
//

import SwiftUI

struct HistoryContextMenu: View {
  let record: CaptureHistoryRecord
  @ObservedObject private var transcriptionResults = TranscriptionResultsModel.shared

  var body: some View {
    if let id = transcriptionResults.resultID(for: record) {
      Button(L10n.TranscriptionResults.view) { TranscriptionResultsWindowController.shared.show(id) }
      Divider()
    }
    Button(L10n.Common.openInFinder) {
      NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
    }

    Button(L10n.Common.copy) {
      HistoryWindowController.shared.copyToClipboard([record])
    }

    Button(L10n.Common.open) {
      HistoryWindowController.shared.openItem(record)
    }

    Divider()

    Button(L10n.Common.deleteAction) {
      HistoryWindowController.shared.deleteRecords([record], asksConfirmation: true)
    }
  }
}
