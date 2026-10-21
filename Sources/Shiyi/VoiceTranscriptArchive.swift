import AppKit
import Combine
import UniformTypeIdentifiers

struct VoiceTranscriptSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var schemaVersion = 1
    var name: String?
    var startedAt = Date()
    var endedAt: Date?
    var source: TranslationLanguage
    var target: TranslationLanguage
    var captions: [VoiceCaption] = []

    mutating func upsert(_ caption: VoiceCaption) {
        if let index = captions.firstIndex(where: { $0.id == caption.id }) { captions[index] = caption }
        else { captions.append(caption) }
    }
    var displayName: String { name?.isEmpty == false ? name! : "语音翻译" }
    func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || [displayName, source.title, target.title].contains { $0.localizedStandardContains(text) }
            || captions.contains { $0.original.localizedStandardContains(text) || $0.translation.localizedStandardContains(text) }
    }
    var markdown: String {
        let date = DateFormatter()
        date.dateStyle = .medium; date.timeStyle = .medium
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
        var lines = ["# 拾译 · \(name ?? "语音翻译记录")", "", "- 开始：\(date.string(from: startedAt))",
                     "- 语言：\(source.title) → \(target.title)", "- 语段：\(captions.count)"]
        if let endedAt { lines.append("- 结束：\(date.string(from: endedAt))") }
        for (index, caption) in captions.enumerated() {
            lines += ["", "## \(index + 1) · \(clock.string(from: caption.recordedAt))", "", "原文：", "", caption.original, "", "译文：", "",
                      caption.translation.isEmpty ? "（未完成翻译\(caption.failure.map { "：" + $0 } ?? "")）" : caption.translation]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct VoiceTranscriptSummary: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let name: String?
    let endedAt: Date?
    let source: TranslationLanguage
    let target: TranslationLanguage
    let count: Int
    var title: String {
        let date = DateFormatter(); date.dateFormat = "MM-dd HH:mm"
        return "\(name.map { $0 + " · " } ?? "")\(date.string(from: startedAt)) · \(source.title) → \(target.title) · \(count) 段"
    }
    init(_ session: VoiceTranscriptSession) {
        id = session.id; startedAt = session.startedAt; name = session.name; endedAt = session.endedAt; source = session.source; target = session.target; count = session.captions.count
    }
}

/// Each session is atomically rewritten on a serial disk queue. UI clearing never
/// deletes archived text; closing/quit flushes pending writes before returning.
@MainActor
final class VoiceTranscriptArchive: ObservableObject {
    @Published private(set) var sessions: [VoiceTranscriptSummary] = []
    @Published private(set) var pendingWrites = 0
    @Published private(set) var saveError: String?
    let directory: URL?
    private var active: [UUID: VoiceTranscriptSession] = [:]
    private var failedSessions: [UUID: String] = [:]
    private var pendingSnapshots: [UUID: VoiceTranscriptSession] = [:]
    private var saveTask: Task<Void, Never>?
    private var writesInFlight = 0
    private let disk = DispatchQueue(label: "com.shiyi.voice.history", qos: .utility)
    static var defaultDirectory: URL {
        LocalVoiceModel.root.appendingPathComponent("VoiceHistory", isDirectory: true)
    }
    init(directory: URL?) { self.directory = directory }
    convenience init() { self.init(directory: Self.defaultDirectory) }

    func begin(source: TranslationLanguage, target: TranslationLanguage) -> UUID {
        let session = VoiceTranscriptSession(source: source, target: target)
        active[session.id] = session
        return session.id
    }
    func record(_ caption: VoiceCaption, sessionID: UUID) {
        guard var session = active[sessionID] else { return }
        session.upsert(caption)
        guard session != active[sessionID] else { return }
        active[sessionID] = session
        persist(session, immediate: !caption.translation.isEmpty || caption.failure != nil)
    }
    func end(_ id: UUID) {
        guard var session = active[id] else { return }
        session.endedAt = session.endedAt ?? Date()
        active[id] = session
        if !session.captions.isEmpty { persist(session, immediate: true) }
    }
    private func persist(_ session: VoiceTranscriptSession, immediate: Bool = false) {
        let summary = VoiceTranscriptSummary(session)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            if sessions[index] != summary { sessions[index] = summary }
        } else { sessions.append(summary); sessions.sort { $0.startedAt > $1.startedAt } }
        guard directory != nil else { return }
        pendingSnapshots[session.id] = session
        updatePendingCount()
        if immediate { writePending() }
        else if saveTask == nil {
            saveTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
                self?.writePending()
            }
        }
    }
    private func updatePendingCount() {
        let count = writesInFlight + pendingSnapshots.count
        if pendingWrites != count { pendingWrites = count }
    }
    private func writePending() {
        saveTask?.cancel(); saveTask = nil
        let snapshots = Array(pendingSnapshots.values)
        pendingSnapshots.removeAll()
        writesInFlight += snapshots.count
        updatePendingCount()
        for session in snapshots { write(session) }
    }
    private func write(_ session: VoiceTranscriptSession) {
        guard let directory else { return }
        disk.async { [weak self] in
            let failure: String?
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let file = directory.appendingPathComponent(session.id.uuidString).appendingPathExtension("json")
                try encoder.encode(session).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                failure = nil
            } catch { failure = "语音记录保存失败，请检查磁盘空间和文件夹权限；本次内容仍在内存中。" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.writesInFlight = max(0, self.writesInFlight - 1)
                self.updatePendingCount()
                if let failure { self.failedSessions[session.id] = failure }
                else { self.failedSessions.removeValue(forKey: session.id) }
                self.saveError = self.failedSessions.values.first
            }
        }
    }
    func flush() { writePending(); disk.sync {} }
    func refresh() async {
        guard let directory else { return }
        let loaded = await withCheckedContinuation { continuation in
            disk.async {
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let rows = files.filter { $0.pathExtension == "json" }.compactMap { file -> VoiceTranscriptSummary? in
                    guard let data = try? Data(contentsOf: file), let session = try? decoder.decode(VoiceTranscriptSession.self, from: data) else { return nil }
                    return VoiceTranscriptSummary(session)
                }
                continuation.resume(returning: rows)
            }
        }
        var merged = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for session in active.values where !session.captions.isEmpty { merged[session.id] = VoiceTranscriptSummary(session) }
        sessions = merged.values.sorted { $0.startedAt > $1.startedAt }
    }
    func load(_ id: UUID) async throws -> VoiceTranscriptSession {
        if let session = active[id] { return session }
        guard let directory else { throw VoiceModelError(message: "没有找到这条翻译记录。") }
        return try await withCheckedThrowingContinuation { continuation in
            disk.async {
                do {
                    let data = try Data(contentsOf: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    continuation.resume(returning: try decoder.decode(VoiceTranscriptSession.self, from: data))
                } catch { continuation.resume(throwing: VoiceModelError(message: "记录无法读取，请检查文件是否仍在保存文件夹中。")) }
            }
        }
    }
    func rename(_ id: UUID, to name: String) async throws {
        var session = try await load(id)
        let clean = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        session.name = clean.isEmpty ? nil : String(clean.prefix(120))
        active[id] = session
        persist(session, immediate: true)
    }
    func showFolder() {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(directory)
        } catch { saveError = "无法打开记录文件夹。" }
    }
    func export(_ id: UUID) async {
        do {
            let session = try await load(id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            let date = DateFormatter(); date.dateFormat = "yyyyMMdd-HHmmss"
            panel.nameFieldStringValue = "拾译-语音翻译-\(date.string(from: session.startedAt)).md"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try session.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch { saveError = error.localizedDescription }
    }
}
