import SwiftUI
import Translation

/// Keep this host in a presented window so macOS can display language preparation UI.
struct SystemTranslationHost: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Group {
            if let job = store.job, job.engine == .system {
                SystemTranslationTaskView(store: store, job: job)
                    .id(job.id)
            }
        }
    }
}

private struct SystemTranslationTaskView: View {
    @ObservedObject var store: AppStore
    let job: TranslationJob

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .translationTask(source: nil, target: Locale.Language(identifier: job.target.rawValue)) { session in
                var stage = "检测语言"
                var languageState = ""
                do {
                    try Task.checkCancellation()
                    let availability = try await LanguageAvailability().status(
                        for: job.selection.text,
                        to: Locale.Language(identifier: job.target.rawValue)
                    )
                    try Task.checkCancellation()
                    switch availability {
                    case .unsupported:
                        await MainActor.run {
                            store.fail("系统翻译暂不支持这段文字与\(job.target.title)之间的翻译。若原文已经是目标语言，无需再次翻译；也可以切换至 AI 语境翻译。", jobID: job.id)
                        }
                        return
                    case .supported:
                        languageState = "语言包尚未安装"
                        await MainActor.run { store.prepareSystemDownload(jobID: job.id) }
                    case .installed:
                        languageState = "语言包已安装"
                    @unknown default:
                        languageState = "语言包状态未知"
                    }
                    stage = "执行翻译"
                    // With source=nil, prepareTranslation() cannot identify a language.
                    // translate(_:) detects it from this text and requests downloads as needed.
                    let response = try await session.translate(job.selection.text)
                    try Task.checkCancellation()
                    let output = TranslationOutput(
                        translation: response.targetText,
                        explanation: "由 macOS 系统翻译。仅翻译选中文字，未额外使用附近上下文。",
                        alternatives: [],
                        detectedScene: "系统翻译"
                    )
                    await MainActor.run { store.complete(output, jobID: job.id) }
                } catch is CancellationError {
                    // A newer job or a closed panel superseded this request.
                } catch {
                    let failure = error as NSError
                    var details = "\(failure.domain) / \(failure.code)"
                    if !languageState.isEmpty { details += "；\(languageState)" }
                    if let reason = failure.localizedFailureReason, !reason.isEmpty {
                        details += "；\(reason)"
                    }
                    let message = "系统翻译未完成：\(failure.localizedDescription)\n\(stage)：\(details)\n可前往系统设置 → 通用 → 语言与地区 → 翻译语言，检查所需语言包后重试。"
                    // Diagnostics include only selected NSError fields, never its userInfo.
                    let safeMessage = job.selection.text.isEmpty ? message : message.replacingOccurrences(of: job.selection.text, with: "[原文已隐去]")
                    await MainActor.run {
                        store.fail(safeMessage, jobID: job.id)
                    }
                }
            }
    }
}
