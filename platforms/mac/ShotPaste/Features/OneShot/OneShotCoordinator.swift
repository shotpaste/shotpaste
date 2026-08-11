//
//  OneShotCoordinator.swift
//  ShotPaste
//
//  Owns the shared frozen selection session and hands committed modes to the
//  existing screenshot, scrolling-capture, recording, and history flows.
//

import AppKit
import Combine

struct OneShotScrollingConfiguration {
  let saveDirectory: URL
  let format: ImageFormat
  let prefetchedContentTask: ShareableContentPrefetchTask?
}

enum OneShotHandoff {
  case scrolling(rect: CGRect)
  case recording(rect: CGRect, options: OneShotRecordingOptions)
  case ocr(image: CGImage)
  case clipboard
}

@MainActor
final class OneShotCoordinator: ObservableObject {
  static let shared = OneShotCoordinator()

  @Published private(set) var isActive = false
  private(set) var sessionState: OneShotSessionState?

  private var onTeardown: (() -> Void)?
  private var onOCRImage: ((CGImage) -> Void)?
  private var resolveScrollingConfiguration: (() -> OneShotScrollingConfiguration?)?

  private init() {}

  @discardableResult
  func beginPreparation(
    switcherDisplayID: CGDirectDisplayID,
    switcherX: CGFloat,
    onTeardown: @escaping () -> Void,
    onOCRImage: @escaping (CGImage) -> Void,
    resolveScrollingConfiguration: @escaping () -> OneShotScrollingConfiguration?
  ) -> OneShotSessionState? {
    guard !isActive,
          !RecordingCoordinator.shared.isActive,
          !ScrollingCaptureCoordinator.shared.isActive,
          !InlineAreaAnnotateCoordinator.shared.isActive
    else {
      AppToastManager.shared.show(
        message: L10n.OneShot.sessionAlreadyActive,
        style: .warning,
        position: .bottomCenter
      )
      return nil
    }

    let state = OneShotSessionState()
    state.beginPreparing(switcherDisplayID: switcherDisplayID, switcherX: switcherX)
    sessionState = state
    self.onTeardown = onTeardown
    self.onOCRImage = onOCRImage
    self.resolveScrollingConfiguration = resolveScrollingConfiguration
    isActive = true
    QuickAccessManager.shared.suspendForCapture()
    DiagnosticLogger.shared.log(.info, .action, "One Shot preparation started")
    return state
  }

  func start(
    state: OneShotSessionState,
    screens: [NSScreen],
    primaryDisplayID: CGDirectDisplayID,
    backdrops: [CGDirectDisplayID: AreaSelectionBackdrop],
    frozenSession: FrozenAreaCaptureSession,
    outputFormat: ImageFormat,
    context: CaptureContext,
    resolveScreenshotSaveDirectory: @escaping () -> URL?
  ) {
    guard isActive, sessionState === state else {
      frozenSession.invalidate()
      return
    }

    state.arm(frozenDisplayIDs: frozenSession.displayIDs)
    DiagnosticLogger.shared.log(
      .info,
      .action,
      "One Shot armed",
      context: ["displayCount": "\(frozenSession.displayIDs.count)"]
    )
    InlineAreaAnnotateCoordinator.shared.startOneShot(
      screens: screens,
      primaryDisplayID: primaryDisplayID,
      backdrops: backdrops,
      frozenSession: frozenSession,
      outputFormat: outputFormat,
      context: context,
      oneShotState: state,
      resolveSaveDirectory: resolveScreenshotSaveDirectory,
      onHandoff: { [weak self] handoff in
        self?.handle(handoff)
      },
      onComplete: { [weak self] result in
        self?.finish(result: result)
      }
    )
  }

  func failPreparation(_ error: CaptureError) {
    finish(result: .failure(error))
  }

  func cancel() {
    guard isActive else { return }
    if InlineAreaAnnotateCoordinator.shared.isActive {
      InlineAreaAnnotateCoordinator.shared.cancelActiveSession()
    } else {
      finish(result: .failure(.cancelled))
    }
  }

  private func handle(_ handoff: OneShotHandoff) {
    guard isActive, let state = sessionState else { return }

    switch handoff {
    case .scrolling(let rect):
      DiagnosticLogger.shared.log(.info, .action, "One Shot handing off to scrolling capture")
      guard let configuration = resolveScrollingConfiguration?() else {
        finish(result: .failure(.saveFailed(L10n.ScreenCapture.saveLocationPermissionRequired)))
        return
      }
      ScrollingCaptureCoordinator.shared.beginSession(
        rect: rect,
        saveDirectory: configuration.saveDirectory,
        format: configuration.format,
        prefetchedContentTask: configuration.prefetchedContentTask,
        onSessionEnded: { [weak self] in
          self?.finish(result: nil)
        }
      )

    case .recording(let rect, let options):
      DiagnosticLogger.shared.log(.info, .action, "One Shot handing off to recording")
      RecordingCoordinator.shared.startOneShotRecording(
        for: rect,
        options: options,
        onSessionEnded: { [weak self] in
          self?.finish(result: nil)
        }
      )

    case .ocr(let image):
      DiagnosticLogger.shared.log(.info, .ocr, "One Shot handing off selected image to OCR")
      let processOCR = onOCRImage
      state.beginTerminating(clearSelection: true)
      finish(result: nil) {
        processOCR?(image)
      }

    case .clipboard:
      DiagnosticLogger.shared.log(.info, .action, "One Shot handing off to clipboard history")
      state.beginTerminating(clearSelection: true)
      finish(result: nil) {
        HistoryFloatingManager.shared.showExpandedAll()
      }
    }
  }

  private func finish(result _: CaptureResult?, afterTeardown: (() -> Void)? = nil) {
    guard isActive else { return }
    let state = sessionState
    state?.beginTerminating()
    guard state?.performTeardown() ?? true else { return }

    QuickAccessManager.shared.resumeAfterCapture()
    let teardown = onTeardown
    onTeardown = nil
    onOCRImage = nil
    resolveScrollingConfiguration = nil
    sessionState = nil
    isActive = false
    DiagnosticLogger.shared.log(.info, .action, "One Shot session cleaned up")

    teardown?()
    afterTeardown?()
  }
}
