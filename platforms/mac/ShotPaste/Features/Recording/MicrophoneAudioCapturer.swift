//
//  MicrophoneAudioCapturer.swift
//  ShotPaste
//
//  Independent microphone capture using AVCaptureSession.
//  Works on macOS 13+ — not gated to macOS 15 like ScreenCaptureKit's built-in mic output.
//

import AVFoundation
import CoreMedia
import Foundation

/// Delegate for receiving captured microphone samples.
nonisolated protocol MicrophoneAudioCapturerDelegate: AnyObject {
  /// Called on the capturer's internal queue for each captured sample buffer.
  func microphoneCapturer(_ capturer: MicrophoneAudioCapturer, didOutput sampleBuffer: CMSampleBuffer)
}

nonisolated protocol MicrophoneCaptureSession: AnyObject {
  func canAddInput(_ input: AVCaptureInput) -> Bool
  func addInput(_ input: AVCaptureInput)
  func canAddOutput(_ output: AVCaptureOutput) -> Bool
  func addOutput(_ output: AVCaptureOutput)
  func startRunning()
  func stopRunning()
}

final nonisolated class AVFoundationMicrophoneCaptureSession: MicrophoneCaptureSession {
  private let session = AVCaptureSession()

  func canAddInput(_ input: AVCaptureInput) -> Bool {
    session.canAddInput(input)
  }

  func addInput(_ input: AVCaptureInput) {
    session.addInput(input)
  }

  func canAddOutput(_ output: AVCaptureOutput) -> Bool {
    session.canAddOutput(output)
  }

  func addOutput(_ output: AVCaptureOutput) {
    session.addOutput(output)
  }

  func startRunning() {
    session.startRunning()
  }

  func stopRunning() {
    session.stopRunning()
  }
}

nonisolated enum MicrophoneCaptureSetupError: Error {
  case noDefaultDevice
  case cannotAddDeviceInput
  case cannotAddDataOutput
}

nonisolated protocol MicrophoneCaptureSessionFactory {
  func authorizationStatus() -> AVAuthorizationStatus
  func makeSession() -> MicrophoneCaptureSession
  func configureInput(on session: MicrophoneCaptureSession, preferredDeviceID: String?) throws -> String
  func configureOutput(
    on session: MicrophoneCaptureSession,
    delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
    queue: DispatchQueue
  ) throws
}

nonisolated struct AVFoundationMicrophoneCaptureSessionFactory: MicrophoneCaptureSessionFactory {
  func authorizationStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  func makeSession() -> MicrophoneCaptureSession {
    AVFoundationMicrophoneCaptureSession()
  }

  func configureInput(on session: MicrophoneCaptureSession, preferredDeviceID: String?) throws -> String {
    guard let device = RecordingMicrophoneDeviceProvider.captureDevice(matching: preferredDeviceID) else {
      throw MicrophoneCaptureSetupError.noDefaultDevice
    }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw MicrophoneCaptureSetupError.cannotAddDeviceInput
    }

    session.addInput(input)
    return device.localizedName
  }

  func configureOutput(
    on session: MicrophoneCaptureSession,
    delegate: AVCaptureAudioDataOutputSampleBufferDelegate,
    queue: DispatchQueue
  ) throws {
    let output = AVCaptureAudioDataOutput()
    // Force 48 kHz LPCM at the capture source so AVFoundation resamples with a proper
    // anti-imaging filter. Otherwise a device-native ~16 kHz mic (Bluetooth/HFP) is
    // appended unmodified to the 48 kHz AAC writer, producing piercing spectral imaging.
    output.audioSettings = RecordingAudioEncodingSettings.makeMicrophoneCaptureLPCMSettings()
    output.setSampleBufferDelegate(delegate, queue: queue)
    guard session.canAddOutput(output) else {
      throw MicrophoneCaptureSetupError.cannotAddDataOutput
    }

    session.addOutput(output)
  }
}

