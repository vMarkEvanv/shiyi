import XCTest
@testable import Shiyi

final class PreferencesTests: XCTestCase {
    @MainActor
    func testVoiceLanguagesAndShortcutPersistIndependentlyOfTextTranslation() throws {
        let suite = "ShiyiTests.voicePrefs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults, keychain: MemoryKeychain(""))
        XCTAssertFalse(preferences.fadeEntireSubtitles)
        XCTAssertFalse(preferences.fadeEntireOverlay)
        preferences.fadeEntireSubtitles = true
        preferences.fadeEntireOverlay = true
        preferences.voiceSubtitleSize = 36
        preferences.voiceSubtitleOpacity = 0.55
        preferences.voiceSource = .german
        preferences.voiceTarget = .english
        preferences.voiceShortcut = .controlShiftR
        let restored = Preferences(defaults: defaults, keychain: MemoryKeychain(""))
        XCTAssertTrue(restored.fadeEntireSubtitles)
        XCTAssertTrue(restored.fadeEntireOverlay)
        XCTAssertEqual(restored.voiceSubtitleSize, 36)
        XCTAssertEqual(restored.voiceSubtitleOpacity, 0.55)
        XCTAssertEqual(restored.voiceSource, .german)
        XCTAssertEqual(restored.voiceTarget, .english)
        XCTAssertEqual(restored.voiceShortcut, .controlShiftR)
        XCTAssertEqual(restored.source, .english)
        XCTAssertEqual(restored.target, .simplifiedChinese)
    }

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
        XCTAssertEqual(preferences.source, .english)
        XCTAssertEqual(preferences.scene, "自动")
        XCTAssertTrue(preferences.excludedBundleIDs.contains("com.apple.keychainaccess"))
        XCTAssertEqual(preferences.apiKey, "original-key")

        preferences.autoTranslate = false
        preferences.sendContext = false
        preferences.engine = .contextual
        preferences.target = .english
        preferences.source = .german
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
        XCTAssertEqual(restored.source, .german)
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
    func testOverlaySettingsPersistAndPositionResetDoesNotChangeOpacity() throws {
        let suite = "ShiyiTests.overlay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = MemoryKeychain("")
        let preferences = Preferences(defaults: defaults, keychain: keys)
        preferences.overlayOpacity = 0.4
        preferences.overlayHorizontal = 0.1
        preferences.overlayVertical = 0.8
        preferences.overlayScreenID = "external-screen"
        preferences.overlayShortcut = .controlOptionT
        let restored = Preferences(defaults: defaults, keychain: keys)
        XCTAssertEqual(restored.overlayOpacity, 0.4)
        XCTAssertEqual(restored.overlayHorizontal, 0.1)
        XCTAssertEqual(restored.overlayVertical, 0.8)
        XCTAssertEqual(restored.overlayScreenID, "external-screen")
        XCTAssertEqual(restored.overlayShortcut, .controlOptionT)
        restored.resetOverlayPosition()
        XCTAssertEqual(restored.overlayScreenID, "main")
        XCTAssertEqual(restored.overlayOpacity, 0.4)
        XCTAssertEqual(restored.overlayShortcut, .controlOptionT)
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
