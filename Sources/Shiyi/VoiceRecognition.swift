import AppKit
import AVFoundation
import Speech

@MainActor
protocol VoiceRecognizing: AnyObject {
    func start(language: TranslationLanguage, onText: @escaping (String, Bool) -> Void,
               onStatus: @escaping (String) -> Void,
               onError: @escaping (String) -> Void) async throws
    func stop()
}

@MainActor
func makeVoiceRecognizer() -> any VoiceRecognizing {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *), SpeechTranscriber.isAvailable { return ModernVoiceRecognizer() }
    #endif
    return LegacyVoiceRecognizer()
}

extension TranslationLanguage {
    var speechLocale: Locale {
        switch self {
        case .english: return Locale(identifier: "en-US")
        case .simplifiedChinese: return Locale(identifier: "zh-CN")
        case .german: return Locale(identifier: "de-DE")
        case .japanese: return Locale(identifier: "ja-JP")
        case .french: return Locale(identifier: "fr-FR")
        }
    }
}

@MainActor
private func requestMicrophone() async throws {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    guard granted else { throw VoiceModelError(message: "麦克风未授权。请在系统设置 → 隐私与安全性 → 麦克风中允许拾译。") }
    try Task.checkCancellation()
}

#if compiler(>=6.2)
/// SpeechAnalyzer performs local, continuous recognition on macOS 26.
@available(macOS 26.0, *)
@MainActor
private final class ModernVoiceRecognizer: VoiceRecognizing {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var ownedLocale: Locale?
    private var configurationObserver: NSObjectProtocol?

    func start(language: TranslationLanguage, onText: @escaping (String, Bool) -> Void,
               onStatus: @escaping (String) -> Void,
               onError: @escaping (String) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.speechLocale) else {
            throw VoiceModelError(message: "本机语音模型暂不支持这个原文语言，请更换语言。")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if !(await AssetInventory.reservedLocales).contains(locale) {
            guard try await AssetInventory.reserve(locale: locale) else { throw VoiceModelError(message: "语音语言资源已达上限，请在系统设置管理已下载语言。") }
            ownedLocale = locale
        }
        onStatus("准备本机语音识别语言（首次可能下载）…")
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        if assetStatus != .installed {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progress = Task { @MainActor in
                    while !Task.isCancelled {
                        onStatus("下载本机语音语言资源 \(Int(installation.progress.fractionCompleted * 100))%…")
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                defer { progress.cancel() }
                try await installation.downloadAndInstall()
            }
        }
        onStatus("等待麦克风授权…")
        try Task.checkCancellation()
        try await requestMicrophone()
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural),
              let converter = AVAudioConverter(from: natural, to: format) else {
            throw VoiceModelError(message: "无法读取麦克风格式，请检查输入设备。")
        }
        let (stream, streamContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = streamContinuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    onText(String(result.text.characters), result.isFinal)
                }
            } catch {
                if !Task.isCancelled { onError("本机语音识别中断，请检查麦克风后重新开始。") }
            }
        }
        analysisTask = Task {
            do { try await analyzer.start(inputSequence: stream) }
            catch { if !Task.isCancelled { onError("语音分析中断，请重新开始。") } }
        }
        let conversion = VoiceAudioConverter(converter: converter, target: format)
        input.installTap(onBus: 0, bufferSize: 2048, format: natural) { buffer, _ in
            do {
                let converted = try conversion.convert(buffer)
                guard converted.frameLength > 0 else { return }
                if case .dropped = streamContinuation.yield(AnalyzerInput(buffer: converted)) {
                    Task { @MainActor in onError("语音处理速度跟不上麦克风输入，已停止；请关闭其他占内存的软件后重试。") }
                }
            } catch {
                Task { @MainActor in onError("麦克风音频转换失败，请重新选择输入设备后重试。") }
            }
        }
        engine = audio
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { _ in
            Task { @MainActor in onError("麦克风设备已改变，请重新开始语音翻译。") }
        }
        audio.prepare()
        try audio.start()
        onStatus("正在听麦克风 · 本机识别")
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        continuation?.finish(); continuation = nil
        resultsTask?.cancel(); analysisTask?.cancel()
        resultsTask = nil; analysisTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        if let locale = ownedLocale { Task { _ = await AssetInventory.release(reservedLocale: locale) } }
        ownedLocale = nil
    }
}

/// The audio tap is serial; converted buffers are owned by the analyzer stream.
private final class VoiceAudioConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    init(converter: AVAudioConverter, target: AVAudioFormat) { self.converter = converter; self.target = target }
    func convert(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * target.sampleRate / source.format.sampleRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw VoiceModelError(message: "音频缓冲区不可用。") }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return source
        }
        guard status != .error, failure == nil else { throw failure ?? VoiceModelError(message: "音频转换失败。") as NSError }
        return output
    }

}
#endif

/// Compatibility for macOS 15: explicitly require on-device recognition;
/// never silently fall back to cloud speech recognition.
@MainActor
private final class LegacyVoiceRecognizer: VoiceRecognizing {
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func start(language: TranslationLanguage, onText: @escaping (String, Bool) -> Void,
               onStatus: @escaping (String) -> Void,
               onError: @escaping (String) -> Void) async throws {
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw VoiceModelError(message: "语音识别未授权，请在系统设置 → 隐私与安全性 → 语音识别中允许拾译。") }
        try await requestMicrophone()
        guard let recognizer = SFSpeechRecognizer(locale: language.speechLocale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { throw VoiceModelError(message: "本机尚无该语言的离线语音识别资源。建议升级 macOS 26 或更换原文语言。") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        self.request = request
        recognition = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                if let result { onText(result.bestTranscription.formattedString, result.isFinal) }
                if error != nil { onError("本机语音识别已结束（旧系统有会话时限），请点击开始继续。") }
            }
        }
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceModelError(message: "麦克风当前不可用。") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine = audio
        audio.prepare()
        try audio.start()
        onStatus("正在听麦克风 · 本机识别（兼容模式）")
    }
    func stop() {
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
    }
}
