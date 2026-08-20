//
//  ScreenCaptureManager.swift
//  ShotPaste
//
//  Core manager for screen capture functionality
//

import AppKit
import Combine
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import os.log
import ScreenCaptureKit

private let logger = Logger(subsystem: "ShotPaste", category: "ScreenCaptureManager")
typealias ShareableContentPrefetchTask = Task<SCShareableContent, Error>

private enum ShareableContentCacheMode: String {
  case standard
  case desktopInclusive = "desktop-inclusive"

  var includeDesktopWindows: Bool {
    self == .desktopInclusive
  }
}

private struct ShareableContentCacheEntry {
  let mode: ShareableContentCacheMode
  let task: ShareableContentPrefetchTask
}

/// Result type for capture operations
enum CaptureResult {
  case success(URL)
  case failure(CaptureError)
}

/// Errors that can occur during capture
enum CaptureError: Error, LocalizedError {
  case permissionDenied
  case unavailable(String)
  case noDisplayFound
  case captureFailed(String)
  case saveFailed(String)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      L10n.ScreenCapture.permissionDenied
    case .unavailable(let reason):
      reason
    case .noDisplayFound:
      L10n.ScreenCapture.noDisplayFound
    case .captureFailed(let reason):
      L10n.ScreenCapture.captureFailed(reason)
    case .saveFailed(let reason):
      L10n.ScreenCapture.saveFailed(reason)
    case .cancelled:
      L10n.ScreenCapture.cancelled
    }
  }
}

nonisolated enum ScreenRecordingPermissionStatus: Equatable {
  case notGranted
  case granted
  case grantedButUnavailableDueToAppIdentity(String)

  var diagnosticName: String {
    switch self {
    case .notGranted:
      "not-granted"
    case .granted:
      "granted"
    case .grantedButUnavailableDueToAppIdentity:
      "identity-blocked"
    }
  }
}

nonisolated enum ScreenCapturePermissionCheckSource: String {
  case initialization
  case applicationLaunch = "application-launch"
  case refresh
  case authorizationRequest = "authorization-request"
  case permissionReset = "permission-reset"

  var alwaysLogs: Bool {
    switch self {
    case .applicationLaunch, .authorizationRequest, .permissionReset:
      true
    case .initialization, .refresh:
      false
    }
  }
}

nonisolated struct ScreenRecordingAuthorizationLogSnapshot: Equatable {
  let rawSystemGranted: Bool
  let effectiveStatus: ScreenRecordingPermissionStatus
  let identityHealthy: Bool
  let identityIssueNames: [String]
  let resetOverrideActive: Bool

  func context(source: ScreenCapturePermissionCheckSource) -> [String: String] {
    [
      "bundleID": Bundle.main.bundleIdentifier ?? "missing",
      "bundlePath": Bundle.main.bundleURL.standardizedFileURL.path,
      "effectiveStatus": effectiveStatus.diagnosticName,
      "identityHealthy": identityHealthy ? "true" : "false",
      "identityIssues": identityIssueNames.isEmpty ? "none" : identityIssueNames.joined(separator: ","),
      "pid": "\(ProcessInfo.processInfo.processIdentifier)",
      "rawTCCGranted": rawSystemGranted ? "true" : "false",
      "resetOverrideActive": resetOverrideActive ? "true" : "false",
      "source": source.rawValue,
    ]
  }
}

nonisolated enum FrozenSnapshotCapturePolicy {
  static func canUseCoreGraphics(
    showCursor: Bool,
    excludeDesktopIcons: Bool,
    excludeDesktopWidgets: Bool,
    excludeOwnApplication: Bool
  ) -> Bool {
    !showCursor
      && !excludeDesktopIcons
      && !excludeDesktopWidgets
      && !excludeOwnApplication
  }
}

/// Keeps the permission guide to one native request. Enumerating shareable
/// content is a capture operation and can display a separate direct-capture
/// confirmation on newer macOS versions, so it must not be part of this flow.
enum ScreenCapturePermissionRequestFlow {
  static func requestAccess(
    preflight: () -> Bool,
    request: () -> Bool
  ) -> Bool {
    guard !preflight() else { return true }
    return request()
  }
}

enum ScreenshotCaptureWindowPolicy {
  static func shouldExceptOwnWindow(
    isHistoryPanel: Bool,
    sharingType: NSWindow.SharingType,
    windowNumber: Int,
    includeAllShareableWindows: Bool
  ) -> Bool {
    (includeAllShareableWindows || isHistoryPanel)
      && sharingType != .none
      && windowNumber > 0
      && CGWindowID(exactly: windowNumber) != nil
  }

  @MainActor
  static func exceptedOwnWindowIDs(
    from windows: [NSWindow],
    includeAllShareableWindows: Bool = false
  ) -> Set<CGWindowID> {
    Set(windows.compactMap { window in
      // Read transient AppKit state once. A capture overlay can close between
      // repeated windowNumber reads and turn an otherwise valid ID into -1.
      let windowNumber = window.windowNumber
      let sharingType = window.sharingType
      guard let windowID = CGWindowID(exactly: windowNumber),
            shouldExceptOwnWindow(
              isHistoryPanel: window is HistoryFloatingPanel,
              sharingType: sharingType,
              windowNumber: windowNumber,
              includeAllShareableWindows: includeAllShareableWindows
            )
      else { return nil }
      return windowID
    })
  }
}

/// Manager class handling all screen capture operations
@MainActor
final class ScreenCaptureManager: ObservableObject {
  struct PreparedAreaCaptureContext {
    let contentFilter: SCContentFilter
    let configuration: SCStreamConfiguration
    let pixelCropRect: CGRect
    let sourceRect: CGRect
    let outputWidth: Int
    let outputHeight: Int
    let scaleFactor: CGFloat
    // Logical (point-space) geometry used at crop time to reconcile against the
    // actually-returned image dimensions. Needed because SCStream may return an
    // image whose pixel size differs from screenFrame × scaleFactor on scaled
    // HiDPI / non-default-density displays (issue #308).
    let screenFrame: CGRect
    let logicalCropSize: CGSize
    let minimumOutputScaleFactor: CGFloat
    let assumedFullPixelSize: CGSize
    let displayID: CGDirectDisplayID
  }

