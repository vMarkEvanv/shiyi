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
    @Published private(set) var captions: [VoiceCaption] = []
    @Published private(set) var level: Double = 0
    @Published private(set) var status = "点击开始，翻译麦克风里的声音。"
    @Published var error: String?
    @Published var shortcutError: String?
    var onShowWindow: (() -> Void)?
    var onPreviewWindow: (() -> Void)?
    private var recognizer: (any VoiceRecognizing)?
    private var startTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var microphoneGeneration = UUID()
    private var translationGeneration = UUID()
    private var draftID = UUID()
    private var queue = VoiceTranslationQueue()
    private var observers = Set<AnyCancellable>()
    private var activeRequest: VoiceTranslationRequest?
    private let recognizerFactory: @MainActor () -> any VoiceRecognizing
    private let translateText: (String, TranslationLanguage, TranslationLanguage) async throws -> String
    private let modelReady: (() -> Bool)?
    private var lastLevelUpdate: TimeInterval = 0

    init(preferences: Preferences,
         archive: VoiceTranscriptArchive? = nil,
         recognizerFactory: @escaping @MainActor () -> any VoiceRecognizing = { makeVoiceRecognizer() },
         modelReady: (() -> Bool)? = nil,
         translate: @escaping (String, TranslationLanguage, TranslationLanguage) async throws -> String = {
             try await LocalVoiceClient().translate($0, source: $1, target: $2)
         }) {
        self.preferences = preferences
        self.archive = archive ?? VoiceTranscriptArchive()
        self.recognizerFactory = recognizerFactory
        self.modelReady = modelReady
        self.translateText = translate
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
        draftID = UUID()
        let token = UUID()
        microphoneGeneration = token
        let source = preferences.voiceSource
        let recognition = recognizerFactory()
        recognizer = recognition
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.modelReady == nil {
                    self.status = "加载本地翻译模型（首次约几秒）…"
                    try await self.model.warmUp()
                }
                try Task.checkCancellation()
                try await recognition.start(language: source, onText: { [weak self] text, final in
                    guard let self, self.microphoneGeneration == token else { return }
                    self.receive(text, final: final)
                }, onLevel: { [weak self] value in
                    guard let self, self.microphoneGeneration == token else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastLevelUpdate > 0.1 { self.level = value; self.lastLevelUpdate = now }
                }, onStatus: { [weak self] text in
                    guard let self, self.microphoneGeneration == token else { return }
                    self.status = text
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
        recognizer?.stop(); recognizer = nil
        listening = false; starting = false; level = 0; liveOriginal = ""
        status = "麦克风已停止。"
        if cancelPending {
            translationGeneration = UUID()
            worker?.cancel(); worker = nil; activeRequest = nil; queue.clear()
            for index in captions.indices where captions[index].translation.isEmpty && captions[index].failure == nil {
                captions[index].failure = "已取消"
                saveCaption(captions[index])
            }
            if modelReady == nil { model.unload() }
        }
        if let sessionID { archive.end(sessionID) }
    }

    func clear() {
        for var caption in captions where caption.translation.isEmpty && caption.failure == nil {
            caption.failure = "屏幕字幕已清空，未完成翻译"
            saveCaption(caption)
        }
        translationGeneration = UUID()
        worker?.cancel(); worker = nil; activeRequest = nil; queue.clear()
        debounce?.cancel(); debounce = nil
        captions.removeAll(); draftID = UUID()
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
        liveOriginal = text
        debounce?.cancel()
        if final {
            submit(text, id: draftID)
            draftID = UUID(); liveOriginal = ""
        } else {
            let id = draftID
            debounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.submit(text, id: id)
            }
        }
    }

    private func submit(_ text: String, id: UUID) {
        if activeRequest == VoiceTranslationRequest(id: id, text: text) { return }
        if let existing = captions.first(where: { $0.id == id }), existing.original == text,
           !existing.translation.isEmpty || queue.requests.contains(where: { $0.id == id && $0.text == text }) { return }
        guard queue.enqueue(VoiceTranslationRequest(id: id, text: text)) else {
            // Preserve the untranslated final phrase before pausing input.
            if let sessionID {
                archive.record(VoiceCaption(id: id, original: text, failure: "翻译排队过多，未完成翻译"), sessionID: sessionID)
                archive.end(sessionID)
            }
            microphoneGeneration = UUID()
            recognizer?.stop(); recognizer = nil
            debounce?.cancel(); startTask?.cancel()
            listening = false; starting = false
            error = "本地翻译暂时跟不上语速，已暂停收音。请等已有字幕完成后再开始；最后一段原文仍显示在上方。"
            return
        }
        if let index = captions.firstIndex(where: { $0.id == id }) {
            captions[index].original = text
            captions[index].translation = ""
            captions[index].failure = nil
        } else {
            captions.append(VoiceCaption(id: id, original: text))
        }
        if let sessionID { captionSessions[id] = captionSessions[id] ?? sessionID }
        if let caption = captions.first(where: { $0.id == id }) { saveCaption(caption) }
        // Keep pending rows; only evict completed history.
        while captions.count > 100, let first = captions.first, !first.translation.isEmpty || first.failure != nil {
            captions.removeFirst()
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
                    let output = try await self.translateText(request.text, source, target)
                    guard !Task.isCancelled, generation == self.translationGeneration else { return }
                    if let index = self.captions.firstIndex(where: { $0.id == request.id && $0.original == request.text }) {
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
            if generation == self.translationGeneration { self.worker = nil; self.activeRequest = nil }
        }
    }
}
