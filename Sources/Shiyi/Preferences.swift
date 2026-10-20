import Combine
import Foundation

@MainActor
final class Preferences: ObservableObject {
    @Published var voiceSubtitleSize: Double { didSet { defaults.set(VoiceSubtitleStyle.fontSize(voiceSubtitleSize), forKey: "voiceSubtitleSize") } }
    @Published var voiceSubtitleOpacity: Double { didSet { defaults.set(OverlayLayout.opacity(voiceSubtitleOpacity), forKey: "voiceSubtitleOpacity") } }
    @Published var voiceSource: TranslationLanguage { didSet { defaults.set(voiceSource.rawValue, forKey: "voiceSource") } }
    @Published var voiceTarget: TranslationLanguage { didSet { defaults.set(voiceTarget.rawValue, forKey: "voiceTarget") } }
    @Published var voiceShortcut: VoiceShortcut { didSet { defaults.set(voiceShortcut.rawValue, forKey: "voiceShortcut") } }
    @Published var copyThenTranslate: Bool { didSet { defaults.set(copyThenTranslate, forKey: "copyThenTranslate") } }
    @Published var autoTranslate: Bool { didSet { defaults.set(autoTranslate, forKey: "autoTranslate") } }
    @Published var engine: TranslationEngine { didSet { defaults.set(engine.rawValue, forKey: "engine") } }
    @Published var source: TranslationLanguage { didSet { defaults.set(source.rawValue, forKey: "source") } }
    @Published var target: TranslationLanguage { didSet { defaults.set(target.rawValue, forKey: "target") } }
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "endpoint") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var sendContext: Bool { didSet { defaults.set(sendContext, forKey: "sendContext") } }
    @Published var excludedBundleIDs: String { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published var scene: String { didSet { defaults.set(scene, forKey: "scene") } }
    @Published var overlayOpacity: Double { didSet { defaults.set(OverlayLayout.opacity(overlayOpacity), forKey: "overlayOpacity") } }
    @Published var overlayHorizontal: Double { didSet { defaults.set(OverlayLayout.unit(overlayHorizontal), forKey: "overlayHorizontal") } }
    @Published var overlayVertical: Double { didSet { defaults.set(OverlayLayout.unit(overlayVertical), forKey: "overlayVertical") } }
    @Published var overlayScreenID: String { didSet { defaults.set(overlayScreenID, forKey: "overlayScreenID") } }
    @Published var overlayShortcut: OverlayShortcut { didSet { defaults.set(overlayShortcut.rawValue, forKey: "overlayShortcut") } }
    @Published var apiKey: String
    @Published private(set) var lastKeyError: String?

    private let defaults: UserDefaults
    private let keychain: any APIKeyStoring

    init(defaults: UserDefaults = .standard, keychain: any APIKeyStoring = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        voiceSubtitleSize = VoiceSubtitleStyle.fontSize(defaults.object(forKey: "voiceSubtitleSize") as? Double ?? 28)
        voiceSubtitleOpacity = OverlayLayout.opacity(defaults.object(forKey: "voiceSubtitleOpacity") as? Double ?? 0.9)
        voiceSource = TranslationLanguage(rawValue: defaults.string(forKey: "voiceSource") ?? "") ?? .english
        voiceTarget = TranslationLanguage(rawValue: defaults.string(forKey: "voiceTarget") ?? "") ?? .simplifiedChinese
        voiceShortcut = VoiceShortcut(rawValue: defaults.string(forKey: "voiceShortcut") ?? "") ?? .optionCommandR
        copyThenTranslate = defaults.object(forKey: "copyThenTranslate") as? Bool ?? true
        autoTranslate = defaults.object(forKey: "autoTranslate") as? Bool ?? true
        engine = TranslationEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .system
        source = TranslationLanguage(rawValue: defaults.string(forKey: "source") ?? "") ?? .english
        target = TranslationLanguage(rawValue: defaults.string(forKey: "target") ?? "") ?? .simplifiedChinese
        endpoint = defaults.string(forKey: "endpoint") ?? ""
        model = defaults.string(forKey: "model") ?? ""
        sendContext = defaults.object(forKey: "sendContext") as? Bool ?? true
        excludedBundleIDs = defaults.string(forKey: "excludedBundleIDs") ?? "com.apple.keychainaccess"
        scene = defaults.string(forKey: "scene") ?? "自动"
        overlayOpacity = OverlayLayout.opacity(defaults.object(forKey: "overlayOpacity") as? Double ?? 0.85)
        overlayHorizontal = OverlayLayout.unit(defaults.object(forKey: "overlayHorizontal") as? Double ?? 0.95)
        overlayVertical = OverlayLayout.unit(defaults.object(forKey: "overlayVertical") as? Double ?? 0.12)
        overlayScreenID = defaults.string(forKey: "overlayScreenID") ?? "main"
        overlayShortcut = OverlayShortcut(rawValue: defaults.string(forKey: "overlayShortcut") ?? "") ?? .optionCommandT
        do {
            apiKey = try keychain.loadAPIKey()
        } catch {
            apiKey = ""
            lastKeyError = error.localizedDescription
        }
    }

    func swapLanguages() {
        let previousSource = source
        source = target
        target = previousSource
    }

    func resetOverlayPosition() {
        overlayHorizontal = 0.95
        overlayVertical = 0.12
        overlayScreenID = "main"
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
