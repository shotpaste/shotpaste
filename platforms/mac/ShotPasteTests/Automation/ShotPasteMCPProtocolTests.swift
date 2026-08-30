//
//  ShotPasteMCPProtocolTests.swift
//  ShotPasteTests
//

@testable import ShotPaste
import XCTest

@MainActor
final class ShotPasteMCPProtocolTests: XCTestCase {
  func testInitializeNegotiatesSupportedVersionAndDeclaresTools() throws {
    let handler = makeHandler()
    let output = handler.handleMessage(try jsonData([
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": [
        "protocolVersion": "2025-11-25",
        "capabilities": [:],
        "clientInfo": ["name": "tests", "version": "1"],
      ],
    ]))

    let response = try responseObject(output)
    let result = try XCTUnwrap(response["result"] as? [String: Any])
    XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
    XCTAssertNotNil(capabilities["tools"])
    let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
    XCTAssertEqual(serverInfo["version"] as? String, "9.9.9-test")
  }

  func testInitializeFallsBackToLatestVersionForUnknownClientVersion() throws {
    let handler = makeHandler()
    let response = try responseObject(handler.handleMessage(try jsonData([
      "jsonrpc": "2.0",
      "id": "init",
      "method": "initialize",
      "params": [
        "protocolVersion": "2099-01-01",
        "capabilities": [:],
        "clientInfo": ["name": "tests", "version": "1"],
      ],
    ])))

    let result = try XCTUnwrap(response["result"] as? [String: Any])
    XCTAssertEqual(result["protocolVersion"] as? String, ShotPasteMCPProtocol.latestProtocolVersion)
  }

  func testToolsListReturnsDeterministicAllowListedTools() throws {
    let response = try responseObject(makeHandler().handleMessage(try jsonData([
      "jsonrpc": "2.0",
      "id": 2,
      "method": "tools/list",
      "params": [:],
    ])))
    let result = try XCTUnwrap(response["result"] as? [String: Any])
    let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

    XCTAssertEqual(tools.compactMap { $0["name"] as? String }, [
      "shotpaste.get_status",
      "shotpaste.start_capture",
      "shotpaste.cancel_capture",
      "shotpaste.open_history",
      "shotpaste.open_settings",
      "shotpaste.control_recording",
    ])
    XCTAssertTrue(tools.allSatisfy { $0["inputSchema"] != nil && $0["outputSchema"] != nil })

    let settingsTool = try XCTUnwrap(tools.first { $0["name"] as? String == "shotpaste.open_settings" })
    let inputSchema = try XCTUnwrap(settingsTool["inputSchema"] as? [String: Any])
    let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
    let tab = try XCTUnwrap(properties["tab"] as? [String: Any])
    let tabValues = try XCTUnwrap(tab["enum"] as? [String])
    XCTAssertTrue(tabValues.contains("agent"))
  }

  func testToolCallMapsArgumentsToSharedAutomationCommand() throws {
    var receivedCommand: ShotPasteAutomationCommand?
    let handler = makeHandler { command in
      receivedCommand = command
      return .success("accepted", state: ["oneShot": "active"])
    }
    let response = try responseObject(handler.handleMessage(try jsonData([
      "jsonrpc": "2.0",
      "id": 3,
      "method": "tools/call",
      "params": [
        "name": "shotpaste.start_capture",
        "arguments": ["mode": "scrolling"],
      ],
    ])))

    XCTAssertEqual(receivedCommand, .startCapture(.scrolling))
    let result = try XCTUnwrap(response["result"] as? [String: Any])
    XCTAssertEqual(result["isError"] as? Bool, false)
    let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
    XCTAssertEqual(structured["ok"] as? Bool, true)
    XCTAssertEqual((structured["state"] as? [String: String])?["oneShot"], "active")
  }

  func testInvalidToolArgumentsReturnToolErrorWithoutExecuting() throws {
    var executionCount = 0
    let handler = makeHandler { _ in
      executionCount += 1
      return .success("unexpected")
    }
    let response = try responseObject(handler.handleMessage(try jsonData([
      "jsonrpc": "2.0",
      "id": 4,
      "method": "tools/call",
      "params": [
        "name": "shotpaste.control_recording",
        "arguments": ["action": "delete"],
      ],
    ])))

    XCTAssertEqual(executionCount, 0)
    let result = try XCTUnwrap(response["result"] as? [String: Any])
    XCTAssertEqual(result["isError"] as? Bool, true)
  }

  func testInitializedNotificationIsAcceptedWithoutResponseBody() throws {
    let output = makeHandler().handleMessage(try jsonData([
      "jsonrpc": "2.0",
      "method": "notifications/initialized",
    ]))

    guard case .acceptedNotification = output else {
      return XCTFail("Expected notification acknowledgement")
    }
  }

  func testHTTPParserWaitsForCompleteBodyAndNormalizesHeaders() throws {
    let body = try jsonData(["jsonrpc": "2.0", "id": 1, "method": "ping"])
    let head = [
      "POST /mcp HTTP/1.1",
      "Host: 127.0.0.1:48123",
      "Content-Type: application/json",
      "Content-Length: \(body.count)",
      "",
      "",
    ].joined(separator: "\r\n")
    var requestData = Data(head.utf8)
    requestData.append(body.prefix(body.count - 1))

    guard case .incomplete = ShotPasteHTTPRequestParser.parse(requestData) else {
      return XCTFail("Expected incomplete request")
    }

    requestData.append(body.suffix(1))
    guard case .complete(let request) = ShotPasteHTTPRequestParser.parse(requestData) else {
      return XCTFail("Expected complete request")
    }
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/mcp")
    XCTAssertEqual(request.headers["host"], "127.0.0.1:48123")
    XCTAssertEqual(request.body, body)
  }

  private func makeHandler(
    execute: @escaping (ShotPasteAutomationCommand) -> ShotPasteAutomationResult = { _ in
      .success("accepted")
    }
  ) -> ShotPasteMCPProtocol {
    ShotPasteMCPProtocol(
      execute: execute,
      status: { .success("status", state: ["platform": "macOS"]) },
      serverVersion: { "9.9.9-test" }
    )
  }

  private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func responseObject(_ output: ShotPasteMCPProtocolOutput) throws -> [String: Any] {
    guard case .response(let response) = output else {
      XCTFail("Expected JSON-RPC response")
      throw NSError(domain: "ShotPasteMCPProtocolTests", code: 1)
    }
    return response
  }
}
