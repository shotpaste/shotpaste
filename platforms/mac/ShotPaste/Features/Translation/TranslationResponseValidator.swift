//
//  TranslationResponseValidator.swift
//  ShotPaste
//
//  Strict, id-keyed validation for text translation responses.  This validator
//  intentionally does not expose or preserve provider geometry.
//

import Foundation

/// Parses and validates the provider's inner text-translation object.
///
/// The legacy image translation implementation currently has a type with the
/// shorter name `TranslationResponseValidator`; the `TranslationText` prefix
/// keeps this new protocol stack source-compatible until that implementation is
/// removed by the coordinator integration.
nonisolated enum TranslationTextResponseValidator {
  static func validate(
    _ response: TranslationTextResponse,
    against request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    try TranslationTextRequestValidator.validate(request)
    guard !request.blocks.isEmpty,
          response.generationID == request.generationID,
          response.translations.count == request.blocks.count
    else {
      throw TranslationTextProviderError.invalidResponse
    }

    let expectedIDs = Set(request.blocks.map(\.id))
    var returnedIDs = Set<String>()
    var translatedCharacters = 0
    var normalizedTranslations: [TranslationTextResultBlock] = []
    normalizedTranslations.reserveCapacity(response.translations.count)

    // Keep the provider's contract one-to-one and deterministic. Rendering is
    // still keyed by ID, but a reordered response is a protocol violation and
    // should not be silently normalized by the client.
    guard response.translations.map(\.id) == request.blocks.map(\.id) else {
      throw TranslationTextProviderError.invalidResponse
    }

    for translation in response.translations {
      let trimmedID = translation.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedText = translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedID == translation.id,
            expectedIDs.contains(translation.id),
            returnedIDs.insert(translation.id).inserted,
            !trimmedText.isEmpty,
            trimmedText.count <= TranslationTextLimits.maximumTranslatedCharactersPerBlock
      else {
        throw TranslationTextProviderError.invalidResponse
      }
      translatedCharacters += trimmedText.count
      guard translatedCharacters <= TranslationTextLimits.maximumTranslatedCharactersPerBatch else {
        throw TranslationTextProviderError.invalidResponse
      }
      normalizedTranslations.append(
        TranslationTextResultBlock(id: translation.id, translatedText: trimmedText)
      )
    }

    guard returnedIDs == expectedIDs else {
      throw TranslationTextProviderError.invalidResponse
    }
    return TranslationTextResponse(
      generationID: response.generationID,
      translations: normalizedTranslations
    )
  }

  /// Strict JSON fallback parser.  Whitespace around the object is accepted;
  /// Markdown fences, prose, arrays, and scalar JSON values are rejected.
  static func decodeStrictJSON(
    _ data: Data,
    against request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    guard let string = String(data: data, encoding: .utf8) else {
      throw TranslationTextProviderError.invalidResponse
    }
    return try decodeStrictJSON(string, against: request)
  }

  static func decodeStrictJSON(
    _ string: String,
    against request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{", trimmed.last == "}" else {
      throw TranslationTextProviderError.invalidResponse
    }
    guard let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
    else {
      throw TranslationTextProviderError.invalidResponse
    }
    return try decodeObject(dictionary, against: request)
  }

  /// Parses an object extracted from a tool call.  Unknown keys are rejected
  /// so the protocol cannot accidentally grow a coordinate-bearing response;
  /// no geometry is ever decoded into a result type.
  static func decodeObject(
    _ object: [String: Any],
    against request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    guard Set(object.keys) == Set(["generation_id", "translations"]),
          let generationID = object["generation_id"] as? String,
          let rawTranslations = object["translations"] as? [[String: Any]]
    else {
      throw TranslationTextProviderError.invalidResponse
    }

    let translations = try rawTranslations.map { raw -> TranslationTextResultBlock in
      guard Set(raw.keys) == Set(["id", "translated_text"]),
            let id = raw["id"] as? String,
            let translatedText = raw["translated_text"] as? String
      else {
        throw TranslationTextProviderError.invalidResponse
      }
      return TranslationTextResultBlock(id: id, translatedText: translatedText)
    }
    return try validate(
      TranslationTextResponse(generationID: generationID, translations: translations),
      against: request
    )
  }

  /// Converts a provider tool argument string without accepting prose around
  /// the JSON object.  This is kept separate from the network adapters so both
  /// protocols use precisely the same validation rules.
  static func decodeToolArguments(
    _ arguments: String,
    against request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    try decodeStrictJSON(arguments, against: request)
  }

  static func decodeToolArguments(
    _ arguments: [String: Any],
    against request: TranslationTextRequest
  ) throws -> TranslationTextResponse {
    try decodeObject(arguments, against: request)
  }
}
