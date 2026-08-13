//
//  ShotPasteMCPServer.swift
//  ShotPaste
//
//  Authenticated MCP Streamable HTTP endpoint bound to IPv4 loopback only.
//

import Combine
import Foundation
import Network
import Security

enum ShotPasteMCPServerState: Equatable {
  case stopped
  case starting(Int)
  case running(Int)
  case failed(String)

  var isRunning: Bool {
    if case .running = self {
      return true
    }
    return false
  }
}

@MainActor
final class ShotPasteMCPServer: ObservableObject {
  static let shared = ShotPasteMCPServer()

  static var defaultPort: Int {
    AppVariant.current.defaultMCPPort
  }

  static let allowedPortRange = 1_024 ... 65_535

  @Published private(set) var state: ShotPasteMCPServerState = .stopped

  private let defaults: UserDefaults
  private let networkQueue = DispatchQueue(label: "com.ahtcfg24.shotpaste.mcp", qos: .userInitiated)
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var defaultsObserver: NSObjectProtocol?
  private var protocolHandler: ShotPasteMCPProtocol?
  private var activePort: Int?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var configuredPort: Int {
    let storedPort = defaults.integer(forKey: PreferencesKeys.mcpServerPort)
    return Self.allowedPortRange.contains(storedPort) ? storedPort : Self.defaultPort
  }

  var endpointURLString: String {
    "http://127.0.0.1:\(activePort ?? configuredPort)/mcp"
  }

