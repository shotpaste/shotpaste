//
//  MockURLSession.swift
//  LiteScreenTests
//
//  Programmable URLSession fake for network tests.
//

import Foundation
@testable import LiteScreen

final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [URLRequest] = []
  private let responder: (URLRequest) async throws -> (Data, URLResponse)

  init(responder: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
    self.responder = responder
  }

  nonisolated deinit {}

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lock.lock()
    _requests.append(request)
    lock.unlock()
    return try await responder(request)
  }

  var requests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return _requests
  }

  static func makeResponse(
    statusCode: Int,
    data: Data = Data(),
    url: URL = URL(string: "https://example.com")!
  ) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: nil
    )!
    return (data, response)
  }
}
