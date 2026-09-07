import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TranscriptionResultsModel: ObservableObject {
  static let shared = TranscriptionResultsModel()
  @Published private(set) var results: [TranscriptionResultSummary] = []
  @Published private(set) var artifacts: [TranscriptionArtifact] = []
  @Published var selectedID: TranscriptionResultID? {
    didSet {
      if oldValue != selectedID { artifacts = []; selectedArtifact = .raw; message = nil }
    }
  }
  @Published var selectedArtifact: TranscriptionArtifactKind = .raw
  @Published var search = ""
  @Published var filter = 0
  @Published var message: String?
  @Published private(set) var actions: Set<TranscriptionResultID> = []
  @Published private var historyLinks: [UUID: TranscriptionResultID] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var startingURLs: Set<URL> = []
  private var pendingMediaURL: URL?
  private var refreshing = false
  private let repository: TranscriptionResultsRepository

  init(repository: TranscriptionResultsRepository = .shared) { self.repository = repository }

  var filteredResults: [TranscriptionResultSummary] {
    results.filter {
      (filter == 0 || (filter == 1 && $0.isAudio) || (filter == 2 && !$0.isAudio))
        && (search.isEmpty || ($0.title + " " + $0.date.formatted(date: .numeric, time: .shortened))
          .localizedStandardContains(search))
    }
  }
  var selected: TranscriptionResultSummary? { results.first { $0.id == selectedID } }
  var artifact: TranscriptionArtifact? { artifacts.first { $0.id == selectedArtifact } }

  func resultID(for record: CaptureHistoryRecord) -> TranscriptionResultID? {
    guard record.captureType == .audio || record.captureType == .video || record.captureType == .file else { return nil }
    if let id = historyLinks[record.id], results.contains(where: { $0.id == id }) { return id }
    return results.first { $0.matches(historyID: record.id, mediaURL: record.fileURL) }?.id
  }

  func focus(_ id: TranscriptionResultID? = nil, mediaURL: URL? = nil) {
    search = ""; filter = 0; message = nil
    pendingMediaURL = mediaURL
    if id != nil || mediaURL != nil { selectedID = id; artifacts = []; selectedArtifact = .raw }
    Task { await refresh() }
  }

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let next = await repository.summaries()
    let links = await repository.historyLinks()
    if links != historyLinks { historyLinks = links }
    if next != results { results = next }
    if let url = pendingMediaURL,
       let match = results.first(where: { $0.mediaURLs.contains(url) }) {
      selectedID = match.id; pendingMediaURL = nil
    }
    if selectedID == nil, pendingMediaURL == nil { selectedID = filteredResults.first?.id }
    await loadSelection()
  }

  func loadSelection() async {
    guard let id = selectedID else { artifacts = []; return }
    let next = await repository.artifacts(for: id)
    guard selectedID == id else { return }
    if next != artifacts { artifacts = next }
  }

  func startVideo(url: URL, configuration: RecordingTranscriptionConfiguration, automaticAI: Bool) {
    guard startingURLs.insert(url).inserted else { return }
    let token = UUID()
    tasks[token] = Task {
      defer { startingURLs.remove(url); tasks[token] = nil }
      do {
        _ = try await VolcengineRecordingTranscriptionService().transcribe(
          recordingURL: url, configuration: configuration, automaticAI: automaticAI)
      } catch is CancellationError { /* Durable cancellation is shown in the list. */ }
      catch { message = (error as? LocalizedError)?.errorDescription ?? L10n.TranscriptionResults.failed }
      await refresh()
    }
  }

  func retry(_ id: TranscriptionResultID, processAI: Bool = false, resubmit: Bool = false) {
    guard actions.insert(id).inserted else { return }
    let token = UUID()
    tasks[token] = Task {
      defer { actions.remove(id); tasks[token] = nil }
      do {
        if resubmit { try await repository.resubmit(id) }
        else { try await repository.retry(id, processAI: processAI) }
      }
      catch { message = (error as? LocalizedError)?.errorDescription ?? L10n.RecordingTranscription.processingFailed }
      await refresh()
    }
  }

  func cancel(_ id: TranscriptionResultID) {
    Task {
      do { try await repository.cancel(id) }
      catch { message = L10n.TranscriptionResults.failed }
      await refresh()
    }
  }

  func copy() {
    guard let artifact else { return }
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(artifact.text, forType: .string) {
      message = L10n.Common.copiedToClipboard
    }
  }

  func save(in window: NSWindow?) {
    guard let artifact, let selected, let window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    let base = selected.isAudio
      ? "audio-" + selected.date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
      : (selected.mediaURLs.first?.deletingPathExtension().lastPathComponent ?? "transcript")
    panel.nameFieldStringValue = base + "-" + artifact.id.rawValue + ".txt"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try artifact.exportText.write(to: url, atomically: true, encoding: .utf8)
        self?.message = L10n.RecordingTranscription.saved(url.lastPathComponent)
      } catch { self?.message = L10n.RecordingTranscription.saveFailed }
    }
  }
}

