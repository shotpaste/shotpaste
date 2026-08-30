//
//  TranslationViews.swift
//  ShotPaste
//
//  Lightweight One Shot controls and result blocks for the translation mode.
//

import SwiftUI

/// Pure presentation mapping keeps the SwiftUI surface easy to exercise
/// without constructing an overlay window or leaking OCR/translation text.
nonisolated enum TranslationViewPresentation {
  static func progressTitle(for progress: TranslationProgress?) -> String {
    switch progress {
    case .recognizingText: L10n.OneShot.translationRecognizingText
    case .detectingLanguage: L10n.OneShot.translationDetectingLanguage
    case .translatingText: L10n.OneShot.translationTranslatingText
    case .layingOut: L10n.OneShot.translationLayingOut
    case nil: L10n.OneShot.translationInProgress
    }
  }

  static func failureMessage(for failure: TranslationFailure) -> String {
    switch failure {
    case .missingAPIKey: L10n.OneShot.translationMissingAPIKey
    case .invalidConfiguration: L10n.OneShot.translationInvalidConfiguration
    case .recognizedTextSharingDisabled: L10n.OneShot.translationRecognizedTextSharingDisabled
    case .timedOut: L10n.OneShot.translationTimedOut
    case .cancelled: L10n.OneShot.translationCancelled
    case .noText: L10n.OneShot.translationNoText
    case .invalidResponse: L10n.OneShot.translationInvalidResponse
    case .providerStatus(let status): L10n.OneShot.translationProviderStatus(status)
    case .inputTooLarge: L10n.OneShot.translationInputTooLarge
    case .captureFailed: L10n.OneShot.translationCaptureFailed
    case .unavailable: L10n.OneShot.translationUnavailable
    }
  }

  static func showsLowConfidence(
    phase: TranslationSessionPhase,
    lowConfidenceLineCount: Int
  ) -> Bool {
    phase == .showingResult && lowConfidenceLineCount > 0
  }
}

struct OneShotTranslationControls: View {
  @ObservedObject var coordinator: TranslationSessionCoordinator
  let onTranslateFullScreen: () -> Void
  let onTranslateSelection: () -> Void
  let onCopyResult: () -> Void
  let onOpenSettings: () -> Void

  @State private var showsSourcePicker = false
  @State private var showsTargetPicker = false
  @State private var sourceQuery = ""

