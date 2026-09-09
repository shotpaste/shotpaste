import Foundation
@testable import ShotPaste
import XCTest

final class AgentAudioLanguageModelProviderTests: XCTestCase {
  func testBothProtocolsSendTextOnlyAndUseConfiguredCredentials() async throws {
    for apiProtocol in [AgentProviderAPIProtocol.openAICompatible, .anthropicMessages] {
      let configuration = AgentProviderConfiguration(endpoint: "https://example.com/v1", model: "test-model",
                                                     thinkingEnabled: false, sendsImages: true, maxActions: 30,
                                                     apiProtocol: apiProtocol)
      let session = MockURLSession { request in
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let payload = try XCTUnwrap(messages.last?["content"] as? String)
        let input = try JSONDecoder().decode(AudioLLMInput.self, from: Data(payload.utf8))
        XCTAssertEqual(input.segmentIDs, ["segment-1"])
        XCTAssertEqual(input.segments.first?.text, "Synthetic text")
        XCTAssertFalse(payload.contains("image_url"))
        XCTAssertFalse(payload.contains("file://"))
        if apiProtocol == .openAICompatible {
          XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
          return MockURLSession.makeResponse(statusCode: 200, data: Data(
            #"{"choices":[{"finish_reason":"stop","message":{"content":"Polished"}}]}"#.utf8
          ))
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "synthetic-key")
        return MockURLSession.makeResponse(statusCode: 200, data: Data(
          #"{"stop_reason":"end_turn","content":[{"type":"text","text":"Polished"}]}"#.utf8
        ))
      }
      let provider = AgentAudioLanguageModelProvider(session: session, settings: { (configuration, "synthetic-key") })
      let result = try await provider.polish(input: AudioLLMInput(template: .generalNotes, language: .en,
                                                                  segments: [.init(
                                                                    id: "segment-1",
                                                                    text: "Synthetic text",
                                                                    speaker: .unknown
                                                                  )]))
      XCTAssertEqual(result, "Polished")
    }
  }

  func testTruncatedLLMResponseIsRejected() async throws {
    let config = AgentProviderConfiguration(endpoint: "https://example.com/v1", model: "test-model",
                                            thinkingEnabled: false, sendsImages: false, maxActions: 30)
    let session = MockURLSession { _ in MockURLSession.makeResponse(statusCode: 200, data: Data(
      #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#.utf8
    )) }
    let provider = AgentAudioLanguageModelProvider(session: session, settings: { (config, "synthetic-key") })
    do {
      _ = try await provider.polish(input: .init(template: .generalNotes, language: .en, segments: []))
      XCTFail("Truncated content must not be accepted")
    } catch { XCTAssertEqual(error as? AudioLocalLLMError, .invalidOutput) }
  }
}