  func configure(automationController: ShotPasteAutomationController) {
    protocolHandler = ShotPasteMCPProtocol(
      execute: { [weak automationController] command in
        guard let automationController else {
          return .failure("ShotPaste automation is not ready.")
        }
        return automationController.execute(command, source: "mcp")
      },
      status: { [weak automationController] in
        automationController?.status() ?? .failure("ShotPaste automation is not ready.")
      }
    )

    if defaultsObserver == nil {
      defaultsObserver = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification,
        object: defaults,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.synchronizeWithPreferences()
        }
      }
    }
    synchronizeWithPreferences()
  }

  func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: PreferencesKeys.mcpServerEnabled)
    synchronizeWithPreferences()
  }

  func synchronizeWithPreferences() {
    let enabled = defaults.object(forKey: PreferencesKeys.mcpServerEnabled) as? Bool ?? false
    guard enabled else {
      stop()
      return
    }

    let port = configuredPort
    switch state {
    case .starting(let currentPort) where currentPort == port:
      return
    case .running(let currentPort) where currentPort == port:
      return
    default:
      start(port: port)
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    connections.values.forEach { $0.cancel() }
    connections.removeAll()
    activePort = nil
    if state != .stopped {
      state = .stopped
      DiagnosticLogger.shared.log(.info, .lifecycle, "MCP server stopped")
    }
  }

  func connectionConfigurationJSON() -> String {
    Self.connectionConfigurationJSON(
      clientName: AppVariant.current.mcpClientName,
      endpointURLString: endpointURLString,
      authorizationToken: authorizationToken()
    )
  }

  nonisolated static func connectionConfigurationJSON(
    clientName: String,
    endpointURLString: String,
    authorizationToken: String
  ) -> String {
    let object: [String: Any] = [
      "mcpServers": [
        clientName: [
          "type": "http",
          "url": endpointURLString,
          "headers": [
            "Authorization": "Bearer \(authorizationToken)",
          ],
        ],
      ],
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else { return "" }
    return string
  }

  private func start(port: Int) {
    guard protocolHandler != nil else {
      state = .failed("Automation controller is not ready.")
      return
    }

    listener?.cancel()
    connections.values.forEach { $0.cancel() }
    connections.removeAll()

    guard let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
      state = .failed("Invalid MCP port \(port).")
      return
    }

    do {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: networkPort)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      activePort = port
      state = .starting(port)
      _ = authorizationToken()

      listener.stateUpdateHandler = { [weak self, weak listener] newState in
        Task { @MainActor [weak self, weak listener] in
          guard let self, let listener, self.listener === listener else { return }
          handleListenerState(newState, port: port)
        }
      }
      listener.newConnectionHandler = { [weak self, weak listener] connection in
        Task { @MainActor [weak self, weak listener] in
          guard let self, let listener, self.listener === listener else {
            connection.cancel()
            return
          }
          accept(connection)
        }
      }
      listener.start(queue: networkQueue)
    } catch {
      activePort = nil
      state = .failed(error.localizedDescription)
      DiagnosticLogger.shared.logError(.lifecycle, error, "MCP server failed to start")
    }
  }

  private func handleListenerState(_ listenerState: NWListener.State, port: Int) {
    switch listenerState {
    case .ready:
      state = .running(port)
      DiagnosticLogger.shared.log(
        .info,
        .lifecycle,
        "MCP server listening",
        context: ["host": "127.0.0.1", "port": "\(port)"]
      )
    case .failed(let error):
      listener?.cancel()
      listener = nil
      activePort = nil
      state = .failed(error.localizedDescription)
      DiagnosticLogger.shared.logError(
        .lifecycle,
        error,
        "MCP server listener failed",
        context: ["port": "\(port)"]
      )
    case .cancelled:
      if state != .stopped {
        state = .stopped
      }
    case .setup, .waiting:
      break
    @unknown default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    let id = UUID()
    connections[id] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
      guard connection != nil else { return }
      if case .failed = connectionState {
        Task { @MainActor [weak self] in self?.closeConnection(id) }
      } else if case .cancelled = connectionState {
        Task { @MainActor [weak self] in self?.closeConnection(id) }
      }
    }
    connection.start(queue: networkQueue)
    receive(on: connection, id: id, accumulatedData: Data())
  }

  private func receive(on connection: NWConnection, id: UUID, accumulatedData: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
      [weak self, weak connection] data, _, isComplete, error in
      guard let connection else { return }
      var requestData = accumulatedData
      if let data {
        requestData.append(data)
      }
      let completeRequestData = requestData

      Task { @MainActor [weak self, weak connection, completeRequestData] in
        guard let self, let connection, connections[id] === connection else { return }
        if let error {
          DiagnosticLogger.shared.logError(.lifecycle, error, "MCP connection receive failed")
          closeConnection(id)
          return
        }

        switch ShotPasteHTTPRequestParser.parse(completeRequestData) {
        case .incomplete:
          if isComplete {
            send(.badRequest("Incomplete HTTP request."), on: connection, id: id)
          } else {
            receive(on: connection, id: id, accumulatedData: completeRequestData)
          }
        case .failure(let failure):
          send(failure.response, on: connection, id: id)
        case .complete(let request):
          handle(request, on: connection, id: id)
        }
      }
    }
  }

  private func handle(_ request: ShotPasteHTTPRequest, on connection: NWConnection, id: UUID) {
    guard request.path == "/mcp" else {
      send(.notFound, on: connection, id: id)
      return
    }

    let expectedHostValues = Set([
      "127.0.0.1:\(configuredPort)",
      "localhost:\(configuredPort)",
    ])
    guard
      let host = request.headers["host"]?.lowercased(),
      expectedHostValues.contains(host)
    else {
      send(.misdirectedRequest, on: connection, id: id)
      return
    }

    if let origin = request.headers["origin"]?.lowercased() {
      let allowedOrigins = Set(expectedHostValues.map { "http://\($0)" })
      guard allowedOrigins.contains(origin) else {
        send(.forbidden("Invalid Origin header."), on: connection, id: id)
        return
      }
    }

    let expectedAuthorization = "Bearer \(authorizationToken())"
    guard
      let authorization = request.headers["authorization"],
      Self.constantTimeEqual(authorization, expectedAuthorization)
    else {
      send(.unauthorized, on: connection, id: id)
      return
    }

    guard request.method == "POST" else {
      send(.methodNotAllowed, on: connection, id: id)
      return
    }

    guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
      send(.unsupportedMediaType, on: connection, id: id)
      return
    }

    if let protocolVersion = request.headers["mcp-protocol-version"],
       !ShotPasteMCPProtocol.supportedProtocolVersions.contains(protocolVersion) {
      send(.badRequest("Unsupported MCP-Protocol-Version."), on: connection, id: id)
      return
    }

    guard let protocolHandler else {
      send(.serviceUnavailable, on: connection, id: id)
      return
    }

    switch protocolHandler.handleMessage(request.body) {
    case .acceptedNotification:
      send(.accepted, on: connection, id: id)
    case .response(let responseObject):
      guard let data = try? JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys]) else {
        send(.internalServerError, on: connection, id: id)
        return
      }
      send(.json(data), on: connection, id: id)
    }
  }

  private func send(_ response: ShotPasteHTTPResponse, on connection: NWConnection, id: UUID) {
    connection.send(content: response.encoded, completion: .contentProcessed { [weak self] _ in
      Task { @MainActor [weak self] in self?.closeConnection(id) }
    })
  }

  private func closeConnection(_ id: UUID) {
    connections.removeValue(forKey: id)?.cancel()
  }

  private func authorizationToken() -> String {
    if let existingToken = defaults.string(forKey: PreferencesKeys.mcpServerAuthToken),
       existingToken.utf8.count >= 32 {
      return existingToken
    }

    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      let fallback = UUID().uuidString + UUID().uuidString
      defaults.set(fallback, forKey: PreferencesKeys.mcpServerAuthToken)
      return fallback
    }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    defaults.set(token, forKey: PreferencesKeys.mcpServerAuthToken)
    return token
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    let count = max(left.count, right.count)
    var difference = left.count ^ right.count
    for index in 0 ..< count {
      let leftByte = index < left.count ? left[index] : 0
      let rightByte = index < right.count ? right[index] : 0
      difference |= Int(leftByte ^ rightByte)
    }
    return difference == 0
  }
}

nonisolated struct ShotPasteHTTPRequest: Sendable {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data
}

nonisolated enum ShotPasteHTTPRequestParseFailure: Error, Sendable {
  case headerTooLarge
  case bodyTooLarge
  case malformed

  var response: ShotPasteHTTPResponse {
    switch self {
    case .headerTooLarge: .requestHeaderFieldsTooLarge
    case .bodyTooLarge: .payloadTooLarge
    case .malformed: .badRequest("Malformed HTTP request.")
    }
  }
}

