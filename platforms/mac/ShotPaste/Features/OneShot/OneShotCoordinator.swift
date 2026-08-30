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

struct OneShotGuidancePolicy {
  static let currentVersion = 1

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func consumePresentationIfNeeded() -> Bool {
    let presentedVersion = defaults.integer(forKey: PreferencesKeys.oneShotGuidancePresentedVersion)
    guard presentedVersion < Self.currentVersion else { return false }
    defaults.set(Self.currentVersion, forKey: PreferencesKeys.oneShotGuidancePresentedVersion)
    return true
  }
}

@MainActor
final class OneShotCoordinator: ObservableObject {
  static let shared = OneShotCoordinator()

  @Published private(set) var isActive = false
  private(set) var sessionState: OneShotSessionState?

  private var onTeardown: (() -> Void)?
  private var onOCRImage: ((CGImage) -> Void)?
  private var resolveScrollingConfiguration: (() -> OneShotScrollingConfiguration?)?
  private var interactionLease: InteractionLeaseCoordinator.Lease?

  private init() {}

  @discardableResult
  func beginPreparation(
    switcherDisplayID: CGDirectDisplayID,
    switcherX: CGFloat,
    initialTab: OneShotTab = .screenshot,
    onTeardown: @escaping () -> Void,
    onOCRImage: @escaping (CGImage) -> Void,
    resolveScrollingConfiguration: @escaping () -> OneShotScrollingConfiguration?
  ) -> OneShotSessionState? {
    guard !isActive,
          !RecordingCoordinator.shared.isActive,
          !ScrollingCaptureCoordinator.shared.isActive,
          !InlineAreaAnnotateCoordinator.shared.isActive,
          let interactionLease = InteractionLeaseCoordinator.shared.acquire(.oneShot)
    else {
      AppToastManager.shared.show(
        message: L10n.OneShot.sessionAlreadyActive,
        style: .warning,
        position: .bottomCenter
      )
      return nil
    }

    let state = OneShotSessionState(initialTab: initialTab)
    state.beginPreparing(switcherDisplayID: switcherDisplayID, switcherX: switcherX)
    sessionState = state
    self.onTeardown = onTeardown
    self.onOCRImage = onOCRImage
    self.resolveScrollingConfiguration = resolveScrollingConfiguration
    self.interactionLease = interactionLease
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
    if OneShotGuidancePolicy().consumePresentationIfNeeded() {
      AppToastManager.shared.show(
        message: L10n.OneShot.shortcutDescription,
        style: .info,
        position: .topCenter,
        duration: 5
      )
    }
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

  @discardableResult
  func cancel(discardChanges: Bool = false) -> Bool {
    guard isActive else { return true }
    if InlineAreaAnnotateCoordinator.shared.isActive {
      return InlineAreaAnnotateCoordinator.shared.cancelActiveSession(discardChanges: discardChanges)
    } else {
      finish(result: .failure(.cancelled))
      return true
    }
  }

  private func handle(_ handoff: OneShotHandoff) {
    guard isActive, let state = sessionState else { return }

    switch handoff {
    case .scrolling(let rect):
      DiagnosticLogger.shared.log(.info, .action, "One Shot handing off to scrolling capture")
      transferInteractionLease(to: .scrollingCapture)
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
      transferInteractionLease(to: .recording)
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
        HistoryFloatingManager.shared.showClipboardHistory()
      }
    }
  }

  private func transferInteractionLease(to owner: InteractionLeaseCoordinator.Owner) {
    guard let interactionLease,
          let transferredLease = InteractionLeaseCoordinator.shared.transfer(
            interactionLease,
            to: owner
          )
    else {
      DiagnosticLogger.shared.log(
        .warning,
        .action,
        "One Shot interaction lease transfer failed",
        context: ["owner": owner.rawValue]
      )
      return
    }
    self.interactionLease = transferredLease
  }

  private func finish(result: CaptureResult?, afterTeardown: (() -> Void)? = nil) {
    guard isActive else { return }
    let failureMessage: String? = if case .failure(let error) = result {
      switch error {
      case .cancelled:
        nil
      default:
        error.localizedDescription
      }
    } else {
      nil
    }
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
    if let interactionLease {
      InteractionLeaseCoordinator.shared.release(interactionLease)
      self.interactionLease = nil
    }
    DiagnosticLogger.shared.log(.info, .action, "One Shot session cleaned up")

    teardown?()
    if let failureMessage {
      AppToastManager.shared.show(
        message: failureMessage,
        style: .error,
        position: .bottomCenter,
        duration: 4
      )
    }
    afterTeardown?()
  }
}
