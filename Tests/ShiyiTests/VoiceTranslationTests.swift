import XCTest
@testable import Shiyi

final class VoiceQueueTests: XCTestCase {
    func testRevisionsReplacePendingDraftWithoutLosingSentenceOrder() {
        var queue = VoiceTranslationQueue(limit: 2)
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertTrue(queue.enqueue(.init(id: first, text: "Hello")))
        XCTAssertTrue(queue.enqueue(.init(id: second, text: "Next")))
        XCTAssertTrue(queue.enqueue(.init(id: first, text: "Hello world")))
        XCTAssertFalse(queue.enqueue(.init(id: third, text: "Overflow")))
        XCTAssertEqual(queue.next(), .init(id: first, text: "Hello world"))
        XCTAssertEqual(queue.next(), .init(id: second, text: "Next"))
        XCTAssertNil(queue.next())
    }
    func testRepeatedSpokenSentenceRemainsSeparateAndClearCancelsPending() {
        var queue = VoiceTranslationQueue()
        XCTAssertTrue(queue.enqueue(.init(id: UUID(), text: "Thank you")))
        XCTAssertTrue(queue.enqueue(.init(id: UUID(), text: "Thank you")))
        XCTAssertEqual(queue.requests.count, 2)
        queue.clear()
        XCTAssertNil(queue.next())
    }
}

@MainActor
private final class FakeVoiceRecognizer: VoiceRecognizing {
    var stopped = false
    var text: ((String, Bool) -> Void)?
    func start(language: TranslationLanguage, onText: @escaping (String, Bool) -> Void,
               onLevel: @escaping (Double) -> Void, onStatus: @escaping (String) -> Void,
               onError: @escaping (String) -> Void) async throws { text = onText }
    func stop() { stopped = true }
}

private struct VoiceTestKeys: APIKeyStoring {
    func loadAPIKey() throws -> String { "" }
    func saveAPIKey(_ value: String) throws {}
}

final class VoiceLifecycleTests: XCTestCase {
    @MainActor
    func testClosingStopsMicrophoneAndRejectsOldRecognitionAndTranslation() async throws {
        let suite = "ShiyiTests.voice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer()
        let requested = expectation(description: "translation began")
        var continuation: CheckedContinuation<String, Never>?
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), recognizerFactory: { recognizer }, modelReady: { true }) { _, _, _ in
            requested.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
        store.start()
        for _ in 0..<20 where !store.listening { await Task.yield() }
        XCTAssertTrue(store.listening)
        recognizer.text?("Hello", true)
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertEqual(store.captions.count, 1)
        store.stop(cancelPending: true)
        XCTAssertTrue(recognizer.stopped)
        XCTAssertFalse(store.listening)
        recognizer.text?("Old callback", true)
        continuation?.resume(returning: "迟到的结果")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.captions.count, 1)
        XCTAssertTrue(store.captions[0].translation.isEmpty)
        XCTAssertEqual(store.captions[0].failure, "已取消")
    }

    @MainActor
    func testLanguageChangesStopMicrophoneAndKeepTextLanguagesIndependent() async throws {
        let suite = "ShiyiTests.voice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults, keychain: VoiceTestKeys())
        let recognizer = FakeVoiceRecognizer()
        let store = VoiceTranslationStore(preferences: preferences, recognizerFactory: { recognizer }, modelReady: { true }) { text, _, _ in text }
        store.start()
        for _ in 0..<20 where !store.listening { await Task.yield() }
        recognizer.text?("First sentence.", true)
        for _ in 0..<20 where store.captions.first?.translation.isEmpty ?? true { await Task.yield() }
        XCTAssertEqual(store.captions.first?.translation, "First sentence.")
        preferences.voiceTarget = .german
        XCTAssertFalse(store.listening)
        XCTAssertTrue(recognizer.stopped)
        XCTAssertEqual(preferences.target, .simplifiedChinese)
    }
}
