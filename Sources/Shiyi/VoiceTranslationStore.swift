import AppKit
import Combine

struct VoiceCaption: Identifiable, Equatable, Codable {
    let id: UUID
    var original: String
    var recordedAt = Date()
    var translation = ""
    var failure: String?
}

struct VoiceTranslationRequest: Equatable {
    let id: UUID
    let text: String
    var isFinal = true
}

struct VoiceTranslationQueue {
    private(set) var requests: [VoiceTranslationRequest] = []
    let limit: Int
    init(limit: Int = 16) { self.limit = limit }
    mutating func enqueue(_ request: VoiceTranslationRequest) -> Bool {
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
            return true
        }
        guard requests.count < limit else { return false }
        requests.append(request)
        return true
    }
    mutating func next() -> VoiceTranslationRequest? { requests.isEmpty ? nil : requests.removeFirst() }
    mutating func clear() { requests.removeAll() }
}

@MainActor
final class VoiceTranslationStore: ObservableObject {
    let preferences: Preferences
    let model = LocalVoiceModel()
    let archive: VoiceTranscriptArchive
    private var sessionID: UUID?
    private var captionSessions: [UUID: UUID] = [:]
    @Published private(set) var listening = false
    @Published private(set) var starting = false
    @Published private(set) var liveOriginal = ""
    @Published private(set) var subtitleCaption: VoiceCaption?
    @Published private(set) var captions: [VoiceCaption] = []
    @Published private(set) var status = "点击开始，翻译麦克风里的声音。"
    @Published var error: String?
    @Published var shortcutError: String?
    var onShowWindow: (() -> Void)?
    var onPreviewWindow: (() -> Void)?
    private var recognizer: (any VoiceRecognizing)?
    private var startTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var maximumWait: Task<Void, Never>?
    private var modelWarmTask: Task<Void, Error>?
    private var previousOriginal = ""
    private var lastPreview = ""
    private var modelLoading = false
    private var microphoneGeneration = UUID()
    private var translationGeneration = UUID()
    private var draftID = UUID()
    private var queue = VoiceTranslationQueue()
    private var observers = Set<AnyCancellable>()
    private var activeRequest: VoiceTranslationRequest?
    private let recognizerFactory: @MainActor () -> any VoiceRecognizing
    private let translateText: (String, TranslationLanguage, TranslationLanguage) async throws -> String
    private let modelReady: (() -> Bool)?
    private let streamTranslate: (@MainActor (String, TranslationLanguage, TranslationLanguage, @escaping @MainActor (String) -> Void) async throws -> String)?

    init(preferences: Preferences,
         archive: VoiceTranscriptArchive? = nil,
         recognizerFactory: @escaping @MainActor () -> any VoiceRecognizing = { makeVoiceRecognizer() },
         modelReady: (() -> Bool)? = nil,
         streamTranslate: (@MainActor (String, TranslationLanguage, TranslationLanguage, @escaping @MainActor (String) -> Void) async throws -> String)? = nil,
         translate: ((String, TranslationLanguage, TranslationLanguage) async throws -> String)? = nil) {
        self.preferences = preferences
        self.archive = archive ?? VoiceTranscriptArchive()
        self.recognizerFactory = recognizerFactory
        self.modelReady = modelReady
        self.translateText = translate ?? { try await LocalVoiceClient().translate($0, source: $1, target: $2) }
        if let streamTranslate { self.streamTranslate = streamTranslate }
        else if translate == nil {
            self.streamTranslate = { try await LocalVoiceClient().translateStreaming($0, source: $1, target: $2, onUpdate: $3) }
        } else { self.streamTranslate = nil }
        Publishers.Merge(preferences.$voiceSource.map { _ in () }, preferences.$voiceTarget.map { _ in () })
            .dropFirst(2).sink { [weak self] in
                self?.stop(cancelPending: true)
                self?.status = "语言已更改，点击开始使用新语言。"
            }.store(in: &observers)
    }

