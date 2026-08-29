//
//  RecordingTranscriptWindow.swift
//  ShotPaste
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RecordingTranscriptViewModel: ObservableObject {
  enum Phase: Equatable {
    case processing
    case completed(String)
    case failed(String)
  }

  @Published var phase: Phase = .processing
  @Published var statusMessage: String?

  var transcript: String? {
    guard case let .completed(text) = phase else { return nil }
    return text
  }
}

@MainActor
final class RecordingTranscriptWindowController: NSWindowController, NSWindowDelegate {
  let id = UUID()

  private let recordingURL: URL
  private let configuration: RecordingTranscriptionConfiguration
  private let service: VolcengineRecordingTranscriptionService
  private let model = RecordingTranscriptViewModel()
  private var transcriptionTask: Task<Void, Never>?
  var onClose: (() -> Void)?

  init(
    recordingURL: URL,
    configuration: RecordingTranscriptionConfiguration,
    service: VolcengineRecordingTranscriptionService = .init()
  ) {
    self.recordingURL = recordingURL
    self.configuration = configuration
    self.service = service

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = L10n.RecordingTranscription.windowTitle
    window.minSize = NSSize(width: 520, height: 360)
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)

    window.delegate = self
    window.contentView = NSHostingView(
      rootView: RecordingTranscriptView(
        model: model,
        onCopy: { [weak self] in self?.copyTranscript() },
        onSave: { [weak self] in self?.saveTranscript() },
        onClose: { [weak self] in self?.close() }
      )
    )
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    startTranscription()
  }

  func windowWillClose(_: Notification) {
    transcriptionTask?.cancel()
    transcriptionTask = nil
    onClose?()
  }

  private func startTranscription() {
    transcriptionTask?.cancel()
    model.phase = .processing
    model.statusMessage = nil
    transcriptionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let transcript = try await service.transcribe(
          recordingURL: recordingURL,
          configuration: configuration
        )
        try Task.checkCancellation()
        model.phase = .completed(transcript.text)
      } catch is CancellationError {
        return
      } catch {
        model.phase = .failed(
          (error as? LocalizedError)?.errorDescription ?? L10n.RecordingTranscription.connectionFailed
        )
      }
    }
  }

  private func copyTranscript() {
    guard let transcript = model.transcript else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.setString(transcript, forType: .string) else { return }
    model.statusMessage = L10n.RecordingTranscription.copied
  }

  private func saveTranscript() {
    guard let transcript = model.transcript, let window else { return }
    let panel = NSSavePanel()
    panel.title = L10n.RecordingTranscription.savePanelTitle
    panel.prompt = L10n.RecordingTranscription.saveButton
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = recordingURL
      .deletingPathExtension()
      .lastPathComponent + "-transcript.txt"
    panel.directoryURL = recordingURL.deletingLastPathComponent()
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let destination = panel.url else { return }
      do {
        try transcript.write(to: destination, atomically: true, encoding: .utf8)
        self?.model.statusMessage = L10n.RecordingTranscription.saved(destination.lastPathComponent)
      } catch {
        self?.model.statusMessage = L10n.RecordingTranscription.saveFailed
      }
    }
  }
}

@MainActor
enum RecordingTranscriptWindowManager {
  private static var controllers: [UUID: RecordingTranscriptWindowController] = [:]

  static func presentIfConfigured(recordingURL: URL) {
    guard let configuration = RecordingTranscriptionConfiguration.current() else { return }
    let controller = RecordingTranscriptWindowController(
      recordingURL: recordingURL,
      configuration: configuration
    )
    controllers[controller.id] = controller
    controller.onClose = { [id = controller.id] in
      controllers.removeValue(forKey: id)
    }
    controller.present()
  }
}

private struct RecordingTranscriptView: View {
  @ObservedObject var model: RecordingTranscriptViewModel
  let onCopy: () -> Void
  let onSave: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      Group {
        switch model.phase {
        case .processing:
          processingView
        case let .completed(text):
          transcriptView(text)
        case let .failed(message):
          failureView(message)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      footer
    }
    .padding(22)
    .frame(minWidth: 520, minHeight: 360)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "text.bubble.fill")
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 42, height: 42)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

      VStack(alignment: .leading, spacing: 3) {
        Text(headerTitle)
          .font(.title3.weight(.semibold))
        Text(headerDescription)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var headerTitle: String {
    switch model.phase {
    case .processing: L10n.RecordingTranscription.processingTitle
    case .completed: L10n.RecordingTranscription.completedTitle
    case .failed: L10n.RecordingTranscription.failedTitle
    }
  }

  private var headerDescription: String {
    switch model.phase {
    case .processing: L10n.RecordingTranscription.processingDescription
    case .completed: L10n.RecordingTranscription.completedDescription
    case .failed: L10n.RecordingTranscription.failedDescription
    }
  }

  private var processingView: some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text(L10n.RecordingTranscription.processingPrivacyNote)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    }
  }

  private func transcriptView(_ text: String) -> some View {
    ScrollView {
      Text(text)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
    }
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
    )
  }

  private func failureView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 28))
        .foregroundStyle(.orange)
      Text(message)
        .font(.body)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: 460)
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if let statusMessage = model.statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button(L10n.Common.close, action: onClose)
      Button(L10n.Common.copy, action: onCopy)
        .disabled(model.transcript == nil)
      Button(L10n.RecordingTranscription.saveButton, action: onSave)
        .keyboardShortcut(.defaultAction)
        .disabled(model.transcript == nil)
    }
  }
}
