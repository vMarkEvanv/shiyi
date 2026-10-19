import Combine
import Foundation

@MainActor
final class Preferences: ObservableObject {
    @Published var autoTranslate: Bool { didSet { defaults.set(autoTranslate, forKey: "autoTranslate") } }
    @Published var engine: TranslationEngine { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var target: TargetLanguage { didSet { defaults.set(target.rawValue, forKey: "target") } }
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var sendContext: Bool { didSet { defaults.set(sendContext, forKey: "sendContext") } }
    @Published var excludedBundleIDs: String { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published var scene: String { didSet { defaults.set(scene, forKey: "scene") } }
    @Published var apiKey: String
    @Published private(set) var lastKeyError: String?

    private let defaults: UserDefaults
    private let keychain: any APIKeyStoring

    init(defaults: UserDefaults = .standard, keychain: any APIKeyStoring = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        autoTranslate = defaults.object(forKey: "autoTranslate") as? Bool ?? true
        engine = TranslationEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .system
        target = TargetLanguage(rawValue: defaults.string(forKey: "target") ?? "") ?? .simplifiedChinese
        endpoint = defaults.string(forKey: "endpoint") ?? ""
        model = defaults.string(forKey: "model") ?? ""
        sendContext = defaults.object(forKey: "sendContext") as? Bool ?? true
        excludedBundleIDs = defaults.string(forKey: "excludedBundleIDs") ?? "com.apple.keychainaccess"
        scene = defaults.string(forKey: "scene") ?? "自动"
        do {
            apiKey = try keychain.loadAPIKey()
        } catch {
            apiKey = ""
            lastKeyError = error.localizedDescription
        }
    }

    func saveAPIKey() throws {
        do {
            let normalized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try keychain.saveAPIKey(normalized)
            apiKey = normalized
            lastKeyError = nil
        } catch {
            lastKeyError = error.localizedDescription
            throw error
        }
    }
}
