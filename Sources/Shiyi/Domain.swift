import Foundation
import CoreGraphics

enum TranslationEngine: String, CaseIterable, Identifiable {
    case system, contextual
    var id: String { rawValue }
    var title: String { self == .system ? "系统翻译" : "AI 语境翻译" }
}

enum TranslationLanguage: String, CaseIterable, Identifiable, Codable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case german = "de"
    case japanese = "ja"
    case french = "fr"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "英语"
        case .german: return "德语"
        case .japanese: return "日语"
        case .french: return "法语"
        }
    }
}

struct CapturedSelection: Equatable {
    var text: String
    var context: String
    var appName: String
    var bundleID: String
    var documentTitle: String
    var anchor: CGPoint
}

struct TranslationJob: Identifiable {
    let id = UUID()
    let selection: CapturedSelection
    let source: TranslationLanguage
    let target: TranslationLanguage
    let engine: TranslationEngine
}

struct TranslationOutput: Equatable, Codable {
    var translation: String
    var explanation: String
    var alternatives: [String]
    var detectedScene: String
}

enum TranslationPhase: Equatable {
    case idle
    case loading
    case finished(TranslationOutput)
    case failed(String)
}
