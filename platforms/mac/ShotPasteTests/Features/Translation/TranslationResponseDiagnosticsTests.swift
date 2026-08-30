//
//  TranslationResponseDiagnosticsTests.swift
//  ShotPasteTests
//

import Foundation
@testable import ShotPaste
import XCTest

final class TranslationResponseDiagnosticsTests: XCTestCase {
  func testOpenAISummaryCapturesResponseShapeWithoutValues() throws {
    let responseBody: [String: Any] = [
      "choices": [[
        "message": [
          "content": "translated secret text",
          "tool_calls": [[
            "type": "function",
            "function": [
              "name": TranslationTextPrompt.toolName,
              "arguments": "{\"translated_text\":\"translated secret text\"}",
            ],
          ]],
        ],
      ]],
    ]
    let data = try JSONSerialization.data(withJSONObject: responseBody)
    let request = URLRequest(url: try XCTUnwrap(URL(string: "http://192.168.31.67:8317/v1/chat/completions")))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    )

    let summary = TranslationResponseDiagnostics.summary(
      request: request,
      response: response,
      data: data,
      attempt: 0
    )

    XCTAssertEqual(summary["http_status"], "200")
    XCTAssertEqual(summary["response_bytes"], "\(data.count)")
    XCTAssertEqual(summary["json_root"], "object")
    XCTAssertEqual(summary["choices_count"], "1")
    XCTAssertEqual(summary["message_content_type"], "string")
    XCTAssertEqual(summary["tool_calls_count"], "1")
    XCTAssertEqual(summary["tool_name"], TranslationTextPrompt.toolName)
    XCTAssertEqual(summary["tool_arguments_type"], "string")

    let values = summary.values.joined(separator: "|")
    XCTAssertFalse(values.contains("translated secret text"))
  }

  func testSummaryIdentifiesInvalidJSONWithoutLoggingBody() throws {
    let secretBody = "provider secret error body"
    let data = Data(secretBody.utf8)
    let request = URLRequest(url: try XCTUnwrap(URL(string: "https://provider.example.test/v1/chat/completions")))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 502,
        httpVersion: nil,
        headerFields: ["Content-Type": "text/plain"]
      )
    )

    let summary = TranslationResponseDiagnostics.summary(
      request: request,
      response: response,
      data: data,
      attempt: 1
    )

    XCTAssertEqual(summary["attempt"], "2")
    XCTAssertEqual(summary["http_status"], "502")
    XCTAssertEqual(summary["json_root"], "invalid")
    XCTAssertFalse(summary.values.joined(separator: "|").contains(secretBody))
  }

  func testAnthropicSummaryCapturesBlockTypesWithoutText() throws {
    let responseBody: [String: Any] = [
      "content": [
        ["type": "thinking", "thinking": "private reasoning"],
        [
          "type": "tool_use",
          "name": TranslationTextPrompt.toolName,
          "input": ["translated_text": "translated secret text"],
        ],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: responseBody)
    let request = URLRequest(url: try XCTUnwrap(URL(string: "https://provider.example.test/v1/messages")))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    )

    let summary = TranslationResponseDiagnostics.summary(
      request: request,
      response: response,
      data: data,
      attempt: 0
    )

    XCTAssertEqual(summary["content_blocks_count"], "2")
    XCTAssertEqual(summary["content_block_types"], "thinking,tool_use")
    XCTAssertEqual(summary["tool_use_count"], "1")
    XCTAssertEqual(summary["tool_use_name"], TranslationTextPrompt.toolName)
    XCTAssertEqual(summary["tool_use_input_type"], "object")
    XCTAssertFalse(summary.values.joined(separator: "|").contains("private reasoning"))
    XCTAssertFalse(summary.values.joined(separator: "|").contains("translated secret text"))
  }

  func testResponseSummaryLoggingIsDebugOnly() {
    XCTAssertTrue(AppVariant.debug.logsTranslationResponseSummaries)
    XCTAssertFalse(AppVariant.release.logsTranslationResponseSummaries)
  }
}