  struct PreparedAreaCaptureResult {
    let image: CGImage
    let scaleFactor: CGFloat
  }

  static let shared = ScreenCaptureManager()

  @Published private(set) var permissionStatus: ScreenRecordingPermissionStatus = .notGranted
  @Published private(set) var hasPermission: Bool = false
  @Published private(set) var isCapturing: Bool = false

  /// Publisher for successful capture completions
  private let captureCompletedSubject = PassthroughSubject<URL, Never>()
  var captureCompletedPublisher: AnyPublisher<URL, Never> {
    captureCompletedSubject.eraseToAnyPublisher()
  }

  private var standardShareableContentCache: ShareableContentCacheEntry?
  private var desktopInclusiveShareableContentCache: ShareableContentCacheEntry?
  private var screenParametersObserver: NSObjectProtocol?
  private var isPermissionResetPending = false
  private var didObserveResetPermissionRevocation = false
  private var lastLoggedAuthorizationSnapshot: ScreenRecordingAuthorizationLogSnapshot?
  private nonisolated static let minimumScreenshotOutputScaleFactor: CGFloat = 2.0

  private init() {
    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.invalidateShareableContentCache()
      }
    }

    Task {
      await checkPermission(source: .initialization)
    }
  }

  // MARK: - Permission Handling

  /// Check if screen recording permission is granted
  func checkPermission(source: ScreenCapturePermissionCheckSource = .refresh) async {
    AppIdentityManager.shared.refresh()
    let rawSystemGranted = CGPreflightScreenCaptureAccess()
    if isPermissionResetPending {
      if !rawSystemGranted {
        didObserveResetPermissionRevocation = true
      } else if didObserveResetPermissionRevocation {
        isPermissionResetPending = false
        didObserveResetPermissionRevocation = false
      }
    }
    updatePermissionStatus(rawSystemGranted: rawSystemGranted, source: source)
  }

  /// Immediately reflect a successful `tccutil reset` in the current process.
  ///
  /// Core Graphics can keep returning the pre-reset value until macOS refreshes
  /// the process' TCC view, so the permission UI must not wait for preflight to
  /// catch up before showing that access was removed.
  func markPermissionReset() {
    isPermissionResetPending = true
    didObserveResetPermissionRevocation = false
    updatePermissionStatus(
      rawSystemGranted: CGPreflightScreenCaptureAccess(),
      source: .permissionReset
    )
  }

  func clearPermissionResetOverride() {
    isPermissionResetPending = false
    didObserveResetPermissionRevocation = false
  }

  /// Request screen recording permission by triggering the system prompt.
  ///
  /// The Core Graphics request owns the complete native authorization UI,
  /// including the user's choice to open System Settings. Do not enumerate
  /// ScreenCaptureKit content or open Settings again from the same action.
  func requestPermission() async -> Bool {
    AppIdentityManager.shared.refresh()
    clearPermissionResetOverride()
    let preflightGranted = CGPreflightScreenCaptureAccess()
    DiagnosticLogger.shared.log(
      .info,
      .capture,
      "Screen recording authorization request started",
      context: ["preflightGranted": preflightGranted ? "true" : "false"]
    )
    let systemGranted = ScreenCapturePermissionRequestFlow.requestAccess(
      preflight: { preflightGranted },
      request: { CGRequestScreenCaptureAccess() }
    )
    updatePermissionStatus(
      rawSystemGranted: systemGranted,
      source: .authorizationRequest
    )
    return hasPermission
  }

  /// Open System Preferences to Screen Recording section
  func openScreenRecordingPreferences() {
    DiagnosticLogger.shared.log(
      .info,
      .preferences,
      "Opening Screen Recording privacy settings",
      context: ["effectiveStatus": permissionStatus.diagnosticName]
    )
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
    NSWorkspace.shared.open(url)
  }

  /// Start loading shareable content before the user finishes a selection so
  /// the actual screenshot can happen immediately on completion.
  func prefetchShareableContent(
    includeDesktopWindows: Bool = false,
    forceRefresh: Bool = false
  ) -> ShareableContentPrefetchTask? {
    guard hasPermission else { return nil }

    let cacheMode = shareableContentCacheMode(includeDesktopWindows: includeDesktopWindows)
    if !forceRefresh, let cached = shareableContentCacheEntry(for: cacheMode) {
      return cached.task
    }

    let task = makeShareableContentPrefetchTask(includeDesktopWindows: includeDesktopWindows)
    setShareableContentCacheEntry(
      ShareableContentCacheEntry(mode: cacheMode, task: task),
      for: cacheMode
    )
    return task
  }

  /// Off-main-thread variant — caller must resolve NSScreen data on main thread first,
  /// then pass as value types so CGDisplayCreateImage can run on a background thread.
  nonisolated func captureFastDisplaySnapshotOffMain(
    displayID: CGDirectDisplayID,
    screenFrame: CGRect,
    backingScaleFactor: CGFloat,
    colorSpaceName: CFString?
  ) -> FrozenDisplaySnapshot? {
    guard let image = CGDisplayCreateImage(displayID) else {
      return nil
    }

    let scaleFactor = Self.imageScaleFactor(
      for: image,
      screenFrame: screenFrame,
      fallback: backingScaleFactor
    )

    return FrozenDisplaySnapshot(
      displayID: displayID,
      screenFrame: screenFrame,
      scaleFactor: scaleFactor,
      colorSpaceName: colorSpaceName,
      image: image
    )
  }

  func captureDisplaySnapshots(
    displayIDs: Set<CGDirectDisplayID>? = nil,
    showCursor: Bool = false,
    excludeDesktopIcons: Bool = false,
    excludeDesktopWidgets: Bool = false,
    excludeOwnApplication: Bool = false,
    prefetchedContentTask: ShareableContentPrefetchTask? = nil
  ) async throws -> [CGDirectDisplayID: FrozenDisplaySnapshot] {
    if let unavailableError = await ensureCaptureAvailability() {
      throw unavailableError
    }

    isCapturing = true
    defer { isCapturing = false }
    DiagnosticLogger.shared.log(.info, .capture, "Frozen display snapshot capture started")

    return try await captureDisplaySnapshotsCore(
      displayIDs: displayIDs,
      showCursor: showCursor,
      excludeDesktopIcons: excludeDesktopIcons,
      excludeDesktopWidgets: excludeDesktopWidgets,
      excludeOwnApplication: excludeOwnApplication,
      prefetchedContentTask: prefetchedContentTask
    )
  }

  /// Core snapshot acquisition shared by the One Shot frozen-session wrapper.
  private func captureDisplaySnapshotsCore(
    displayIDs: Set<CGDirectDisplayID>? = nil,
    showCursor: Bool = false,
    excludeDesktopIcons: Bool = false,
    excludeDesktopWidgets: Bool = false,
    excludeOwnApplication: Bool = false,
    prefetchedContentTask: ShareableContentPrefetchTask? = nil
  ) async throws -> [CGDirectDisplayID: FrozenDisplaySnapshot] {
    let includeDesktopWindows = excludeDesktopIcons || excludeDesktopWidgets
    let content = try await loadShareableContent(
      prefetchedContentTask: prefetchedContentTask,
      includeDesktopWindows: includeDesktopWindows
    )

    let screensToCapture = NSScreen.screens.filter { screen in
      guard let displayID = screen.displayID else { return false }
      guard let displayIDs else { return true }
      return displayIDs.contains(displayID)
    }

    guard !screensToCapture.isEmpty else {
      throw CaptureError.noDisplayFound
    }

    let snapshots = try await withThrowingTaskGroup(
      of: (CGDirectDisplayID, FrozenDisplaySnapshot).self,
      returning: [CGDirectDisplayID: FrozenDisplaySnapshot].self
    ) { group in
      for screen in screensToCapture {
        guard let displayID = screen.displayID else { continue }
        guard let display = content.displays.first(where: { $0.displayID == Int(displayID) }) else {
          throw CaptureError.noDisplayFound
        }

        // Compute filter, scale factor, and configuration on the main actor
        // before entering the child task, since these methods are @MainActor-isolated.
        let filter = buildFilter(
          display: display,
          content: content,
          excludeDesktopIcons: excludeDesktopIcons,
          excludeDesktopWidgets: excludeDesktopWidgets,
          excludeOwnApplication: excludeOwnApplication
        )
        let scaleFactor = displaySnapshotScaleFactor(
          for: screen,
          display: display,
          contentFilter: filter
        )
        let configuration = makeDisplaySnapshotConfiguration(
          for: screen,
          scaleFactor: scaleFactor,
          showsCursor: showCursor
        )
        let screenFrame = screen.frame

        group.addTask {
          let image = try await Self.captureImageCompat(
            contentFilter: filter,
            configuration: configuration
          )
          let imageScaleFactor = Self.imageScaleFactor(
            for: image,
            screenFrame: screenFrame,
            fallback: scaleFactor
          )
          return (displayID, FrozenDisplaySnapshot(
            displayID: displayID,
            screenFrame: screenFrame,
            scaleFactor: imageScaleFactor,
            colorSpaceName: configuration.colorSpaceName,
            image: image
          ))
        }
      }

      var result: [CGDirectDisplayID: FrozenDisplaySnapshot] = [:]
      for try await (displayID, snapshot) in group {
        result[displayID] = snapshot
      }
      return result
    }

    guard !snapshots.isEmpty else {
      throw CaptureError.noDisplayFound
    }

    return snapshots
  }

  // MARK: - Image Saving

  /// Save a CGImage to disk with write verification
  private func saveImage(
    _ image: CGImage,
    to directory: URL,
    fileName: String?,
    format: ImageFormat,
    scaleFactor: CGFloat? = nil,
    emitCompletion: Bool = true,
    context: CaptureContext = .empty
  ) async -> CaptureResult {
    let directoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(directory)
    defer { directoryAccess.stop() }
    let scopedDirectory = directoryAccess.url

    // Resolve filename using the user-configurable template with a safe fallback.
    let baseName = CaptureOutputNaming.resolveBaseName(
      customName: fileName,
      kind: .screenshot,
      context: context
    )
    let fileExtension = format.fileExtension

    logger.info("Saving capture to \(scopedDirectory.lastPathComponent)/\(baseName).\(fileExtension)")

    // Capture format properties before entering detached task
    let utType = format.utType

    // Move file I/O to background thread to avoid blocking main thread
    let isWebP = fileExtension == "webp"
    let storedLossyQuality = UserDefaults.standard.integer(forKey: PreferencesKeys.screenshotLossyQuality)
    let lossyQuality = CGFloat(storedLossyQuality == 0 ? 90 : min(max(storedLossyQuality, 1), 100)) / 100.0
    let destinationProperties = Self.imageDestinationProperties(for: format, scaleFactor: scaleFactor)
    let fileURL = CaptureOutputNaming.makeUniqueFileURL(
      in: scopedDirectory,
      baseName: baseName,
      fileExtension: fileExtension
    )
    let writeResult: Result<URL, CaptureError> = await Task.detached {
      // Create directory if needed
      do {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
      } catch {
        return .failure(.saveFailed(L10n.ScreenCapture.couldNotCreateDirectory(error.localizedDescription)))
      }

      if isWebP {
        // WebP: use WebPEncoder (cwebp CLI) since ImageIO doesn't support WebP encoding
        guard WebPEncoderService.write(image, to: fileURL, quality: lossyQuality) else {
          return .failure(.saveFailed(L10n.ScreenCapture.webpEncodingFailed))
        }
      } else {
        // PNG/JPEG: use CGImageDestination
        guard
          let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            utType,
            1,
            nil
          )
        else {
          return .failure(.saveFailed(L10n.ScreenCapture.couldNotCreateImageDestination))
        }

        CGImageDestinationAddImage(destination, image, destinationProperties)

        guard CGImageDestinationFinalize(destination) else {
          return .failure(.saveFailed(L10n.ScreenCapture.failedToWriteImageToDisk))
        }
      }

      // Verify file is fully written
      let verified = await Self.verifyFileWritten(at: fileURL)
      if verified {
        return .success(fileURL)
      } else {
        return .failure(.saveFailed(L10n.ScreenCapture.fileWriteVerificationFailed(fileURL.lastPathComponent)))
      }
    }.value

    switch writeResult {
    case .success(let url):
      DiagnosticLogger.shared.log(.info, .capture, "Capture saved: \(url.lastPathComponent)")
      if emitCompletion {
        captureCompletedSubject.send(url)
      }
      return .success(url)
    case .failure(let error):
      DiagnosticLogger.shared.log(.error, .capture, "Save failed: \(error.localizedDescription)")
      logger.error("Save failed: \(error.localizedDescription)")
      return .failure(error)
    }
  }

  /// Save an already-processed image (for example OCR/cutout post-processing flows)
  /// using the same naming, sandbox access, verification, and post-capture pipeline.
  func saveProcessedImage(
    _ image: CGImage,
    to directory: URL,
    fileName: String? = nil,
    format: ImageFormat = .png,
    scaleFactor: CGFloat? = nil,
    emitCompletion: Bool = true,
    context: CaptureContext = .empty
  ) async -> CaptureResult {
    await saveImage(
      image,
      to: directory,
      fileName: fileName,
      format: format,
      scaleFactor: scaleFactor,
      emitCompletion: emitCompletion,
      context: context
    )
  }

  /// Verify file exists on disk with non-zero size, retrying up to maxAttempts.
  /// Runs on caller's thread (designed for background execution).
  private nonisolated static func verifyFileWritten(at url: URL, maxAttempts: Int = 3,
                                                    delayMs: UInt64 = 50) async -> Bool {
    let logger = Logger(subsystem: "ShotPaste", category: "ScreenCaptureManager")
    for attempt in 1 ... maxAttempts {
      if FileManager.default.fileExists(atPath: url.path) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? UInt64 ?? 0
        if size > 0 {
          logger.debug("File verified on attempt \(attempt): \(url.lastPathComponent) (\(size) bytes)")
          return true
        }
      }
      if attempt < maxAttempts {
        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
      }
    }
    logger.error("File verification failed after \(maxAttempts) attempts: \(url.lastPathComponent)")
    return false
  }

  private nonisolated static func imageDestinationProperties(
    for format: ImageFormat,
    scaleFactor: CGFloat?
  ) -> CFDictionary? {
    let resolvedScale = max(Double(scaleFactor ?? 1.0), 1.0)
    let dpi = resolvedScale * 72.0
    var properties: [CFString: Any] = [
      kCGImagePropertyDPIWidth: dpi,
      kCGImagePropertyDPIHeight: dpi,
    ]

    switch format {
    case .png:
      let pixelsPerMeter = Int((dpi / 0.0254).rounded())
      properties[kCGImagePropertyPNGDictionary] = [
        kCGImagePropertyPNGXPixelsPerMeter: pixelsPerMeter,
        kCGImagePropertyPNGYPixelsPerMeter: pixelsPerMeter,
      ] as CFDictionary
    case .jpeg(let quality):
      properties[kCGImageDestinationLossyCompressionQuality] = quality
    case .webp:
      break
    }

    return properties as CFDictionary
  }

  func prepareAreaCapture(
    rect: CGRect,
    showCursor: Bool = false,
    excludeDesktopIcons: Bool = false,
    excludeDesktopWidgets: Bool = false,
    excludeOwnApplication: Bool = false,
    includeAllShareableOwnWindows: Bool = false,
    prefetchedContentTask: ShareableContentPrefetchTask? = nil
  ) async throws -> PreparedAreaCaptureContext {
    if let unavailableError = await ensureCaptureAvailability() {
      throw unavailableError
    }

    return try await makePreparedAreaCaptureContext(
      rect: rect,
      showCursor: showCursor,
      excludeDesktopIcons: excludeDesktopIcons,
      excludeDesktopWidgets: excludeDesktopWidgets,
      excludeOwnApplication: excludeOwnApplication,
      includeAllShareableOwnWindows: includeAllShareableOwnWindows,
      prefetchedContentTask: prefetchedContentTask
    )
  }

  func capturePreparedArea(_ context: PreparedAreaCaptureContext) async throws -> PreparedAreaCaptureResult? {
    let fullImage = try await Self.captureImageCompat(
      contentFilter: context.contentFilter,
      configuration: context.configuration
    )

    // Reconcile assumed-vs-actual: SCStream can return an image whose pixel
    // size differs from `screenFrame × assumedScale` on scaled HiDPI displays.
    // Trusting the pre-computed `pixelCropRect` against the actual image clamps
    // the crop to upper-left when the image is smaller than assumed (issue #308).
    let reconciled = Self.reconciledPixelCrop(
      fullImagePixelWidth: fullImage.width,
      fullImagePixelHeight: fullImage.height,
      screenFrame: context.screenFrame,
      logicalSourceRect: context.sourceRect,
      logicalCropSize: context.logicalCropSize,
      fallbackScale: context.scaleFactor
    )

    let assumedWidth = Int(context.assumedFullPixelSize.width.rounded())
    let assumedHeight = Int(context.assumedFullPixelSize.height.rounded())
    let mismatch =
      abs(fullImage.width - assumedWidth) > 1 ||
      abs(fullImage.height - assumedHeight) > 1

    DiagnosticLogger.shared.log(
      .debug,
      .capture,
      "Area captured image",
      context: [
        "displayID": "\(context.displayID)",
        "actualFull": "\(fullImage.width)x\(fullImage.height)",
        "assumedFull": "\(assumedWidth)x\(assumedHeight)",
        "actualScale": String(format: "%.3f", Double(reconciled.actualScale)),
        "assumedScale": String(format: "%.3f", Double(context.scaleFactor)),
        "rebuiltCrop": "\(Int(reconciled.pixelCrop.origin.x))x\(Int(reconciled.pixelCrop.origin.y))+\(Int(reconciled.pixelCrop.width))x\(Int(reconciled.pixelCrop.height))",
      ]
    )

    if mismatch {
      DiagnosticLogger.shared.log(
        .info,
        .capture,
        "#308 dimension mismatch (actual≠assumed) — rebuilt crop from actual pixels",
        context: [
          "displayID": "\(context.displayID)",
          "actualFull": "\(fullImage.width)x\(fullImage.height)",
          "assumedFull": "\(assumedWidth)x\(assumedHeight)",
          "actualScale": String(format: "%.3f", Double(reconciled.actualScale)),
        ]
      )
    }

    let fullImageBounds = CGRect(
      x: 0,
      y: 0,
      width: fullImage.width,
      height: fullImage.height
    )
    let capturedImage: CGImage? = if reconciled.pixelCrop.integral == fullImageBounds.integral {
      fullImage
    } else if reconciled.pixelCrop.isEmpty {
      nil
    } else {
      fullImage.cropping(to: reconciled.pixelCrop)
    }

    guard let capturedImage else {
      return nil
    }

    // Promote low-density slices to the minimum One Shot screenshot baseline.
    // Native-density images pass through
    // unchanged; the sharpener only runs when an actual upscale happened.
    let promoted = FrozenAreaCaptureSession.imageByPromotingScaleIfNeeded(
      capturedImage,
      logicalSize: context.logicalCropSize,
      sourceScaleFactor: reconciled.actualScale,
      minimumOutputScaleFactor: context.minimumOutputScaleFactor,
      colorSpaceName: context.configuration.colorSpaceName
    )

    let didPromote = promoted.scaleFactor > reconciled.actualScale + 0.0001
    let outputImage = didPromote
      ? FrozenAreaCaptureSession.sharpenPromotedImageIfUseful(
        promoted.image,
        colorSpaceName: context.configuration.colorSpaceName
      )
      : promoted.image

    return PreparedAreaCaptureResult(image: outputImage, scaleFactor: promoted.scaleFactor)
  }

  /// Pure geometry helper — given the actually-returned pixel dimensions, the
  /// logical screen frame, and the logical (point-space, top-left, screen-local)
  /// source rect, returns the pixel crop rect and the derived actual scale.
  /// Exposed (internal) for unit-testing scale-mismatch without SCStream.
  nonisolated static func reconciledPixelCrop(
    fullImagePixelWidth: Int,
    fullImagePixelHeight: Int,
    screenFrame: CGRect,
    logicalSourceRect: CGRect,
    logicalCropSize: CGSize,
    fallbackScale: CGFloat
  ) -> (pixelCrop: CGRect, actualScale: CGFloat) {
    let actualScale = dimensionScale(
      pixelWidth: fullImagePixelWidth,
      pixelHeight: fullImagePixelHeight,
      frame: screenFrame
    ) ?? max(fallbackScale, 1)

    let originX = (logicalSourceRect.origin.x * actualScale).rounded()
    let originY = (logicalSourceRect.origin.y * actualScale).rounded()
    let width = CGFloat(max(1, Int((logicalCropSize.width * actualScale).rounded())))
    let height = CGFloat(max(1, Int((logicalCropSize.height * actualScale).rounded())))

    let rawCrop = CGRect(x: originX, y: originY, width: width, height: height)
    let imageBounds = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(fullImagePixelWidth),
      height: CGFloat(fullImagePixelHeight)
    )
    return (rawCrop.intersection(imageBounds), actualScale)
  }

  /// Pure straddle picker — index of the frame in `frames` with the LARGEST area
  /// intersection with `rect`, or `nil` if no frame intersects. One Shot uses
  /// the same rule when resolving a cross-display selection.
  nonisolated static func indexOfLargestIntersectingFrame(
    frames: [CGRect],
    rect: CGRect
  ) -> Int? {
    var bestIndex: Int?
    var bestArea: CGFloat = 0
    for (index, frame) in frames.enumerated() {
      let intersection = frame.intersection(rect)
      guard !intersection.isEmpty else { continue }
      let area = intersection.width * intersection.height
      if area > bestArea {
        bestArea = area
        bestIndex = index
      }
    }
    return bestIndex
  }

  func makeAreaStreamConfiguration(
    from context: PreparedAreaCaptureContext,
    maximumFrameRate: Int = 30,
    showsCursor: Bool = false
  ) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = context.outputWidth
    configuration.height = context.outputHeight
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = showsCursor
    configuration.sourceRect = context.sourceRect
    configuration.queueDepth = maximumFrameRate >= 60 ? 3 : 2
    configuration.minimumFrameInterval = CMTime(
      value: 1,
      timescale: CMTimeScale(max(1, maximumFrameRate))
    )
    if #available(macOS 14.0, *) {
      configuration.ignoreShadowsSingleWindow = false
    }
    if #available(macOS 14.2, *) {
      configuration.captureResolution = .best
    }
    configuration.colorSpaceName = context.configuration.colorSpaceName
    return configuration
  }

  private func makePreparedAreaCaptureContext(
    rect: CGRect,
    showCursor: Bool,
    excludeDesktopIcons: Bool,
    excludeDesktopWidgets: Bool,
    excludeOwnApplication: Bool,
    includeAllShareableOwnWindows: Bool,
    prefetchedContentTask: ShareableContentPrefetchTask?,
    minimumOutputScaleFactor: CGFloat = ScreenCaptureManager.minimumScreenshotOutputScaleFactor
  ) async throws -> PreparedAreaCaptureContext {
    let includeDesktopWindows = excludeDesktopIcons || excludeDesktopWidgets
    let content = try await loadShareableContent(
      prefetchedContentTask: prefetchedContentTask,
      includeDesktopWindows: includeDesktopWindows
    )

    // Pick the display with the LARGEST intersection (phase-03). Order-dependent
    // `first` pick was wrong for straddling selections — see issue #308 notes.
    let targetScreen: NSScreen? = if let bestIndex = Self.indexOfLargestIntersectingFrame(
      frames: NSScreen.screens.map(\.frame),
      rect: rect
    ) {
      NSScreen.screens[bestIndex]
    } else {
      nil
    }

    let targetDisplayID: CGDirectDisplayID = if let screen = targetScreen,
                                                let displayID = screen
                                                .deviceDescription[
                                                  NSDeviceDescriptionKey("NSScreenNumber")
                                                ] as? CGDirectDisplayID {
      displayID
    } else {
      CGMainDisplayID()
    }

    guard let display = content.displays.first(where: { $0.displayID == Int(targetDisplayID) })
      ?? content.displays.first
    else {
      throw CaptureError.noDisplayFound
    }

    let contentFilter = buildFilter(
      display: display,
      content: content,
      excludeDesktopIcons: excludeDesktopIcons,
      excludeDesktopWidgets: excludeDesktopWidgets,
      excludeOwnApplication: excludeOwnApplication,
      includeAllShareableOwnWindows: includeAllShareableOwnWindows
    )
    guard let matchingScreen = targetScreen ?? NSScreen.screens.first(where: {
      Int($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0)
        == display.displayID
    }) else {
      throw CaptureError.noDisplayFound
    }

    let screenFrame = matchingScreen.frame
    let nativeScaleFactor = displaySnapshotScaleFactor(
      for: matchingScreen,
      display: display,
      contentFilter: contentFilter
    )
    let captureScale = nativeScaleFactor
    let outputScale = max(nativeScaleFactor, minimumOutputScaleFactor)

    let relativeRect = CGRect(
      x: rect.origin.x - screenFrame.origin.x,
      y: rect.origin.y - screenFrame.origin.y,
      width: rect.width,
      height: rect.height
    )

    let screenBounds = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height)
    let clampedRect = relativeRect.intersection(screenBounds)

    guard !clampedRect.isEmpty else {
      throw CaptureError.captureFailed(L10n.ScreenCapture.selectionOutsideDisplayBounds)
    }

    let alignedRect = pixelAlignedRect(clampedRect, scaleFactor: captureScale, bounds: screenBounds)
    guard !alignedRect.isEmpty else {
      throw CaptureError.captureFailed(L10n.ScreenCapture.selectionOutsideDisplayBounds)
    }

    let flippedY = screenFrame.height - alignedRect.origin.y - alignedRect.height
    let sourceRect = CGRect(
      x: alignedRect.origin.x,
      y: flippedY,
      width: alignedRect.width,
      height: alignedRect.height
    )
    let outputWidth = max(1, Int((alignedRect.width * captureScale).rounded()))
    let outputHeight = max(1, Int((alignedRect.height * captureScale).rounded()))
    let fullCaptureWidth = max(1, Int((screenFrame.width * captureScale).rounded()))
    let fullCaptureHeight = max(1, Int((screenFrame.height * captureScale).rounded()))

    let config = SCStreamConfiguration()
    if #available(macOS 14.0, *) {
      config.ignoreShadowsSingleWindow = false
    }
    if #available(macOS 14.2, *) {
      config.captureResolution = .best
    }
    config.width = fullCaptureWidth
    config.height = fullCaptureHeight
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = showCursor
    if let colorSpaceName = preferredCaptureColorSpaceName(for: matchingScreen) {
      config.colorSpaceName = colorSpaceName
    }

    let pixelCropRect = CGRect(
      x: (sourceRect.origin.x * captureScale).rounded(),
      y: (sourceRect.origin.y * captureScale).rounded(),
      width: CGFloat(outputWidth),
      height: CGFloat(outputHeight)
    ).intersection(
      CGRect(x: 0, y: 0, width: CGFloat(fullCaptureWidth), height: CGFloat(fullCaptureHeight))
    )

    let context = PreparedAreaCaptureContext(
      contentFilter: contentFilter,
      configuration: config,
      pixelCropRect: pixelCropRect,
      sourceRect: sourceRect,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      scaleFactor: captureScale,
      screenFrame: screenFrame,
      logicalCropSize: alignedRect.size,
      minimumOutputScaleFactor: outputScale,
      assumedFullPixelSize: CGSize(width: fullCaptureWidth, height: fullCaptureHeight),
      displayID: targetDisplayID
    )

    DiagnosticLogger.shared.log(
      .debug,
      .capture,
      "Area prepared context",
      context: [
        "displayID": "\(targetDisplayID)",
        "screenFrame": "\(Int(screenFrame.width))x\(Int(screenFrame.height))",
        "nativeScale": String(format: "%.3f", Double(nativeScaleFactor)),
        "scale": String(format: "%.3f", Double(captureScale)),
        "outputScale": String(format: "%.3f", Double(outputScale)),
        "assumedFull": "\(fullCaptureWidth)x\(fullCaptureHeight)",
        "assumedPixelCrop": "\(Int(pixelCropRect.origin.x))x\(Int(pixelCropRect.origin.y))+\(Int(pixelCropRect.width))x\(Int(pixelCropRect.height))",
      ]
    )

    return context
  }

  private func displaySnapshotScaleFactor(
    for screen: NSScreen?,
    display: SCDisplay,
    contentFilter: SCContentFilter? = nil
  ) -> CGFloat {
    if #available(macOS 14.0, *), let contentFilter {
      let pointPixelScale = CGFloat(contentFilter.pointPixelScale)
      if pointPixelScale.isFinite, pointPixelScale > 0 {
        return pointPixelScale
      }
    }

    if let screen,
       let displayScale = Self.dimensionScale(
         pixelWidth: display.width,
         pixelHeight: display.height,
         frame: screen.frame
       ) {
      return displayScale
    }

    if let displayScale = Self.dimensionScale(
      pixelWidth: display.width,
      pixelHeight: display.height,
      frame: display.frame
    ) {
      return displayScale
    }

    if let screen {
      return max(screen.backingScaleFactor, 1)
    }

    return 2
  }

  private nonisolated static func imageScaleFactor(
    for image: CGImage,
    screenFrame: CGRect,
    fallback: CGFloat
  ) -> CGFloat {
    dimensionScale(
      pixelWidth: image.width,
      pixelHeight: image.height,
      frame: screenFrame
    ) ?? max(fallback, 1)
  }

  private nonisolated static func dimensionScale(
    pixelWidth: Int,
    pixelHeight: Int,
    frame: CGRect
  ) -> CGFloat? {
    let widthScale = frame.width > 0 ? CGFloat(pixelWidth) / frame.width : 0
    let heightScale = frame.height > 0 ? CGFloat(pixelHeight) / frame.height : 0
    let candidates = [widthScale, heightScale].filter { $0.isFinite && $0 > 0 }
    return candidates.max()
  }

  private func pixelAlignedRect(_ rect: CGRect, scaleFactor: CGFloat, bounds: CGRect) -> CGRect {
    guard scaleFactor > 0 else { return rect.intersection(bounds) }

    let minX = floor(rect.minX * scaleFactor) / scaleFactor
    let minY = floor(rect.minY * scaleFactor) / scaleFactor
    let maxX = ceil(rect.maxX * scaleFactor) / scaleFactor
    let maxY = ceil(rect.maxY * scaleFactor) / scaleFactor

    let alignedRect = CGRect(
      x: minX,
      y: minY,
      width: max(0, maxX - minX),
      height: max(0, maxY - minY)
    )

    return alignedRect.intersection(bounds)
  }

  private func makeDisplaySnapshotConfiguration(
    for screen: NSScreen,
    scaleFactor: CGFloat,
    showsCursor: Bool
  ) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    if #available(macOS 14.0, *) {
      configuration.ignoreShadowsSingleWindow = false
    }
    if #available(macOS 14.2, *) {
      configuration.captureResolution = .best
    }
    configuration.width = max(1, Int((screen.frame.width * scaleFactor).rounded()))
    configuration.height = max(1, Int((screen.frame.height * scaleFactor).rounded()))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = showsCursor
    if let colorSpaceName = preferredCaptureColorSpaceName(for: screen) {
      configuration.colorSpaceName = colorSpaceName
    }
    return configuration
  }

  func preferredCaptureColorSpaceName(for screen: NSScreen) -> CFString? {
    switch UserDefaults.standard.string(forKey: PreferencesKeys.screenshotColorSpace)?.lowercased() {
    case "srgb":
      return CGColorSpace.sRGB
    case "displayp3":
      return CGColorSpace.displayP3
    default:
      break
    }

    guard let colorSpaceName = screen.colorSpace?.cgColorSpace?.name else {
      return nil
    }

    if CFEqual(colorSpaceName, CGColorSpace.displayP3) {
      return CGColorSpace.displayP3
    }

    if CFEqual(colorSpaceName, CGColorSpace.sRGB) {
      return CGColorSpace.sRGB
    }

    return nil
  }

  // MARK: - Filter Builder

  private func loadShareableContent(
    prefetchedContentTask: ShareableContentPrefetchTask?,
    includeDesktopWindows: Bool = false
  ) async throws -> SCShareableContent {
    let cacheMode = shareableContentCacheMode(includeDesktopWindows: includeDesktopWindows)
    let loadStartedAt = Date()

    if let prefetchedContentTask {
      do {
        let content = try await prefetchedContentTask.value
        logShareableContentLoad(mode: cacheMode, source: "prefetched", startedAt: loadStartedAt)
        return content
      } catch {
        invalidateShareableContentCache(mode: cacheMode)
        logger.debug("Prefetched shareable content failed; refetching current content")
      }
    }

    if let cachedTask = prefetchShareableContent(includeDesktopWindows: includeDesktopWindows) {
      do {
        let content = try await cachedTask.value
        logShareableContentLoad(mode: cacheMode, source: "cached", startedAt: loadStartedAt)
        return content
      } catch {
        invalidateShareableContentCache(mode: cacheMode)
        logger.debug("Cached shareable content failed; forcing refresh")
      }
    }

    guard let refreshedTask = prefetchShareableContent(
      includeDesktopWindows: includeDesktopWindows,
      forceRefresh: true
    ) else {
      let content = try await fetchShareableContent(includeDesktopWindows: includeDesktopWindows)
      logShareableContentLoad(mode: cacheMode, source: "direct", startedAt: loadStartedAt)
      return content
    }

    do {
      let content = try await refreshedTask.value
      logShareableContentLoad(mode: cacheMode, source: "refreshed", startedAt: loadStartedAt)
      return content
    } catch {
      invalidateShareableContentCache(mode: cacheMode)
      throw error
    }
  }

  private func ensureCaptureAvailability() async -> CaptureError? {
    await checkPermission()

    switch permissionStatus {
    case .granted:
      return nil
    case .notGranted:
      let granted = await requestPermission()
      if granted {
        return nil
      }
      return .permissionDenied
    case .grantedButUnavailableDueToAppIdentity(let reason):
      return .unavailable(reason)
    }
  }

  private func updatePermissionStatus(
    rawSystemGranted: Bool,
    source: ScreenCapturePermissionCheckSource
  ) {
    let systemGranted = rawSystemGranted && !isPermissionResetPending
    let identityHealth = AppIdentityManager.shared.health
    if !systemGranted {
      permissionStatus = .notGranted
      hasPermission = false
    } else if !identityHealth.isHealthy {
      permissionStatus = .grantedButUnavailableDueToAppIdentity(identityHealth.summary)
      hasPermission = false
    } else {
      permissionStatus = .granted
      hasPermission = true
    }

    if !hasPermission {
      invalidateShareableContentCache()
    }

    logAuthorizationState(
      rawSystemGranted: rawSystemGranted,
      identityHealth: identityHealth,
      source: source
    )
    // Do not enumerate shareable content as a side effect of checking TCC state.
    // macOS 26 can present a separate confirmation for apps that access the
    // screen directly instead of using the system picker. Starting that request
    // at launch lets a later One Shot overlay freeze the still-pending
    // confirmation into its backdrop, leaving the real dialog underneath and
    // impossible to click. Capture entry points prefetch on an explicit user
    // action and must await the task before presenting the frozen desktop UI.
  }

  private func logAuthorizationState(
    rawSystemGranted: Bool,
    identityHealth: AppIdentityHealth,
    source: ScreenCapturePermissionCheckSource
  ) {
    let snapshot = ScreenRecordingAuthorizationLogSnapshot(
      rawSystemGranted: rawSystemGranted,
      effectiveStatus: permissionStatus,
      identityHealthy: identityHealth.isHealthy,
      identityIssueNames: identityHealth.issues.map(\.diagnosticName),
      resetOverrideActive: isPermissionResetPending
    )
    let previousSnapshot = lastLoggedAuthorizationSnapshot
    guard source.alwaysLogs || snapshot != previousSnapshot else { return }
    lastLoggedAuthorizationSnapshot = snapshot

    let message = if previousSnapshot == nil {
      "Screen recording authorization state observed"
    } else if snapshot != previousSnapshot {
      "Screen recording authorization state changed"
    } else {
      "Screen recording authorization state confirmed"
    }

    DiagnosticLogger.shared.log(
      .info,
      .capture,
      message,
      context: snapshot.context(source: source)
    )
  }

  private func shareableContentCacheMode(includeDesktopWindows: Bool) -> ShareableContentCacheMode {
    includeDesktopWindows ? .desktopInclusive : .standard
  }

  private func shareableContentCacheEntry(for mode: ShareableContentCacheMode) -> ShareableContentCacheEntry? {
    switch mode {
    case .standard:
      standardShareableContentCache
    case .desktopInclusive:
      desktopInclusiveShareableContentCache
    }
  }

  private func setShareableContentCacheEntry(
    _ entry: ShareableContentCacheEntry?,
    for mode: ShareableContentCacheMode
  ) {
    switch mode {
    case .standard:
      standardShareableContentCache = entry
    case .desktopInclusive:
      desktopInclusiveShareableContentCache = entry
    }
  }

  private func fetchShareableContent(includeDesktopWindows: Bool) async throws -> SCShareableContent {
    if includeDesktopWindows {
      return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    return try await SCShareableContent.current
  }

  private func makeShareableContentPrefetchTask(includeDesktopWindows: Bool) -> ShareableContentPrefetchTask {
    Task(priority: .userInitiated) {
      try await self.fetchShareableContent(includeDesktopWindows: includeDesktopWindows)
    }
  }

  private func logShareableContentLoad(
    mode: ShareableContentCacheMode,
    source: String,
    startedAt: Date
  ) {
    let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    DiagnosticLogger.shared.log(
      .debug,
      .capture,
      "Shareable content loaded",
      context: [
        "mode": mode.rawValue,
        "source": source,
        "duration_ms": "\(durationMs)",
      ]
    )
  }

  private func invalidateShareableContentCache(mode: ShareableContentCacheMode? = nil) {
    switch mode {
    case .standard:
      standardShareableContentCache = nil
    case .desktopInclusive:
      desktopInclusiveShareableContentCache = nil
    case nil:
      standardShareableContentCache = nil
      desktopInclusiveShareableContentCache = nil
    }
  }

  /// Compatibility wrapper: uses SCScreenshotManager on macOS 14+, falls back to SCStream single-frame capture on macOS
  /// 13.
  private static func captureImageCompat(
    contentFilter: SCContentFilter,
    configuration: SCStreamConfiguration
  ) async throws -> CGImage {
    if #available(macOS 14.0, *) {
      try await SCScreenshotManager.captureImage(
        contentFilter: contentFilter,
        configuration: configuration
      )
    } else {
      // Fallback: use SCStream to capture a single frame. The session keeps the
      // stream/output/delegate alive, surfaces stream errors, and bounds the wait
      // with a timeout so the capture can never hang forever (issue #286).
      try await SingleFrameStreamCaptureSession.capture(
        contentFilter: contentFilter,
        configuration: configuration
      )
    }
  }

  /// Build SCContentFilter, optionally excluding Finder (desktop icons) and/or widgets.
  /// Open Finder windows and the desktop background remain visible.
  private func buildFilter(
    display: SCDisplay,
    content: SCShareableContent,
    excludeDesktopIcons: Bool,
    excludeDesktopWidgets: Bool,
    excludeOwnApplication: Bool,
    includeAllShareableOwnWindows: Bool = false
  ) -> SCContentFilter {
    let iconManager = DesktopIconManager.shared
    var excludedApps: [SCRunningApplication] = []
    var exceptedWindows: [SCWindow] = []

    if excludeOwnApplication, let bundleID = Bundle.main.bundleIdentifier {
      excludedApps += content.applications.filter { $0.bundleIdentifier == bundleID }
      let capturableHistoryWindowIDs = ScreenshotCaptureWindowPolicy.exceptedOwnWindowIDs(
        from: NSApp.windows,
        includeAllShareableWindows: includeAllShareableOwnWindows
      )
      exceptedWindows += content.windows.filter {
        capturableHistoryWindowIDs.contains($0.windowID)
      }
    }

    if excludeDesktopIcons {
      excludedApps += iconManager.getFinderApps(from: content)
      exceptedWindows += iconManager.getVisibleFinderWindows(from: content)
    }

    if excludeDesktopWidgets {
      excludedApps += iconManager.getWidgetApps(from: content)
    }

    if !excludedApps.isEmpty {
      return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: exceptedWindows)
    }
    return SCContentFilter(display: display, excludingWindows: [])
  }
}

// MARK: - Image Format

enum ImageFormat {
  case png
  case jpeg(quality: CGFloat)
  case webp

  var fileExtension: String {
    switch self {
    case .png: "png"
    case .jpeg: "jpg"
    case .webp: "webp"
    }
  }

  var utType: CFString {
    switch self {
    case .png: "public.png" as CFString
    case .jpeg: "public.jpeg" as CFString
    case .webp: "org.webmproject.webp" as CFString
    }
  }
}
