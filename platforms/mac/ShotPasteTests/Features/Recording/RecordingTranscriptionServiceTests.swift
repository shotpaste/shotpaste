import Foundation
@testable import ShotPaste
import XCTest

final class RecordingTranscriptionServiceTests: XCTestCase {
  func testConfigurationRejectsMissingAndHeaderInjectingCredentials() {
    XCTAssertNil(RecordingTranscriptionConfiguration(
      apiKey: "",
      modelID: "model",
      sourceLanguage: .chinese
    ))
    XCTAssertNil(RecordingTranscriptionConfiguration(
      apiKey: "key\r\nInjected: value",
      modelID: "model",
      sourceLanguage: .chinese
    ))
    XCTAssertNil(RecordingTranscriptionConfiguration(
      apiKey: "key",
      modelID: "model\nother",
      sourceLanguage: .chinese
    ))
  }

  func testSessionUpdateUsesOfficialClasiShapeAndOppositeTargetLanguage() throws {
    let configuration = try XCTUnwrap(RecordingTranscriptionConfiguration(
      apiKey: "test-key",
      modelID: "test-model",
      sourceLanguage: .chinese
    ))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: try VolcengineTranscriptionProtocol.sessionUpdateData(configuration: configuration)
      ) as? [String: Any]
    )
    XCTAssertEqual(object["type"] as? String, "session.update")
    let session = try XCTUnwrap(object["session"] as? [String: Any])
    XCTAssertEqual(session["input_audio_format"] as? String, "pcm16")
    let translation = try XCTUnwrap(session["input_audio_translation"] as? [String: Any])
    XCTAssertEqual(translation["source_language"] as? String, "zh")
    XCTAssertEqual(translation["target_language"] as? String, "en")
  }

  func testAudioCommitUsesBoundedBase64Payload() throws {
    let pcm = Data(repeating: 0x2A, count: VolcengineTranscriptionProtocol.pcmBytesPerCommit)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: try VolcengineTranscriptionProtocol.audioCommitData(pcm)
      ) as? [String: Any]
    )
    XCTAssertEqual(object["type"] as? String, "input_audio.commit")
    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(object["audio"] as? String)), pcm)
    XCTAssertThrowsError(
      try VolcengineTranscriptionProtocol.audioCommitData(
        Data(repeating: 0, count: VolcengineTranscriptionProtocol.pcmBytesPerCommit + 1)
      )
    )
  }

  func testServerEventParsesTranscriptAndServiceError() throws {
    let delta = try VolcengineTranscriptionProtocol.parseServerEvent(Data(
      #"{"type":"response.input_audio_transcription.delta","delta":"hello","speaker_change":true}"#.utf8
    ))
    XCTAssertEqual(delta.type, "response.input_audio_transcription.delta")
    XCTAssertEqual(delta.delta, "hello")
    XCTAssertTrue(delta.speakerChange)

    let error = try VolcengineTranscriptionProtocol.parseServerEvent(Data(
      #"{"type":"error","error":{"code":"InvalidParameter","message":"bad input"}}"#.utf8
    ))
    XCTAssertEqual(error.errorCode, "InvalidParameter")
    XCTAssertEqual(error.errorMessage, "bad input")
  }

  func testEndpointEncodesModelIDAndUsesOfficialService() throws {
    let endpoint = try XCTUnwrap(VolcengineTranscriptionProtocol.endpointURL(modelID: "model/with space"))
    let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "wss")
    XCTAssertEqual(components.host, "ark-beta.cn-beijing.volces.com")
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") }),
      ["service": "clasi", "model": "model/with space"]
    )
  }
}
