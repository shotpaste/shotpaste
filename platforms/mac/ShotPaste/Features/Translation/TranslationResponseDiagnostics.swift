//
//  TranslationResponseDiagnostics.swift
//  ShotPaste
//
//  Debug-only metadata summaries for text-provider responses. Response bodies,
//  OCR text, translated text, prompts, and credentials are never logged.
//

import Foundation

nonisolated enum TranslationResponseDiagnostics {
  static func logIfEnabled(
    request: URLRequest,
    response: URLResponse,
    data: Data,
    attempt: Int,
    variant: AppVariant = .current
  ) {
    guard variant.logsTranslationResponseSummaries else { return }

    DiagnosticLogger.shared.log(
      .debug,
      .action,
      "Translation provider response summary",
      context: summary(
        request: request,
        response: response,
        data: data,
        attempt: attempt
      )
    )
  }

  /// Returns bounded, value-free response metadata for deterministic tests and
  /// the Debug log. All server-controlled strings are reduced to safe tokens.
  static func summary(
    request: URLRequest,
    response: URLResponse,
    data: Data,
    attempt: Int
  ) -> [String: String] {
    var context: [String: String] = [
      "attempt": "\(max(1, attempt + 1))",
      "content_type": safeMetadata(response.mimeType ?? "unknown"),
      "request_method": safeMetadata(request.httpMethod ?? "unknown"),
      "response_bytes": "\(data.count)",
      "summary_version": "1",
    ]

    if let url = request.url {
      context["endpoint_host"] = safeMetadata(url.host ?? "unknown")
      context["endpoint_path"] = safeMetadata(url.path.isEmpty ? "/" : url.path)
    }

    if let httpResponse = response as? HTTPURLResponse {
      context["http_status"] = "\(httpResponse.statusCode)"
    } else {
      context["http_status"] = "non_http_response"
    }

    guard let object = try? JSONSerialization.jsonObject(with: data) else {
      context["json_root"] = "invalid"
      return context
    }

    context["json_root"] = valueKind(object)
    guard let root = object as? [String: Any] else { return context }

    context["root_keys"] = safeKeyList(Array(root.keys))
    summarizeOpenAI(root, into: &context)
    summarizeAnthropic(root, into: &context)
    return context
  }

  private static func summarizeOpenAI(
    _ root: [String: Any],
    into context: inout [String: String]
  ) {
    guard let rawChoices = root["choices"] else { return }
    context["choices_type"] = valueKind(rawChoices)
    guard let choices = rawChoices as? [[String: Any]] else { return }

    context["choices_count"] = "\(choices.count)"
    guard let firstChoice = choices.first else { return }
    context["first_choice_keys"] = safeKeyList(Array(firstChoice.keys))

    let rawMessage = firstChoice["message"]
    context["message_type"] = valueKind(rawMessage)
    guard let message = rawMessage as? [String: Any] else { return }

    context["message_keys"] = safeKeyList(Array(message.keys))
    context["message_content_type"] = valueKind(message["content"])
    if message.keys.contains("refusal") {
      context["message_refusal_type"] = valueKind(message["refusal"])
    }

    let rawToolCalls = message["tool_calls"]
    context["tool_calls_type"] = valueKind(rawToolCalls)
    guard let rawToolCalls,
          let toolCalls = rawToolCalls as? [[String: Any]] else { return }

    context["tool_calls_count"] = "\(toolCalls.count)"
    guard let firstToolCall = toolCalls.first else { return }
    context["first_tool_call_keys"] = safeKeyList(Array(firstToolCall.keys))

    let rawFunction = firstToolCall["function"]
    context["function_type"] = valueKind(rawFunction)
    guard let function = rawFunction as? [String: Any] else { return }

    context["function_keys"] = safeKeyList(Array(function.keys))
    context["tool_name"] = safeMetadata(function["name"] as? String ?? "missing")
    context["tool_arguments_type"] = valueKind(function["arguments"])
  }

  private static func summarizeAnthropic(
    _ root: [String: Any],
    into context: inout [String: String]
  ) {
    guard let rawContent = root["content"] else { return }
    context["content_blocks_type"] = valueKind(rawContent)
    guard let content = rawContent as? [[String: Any]] else { return }

    context["content_blocks_count"] = "\(content.count)"
    context["content_block_types"] = safeTypeList(content)
    guard let firstBlock = content.first else { return }
    context["first_content_block_keys"] = safeKeyList(Array(firstBlock.keys))

    let toolUseBlocks = content.filter { $0["type"] as? String == "tool_use" }
    context["tool_use_count"] = "\(toolUseBlocks.count)"
    guard let firstToolUse = toolUseBlocks.first else { return }
    context["tool_use_name"] = safeMetadata(firstToolUse["name"] as? String ?? "missing")
    context["tool_use_input_type"] = valueKind(firstToolUse["input"])
  }

  private static func valueKind(_ value: Any?) -> String {
    guard let value else { return "missing" }
    if value is NSNull { return "null" }
    if value is String { return "string" }
    if value is [String: Any] { return "object" }
    if value is [Any] { return "array" }
    if value is NSNumber { return "number_or_bool" }
    return "other"
  }

  private static func safeKeyList(_ keys: [String]) -> String {
    let sortedKeys = keys.sorted()
    let visibleKeys = sortedKeys.prefix(16).map { safeMetadata($0, maximumLength: 64) }
    let suffix = sortedKeys.count > visibleKeys.count ? ",+\(sortedKeys.count - visibleKeys.count)" : ""
    return visibleKeys.joined(separator: ",") + suffix
  }

  private static func safeTypeList(_ blocks: [[String: Any]]) -> String {
    let visibleBlocks = blocks.prefix(16)
    let types = visibleBlocks.map { safeMetadata($0["type"] as? String ?? "missing", maximumLength: 64) }
    let suffix = blocks.count > visibleBlocks.count ? ",+\(blocks.count - visibleBlocks.count)" : ""
    return types.joined(separator: ",") + suffix
  }

  private static func safeMetadata(_ value: String, maximumLength: Int = 128) -> String {
    let sanitized = value.map { character in
      if character.isLetter || character.isNumber || "._:/-".contains(character) {
        return character
      }
      return "_"
    }
    return String(sanitized.prefix(maximumLength))
  }
}
