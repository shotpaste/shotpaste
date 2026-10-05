import Foundation
@testable import ShotPaste
import XCTest

final class AgentAudioLanguageModelProviderTests: XCTestCase {
  func testResponsesPolishSendsOnlyTextAndReadsOutputMessages() async throws {
    let configuration = AgentProviderConfiguration(endpoint: "https://example.com/v1", model: "test-model",
                                                   thinkingEnabled: true, sendsImages: true, maxActions: 30,
                                                   apiProtocol: .openAIResponses)
    let session = MockURLSession { request in
      XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/responses")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertNil(body["messages"])
      XCTAssertNil(body["tools"])
      XCTAssertNil(body["temperature"])
      XCTAssertNil(body["max_tokens"])
      XCTAssertEqual(body["max_output_tokens"] as? Int, 8192)
      XCTAssertEqual(body["store"] as? Bool, false)
      XCTAssertEqual(body["stream"] as? Bool, false)
      let content = try XCTUnwrap((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
      XCTAssertEqual(content.count, 1)
      XCTAssertEqual(content.first?["type"] as? String, "input_text")
      let payload = try XCTUnwrap(content.first?["text"] as? String)
      let input = try JSONDecoder().decode(AudioLLMInput.self, from: Data(payload.utf8))
      XCTAssertEqual(input.segmentIDs, ["segment-1"])
      XCTAssertFalse(payload.contains("image_url"))
      XCTAssertFalse(payload.contains("file://"))
      return MockURLSession.makeResponse(statusCode: 200, data: Data(
        #"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"Polished"}]}]}"#.utf8
      ))
    }
    let provider = AgentAudioLanguageModelProvider(session: session, settings: { (configuration, "synthetic-key") })
    let result = try await provider.polish(input: .init(template: .generalNotes, language: .en,
      segments: [.init(id: "segment-1", text: "Synthetic text", speaker: .unknown)]))
    XCTAssertEqual(result, "Polished")
  }

  func testResponsesPartialRefusalAndToolOutputAreRejected() async throws {
    let configuration = AgentProviderConfiguration(endpoint: "https://example.com/v1", model: "test-model",
                                                   thinkingEnabled: false, sendsImages: false, maxActions: 30,
                                                   apiProtocol: .openAIResponses)
    for response in [
      #"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#,
      #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"No"}]}]}"#,
      #"{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"unsupported","arguments":"{}"}]}"#,
      #"{"status":"completed","output":[],"output_text":"shortcut"}"#,
    ] {
      let session = MockURLSession { _ in MockURLSession.makeResponse(statusCode: 200, data: Data(response.utf8)) }
      let provider = AgentAudioLanguageModelProvider(session: session, settings: { (configuration, "synthetic-key") })
      do {
        _ = try await provider.polish(input: .init(template: .generalNotes, language: .en, segments: []))
        XCTFail("Invalid Responses audio processing output must fail")
      } catch { XCTAssertEqual(error as? AudioLocalLLMError, .invalidOutput) }
    }
  }

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
