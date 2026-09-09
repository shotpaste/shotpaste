//
//  AppEnvironment.swift
//  ShotPaste
//
//  App-level dependency container.
//

import Foundation

@MainActor
final class AppEnvironment {
  let screenCaptureViewModel: ScreenCaptureViewModel
  let audioRecordingCoordinator: AudioRecordingCoordinator

  init(
    screenCaptureViewModel: ScreenCaptureViewModel,
    audioRecordingCoordinator: AudioRecordingCoordinator = .shared
  ) {
    self.screenCaptureViewModel = screenCaptureViewModel
    self.audioRecordingCoordinator = audioRecordingCoordinator
  }

  static func live() -> AppEnvironment {
    AppEnvironment(screenCaptureViewModel: ScreenCaptureViewModel())
  }
}