nonisolated enum ShotPasteHTTPRequestParseResult: Sendable {
  case incomplete
  case complete(ShotPasteHTTPRequest)
  case failure(ShotPasteHTTPRequestParseFailure)
}

nonisolated enum ShotPasteHTTPRequestParser {
  private static let headerLimit = 32 * 1_024
  private static let bodyLimit = 1_024 * 1_024
  private static let headerDelimiter = Data("\r\n\r\n".utf8)

  static func parse(_ data: Data) -> ShotPasteHTTPRequestParseResult {
    guard let headerRange = data.range(of: headerDelimiter) else {
      return data.count > headerLimit ? .failure(.headerTooLarge) : .incomplete
    }
    guard headerRange.lowerBound <= headerLimit else { return .failure(.headerTooLarge) }

    let headerData = data[..<headerRange.lowerBound]
    guard let headerString = String(data: headerData, encoding: .utf8) else {
      return .failure(.malformed)
    }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .failure(.malformed) }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/1.") else {
      return .failure(.malformed)
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { return .failure(.malformed) }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return .failure(.malformed) }
      if let existing = headers[name] {
        headers[name] = "\(existing), \(value)"
      } else {
        headers[name] = value
      }
    }

    let contentLength: Int
    if let contentLengthValue = headers["content-length"] {
      guard let parsedLength = Int(contentLengthValue), parsedLength >= 0 else {
        return .failure(.malformed)
      }
      contentLength = parsedLength
    } else {
      contentLength = 0
    }
    guard contentLength <= bodyLimit else { return .failure(.bodyTooLarge) }

    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return .incomplete }
    let body = data.subdata(in: bodyStart ..< bodyStart + contentLength)
    let rawTarget = String(requestParts[1])
    let path = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
      ?? rawTarget
    return .complete(
      ShotPasteHTTPRequest(
        method: String(requestParts[0]).uppercased(),
        path: path,
        headers: headers,
        body: body
      )
    )
  }
}

nonisolated struct ShotPasteHTTPResponse: Sendable {
  let statusCode: Int
  let reason: String
  let headers: [String: String]
  let body: Data

  var encoded: Data {
    var responseHeaders = headers
    responseHeaders["Content-Length"] = "\(body.count)"
    responseHeaders["Connection"] = "close"
    responseHeaders["Cache-Control"] = "no-store"
    var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
    for key in responseHeaders.keys.sorted() {
      head += "\(key): \(responseHeaders[key] ?? "")\r\n"
    }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
  }

  static func json(_ data: Data) -> Self {
    Self(statusCode: 200, reason: "OK", headers: ["Content-Type": "application/json"], body: data)
  }

  static let accepted = Self(statusCode: 202, reason: "Accepted", headers: [:], body: Data())
  static let notFound = jsonError(statusCode: 404, reason: "Not Found", message: "MCP endpoint not found.")
  static let misdirectedRequest = jsonError(
    statusCode: 421,
    reason: "Misdirected Request",
    message: "Invalid Host header."
  )
  static let unauthorized = jsonError(
    statusCode: 401,
    reason: "Unauthorized",
    message: "Missing or invalid bearer token.",
    headers: ["WWW-Authenticate": "Bearer realm=\"ShotPaste MCP\""]
  )
  static let methodNotAllowed = jsonError(
    statusCode: 405,
    reason: "Method Not Allowed",
    message: "This MCP server accepts POST requests only.",
    headers: ["Allow": "POST"]
  )
  static let payloadTooLarge = jsonError(
    statusCode: 413,
    reason: "Payload Too Large",
    message: "MCP request body is too large."
  )
  static let unsupportedMediaType = jsonError(
    statusCode: 415,
    reason: "Unsupported Media Type",
    message: "Content-Type must be application/json."
  )
  static let requestHeaderFieldsTooLarge = jsonError(
    statusCode: 431,
    reason: "Request Header Fields Too Large",
    message: "HTTP request headers are too large."
  )
  static let internalServerError = jsonError(
    statusCode: 500,
    reason: "Internal Server Error",
    message: "Unable to encode MCP response."
  )
  static let serviceUnavailable = jsonError(
    statusCode: 503,
    reason: "Service Unavailable",
    message: "ShotPaste automation is not ready."
  )

  static func badRequest(_ message: String) -> Self {
    jsonError(statusCode: 400, reason: "Bad Request", message: message)
  }

  static func forbidden(_ message: String) -> Self {
    jsonError(statusCode: 403, reason: "Forbidden", message: message)
  }

  private static func jsonError(
    statusCode: Int,
    reason: String,
    message: String,
    headers: [String: String] = [:]
  ) -> Self {
    let object: [String: Any] = [
      "jsonrpc": "2.0",
      "id": NSNull(),
      "error": ["code": -32_000, "message": message],
    ]
    let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    var responseHeaders = headers
    responseHeaders["Content-Type"] = "application/json"
    return Self(statusCode: statusCode, reason: reason, headers: responseHeaders, body: body)
  }
}
