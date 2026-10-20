import XCTest
@testable import Shiyi

private final class VoiceHTTPStub: URLProtocol {
    static var response: (Int, Data) = (200, Data())
    static var lastRequest: URLRequest?
    static var lastBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody
        if Self.lastBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            Self.lastBody = data
        }
        let (status, data) = Self.response
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LocalVoiceClientTests: XCTestCase {
    private func client() -> LocalVoiceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceHTTPStub.self]
        return LocalVoiceClient(session: URLSession(configuration: config))
    }
    func testTranslationUsesOnlyLoopbackAndExplicitLanguagePair() async throws {
        VoiceHTTPStub.response = (200, Data(#"{"message":{"content":"早上好"},"done_reason":"stop"}"#.utf8))
        let output = try await client().translate("Good morning", source: .english, target: .simplifiedChinese)
        XCTAssertEqual(output, "早上好")
        let request = try XCTUnwrap(VoiceHTTPStub.lastRequest)
        XCTAssertEqual(request.url?.host, "127.0.0.1")
        XCTAssertEqual(request.url?.path, "/api/chat")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(VoiceHTTPStub.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "translategemma:4b")
        let message = try XCTUnwrap((body["messages"] as? [[String: String]])?.first?["content"])
        XCTAssertTrue(message.contains("English (en)"))
        XCTAssertTrue(message.contains("Chinese (Simplified) (zh-Hans)"))
        XCTAssertTrue(message.hasSuffix("\n\n\nGood morning"))
    }
    func testSameLanguageNeedsNoInference() async throws {
        VoiceHTTPStub.lastRequest = nil
        let result = try await client().translate("你好", source: .simplifiedChinese, target: .simplifiedChinese)
        XCTAssertEqual(result, "你好")
        XCTAssertNil(VoiceHTTPStub.lastRequest)
    }
    func testFailureDoesNotLeakResponseAndTruncationIsRejected() async {
        for response in [(500, #"{"error":"PRIVATE_SPOKEN_TEXT"}"#),
                         (200, #"{"message":{"content":""}}"#),
                         (200, #"{"message":{"content":"partial"},"done_reason":"length"}"#)] {
            VoiceHTTPStub.response = (response.0, Data(response.1.utf8))
            do {
                _ = try await client().translate("hello", source: .english, target: .german)
                XCTFail("Expected rejection")
            } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE_SPOKEN_TEXT")) }
        }
    }
    @MainActor
    func testStreamingUsesLoopbackAndPublishesBeforeCompletion() async throws {
        VoiceHTTPStub.response = (200, Data((#"{"message":{"content":"早上好，"},"done":false}"# + "\n" + #"{"message":{"content":"会议九点开始。"},"done":true,"done_reason":"stop"}"# + "\n").utf8))
        var updates: [String] = []
        let result = try await client().translateStreaming("Good morning", source: .english, target: .simplifiedChinese) { updates.append($0) }
        XCTAssertEqual(result, "早上好，会议九点开始。")
        XCTAssertEqual(updates.first, "早上好，")
        XCTAssertEqual(updates.last, result)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(VoiceHTTPStub.lastBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["keep_alive"] as? String, "10m")
        XCTAssertEqual(VoiceHTTPStub.lastRequest?.url?.host, "127.0.0.1")
    }
    func testUnfinishedOrTruncatedStreamsCannotBecomeFinalRecords() throws {
        var decoder = VoiceTranslationStream()
        try decoder.append(#"{"message":{"content":"temporary"},"done":false}"#)
        XCTAssertThrowsError(try decoder.completed())
        XCTAssertThrowsError(try decoder.append(#"{"done":true,"done_reason":"length"}"#))
        var broken = VoiceTranslationStream()
        XCTAssertThrowsError(try broken.append(#"{"error":"PRIVATE_AUDIO_CONTENT"}"#)) { error in
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_AUDIO_CONTENT"))
        }
    }

}
