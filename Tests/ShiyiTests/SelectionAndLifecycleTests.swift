import XCTest
@testable import Shiyi

final class TextContextTests: XCTestCase {
    func testContextUsesSelectionOffsetRatherThanDocumentBeginning() {
        let text = String(repeating: "a", count: 2_000) + "The selected token means a credential." + String(repeating: "b", count: 2_000)
        let selection = (text as NSString).range(of: "token")
        let result = TextContext.surroundingText(in: text, selection: selection, radius: 30)
        XCTAssertTrue(result.contains("selected token means a credential"))
        XCTAssertLessThanOrEqual(result.utf16.count, 65)
    }

    func testContextDoesNotSplitEmojiAndCombiningCharacters() {
        let text = "👨‍👩‍👧‍👦token e\u{301} end"
        let selection = (text as NSString).range(of: "token")
        let result = TextContext.surroundingText(in: text, selection: selection, radius: 1)
        XCTAssertTrue(result.hasPrefix("👨‍👩‍👧‍👦"))
        XCTAssertTrue(result.contains("token"))
        XCTAssertFalse(result.contains("�"))
    }

    func testInvalidAndOverflowingRangesReturnEmpty() {
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 9, length: 2), NSRange(location: 1, length: Int.max)] {
            XCTAssertEqual(TextContext.surroundingText(in: "short", selection: range), "")
        }
    }

    func testExcludedAppsAcceptsMultilineCommaAndWhitespace() {
        XCTAssertEqual(TextContext.excludedApps(from: "com.apple.Terminal\ncom.apple.keychainaccess, com.apple.Terminal;\tcom.example.app"),
                       Set(["com.apple.Terminal", "com.apple.keychainaccess", "com.example.app"]))
    }
}

final class AppStoreLifecycleTests: XCTestCase {
    private struct EmptyKeys: APIKeyStoring {
        func loadAPIKey() throws -> String { "" }
        func saveAPIKey(_ value: String) throws {}
    }

    @MainActor
    private func makeStore() -> (AppStore, UserDefaults, String) {
        let name = "ShiyiTests.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let store = AppStore(preferences: Preferences(defaults: defaults, keychain: EmptyKeys()))
        return (store, defaults, name)
    }

    private func selection(_ text: String) -> CapturedSelection {
        CapturedSelection(text: text, context: "surrounding sentence", appName: "Test", bundleID: "test.app",
                          documentTitle: "Test document", anchor: .zero)
    }

    @MainActor
    func testOlderCompletionCannotReplaceNewSelection() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.translate(selection("first"))
        let first = store.job!.id
        store.translate(selection("second"))
        let second = store.job!.id
        let output = TranslationOutput(translation: "第二个", explanation: "", alternatives: [], detectedScene: "")
        store.complete(output, jobID: first)
        XCTAssertEqual(store.phase, .loading)
        store.fail("old error", jobID: first)
        XCTAssertEqual(store.phase, .loading)
        store.complete(output, jobID: second)
        XCTAssertEqual(store.phase, .finished(output))
    }

    @MainActor
    func testDismissInvalidatesInFlightSystemTranslation() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.translate(selection("token"))
        let jobID = store.job!.id
        store.isPinned = true
        store.dismiss()
        store.complete(TranslationOutput(translation: "late", explanation: "", alternatives: [], detectedScene: ""), jobID: jobID)
        XCTAssertNil(store.job)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isPinned)
    }

    @MainActor
    func testLanguagePairIsSnapshottedAndRetryUsesNewPair() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.preferences.source = .german
        store.preferences.target = .english
        store.translate(selection("Wort"))
        let originalID = store.job!.id
        store.preferences.swapLanguages()
        XCTAssertEqual(store.job?.source, .german)
        XCTAssertEqual(store.job?.target, .english)
        store.retry()
        XCTAssertNotEqual(store.job?.id, originalID)
        XCTAssertEqual(store.job?.source, .english)
        XCTAssertEqual(store.job?.target, .german)
        let restored = Preferences(defaults: defaults, keychain: EmptyKeys())
        XCTAssertEqual(restored.source, .english)
        XCTAssertEqual(restored.target, .german)
    }

    @MainActor
    func testSameLanguageReturnsOriginalWithoutCallingAnEngine() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.preferences.source = .english
        store.preferences.target = .english
        store.preferences.engine = .contextual
        store.translate(selection("token"))
        guard case .finished(let output) = store.phase else {
            return XCTFail("Same-language input should complete without credentials or a network request")
        }
        XCTAssertEqual(output.translation, "token")
        XCTAssertEqual(output.detectedScene, "无需翻译")
    }

    @MainActor
    func testRetryAfterContextDisabledDropsContextAndTitle() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.translate(selection("token"))
        store.preferences.sendContext = false
        store.retry()
        XCTAssertEqual(store.job?.selection.context, "")
        XCTAssertEqual(store.job?.selection.documentTitle, "")
    }
}
