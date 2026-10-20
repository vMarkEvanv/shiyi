import Foundation
import CryptoKit
import Combine

struct VoiceModelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LocalVoiceClient {
    static let base = URL(string: "http://127.0.0.1:11439")!
    static let model = "translategemma:4b"
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func prompt(_ text: String, source: TranslationLanguage, target: TranslationLanguage) -> String {
        let names: [TranslationLanguage: String] = [.english: "English", .simplifiedChinese: "Chinese (Simplified)",
            .german: "German", .japanese: "Japanese", .french: "French"]
        let from = names[source]!, to = names[target]!
        return "You are a professional \(from) (\(source.rawValue)) to \(to) (\(target.rawValue)) translator. Your goal is to accurately convey the meaning and nuances of the original \(from) text while adhering to \(to) grammar, vocabulary, and cultural sensitivities.\nProduce only the \(to) translation, without any additional explanations or commentary. Please translate the following \(from) text into \(to):\n\n\n\(text)"
    }

    func translate(_ text: String, source: TranslationLanguage, target: TranslationLanguage) async throws -> String {
        if source == target { return text }
        var request = URLRequest(url: Self.base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model, "stream": false, "keep_alive": "2m",
            "messages": [["role": "user", "content": Self.prompt(text, source: source, target: target)]],
            "options": ["temperature": 0, "num_ctx": 2048, "num_predict": 384]
        ])
        let (data, response) = try await session.data(for: request, delegate: VoiceNoRedirects())
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VoiceModelError(message: "本地翻译模型未返回结果，请在主窗口检查模型状态。")
        }
        guard data.count < 1_000_000,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = result["message"] as? [String: Any], let output = message["content"] as? String,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceModelError(message: "本地模型返回了空译文，请重试。")
        }
        guard result["done_reason"] as? String != "length" else {
            throw VoiceModelError(message: "本句译文达到长度上限，请分成更短的句子重试。")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class VoiceNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class LocalVoiceModel: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var preparing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "首次使用需准备免费模型（约 3.3GB）"
    private var process: Process?
    private var serverStartup: Task<Void, Error>?
    private var preparation: Task<Void, Never>?
    static let version = "v0.40.6"
    static let runtimeHash = "b2b55434865a668decb494110d7fd970eed3ecc8837be2872f672ccbb95df974"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.shiyi.app")
    }
    static var runtime: URL { root.appendingPathComponent("VoiceRuntime/\(version)") }

    func prepare() {
        guard !preparing else { return }
        preparing = true
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { self.preparing = false; self.preparation = nil }
            do {
                try await self.installRuntimeIfNeeded()
                try await self.ensureServer()
                if try await self.hasModel() {
                    self.ready = true; self.progress = 1; self.status = "TranslateGemma 4B 已就绪 · 本地免费"
                    return
                }
                self.status = "下载 TranslateGemma 4B（约 3.3GB）…"
                var request = URLRequest(url: LocalVoiceClient.base.appendingPathComponent("api/pull"))
                request.httpMethod = "POST"
                request.timeoutInterval = 7200
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["model": LocalVoiceClient.model, "stream": true])
                let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: VoiceNoRedirects())
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceModelError(message: "模型下载服务无法连接。") }
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.utf8.count < 65_536, let data = line.data(using: .utf8),
                          let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if item["error"] != nil { throw VoiceModelError(message: "模型下载未完成，请检查网络后重试；已下载部分会保留。") }
                    if let total = item["total"] as? Double, total > 0, let completed = item["completed"] as? Double {
                        self.progress = min(0.99, completed / total)
                        self.status = "下载模型 \(Int(self.progress * 100))% · 首次约 3.3GB"
                    }
                }
                guard try await self.hasModel() else { throw VoiceModelError(message: "模型尚未完整下载，请重试。") }
                self.ready = true; self.progress = 1; self.status = "TranslateGemma 4B 已就绪 · 本地免费"
            } catch is CancellationError {
                self.status = "准备已取消，可稍后继续。"
            } catch {
                self.status = error.localizedDescription
                self.ready = false
            }
        }
    }

    func refresh() async {
        guard !preparing, FileManager.default.isExecutableFile(atPath: Self.runtime.appendingPathComponent("ollama").path) else { return }
        do {
            try await ensureServer()
            ready = try await hasModel()
            status = ready ? "TranslateGemma 4B 已就绪 · 本地免费" : "首次使用需下载 TranslateGemma 4B（约 3.3GB）"
        } catch { status = "本地服务尚未就绪，可点击准备模型重试。" }
    }

    func cancelPreparation() { preparation?.cancel() }
    func shutdown() {
        preparation?.cancel()
        serverStartup?.cancel()
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    func warmUp() async throws {
        try await ensureServer()
        var request = URLRequest(url: LocalVoiceClient.base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": LocalVoiceClient.model, "keep_alive": "2m", "stream": false,
                                                                        "options": ["num_ctx": 2048]])
        let (_, response) = try await URLSession.shared.data(for: request, delegate: VoiceNoRedirects())
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceModelError(message: "本地翻译模型加载失败，请检查可用内存后重试。") }
    }

    func unload() {
        Task {
            var request = URLRequest(url: LocalVoiceClient.base.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": LocalVoiceClient.model, "keep_alive": 0])
            _ = try? await URLSession.shared.data(for: request, delegate: VoiceNoRedirects())
        }
    }

    private func hasModel() async throws -> Bool {
        var request = URLRequest(url: LocalVoiceClient.base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request, delegate: VoiceNoRedirects())
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String) == LocalVoiceClient.model }
    }

    private func serverAvailable() async -> Bool {
        var request = URLRequest(url: LocalVoiceClient.base.appendingPathComponent("api/version"))
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request, delegate: VoiceNoRedirects()),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["version"] is String
    }

    private func ensureServer() async throws {
        if let serverStartup { try await serverStartup.value; return }
        let startup = Task { try await self.launchServer() }
        serverStartup = startup
        defer { serverStartup = nil }
        try await startup.value
    }

    private func launchServer() async throws {
        if await serverAvailable() { return }
        let executable = Self.runtime.appendingPathComponent("ollama")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw VoiceModelError(message: "本地推理组件未安装，请先准备模型。") }
        let service = Process()
        service.executableURL = executable
        service.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:11439"
        env["OLLAMA_MODELS"] = Self.root.appendingPathComponent("VoiceModels").path
        env["OLLAMA_NO_CLOUD"] = "1"
        env["OLLAMA_NUM_PARALLEL"] = "1"
        env["OLLAMA_MAX_LOADED_MODELS"] = "1"
        env["OLLAMA_DEBUG_LOG_REQUESTS"] = "false"
        service.environment = env
        service.standardOutput = FileHandle.nullDevice
        service.standardError = FileHandle.nullDevice
        try service.run()
        process = service
        for _ in 0..<80 {
            try Task.checkCancellation()
            if await serverAvailable() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VoiceModelError(message: "本地翻译服务启动超时，请重试。")
    }

    private func installRuntimeIfNeeded() async throws {
        if FileManager.default.isExecutableFile(atPath: Self.runtime.appendingPathComponent("ollama").path) { return }
        status = "下载本地推理组件（约 175MB）…"
        let url = URL(string: "https://github.com/ollama/ollama/releases/download/\(Self.version)/ollama-darwin.tgz")!
        let (download, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw VoiceModelError(message: "推理组件下载失败，请检查网络。") }
        let hash = try await Task.detached {
            let file = try FileHandle(forReadingFrom: download)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        guard hash == Self.runtimeHash else { throw VoiceModelError(message: "推理组件校验失败，请重新下载。") }
        try Task.checkCancellation()
        let staging = Self.root.appendingPathComponent("VoiceRuntime/install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let exit: Int32 = try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            task.arguments = ["-xzf", download.path, "-C", staging.path]
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
        guard exit == 0 else { throw VoiceModelError(message: "本地推理组件解压失败。") }
        if FileManager.default.fileExists(atPath: Self.runtime.path) { try FileManager.default.removeItem(at: Self.runtime) }
        try FileManager.default.moveItem(at: staging, to: Self.runtime)
    }
}
