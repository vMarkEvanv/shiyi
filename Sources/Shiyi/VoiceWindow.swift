import AppKit
import SwiftUI
import Carbon

// Kept independent from the text-overlay shortcut and the temporary copy key.
enum VoiceShortcut: String, CaseIterable, Identifiable {
    case optionCommandR, controlOptionR, controlShiftR
    var id: String { rawValue }
    var title: String {
        switch self {
        case .optionCommandR: return "⌥⌘R"
        case .controlOptionR: return "⌃⌥R"
        case .controlShiftR: return "⌃⇧R"
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .optionCommandR: return UInt32(optionKey | cmdKey)
        case .controlOptionR: return UInt32(controlKey | optionKey)
        case .controlShiftR: return UInt32(controlKey | shiftKey)
        }
    }
}

@MainActor
final class VoiceHotKey {
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var current: VoiceShortcut?
    func register(_ shortcut: VoiceShortcut) -> Bool {
        if current == shortcut, reference != nil { return true }
        if handler == nil {
            var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
                guard let event, let data else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == 0x53485643 else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<VoiceHotKey>.fromOpaque(data).takeUnretainedValue()
                Task { @MainActor in owner.onPress?() }
                return noErr
            }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return false }
        }
        var candidate: EventHotKeyRef?
        guard RegisterEventHotKey(UInt32(kVK_ANSI_R), shortcut.modifiers, EventHotKeyID(signature: 0x53485643, id: 3),
                                  GetApplicationEventTarget(), 0, &candidate) == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate; current = shortcut
        return true
    }
}

@MainActor
final class VoiceWindowController: NSObject, NSWindowDelegate {
    private let store: VoiceTranslationStore
    private let window: NSPanel
    init(store: VoiceTranslationStore) {
        self.store = store
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        window.title = "拾译 · 麦克风实时翻译"
        window.minSize = NSSize(width: 430, height: 320)
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: VoiceCaptionView(store: store))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ShiyiVoiceCaptions")
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func toggle() { if window.isVisible { close() } else { show() } }
    func close() { store.stop(cancelPending: true); window.orderOut(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { store.stop(cancelPending: true); return true }
}

private struct VoiceCaptionView: View {
    @ObservedObject var store: VoiceTranslationStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(store.listening ? "麦克风正在收音" : "麦克风翻译", systemImage: store.listening ? "mic.fill" : "mic")
                    .font(.headline).foregroundStyle(store.listening ? .red : ShiyiTheme.ink)
                Spacer()
                Button(store.listening || store.starting ? "停止" : "开始") {
                    if store.listening || store.starting { store.stop() } else { store.start() }
                }.keyboardShortcut(.space, modifiers: [])
                Button("清空") { store.clear() }
            }
            Text(store.status).font(.caption).foregroundStyle(ShiyiTheme.muted)
            if store.listening { ProgressView(value: store.level).tint(ShiyiTheme.accent).accessibilityLabel("麦克风音量") }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if !store.liveOriginal.isEmpty {
                Text(store.liveOriginal).font(.system(size: 14)).foregroundStyle(ShiyiTheme.muted)
                    .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.captions.isEmpty {
                            Text("说话后，原文和译文会逐句显示在这里。\n开始前请在主窗口选择原文和目标语言。")
                                .foregroundStyle(ShiyiTheme.muted).padding(.top, 24)
                        }
                        ForEach(store.captions) { caption in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(caption.original).font(.system(size: 13)).foregroundStyle(ShiyiTheme.muted)
                                if !caption.translation.isEmpty {
                                    Text(caption.translation).font(.system(size: 21, weight: .medium))
                                } else if let failure = caption.failure {
                                    Text(failure).font(.caption).foregroundStyle(.orange)
                                } else { Text("正在本地翻译…").foregroundStyle(ShiyiTheme.muted).font(.callout) }
                            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(caption.id)
                        }
                    }.padding(.vertical, 4)
                }
                .onChange(of: store.captions.count) { _, _ in
                    if let last = store.captions.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Text("本机识别 · TranslateGemma 4B · 关闭窗口停止收音")
                .font(.system(size: 10)).foregroundStyle(ShiyiTheme.muted)
        }.padding(20).background(ShiyiTheme.canvas)
            .foregroundStyle(ShiyiTheme.ink)
            .environment(\.colorScheme, .light)
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var store: VoiceTranslationStore
    @ObservedObject private var preferences: Preferences
    @ObservedObject private var model: LocalVoiceModel
    init(store: VoiceTranslationStore) { self.store = store; preferences = store.preferences; model = store.model }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("麦克风实时翻译", systemImage: "waveform").font(.title2.weight(.semibold))
            Text("持续识别麦克风的声音，稳定成句后在本机翻译。不会采集电脑播放声音，不保存录音。")
                .font(.callout).foregroundStyle(ShiyiTheme.muted)
            HStack {
                Picker("原文", selection: $preferences.voiceSource) {
                    ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker("译文", selection: $preferences.voiceTarget) {
                    ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
            Picker("打开/关闭语音窗", selection: $preferences.voiceShortcut) {
                ForEach(VoiceShortcut.allCases) { Text($0.title).tag($0) }
            }
            if let message = store.shortcutError { Text(message).foregroundStyle(.orange).font(.caption) }
            Divider()
            Text("免费本地模型").font(.headline)
            Text("Google TranslateGemma 4B（约 3.3GB）\n首次另需下载约 175MB 推理组件和本机语音语言资源。模型准备好后无需 API 密钥，音频与文字不发送到云端翻译服务。")
                .font(.callout).foregroundStyle(ShiyiTheme.muted)
            Text(model.status).font(.callout).textSelection(.enabled)
            if model.preparing { ProgressView(value: model.progress) }
            HStack {
                Button(model.ready ? "检查模型" : "准备免费模型") { model.prepare() }.disabled(model.preparing)
                if model.preparing { Button("取消下载") { model.cancelPreparation() } }
                Spacer()
                Button("打开语音字幕窗") { store.onShowWindow?() }.buttonStyle(.borderedProminent)
            }
            Text("快捷键只打开或关闭窗口；点击“开始”后才请求麦克风权限。关闭窗口会停止收音。语言在这里手动选择，独立于划词翻译；旧版 macOS 使用离线识别兼容模式。")
                .font(.caption).foregroundStyle(ShiyiTheme.muted)
            Link("TranslateGemma 模型与许可", destination: URL(string: "https://ollama.com/library/translategemma:4b")!)
                .font(.caption)
        }.padding(20).background(.white.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 16))
        .task { await model.refresh() }
    }
}