    func start() {
        guard !starting, !listening else { return }
        guard modelReady?() ?? model.ready else { error = "请先在主窗口 → 语音翻译中准备免费模型。"; return }
        error = nil
        sessionID = archive.begin(source: preferences.voiceSource, target: preferences.voiceTarget)
        starting = true
        status = "准备语音识别与麦克风…"
        liveOriginal = ""
        draftID = UUID(); previousOriginal = ""; lastPreview = ""
        if modelReady == nil { model.retainWhileListening() }
        let token = UUID()
        microphoneGeneration = token
        let source = preferences.voiceSource
        let recognition = recognizerFactory()
        recognizer = recognition
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.modelReady == nil {
                    self.modelLoading = true
                    self.modelWarmTask = Task {
                        defer { if self.microphoneGeneration == token { self.modelLoading = false } }
                        do {
                            try await self.model.warmUp()
                            if self.listening, self.microphoneGeneration == token { self.status = "正在听麦克风 · 本机识别与翻译" }
                        } catch {
                            if self.microphoneGeneration == token {
                                self.stop(cancelPending: true)
                                self.error = "翻译模型加载失败，请检查可用内存后重新开始。"
                            }
                            throw error
                        }
                    }
                }
                try Task.checkCancellation()
                try await recognition.start(language: source, onText: { [weak self] text, final in
                    guard let self, self.microphoneGeneration == token else { return }
                    self.receive(text, final: final)
                }, onStatus: { [weak self] text in
                    guard let self, self.microphoneGeneration == token else { return }
                    self.status = text + (self.modelLoading ? " · 翻译模型加载中" : "")
                }, onError: { [weak self] message in
                    guard let self, self.microphoneGeneration == token else { return }
                    self.stop()
                    self.error = message
                })
                guard !Task.isCancelled, self.microphoneGeneration == token else { recognition.stop(); return }
                self.starting = false
                self.listening = true
            } catch {
                guard self.microphoneGeneration == token else { recognition.stop(); return }
                self.stop()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func stop(cancelPending: Bool = false) {
        if cancelPending, !liveOriginal.isEmpty, let sessionID {
            var draft = captions.first(where: { $0.id == draftID }) ?? VoiceCaption(id: draftID, original: liveOriginal)
            if draft.original != liveOriginal { draft.translation = "" }
            draft.original = liveOriginal
            if let index = captions.firstIndex(where: { $0.id == draftID }) { captions[index] = draft }
            if draft.translation.isEmpty { draft.failure = "收听结束，尚未翻译" }
            captionSessions[draftID] = sessionID
            archive.record(draft, sessionID: sessionID)
        }
        if !cancelPending, !liveOriginal.isEmpty { submit(liveOriginal, id: draftID) }
        microphoneGeneration = UUID()
        startTask?.cancel(); startTask = nil
        debounce?.cancel(); debounce = nil
        maximumWait?.cancel(); maximumWait = nil
        recognizer?.stop(); recognizer = nil
        listening = false; starting = false; liveOriginal = ""; modelLoading = false
        status = "麦克风已停止。"
        if cancelPending {
            translationGeneration = UUID()
            worker?.cancel(); worker = nil; activeRequest = nil; queue.clear()
            for index in captions.indices where captions[index].translation.isEmpty && captions[index].failure == nil {
                captions[index].failure = "已取消"
                saveCaption(captions[index])
            }
            modelWarmTask?.cancel(); modelWarmTask = nil
            if modelReady == nil { model.unload() }
        }
        if let sessionID { archive.end(sessionID) }
        if worker == nil, modelReady == nil { model.unload() }
    }

    func clear() {
        for var caption in captions where caption.translation.isEmpty && caption.failure == nil {
            caption.failure = "屏幕字幕已清空，未完成翻译"
            saveCaption(caption)
        }
        translationGeneration = UUID()
        worker?.cancel(); worker = nil; activeRequest = nil; queue.clear()
        debounce?.cancel(); debounce = nil
        maximumWait?.cancel(); maximumWait = nil
        captions.removeAll(); subtitleCaption = nil; draftID = UUID(); liveOriginal = ""; previousOriginal = ""; lastPreview = ""
    }

    private func receive(_ text: String, final: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 1200 else {
            liveOriginal = text
            stop(cancelPending: true)
            error = "连续语句过长，已停止收音；请分句说话后重新开始，避免截断译文。"
            return
        }
        // Duplicate volatile callbacks must not postpone a stable phrase.
        if text == liveOriginal, !final { return }
        previousOriginal = liveOriginal
        liveOriginal = text
        updateOriginal(text, id: draftID)
        debounce?.cancel()
        if final {
            maximumWait?.cancel(); maximumWait = nil
            submit(text, id: draftID)
            draftID = UUID(); liveOriginal = ""; previousOriginal = ""; lastPreview = ""
        } else {
            let id = draftID, token = microphoneGeneration
            debounce = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                guard let self, self.draftID == id, self.microphoneGeneration == token else { return }
                self.maximumWait?.cancel(); self.maximumWait = nil
                self.submitPreview(stable: true)
            }
            if maximumWait == nil {
                maximumWait = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return }
                    guard let self, self.draftID == id, self.microphoneGeneration == token else { return }
                    self.maximumWait = nil
                    self.submitPreview(stable: false)
                }
            }
        }
    }

    private func updateOriginal(_ text: String, id: UUID) {
        if let index = captions.firstIndex(where: { $0.id == id }) {
            if captions[index].original != text {
                if VoiceLivePolicy.normalized(captions[index].original) != VoiceLivePolicy.normalized(text) { captions[index].translation = "" }
                captions[index].original = text; captions[index].failure = nil
            }
        } else { captions.append(VoiceCaption(id: id, original: text)) }
        if let sessionID { captionSessions[id] = captionSessions[id] ?? sessionID }
        if let caption = captions.first(where: { $0.id == id }) { saveCaption(caption) }
        while captions.count > 100, let first = captions.first, !first.translation.isEmpty || first.failure != nil { captions.removeFirst() }
    }

    private func submitPreview(stable: Bool) {
        let text = VoiceLivePolicy.preview(liveOriginal, previous: previousOriginal, settled: stable)
        let normalized = VoiceLivePolicy.normalized(text)
        guard !normalized.isEmpty, normalized != lastPreview else { return }
        // Final records take priority over speculative drafts on a single GPU.
        guard queue.requests.filter({ $0.isFinal }).count < 2 else { return }
        lastPreview = normalized
        submit(text, id: draftID, isFinal: false)
    }

    private func submit(_ text: String, id: UUID, isFinal: Bool = true) {
        let normalized = VoiceLivePolicy.normalized(text)
        if let activeRequest, activeRequest.id == id, VoiceLivePolicy.normalized(activeRequest.text) == normalized { return }
        if let existing = captions.first(where: { $0.id == id }),
           VoiceLivePolicy.normalized(existing.original) == normalized, !existing.translation.isEmpty { return }
        if isFinal { updateOriginal(text, id: id) }
        let request = VoiceTranslationRequest(id: id, text: text, isFinal: isFinal)
        guard queue.enqueue(request) else {
            guard isFinal else { return }
            if let sessionID {
                archive.record(VoiceCaption(id: id, original: text, failure: "翻译排队过多，未完成翻译"), sessionID: sessionID)
                archive.end(sessionID)
            }
            microphoneGeneration = UUID()
            recognizer?.stop(); recognizer = nil
            debounce?.cancel(); maximumWait?.cancel(); maximumWait = nil; startTask?.cancel()
            listening = false; starting = false
            if modelReady == nil { model.unload() }
            error = "本地翻译暂时跟不上语速，已暂停收音；原文已保存，请等现有任务完成后再开始。"
            return
        }
        runQueue()
    }

    private func saveCaption(_ caption: VoiceCaption) {
        if let session = captionSessions[caption.id] { archive.record(caption, sessionID: session) }
    }

    private func runQueue() {
        guard worker == nil else { return }
        let generation = translationGeneration
        let source = preferences.voiceSource, target = preferences.voiceTarget
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == self.translationGeneration, let request = self.queue.next() {
                self.activeRequest = request
                do {
                    try await self.modelWarmTask?.value
                    try Task.checkCancellation()
                    let output: String
                    if let streaming = self.streamTranslate {
                        output = try await streaming(request.text, source, target) { [weak self] text in
                            guard let self, generation == self.translationGeneration, !Task.isCancelled else { return }
                            self.present(text, for: request)
                        }
                    } else { output = try await self.translateText(request.text, source, target) }
                    guard !Task.isCancelled, generation == self.translationGeneration else { return }
                    self.present(output, for: request)
                    if let index = self.captions.firstIndex(where: { $0.id == request.id && VoiceLivePolicy.normalized($0.original) == VoiceLivePolicy.normalized(request.text) }) {
                        self.captions[index].failure = nil
                        self.captions[index].translation = output
                        self.saveCaption(self.captions[index])
                    }
                } catch {
                    guard !Task.isCancelled, generation == self.translationGeneration else { return }
                    if let index = self.captions.firstIndex(where: { $0.id == request.id && $0.original == request.text }) {
                        self.captions[index].failure = error.localizedDescription
                        self.saveCaption(self.captions[index])
                    }
                }
            }
            if generation == self.translationGeneration {
                self.worker = nil; self.activeRequest = nil
                if !self.listening, !self.starting, self.modelReady == nil { self.model.unload() }
            }
        }
    }
    private func present(_ text: String, for request: VoiceTranslationRequest) {
        guard !text.isEmpty, let original = captions.first(where: { $0.id == request.id }) else { return }
        let pair = VoiceCaption(id: request.id, original: request.text, recordedAt: original.recordedAt, translation: text)
        if subtitleCaption == nil || pair.recordedAt >= subtitleCaption!.recordedAt { subtitleCaption = pair }
    }

}