/// Captures microphone audio via AVCaptureSession, delivering CMSampleBuffer objects
/// that can be written directly to an AVAssetWriter audio input.
final nonisolated class MicrophoneAudioCapturer: NSObject, @unchecked Sendable {
  weak var delegate: MicrophoneAudioCapturerDelegate?

  private let captureSessionFactory: MicrophoneCaptureSessionFactory
  private let preferredDeviceID: String?
  private var captureSession: MicrophoneCaptureSession?
  private let sessionQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.microphone.session",
    qos: .userInteractive
  )
  private let dataOutputQueue = DispatchQueue(
    label: "com.ahtcfg24.shotpaste.microphone.data",
    qos: .userInteractive
  )

  private var isRunning = false

  init(
    preferredDeviceID: String? = nil,
    captureSessionFactory: MicrophoneCaptureSessionFactory = AVFoundationMicrophoneCaptureSessionFactory()
  ) {
    self.preferredDeviceID = RecordingMicrophoneDeviceProvider.normalizedCaptureDeviceID(preferredDeviceID)
    self.captureSessionFactory = captureSessionFactory
    super.init()
  }

  /// Whether the capturer is currently running.
  var running: Bool {
    sessionQueue.sync { isRunning }
  }

  // MARK: - Lifecycle

  /// Start capturing from the default microphone device.
  /// Call from any queue; session setup happens on an internal queue.
  func start() {
    sessionQueue.async { [weak self] in
      guard let self, !self.isRunning else { return }
      isRunning = true
      setupAndStartSession()
    }
  }

  /// Stop capturing.
  func stop() {
    sessionQueue.async { [weak self] in
      guard let self, isRunning else { return }
      isRunning = false
      captureSession?.stopRunning()
      captureSession = nil
    }
  }

  // MARK: - Private

  private func setupAndStartSession() {
    let authorizationStatus = captureSessionFactory.authorizationStatus()
    guard authorizationStatus == .authorized else {
      log(.warning, "MicrophoneAudioCapturer: microphone permission unavailable", context: [
        "status": "\(authorizationStatus.rawValue)",
      ])
      resetCaptureState()
      return
    }

    let session = captureSessionFactory.makeSession()
    captureSession = session

    do {
      let deviceName = try captureSessionFactory.configureInput(
        on: session,
        preferredDeviceID: preferredDeviceID
      )
      try captureSessionFactory.configureOutput(on: session, delegate: self, queue: dataOutputQueue)
      session.startRunning()
      log(.info, "MicrophoneAudioCapturer: session started", context: [
        "deviceID": preferredDeviceID ?? RecordingMicrophoneDeviceProvider.systemDefaultID,
        "device": deviceName,
      ])
    } catch MicrophoneCaptureSetupError.noDefaultDevice {
      log(.warning, "MicrophoneAudioCapturer: no default audio device found")
      resetCaptureState()
    } catch MicrophoneCaptureSetupError.cannotAddDeviceInput {
      log(.warning, "MicrophoneAudioCapturer: cannot add device input")
      resetCaptureState()
    } catch MicrophoneCaptureSetupError.cannotAddDataOutput {
      log(.warning, "MicrophoneAudioCapturer: cannot add data output")
      resetCaptureState()
    } catch {
      logError(error, "MicrophoneAudioCapturer: failed to create device input")
      resetCaptureState()
    }
  }

  private func resetCaptureState() {
    isRunning = false
    captureSession = nil
  }

  private func log(
    _ level: DiagnosticLogLevel,
    _ message: String,
    context: [String: String]? = nil,
    file: String = #fileID,
    function: String = #function,
    line: Int = #line
  ) {
    Task { @MainActor in
      DiagnosticLogger.shared.log(
        level,
        .recording,
        message,
        context: context,
        file: file,
        function: function,
        line: line
      )
    }
  }

  private func logError(
    _ error: Error,
    _ message: String,
    file: String = #fileID,
    function: String = #function,
    line: Int = #line
  ) {
    Task { @MainActor in
      DiagnosticLogger.shared.logError(
        .recording,
        error,
        message,
        file: file,
        function: function,
        line: line
      )
    }
  }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

nonisolated extension MicrophoneAudioCapturer: AVCaptureAudioDataOutputSampleBufferDelegate {
  func captureOutput(
    _: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from _: AVCaptureConnection
  ) {
    guard sampleBuffer.isValid else { return }
    delegate?.microphoneCapturer(self, didOutput: sampleBuffer)
  }
}
