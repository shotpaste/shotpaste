//
//  ShotPasteMCPProtocol.swift
//  ShotPaste
//
//  Minimal MCP 2025-11-25 JSON-RPC implementation for ShotPaste tools.
//

import Foundation

enum ShotPasteMCPProtocolOutput {
  case response([String: Any])
  case acceptedNotification
}

@MainActor
struct ShotPasteMCPProtocol {
  static let latestProtocolVersion = "2025-11-25"
  static let supportedProtocolVersions = Set([
    latestProtocolVersion,
    "2025-06-18",
    "2025-03-26",
  ])

  private let execute: (ShotPasteAutomationCommand) -> ShotPasteAutomationResult
  private let status: () -> ShotPasteAutomationResult
  private let serverVersion: () -> String

  init(
    execute: @escaping (ShotPasteAutomationCommand) -> ShotPasteAutomationResult,
    status: @escaping () -> ShotPasteAutomationResult,
    serverVersion: @escaping () -> String = {
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
  ) {
    self.execute = execute
    self.status = status
    self.serverVersion = serverVersion
  }

  func handleMessage(_ data: Data) -> ShotPasteMCPProtocolOutput {
    let message: Any
    do {
      message = try JSONSerialization.jsonObject(with: data)
    } catch {
      return .response(Self.errorResponse(id: nil, code: -32700, message: "Parse error"))
    }

    guard let request = message as? [String: Any], request["jsonrpc"] as? String == "2.0" else {
      return .response(Self.errorResponse(id: nil, code: -32600, message: "Invalid Request"))
    }

    guard let method = request["method"] as? String else {
      // The server never sends JSON-RPC requests, so a well-formed response can
      // be safely acknowledged without additional processing.
      if request["id"] != nil, request["result"] != nil || request["error"] != nil {
        return .acceptedNotification
      }
      return .response(Self.errorResponse(id: request["id"], code: -32600, message: "Invalid Request"))
    }

    let id = request["id"]
    if id == nil {
      return handleNotification(method: method)
    }

    switch method {
    case "initialize":
      return .response(initializeResponse(id: id, params: request["params"]))
    case "ping":
      return .response(Self.successResponse(id: id, result: [:]))
    case "tools/list":
      return .response(Self.successResponse(id: id, result: ["tools": Self.tools]))
    case "tools/call":
      return .response(callToolResponse(id: id, params: request["params"]))
    default:
      return .response(Self.errorResponse(id: id, code: -32601, message: "Method not found"))
    }
  }

  private func handleNotification(method: String) -> ShotPasteMCPProtocolOutput {
    switch method {
    case "notifications/initialized", "notifications/cancelled":
      .acceptedNotification
    default:
      // JSON-RPC notifications never receive a response, including unknown
      // notification methods.
      .acceptedNotification
    }
  }

  private func initializeResponse(id: Any?, params: Any?) -> [String: Any] {
    guard
      let params = params as? [String: Any],
      let requestedVersion = params["protocolVersion"] as? String,
      params["capabilities"] is [String: Any],
      params["clientInfo"] is [String: Any]
    else {
      return Self.errorResponse(id: id, code: -32602, message: "Invalid initialize parameters")
    }

    let negotiatedVersion = Self.supportedProtocolVersions.contains(requestedVersion)
      ? requestedVersion
      : Self.latestProtocolVersion
    return Self.successResponse(
      id: id,
      result: [
        "protocolVersion": negotiatedVersion,
        "capabilities": [
          "tools": ["listChanged": false],
        ],
        "serverInfo": [
          "name": "shotpaste-macos",
          "title": "ShotPaste for macOS",
          "version": serverVersion(),
          "description": "Local automation tools for the running ShotPaste application.",
        ],
        "instructions": "Use these tools to operate the local ShotPaste UI. Capture commands remain visible and user-controlled.",
      ]
    )
  }

  private func callToolResponse(id: Any?, params: Any?) -> [String: Any] {
    guard
      let params = params as? [String: Any],
      let name = params["name"] as? String
    else {
      return Self.errorResponse(id: id, code: -32602, message: "Invalid tools/call parameters")
    }

    let arguments: [String: Any]
    if let suppliedArguments = params["arguments"] {
      guard let suppliedArguments = suppliedArguments as? [String: Any] else {
        return Self.errorResponse(id: id, code: -32602, message: "Tool arguments must be an object")
      }
      arguments = suppliedArguments
    } else {
      arguments = [:]
    }

    let result: ShotPasteAutomationResult
    switch name {
    case "shotpaste.get_status":
      guard arguments.isEmpty else {
        return Self.toolResultResponse(
          id: id,
          result: .failure("shotpaste.get_status does not accept arguments.")
        )
      }
      result = status()
    case "shotpaste.start_capture":
      guard
        Set(arguments.keys).isSubset(of: ["mode"]),
        let rawMode = arguments["mode"] as? String,
        let mode = ShotPasteAutomationCaptureMode(rawValue: rawMode.lowercased())
      else {
        return Self.toolResultResponse(
          id: id,
          result: .failure("mode must be screenshot, scrolling, or recording.")
        )
      }
      result = execute(.startCapture(mode))
    case "shotpaste.cancel_capture":
      guard arguments.isEmpty else {
        return Self.toolResultResponse(
          id: id,
          result: .failure("shotpaste.cancel_capture does not accept arguments.")
        )
      }
      result = execute(.cancelCapture)
    case "shotpaste.open_history":
      guard Set(arguments.keys).isSubset(of: ["filter"]) else {
        return Self.toolResultResponse(
          id: id,
          result: .failure("shotpaste.open_history only accepts filter.")
        )
      }
      let filter: ShotPasteAutomationHistoryFilter?
      if let rawFilter = arguments["filter"] as? String {
        guard let parsedFilter = ShotPasteAutomationHistoryFilter(rawValue: rawFilter.lowercased()) else {
          return Self.toolResultResponse(
            id: id,
            result: .failure("filter must be all, screenshot, scrolling, recording, or clipboard.")
          )
        }
        filter = parsedFilter
      } else {
        filter = nil
      }
      result = execute(.openHistory(filter))
    case "shotpaste.open_settings":
      guard Set(arguments.keys).isSubset(of: ["tab"]) else {
        return Self.toolResultResponse(
          id: id,
          result: .failure("shotpaste.open_settings only accepts tab.")
        )
      }
      let tab: PreferencesTab?
      if let rawTab = arguments["tab"] as? String {
        guard let parsedTab = ShotPasteAutomationCommand.preferencesTab(named: rawTab) else {
          return Self.toolResultResponse(
            id: id,
            result: .failure(
              "tab must be general, capture, quick-access, history, agent, shortcuts, permissions, or advanced."
            )
          )
        }
        tab = parsedTab
      } else {
        tab = nil
      }
      result = execute(.openSettings(tab))
    case "shotpaste.control_recording":
      guard
        Set(arguments.keys).isSubset(of: ["action"]),
        let rawAction = arguments["action"] as? String,
        let action = ShotPasteAutomationRecordingAction(rawValue: rawAction.lowercased())
      else {
        return Self.toolResultResponse(
          id: id,
          result: .failure("action must be pause, resume, or stop.")
        )
      }
      result = execute(.controlRecording(action))
    default:
      return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
    }

    return Self.toolResultResponse(id: id, result: result)
  }

  private static func successResponse(id: Any?, result: [String: Any]) -> [String: Any] {
    [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "result": result,
    ]
  }

  private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
    [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": [
        "code": code,
        "message": message,
      ],
    ]
  }

  private static func toolResultResponse(
    id: Any?,
    result: ShotPasteAutomationResult
  ) -> [String: Any] {
    let structuredContent: [String: Any] = [
      "ok": result.isSuccess,
      "message": result.message,
      "state": result.state,
    ]
    let text = serializedJSONString(structuredContent)
    return successResponse(
      id: id,
      result: [
        "content": [
          ["type": "text", "text": text],
        ],
        "structuredContent": structuredContent,
        "isError": !result.isSuccess,
      ]
    )
  }

  private static func serializedJSONString(_ object: [String: Any]) -> String {
    guard
      JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{\"ok\":false,\"message\":\"Unable to serialize tool result.\",\"state\":{}}"
    }
    return string
  }

  private static let resultOutputSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "ok": ["type": "boolean"],
      "message": ["type": "string"],
      "state": [
        "type": "object",
        "additionalProperties": ["type": "string"],
      ],
    ],
    "required": ["ok", "message", "state"],
    "additionalProperties": false,
  ]

  private static let tools: [[String: Any]] = [
    tool(
      name: "shotpaste.get_status",
      title: "Get ShotPaste status",
      description: "Read the current One Shot, scrolling capture, recording, and history UI state.",
      inputSchema: emptyInputSchema,
      readOnly: true,
      idempotent: true
    ),
    tool(
      name: "shotpaste.start_capture",
      title: "Start ShotPaste capture",
      description: "Open the visible One Shot selection UI with screenshot, scrolling, or recording preselected.",
      inputSchema: [
        "type": "object",
        "properties": [
          "mode": [
            "type": "string",
            "enum": ShotPasteAutomationCaptureMode.allCases.map(\.rawValue),
            "description": "The One Shot mode to preselect.",
          ],
        ],
        "required": ["mode"],
        "additionalProperties": false,
      ],
      readOnly: false,
      idempotent: false
    ),
    tool(
      name: "shotpaste.cancel_capture",
      title: "Cancel ShotPaste capture",
      description: "Cancel the active One Shot selection session, if one exists.",
      inputSchema: emptyInputSchema,
      readOnly: false,
      idempotent: true
    ),
    tool(
      name: "shotpaste.open_history",
      title: "Open ShotPaste history",
      description: "Open the full ShotPaste history UI, optionally with a product filter.",
      inputSchema: [
        "type": "object",
        "properties": [
          "filter": [
            "type": "string",
            "enum": ShotPasteAutomationHistoryFilter.allCases.map(\.rawValue),
            "description": "Omit this value to use the user's configured default filter.",
          ],
        ],
        "additionalProperties": false,
      ],
      readOnly: false,
      idempotent: true
    ),
    tool(
      name: "shotpaste.open_settings",
      title: "Open ShotPaste settings",
      description: "Open ShotPaste settings at an optional tab.",
      inputSchema: [
        "type": "object",
        "properties": [
          "tab": [
            "type": "string",
            "enum": [
              "general", "capture", "quick-access", "history", "agent", "shortcuts", "permissions", "advanced",
            ],
          ],
        ],
        "additionalProperties": false,
      ],
      readOnly: false,
      idempotent: true
    ),
    tool(
      name: "shotpaste.control_recording",
      title: "Control ShotPaste recording",
      description: "Pause, resume, or stop the active ShotPaste recording.",
      inputSchema: [
        "type": "object",
        "properties": [
          "action": [
            "type": "string",
            "enum": ShotPasteAutomationRecordingAction.allCases.map(\.rawValue),
          ],
        ],
        "required": ["action"],
        "additionalProperties": false,
      ],
      readOnly: false,
      idempotent: true
    ),
  ]

  private static let emptyInputSchema: [String: Any] = [
    "type": "object",
    "additionalProperties": false,
  ]

  private static func tool(
    name: String,
    title: String,
    description: String,
    inputSchema: [String: Any],
    readOnly: Bool,
    idempotent: Bool
  ) -> [String: Any] {
    [
      "name": name,
      "title": title,
      "description": description,
      "inputSchema": inputSchema,
      "outputSchema": resultOutputSchema,
      "annotations": [
        "readOnlyHint": readOnly,
        "destructiveHint": false,
        "idempotentHint": idempotent,
        "openWorldHint": false,
      ],
      "execution": ["taskSupport": "forbidden"],
    ]
  }
}
