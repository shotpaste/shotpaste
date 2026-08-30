//
//  Text provider router implementation.
//  ShotPaste
//
//  Text-only protocol router. The concrete adapters own the HTTP protocol;
//  this file only selects the already configured OpenAI-compatible or
//  Anthropic text adapter and never inspects Agent Mode image preferences.
//

import Foundation

nonisolated struct TranslationConfigurableTextProvider: TranslationTextProvider, Sendable {
  private let openAIProvider: OpenAITextTranslationProvider
  private let anthropicProvider: AnthropicTextTranslationProvider

  init(
    openAIProvider: OpenAITextTranslationProvider = OpenAITextTranslationProvider(),
    anthropicProvider: AnthropicTextTranslationProvider = AnthropicTextTranslationProvider()
  ) {
    self.openAIProvider = openAIProvider
    self.anthropicProvider = anthropicProvider
  }

  func translate(
    request: TranslationTextRequest,
    configuration: AgentProviderConfiguration,
    apiKey: String?,
    deadline: Date
  ) async throws -> TranslationTextResponse {
    switch configuration.apiProtocol {
    case .openAICompatible:
      try await openAIProvider.translate(
        request: request,
        configuration: configuration,
        apiKey: apiKey,
        deadline: deadline
      )
    case .anthropicMessages:
      try await anthropicProvider.translate(
        request: request,
        configuration: configuration,
        apiKey: apiKey,
        deadline: deadline
      )
    }
  }
}
