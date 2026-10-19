import XCTest
@testable import Shiyi

final class PreferencesTests: XCTestCase {
    @MainActor
    func testPreferencesPersistWhileAPIKeyRequiresExplicitKeychainSave() async throws {
        let suite = "ShiyiTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain("original-key")
        let preferences = Preferences(defaults: defaults, keychain: keychain)
        XCTAssertTrue(preferences.autoTranslate)
        XCTAssertTrue(preferences.sendContext)
        XCTAssertEqual(preferences.engine, .system)
        XCTAssertEqual(preferences.target, .simplifiedChinese)
        XCTAssertEqual(preferences.scene, "自动")
        XCTAssertTrue(preferences.excludedBundleIDs.contains("com.apple.keychainaccess"))
        XCTAssertEqual(preferences.apiKey, "original-key")

        preferences.autoTranslate = false
        preferences.sendContext = false
        preferences.engine = .contextual
        preferences.target = .english
        preferences.endpoint = "https://api.example.com/v1"
        preferences.model = "a-model"
        preferences.scene = "技术文档"
        preferences.excludedBundleIDs = "com.example.editor"
        preferences.apiKey = "  changed-key \n"
        XCTAssertEqual(keychain.value, "original-key")
        XCTAssertNil(defaults.object(forKey: "apiKey"))
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains("changed-key"))

        let restored = Preferences(defaults: defaults, keychain: keychain)
        XCTAssertFalse(restored.autoTranslate)
        XCTAssertFalse(restored.sendContext)
        XCTAssertEqual(restored.engine, .contextual)
        XCTAssertEqual(restored.target, .english)
        XCTAssertEqual(restored.endpoint, preferences.endpoint)
        XCTAssertEqual(restored.model, preferences.model)
        XCTAssertEqual(restored.scene, preferences.scene)
        XCTAssertEqual(restored.excludedBundleIDs, preferences.excludedBundleIDs)

        try preferences.saveAPIKey()
        XCTAssertEqual(preferences.apiKey, "changed-key")
        XCTAssertEqual(keychain.value, "changed-key")
        XCTAssertNil(preferences.lastKeyError)
        preferences.apiKey = ""
        try preferences.saveAPIKey()
        XCTAssertEqual(keychain.value, "")
    }

    @MainActor
    func testKeychainFailureIsReportedAndDoesNotPersistSecretElsewhere() async throws {
        let suite = "ShiyiTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MemoryKeychain("")
        keychain.shouldFail = true
        let preferences = Preferences(defaults: defaults, keychain: keychain)
        XCTAssertNotNil(preferences.lastKeyError)
        XCTAssertEqual(preferences.apiKey, "")
        preferences.apiKey = "unsaved-secret"
        XCTAssertThrowsError(try preferences.saveAPIKey())
        XCTAssertNotNil(preferences.lastKeyError)
        XCTAssertNil(defaults.object(forKey: "apiKey"))
        XCTAssertEqual(keychain.value, "")
    }
}

private final class MemoryKeychain: APIKeyStoring {
    var value: String
    var shouldFail = false
    init(_ value: String) { self.value = value }
    func loadAPIKey() throws -> String {
        if shouldFail { throw KeychainError.invalidData }
        return value
    }
    func saveAPIKey(_ value: String) throws {
        if shouldFail { throw KeychainError.invalidData }
        self.value = value
    }
}
