import AppKit

/// Capture routes to one results page; closing it keeps tasks running.
@MainActor
enum RecordingTranscriptWindowManager {
  static func presentSaved(_ work: VolcengineRecordingWork, processAI: Bool = false) {
    TranscriptionResultsWindowController.shared.show(.video(work.id))
    if processAI { TranscriptionResultsModel.shared.retry(.video(work.id), processAI: true) }
  }

  static func presentIfConfigured(recordingURL: URL, options: OneShotRecordingOptions) {
    guard let configuration = RecordingTranscriptionConfiguration.current(for: options) else { return }
    TranscriptionResultsWindowController.shared.show(mediaURL: recordingURL)
    TranscriptionResultsModel.shared.startVideo(url: recordingURL, configuration: configuration,
      automaticAI: options.shouldProcessTranscriptWithAI)
  }
}