  private var isRequestInFlight: Bool {
    coordinator.phase == .translating || coordinator.progress != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 9) {
          actionButtons
          languageSelectors
        }
        VStack(alignment: .leading, spacing: 8) {
          actionButtons
          languageSelectors
        }
      }

      if isRequestInFlight, coordinator.progress != nil {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text(progressTitle)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("oneshot-translation-progress")
      }

      if TranslationViewPresentation.showsLowConfidence(
        phase: coordinator.phase,
        lowConfidenceLineCount: coordinator.lowConfidenceLineCount
      ) {
        Label(L10n.OneShot.translationLowConfidence, systemImage: "exclamationmark.circle")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("oneshot-translation-low-confidence")
      }

      if case .failed(let failure) = coordinator.phase {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(message(for: failure))
            .font(.system(size: 11.5, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
          if failure.requiresProviderSettings {
            Button(L10n.OneShot.translationOpenSettings, action: onOpenSettings)
              .buttonStyle(.borderless)
              .font(.system(size: 11.5, weight: .semibold))
          }
        }
        .frame(maxWidth: 520, alignment: .leading)
      }
    }
    .padding(9)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.25), radius: 9, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("oneshot-translation-controls")
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      Button(action: onTranslateFullScreen) {
        if isRequestInFlight {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(fullScreenTitle)
          }
        } else {
          Label(fullScreenTitle, systemImage: "arrow.up.left.and.arrow.down.right")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isRequestInFlight)
      .accessibilityIdentifier("oneshot-translation-full-screen")

      Button(action: onTranslateSelection) {
        if isRequestInFlight {
          Label(selectionTitle, systemImage: "hourglass")
        } else {
          Label(selectionTitle, systemImage: "selection.pin.in.out")
        }
      }
      .buttonStyle(.bordered)
      .disabled(isRequestInFlight)
      .accessibilityIdentifier("oneshot-translation-selection")

      if coordinator.phase == .showingResult {
        Button(action: onCopyResult) {
          Label(L10n.OneShot.translationCopyResult, systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("oneshot-translation-copy-result")
      }
    }
  }

  private var languageSelectors: some View {
    HStack(spacing: 6) {
      Button {
        showsSourcePicker = true
      } label: {
        Label(
          TranslationLanguageCatalog.displayName(for: coordinator.sourceLanguage),
          systemImage: "chevron.down"
        )
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
      }
      .buttonStyle(.bordered)
      .disabled(isRequestInFlight)
      .popover(isPresented: $showsSourcePicker, arrowEdge: .bottom) {
        sourcePicker
      }
      .accessibilityIdentifier("oneshot-translation-source-language")

      Image(systemName: "arrow.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      Button {
        showsTargetPicker = true
      } label: {
        Label(
          TranslationLanguageCatalog.displayName(for: coordinator.targetLanguage),
          systemImage: "chevron.down"
        )
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
      }
      .buttonStyle(.bordered)
      .disabled(isRequestInFlight)
      .popover(isPresented: $showsTargetPicker, arrowEdge: .bottom) {
        targetPicker
      }
      .accessibilityIdentifier("oneshot-translation-target-language")
    }
  }

  private var sourcePicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(L10n.OneShot.translationSearchLanguage, text: $sourceQuery)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("oneshot-translation-source-search")

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(filteredSourceOptions) { option in
            Button {
              coordinator.sourceLanguage = option
              showsSourcePicker = false
              sourceQuery = ""
            } label: {
              languageRow(
                title: TranslationLanguageCatalog.displayName(for: option),
                selected: coordinator.sourceLanguage == option
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(maxHeight: 260)
    }
    .padding(10)
    .frame(width: 230)
  }

  private var targetPicker: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(TranslationLanguageCatalog.targetOptions) { option in
          Button {
            coordinator.targetLanguage = option
            showsTargetPicker = false
          } label: {
            languageRow(
              title: TranslationLanguageCatalog.displayName(for: option),
              selected: coordinator.targetLanguage == option
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .frame(width: 230, height: 260)
    .padding(10)
  }

  private var filteredSourceOptions: [TranslationSourceLanguage] {
    let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return TranslationLanguageCatalog.sourceOptions }
    return TranslationLanguageCatalog.sourceOptions.filter {
      TranslationLanguageCatalog.displayName(for: $0).localizedCaseInsensitiveContains(query)
        || $0.providerValue.localizedCaseInsensitiveContains(query)
    }
  }

  private func languageRow(title: String, selected: Bool) -> some View {
    HStack {
      Text(title)
        .font(.system(size: 13))
      Spacer(minLength: 16)
      if selected {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
  }

  private var fullScreenTitle: String {
    if isRequestInFlight {
      return progressTitle
    }
    return coordinator.phase == .showingResult
      ? L10n.OneShot.translationTranslated : L10n.OneShot.translationFullScreen
  }

  private var selectionTitle: String {
    if isRequestInFlight {
      return progressTitle
    }
    return coordinator.phase == .showingResult
      ? L10n.OneShot.translationTranslated : L10n.OneShot.translationSelection
  }

  private var progressTitle: String {
    TranslationViewPresentation.progressTitle(for: coordinator.progress)
  }

  private func message(for failure: TranslationFailure) -> String {
    TranslationViewPresentation.failureMessage(for: failure)
  }
}

struct TranslationResultBlockView: View {
  let block: TranslationRenderBlock
  let frame: CGRect

  private var textAlignment: TextAlignment {
    switch block.alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  private var alignment: Alignment {
    switch block.alignment {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }

  var body: some View {
    Text(block.translatedText)
      .font(.system(size: block.fontSize, weight: .semibold))
      .multilineTextAlignment(textAlignment)
      .foregroundStyle(block.usesLightBackground ? Color.black : Color.white)
      // Keep the complete value available to the local layout while the
      // fixed frame/overlay clip bounds it. The hover help remains the full
      // translation even when a very long value cannot fit visually.
      .lineLimit(nil)
      .minimumScaleFactor(0.54)
      .frame(width: max(1, frame.width), height: max(1, frame.height), alignment: alignment)
      .padding(4)
      .background(
        RoundedRectangle(cornerRadius: min(8, max(3, frame.height * 0.16)), style: .continuous)
          .fill(
            block.usesLightBackground
              ? Color.white.opacity(0.88) : Color.black.opacity(0.84)
          )
      )
      .rotationEffect(
        .degrees(
          block.direction == .vertical && block.rotationDegrees == 0
            ? 90 : block.rotationDegrees
        )
      )
      .position(x: frame.midX, y: frame.midY)
      .help(block.translatedText)
      .accessibilityLabel(block.translatedText)
      .accessibilityIdentifier("oneshot-translation-result-\(block.id)")
  }
}