/// Display-only short clauses; the complete recognition remains in the archive.
enum VoiceLivePolicy {
    static func normalized(_ text: String) -> String {
        var result = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Only sentence-end punctuation is cosmetic. Preserve decimal points,
        // apostrophes and other symbols inside the recognized content.
        if result.contains(where: \.isLetter) {
            while let last = result.last, ".,!?;:。！？；，： ".contains(last) { result.removeLast() }
        }
        return result
    }
    static func preview(_ text: String, previous: String, settled: Bool) -> String {
        var stable = text
        if !settled {
            stable = String(zip(text, previous).prefix(while: { $0 == $1 }).map { $0.0 })
            // Do not send an English word whose spelling is still changing.
            if let end = stable.last, end.isASCII, end.isLetter {
                guard let space = stable.lastIndex(of: " ") else { return "" }
                stable = String(stable[..<space])
            }
        }
        let boundaries = CharacterSet(charactersIn: ".!?;。！？；，,\n")
        let clauses = stable.components(separatedBy: boundaries).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let phrase = clauses.last ?? stable
        let words = phrase.split(whereSeparator: \.isWhitespace)
        if words.count > 14 { return words.suffix(14).joined(separator: " ") }
        if words.count > 1 || phrase.allSatisfy({ $0.isASCII }) { return phrase }
        // CJK lacks spaces; bound live previews without truncating saved text.
        return String(phrase.suffix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
