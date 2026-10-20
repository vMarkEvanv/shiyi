import XCTest
import Combine
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
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: VoiceTranscriptArchive(directory: nil), recognizerFactory: { recognizer }, modelReady: { true }, translate: { _, _, _ in
            requested.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        })
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
        let store = VoiceTranslationStore(preferences: preferences, archive: VoiceTranscriptArchive(directory: nil), recognizerFactory: { recognizer }, modelReady: { true }, translate: { text, _, _ in text })
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
    @MainActor
    func testClearScreenDoesNotDeleteArchivedTranslation() async throws {
        let suite = "ShiyiTests.voiceClear.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer()
        let archive = VoiceTranscriptArchive(directory: nil)
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: archive,
                                          recognizerFactory: { recognizer }, modelReady: { true }, translate: { _, _, _ in "你好" })
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        recognizer.text?("Hello", true)
        for _ in 0..<30 where store.captions.first?.translation.isEmpty ?? true { await Task.yield() }
        let id = try XCTUnwrap(archive.sessions.first?.id)
        store.clear()
        store.stop(cancelPending: true)
        XCTAssertTrue(store.captions.isEmpty)
        let saved = try await archive.load(id)
        XCTAssertEqual(saved.captions.count, 1)
        XCTAssertEqual(saved.captions.first?.translation, "你好")
    }
    @MainActor
    func testClosingPreservesUnfinishedRecognitionWithoutStartingTranslation() async throws {
        let suite = "ShiyiTests.voiceDraft.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer()
        let archive = VoiceTranscriptArchive(directory: nil)
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: archive,
                                          recognizerFactory: { recognizer }, modelReady: { true }, translate: { _, _, _ in
            XCTFail("Closing should not start a new translation")
            return ""
        })
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        recognizer.text?("unfinished original", false)
        store.stop(cancelPending: true)
        let id = try XCTUnwrap(archive.sessions.first?.id)
        let saved = try await archive.load(id)
        XCTAssertEqual(saved.captions.first?.original, "unfinished original")
        XCTAssertTrue(saved.captions.first?.translation.isEmpty ?? false)
        XCTAssertNotNil(saved.captions.first?.failure)
        XCTAssertNotNil(saved.endedAt)
    }

    @MainActor
    func testInFlightPreviewKeepsItsOwnSourceAndFinalRevisionIsArchived() async throws {
        let suite = "ShiyiTests.voiceRevision.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer(), archive = VoiceTranscriptArchive(directory: nil)
        let firstBegan = expectation(description: "preview began"), finalBegan = expectation(description: "final began")
        var firstFinish: CheckedContinuation<String, Never>?, finalFinish: CheckedContinuation<String, Never>?
        var count = 0
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: archive, recognizerFactory: { recognizer }, modelReady: { true }, translate: { _, _, _ in
            count += 1
            if count == 1 {
                firstBegan.fulfill()
                return await withCheckedContinuation { firstFinish = $0 }
            }
            finalBegan.fulfill()
            return await withCheckedContinuation { finalFinish = $0 }
        })
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        recognizer.text?("We meet tomorrow", false)
        await fulfillment(of: [firstBegan], timeout: 1)
        recognizer.text?("We meet tomorrow at nine", true)
        firstFinish?.resume(returning: "我们明天见面")
        await fulfillment(of: [finalBegan], timeout: 1)
        XCTAssertEqual(store.subtitleCaption?.original, "We meet tomorrow")
        XCTAssertTrue(store.captions.first?.translation.isEmpty ?? false)
        finalFinish?.resume(returning: "我们明天九点见面")
        for _ in 0..<100 where store.captions.first?.translation.isEmpty ?? true { await Task.yield() }
        XCTAssertEqual(store.captions.first?.original, "We meet tomorrow at nine")
        XCTAssertEqual(store.captions.first?.translation, "我们明天九点见面")
        store.stop(cancelPending: true)
        let saved = try await archive.load(XCTUnwrap(archive.sessions.first?.id))
        XCTAssertEqual(saved.captions.count, 1)
        XCTAssertEqual(saved.captions.first?.translation, "我们明天九点见面")
    }

    @MainActor
    func testOptInLocalFirstSubtitleLatency() async throws {
        guard ProcessInfo.processInfo.environment["SHIYI_LATENCY_BENCH"] == "1" else { throw XCTSkip("Opt-in local inference benchmark") }
        let suite = "ShiyiTests.latency.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer()
        let began = expectation(description: "first readable subtitle")
        let done = expectation(description: "complete translation saved")
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: VoiceTranscriptArchive(directory: nil), recognizerFactory: { recognizer }, modelReady: { true })
        let start = ProcessInfo.processInfo.systemUptime
        var first: Double?, complete: Double?
        let updates = store.$subtitleCaption.sink { caption in
            if caption != nil, first == nil { first = ProcessInfo.processInfo.systemUptime - start; began.fulfill() }
        }
        let finished = store.$captions.sink { captions in
            if captions.first?.translation.isEmpty == false, complete == nil { complete = ProcessInfo.processInfo.systemUptime - start; done.fulfill() }
        }
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        recognizer.text?("The meeting starts at nine", false)
        await fulfillment(of: [began, done], timeout: 90)
        XCTAssertLessThan(try XCTUnwrap(first), try XCTUnwrap(complete))
        print("LATENCY_BENCH first_subtitle_seconds=\(first ?? -1) completed_seconds=\(complete ?? -1)")
        store.stop(cancelPending: true)
        withExtendedLifetime([updates, finished]) {}
    }

    @MainActor
    func testRepeatedPartialDoesNotKeepPostponingTranslation() async throws {
        let suite = "ShiyiTests.voiceDebounce.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer()
        let began = expectation(description: "stable text translated")
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: VoiceTranscriptArchive(directory: nil), recognizerFactory: { recognizer }, modelReady: { true }, translate: { text, _, _ in
            began.fulfill(); return "译文"
        })
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        recognizer.text?("The meeting starts at nine", false)
        let repeats = Task {
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                recognizer.text?("The meeting starts at nine", false)
            }
        }
        await fulfillment(of: [began], timeout: 0.75)
        repeats.cancel(); store.stop(cancelPending: true)
    }
    @MainActor
    func testContinuousChangesHaveABoundedWaitAndPreserveFullOriginal() async throws {
        let suite = "ShiyiTests.voiceDeadline.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer(), archive = VoiceTranscriptArchive(directory: nil)
        let began = expectation(description: "translated before speech stops")
        began.assertForOverFulfill = false
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: archive, recognizerFactory: { recognizer }, modelReady: { true }, translate: { text, _, _ in
            began.fulfill(); return "实时预览"
        })
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        let speech = Task {
            for index in 0..<18 {
                recognizer.text?("The meeting starts at nine and we discuss topic \(index)", false)
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
            }
        }
        await fulfillment(of: [began], timeout: 1.6)
        speech.cancel()
        let complete = store.liveOriginal
        store.stop(cancelPending: true)
        let id = try XCTUnwrap(archive.sessions.first?.id)
        let saved = try await archive.load(id)
        XCTAssertEqual(saved.captions.last?.original, complete)
    }
    @MainActor
    func testStreamingPreviewIsPairedButNeverSavedAsCompletedTranslation() async throws {
        let suite = "ShiyiTests.voiceStream.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = FakeVoiceRecognizer(), archive = VoiceTranscriptArchive(directory: nil)
        let began = expectation(description: "partial translation shown")
        var finish: CheckedContinuation<String, Never>?
        let store = VoiceTranslationStore(preferences: Preferences(defaults: defaults, keychain: VoiceTestKeys()), archive: archive, recognizerFactory: { recognizer }, modelReady: { true }, streamTranslate: { _, _, _, update in
            update("正在生成的译文")
            began.fulfill()
            return await withCheckedContinuation { finish = $0 }
        })
        store.start()
        for _ in 0..<30 where !store.listening { await Task.yield() }
        recognizer.text?("Good morning", true)
        await fulfillment(of: [began], timeout: 1)
        XCTAssertEqual(store.subtitleCaption?.original, "Good morning")
        XCTAssertEqual(store.subtitleCaption?.translation, "正在生成的译文")
        XCTAssertTrue(store.captions.first?.translation.isEmpty ?? false)
        store.stop(cancelPending: true)
        finish?.resume(returning: "迟到的完成译文")
        for _ in 0..<30 { await Task.yield() }
        let id = try XCTUnwrap(archive.sessions.first?.id)
        let saved = try await archive.load(id)
        XCTAssertTrue(saved.captions.first?.translation.isEmpty ?? false)
        XCTAssertEqual(saved.captions.first?.failure, "已取消")
    }

}

final class VoiceLivePolicyTests: XCTestCase {
    func testNumericAndNegationChangesAreNeverDeduplicatedAsPunctuation() {
        XCTAssertNotEqual(VoiceLivePolicy.normalized("1.5"), VoiceLivePolicy.normalized("15"))
        XCTAssertNotEqual(VoiceLivePolicy.normalized(".5"), VoiceLivePolicy.normalized("5"))
        XCTAssertNotEqual(VoiceLivePolicy.normalized("can't"), VoiceLivePolicy.normalized("cant"))
        XCTAssertEqual(VoiceLivePolicy.normalized("Hello!"), VoiceLivePolicy.normalized("hello."))
    }
    func testPreviewUsesStablePrefixAndKeepsWholeEnglishWords() {
        XCTAssertEqual(VoiceLivePolicy.preview("The meeting starts tomorrow", previous: "The meeting starts today", settled: false), "The meeting starts")
        XCTAssertEqual(VoiceLivePolicy.preview("Hello. The meeting starts at nine.", previous: "", settled: true), "The meeting starts at nine")
        let text = "Accessibility improvements prevent unnecessary interruptions during translation"
        XCTAssertEqual(VoiceLivePolicy.preview(text, previous: "", settled: true), text)
    }
}