@MainActor
final class TranscriptionResultsWindowController: NSWindowController, NSWindowDelegate {
  static let shared = TranscriptionResultsWindowController()
  private var polling: Task<Void, Never>?

  private init() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = L10n.TranscriptionResults.title
    window.minSize = NSSize(width: 820, height: 520)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("TranscriptionResults")
    window.center()
    super.init(window: window)
    window.delegate = self
    window.contentView = NSHostingView(rootView: TranscriptionResultsView(model: .shared,
      onSave: { [weak window] in TranscriptionResultsModel.shared.save(in: window) }))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(_ id: TranscriptionResultID? = nil, mediaURL: URL? = nil) {
    TranscriptionResultsModel.shared.focus(id, mediaURL: mediaURL)
    HistoryFloatingManager.shared.hide()
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    polling?.cancel()
    polling = Task {
      while !Task.isCancelled {
        await TranscriptionResultsModel.shared.refresh()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
  }

  func windowWillClose(_ notification: Notification) { polling?.cancel(); polling = nil }
}

private struct TranscriptionResultsView: View {
  @ObservedObject var model: TranscriptionResultsModel
  @ObservedObject private var theme = ThemeManager.shared
  @State private var pendingResubmission: TranscriptionResultID?
  let onSave: () -> Void

  var body: some View {
    HSplitView {
      sidebar.frame(minWidth: 270, idealWidth: 310, maxWidth: 390)
      detail.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }
    .preferredColorScheme(theme.systemAppearance)
    .onChange(of: model.selectedID) { _ in
      model.selectedArtifact = .raw
      model.message = nil
      Task { await model.loadSelection() }
    }
    .onChange(of: model.filter) { _ in selectVisibleResult() }
    .onChange(of: model.search) { _ in selectVisibleResult() }
    .alert(L10n.CloudTranscription.resubmit, isPresented: Binding(
      get: { pendingResubmission != nil },
      set: { if !$0 { pendingResubmission = nil } }), presenting: pendingResubmission) { id in
      Button(L10n.CloudTranscription.resubmit) { model.retry(id, resubmit: true) }
      Button(L10n.Common.cancel, role: .cancel) {}
    } message: { _ in Text(L10n.CloudTranscription.uncertain) }
  }

  private func selectVisibleResult() {
    if !model.filteredResults.contains(where: { $0.id == model.selectedID }) {
      model.selectedID = model.filteredResults.first?.id
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(L10n.TranscriptionResults.title, systemImage: "text.bubble").font(.headline)
        Spacer()
        Text("\(model.filteredResults.count)").foregroundStyle(.secondary).monospacedDigit()
      }
      TextField(L10n.TranscriptionResults.search, text: $model.search).textFieldStyle(.roundedBorder)
      Picker(L10n.TranscriptionResults.filter, selection: $model.filter) {
        Text(L10n.TranscriptionResults.all).tag(0)
        Text(L10n.TranscriptionResults.audio).tag(1)
        Text(L10n.TranscriptionResults.video).tag(2)
      }.pickerStyle(.segmented)
      if model.filteredResults.isEmpty {
        Spacer()
        Text(model.results.isEmpty ? L10n.TranscriptionResults.empty : L10n.TranscriptionResults.noMatches)
          .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        Spacer()
      } else {
        List(selection: $model.selectedID) {
          ForEach(model.filteredResults) { result in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: result.isAudio ? "waveform" : "video")
                .font(.title3).foregroundStyle(Color.accentColor).frame(width: 25)
              VStack(alignment: .leading, spacing: 6) {
                Text(result.title).font(.body.weight(.medium)).lineLimit(2)
                Text(result.date, format: .dateTime.year().month().day().hour().minute())
                  .font(.caption).foregroundStyle(.secondary)
                Text(result.status).font(.caption)
                  .foregroundStyle(result.stage == .failed ? Color.orange : Color.secondary)
              }
            }.padding(.vertical, 8).tag(result.id).accessibilityElement(children: .combine)
          }
        }.listStyle(.sidebar)
      }
      Button(L10n.Actions.openHistory) { HistoryFloatingManager.shared.showClipboardHistory() }
        .buttonStyle(.plain).foregroundStyle(.secondary)
    }.padding(16).background(.regularMaterial)
  }

  @ViewBuilder private var detail: some View {
    if let result = model.selected {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(result.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(result.date, format: .dateTime.year().month().day().hour().minute())
              .font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
          if let url = result.mediaURLs.first, FileManager.default.fileExists(atPath: url.path) {
            Button(L10n.Common.openInFinder) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        }
        HStack {
          if result.isRunning || model.actions.contains(result.id) { ProgressView().controlSize(.small) }
          Text(result.status).font(.callout).foregroundStyle(.secondary)
          Spacer()
          if result.isRunning && result.stage != .polishing && result.stage != .organizing {
            Button(L10n.Common.cancel) { model.cancel(result.id) }
          } else if result.stage == .failed || result.stage == .waitingForModel {
            if result.requiresResubmission {
              Button(L10n.CloudTranscription.resubmit) { pendingResubmission = result.id }
                .disabled(model.actions.contains(result.id))
            } else {
              Button(L10n.CloudTranscription.resume) { model.retry(result.id) }
                .disabled(model.actions.contains(result.id))
            }
          }
          if model.artifacts.contains(where: { $0.id == .raw }) && !result.isRunning
            && !model.artifacts.contains(where: { $0.id == .polished }) {
            Button(L10n.TranscriptionResults.processAI) { model.retry(result.id, processAI: true) }
              .disabled(model.actions.contains(result.id))
          }
        }
        Picker(L10n.TranscriptionResults.artifact, selection: $model.selectedArtifact) {
          ForEach(TranscriptionArtifactKind.allCases) { kind in Text(kind.title).tag(kind) }
        }.pickerStyle(.segmented)
        if let artifact = model.artifact {
          ScrollView {
            Text(artifact.exportText.isEmpty ? L10n.RecordingTranscription.emptyTranscript : artifact.exportText)
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
          }
          .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.16)))
          .id("\(String(describing: result.id))-\(artifact.id.rawValue)")
        } else {
          VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(result.isRunning ? L10n.TranscriptionResults.processingNote : L10n.TranscriptionResults.unavailable)
              .foregroundStyle(.secondary).multilineTextAlignment(.center)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        HStack {
          Text(model.message ?? L10n.TranscriptionResults.savedLocally)
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          Spacer()
          Button(L10n.Common.copy) { model.copy() }.keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.artifact == nil)
          Button(L10n.RecordingTranscription.saveButton, action: onSave).keyboardShortcut("s")
            .disabled(model.artifact == nil)
        }
      }.padding(24)
    } else {
      VStack(spacing: 14) {
        Image(systemName: "text.bubble").font(.system(size: 40)).foregroundStyle(.secondary)
        Text(L10n.TranscriptionResults.title).font(.title2.weight(.semibold))
        Text(model.message ?? L10n.TranscriptionResults.empty)
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
      }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
