import AppKit
import ApplicationServices
import Combine

@MainActor
final class AppStore: ObservableObject {
    let preferences: Preferences
    @Published var selection: CapturedSelection?
    @Published var phase: TranslationPhase = .idle
    @Published var job: TranslationJob?
    @Published var permissionGranted = AXIsProcessTrusted()
    @Published private(set) var isOverlayVisible = false
    @Published private(set) var isOverlayExpanded = false
    @Published private(set) var overlayScrollIndex = 0
    @Published var overlayWidth: CGFloat = OverlayLayout.width
    @Published var overlayHeight: CGFloat = OverlayLayout.compactHeight
    @Published var availableDisplays = [OverlayDisplay(id: "main", title: "主屏幕")]
    @Published var shortcutError: String?
    @Published var manualText = ""
    @Published private(set) var isPreparingSystemLanguages = false
    var onShowPanel: (() -> Void)?
    var onDismissPanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSystemDownloadNeeded: (() -> Void)?
    private var translationTask: Task<Void, Never>?
    private let client = TranslationClient()

    init(preferences: Preferences? = nil) { self.preferences = preferences ?? Preferences() }

    func translate(_ captured: CapturedSelection) {
        cancelCurrentJob()
        selection = captured
        let next = TranslationJob(selection: captured, source: preferences.source, target: preferences.target, engine: preferences.engine)
        job = next
        phase = .loading
        overlayScrollIndex = 0
        if next.source == next.target {
            complete(TranslationOutput(translation: captured.text, explanation: "原文语言与目标语言相同，已保留原文。", alternatives: [], detectedScene: "无需翻译"), jobID: next.id)
            return
        }
        guard next.engine == .contextual else { return }
        // Snapshot all settings: a request never mixes an old selection with new credentials.
        let endpoint = preferences.endpoint
        let model = preferences.model
        let key = preferences.apiKey
        let includeContext = preferences.sendContext
        let scene = preferences.scene
        translationTask = Task { [weak self, client] in
            do {
                let output = try await client.translate(selection: captured, source: next.source, target: next.target, endpoint: endpoint,
                                                        model: model, apiKey: key, sendContext: includeContext, scene: scene)
                guard !Task.isCancelled else { return }
                self?.complete(output, jobID: next.id)
            } catch is CancellationError {
                // A new selection or dismissal intentionally cancels the previous request.
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error.localizedDescription, jobID: next.id)
            }
        }
    }

    func translateManual() {
        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .failed("请先输入或粘贴要翻译的文字。"); return }
        guard text.count <= 5_000 else { phase = .failed("请将文字控制在 5,000 字以内。"); return }
        let captured = CapturedSelection(text: text, context: "", appName: "手动输入", bundleID: "",
                                         documentTitle: "", anchor: NSEvent.mouseLocation)
        translate(captured)
    }

    func retry() {
        guard let selection else { translateManual(); return }
        // A stored selection must not resend context after the privacy toggle is disabled.
        var next = selection
        if !preferences.sendContext { next.context = ""; next.documentTitle = "" }
        translate(next)
    }

    func complete(_ output: TranslationOutput, jobID: UUID) {
        guard job?.id == jobID else { return }
        isPreparingSystemLanguages = false
        phase = .finished(output)
    }

    func fail(_ message: String, jobID: UUID) {
        guard job?.id == jobID else { return }
        isPreparingSystemLanguages = false
        phase = .failed(message)
    }

    func prepareSystemDownload(jobID: UUID) {
        guard job?.id == jobID else { return }
        isPreparingSystemLanguages = true
        onSystemDownloadNeeded?()
    }

    func captureFailed(_ message: String) {
        cancelCurrentJob()
        selection = nil
        phase = .failed(message)
    }

    func showOverlay() {
        if !isOverlayVisible {
            // Moving a system host between windows must not replay an old request.
            if phase == .loading { cancelCurrentJob(); phase = .idle }
            isOverlayVisible = true
        }
        onShowPanel?()
    }

    func toggleOverlayExpansion() {
        guard isOverlayVisible else { return }
        isOverlayExpanded.toggle()
        overlayScrollIndex = 0
    }

    func collapseOverlay() {
        isOverlayExpanded = false
        overlayScrollIndex = 0
    }

    func invalidateTranslation() {
        cancelCurrentJob()
        selection = nil
        phase = .idle
        overlayScrollIndex = 0
    }

    var overlayDetailText: String {
        guard case .finished(let output) = phase else {
            if case .failed(let message) = phase { return message }
            return phase == .loading ? "正在翻译…" : "在其他应用中选中文字，译文会更新在这里。"
        }
        var parts: [String] = []
        if let selection { parts.append("原文\n" + selection.text) }
        parts.append("译文\n" + output.translation)
        if !output.explanation.isEmpty { parts.append("说明\n" + output.explanation) }
        if !output.alternatives.isEmpty { parts.append("其他译法\n" + output.alternatives.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    var overlayBlocks: [String] { OverlayText.blocks(overlayDetailText) }

    func scrollOverlay(by direction: Int) {
        guard isOverlayExpanded else { return }
        overlayScrollIndex = min(max(0, overlayScrollIndex + direction), max(0, overlayBlocks.count - 1))
    }

    func copyTranslation() {
        guard case .finished(let output) = phase else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.translation, forType: .string)
    }

    func dismiss() {
        cancelCurrentJob()
        isOverlayVisible = false
        collapseOverlay()
        if phase == .loading { phase = .idle }
        onDismissPanel?()
    }

    func cancelCurrentJob() {
        isPreparingSystemLanguages = false
        translationTask?.cancel()
        translationTask = nil
        job = nil
    }

    func refreshPermission() { permissionGranted = AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        permissionGranted = AXIsProcessTrustedWithOptions(options)
        if !permissionGranted { openAccessibilitySettings() }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func blockCurrentApp() {
        guard let id = selection?.bundleID, !id.isEmpty else { return }
        var excluded = TextContext.excludedApps(from: preferences.excludedBundleIDs)
        excluded.insert(id)
        preferences.excludedBundleIDs = excluded.sorted().joined(separator: "\n")
        dismiss()
    }
}
