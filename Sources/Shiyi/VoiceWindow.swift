import AppKit
import SwiftUI
import Carbon
import Combine

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

enum VoiceSubtitleStyle {
    static func fontSize(_ value: Double) -> Double { value.isFinite ? min(56, max(16, value)) : 28 }
}

/// A native surface owns both sizing and dragging, avoiding SwiftUI hit testing
/// and proposed-height feedback in a borderless non-key window.
private final class NativeSubtitleSurface: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private var original = NSAttributedString()
    private var translation = NSAttributedString()
    private var originalHeight: CGFloat = 0
    private var translationHeight: CGFloat = 0
    private let padding: CGFloat = 24
    private(set) var dragging = false
    var onDragEnded: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        dragging = true
        window?.performDrag(with: event)
        dragging = false
        onDragEnded?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    func update(original: String, translation: String, fontSize: Double, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        self.original = NSAttributedString(string: original, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize * 0.7, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph
        ])
        self.translation = NSAttributedString(string: translation, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
        let textWidth = max(1, width - padding * 2)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        originalHeight = original.isEmpty ? 0 : ceil(self.original.boundingRect(with: NSSize(width: textWidth, height: 10000), options: options).height)
        translationHeight = translation.isEmpty ? 0 : ceil(self.translation.boundingRect(with: NSSize(width: textWidth, height: 10000), options: options).height)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel([original, translation].filter { !$0.isEmpty }.joined(separator: "\n"))
        needsDisplay = true
        return max(64, originalHeight + translationHeight + (originalHeight > 0 && translationHeight > 0 ? 10 : 0) + 36)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard original.length > 0 || translation.length > 0 else { return }
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let width = max(1, bounds.width - padding * 2)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        original.draw(with: NSRect(x: padding, y: 18, width: width, height: originalHeight + 2), options: options)
        translation.draw(with: NSRect(x: padding, y: 18 + originalHeight + (originalHeight > 0 && translationHeight > 0 ? 10 : 0),
                                      width: width, height: translationHeight + 2), options: options)
    }
}

@MainActor
final class VoiceWindowController: NSObject, NSWindowDelegate {
    private let store: VoiceTranslationStore
    private let window: OverlayPanel
    private let surface = NativeSubtitleSurface()
    private var observers = Set<AnyCancellable>()
    private var previewing = false
    init(store: VoiceTranslationStore) {
        self.store = store
        let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(860, area.width - 40)
        window = OverlayPanel(contentRect: NSRect(x: area.midX - width / 2, y: area.minY + 70, width: width, height: 150),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "拾译 · 语音字幕"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = true
        window.ignoresMouseEvents = false
        surface.onDragEnded = { [weak self] in self?.render() }
        window.contentView = surface
        window.delegate = self
        window.setFrameAutosaveName("ShiyiVoiceSubtitles")
        Publishers.MergeMany([
            store.preferences.$voiceSubtitleSize.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$voiceSubtitleOpacity.map { _ in () }.eraseToAnyPublisher(),
            store.$captions.map { _ in () }.eraseToAnyPublisher(),
            store.$liveOriginal.map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: DispatchQueue.main).sink { [weak self] in self?.render() }.store(in: &observers)
    }
    private func render() {
        guard !surface.dragging else { return }
        let area = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? window.frame
        var frame = window.frame
        frame.size.width = min(frame.width, max(1, area.width - 24))
        let original = previewing ? "Good morning. The meeting starts at nine." : store.captions.last?.original ?? store.liveOriginal
        let translation = previewing ? "早上好。会议将于上午九点开始。" : store.captions.last?.translation ?? ""
        let height = surface.update(original: original, translation: translation,
                                    fontSize: VoiceSubtitleStyle.fontSize(store.preferences.voiceSubtitleSize), width: frame.width)
        frame.size.height = min(height, max(64, area.height - 24))
        if NSEvent.pressedMouseButtons == 0 {
            frame.origin.x = min(max(area.minX + 12, frame.minX), area.maxX - frame.width - 12)
            frame.origin.y = min(max(area.minY + 12, frame.minY), area.maxY - frame.height - 12)
        }
        window.setFrame(frame, display: true)
        window.alphaValue = OverlayLayout.opacity(store.preferences.voiceSubtitleOpacity)
        surface.needsDisplay = true
    }
    func show() { previewing = false; render(); window.orderFrontRegardless() }
    func preview() { previewing = true; render(); window.orderFrontRegardless() }
    func toggle() {
        if window.isVisible { close() }
        else { show(); store.start() }
    }
    func close() { store.stop(cancelPending: true); window.orderOut(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { store.stop(cancelPending: true); return true }
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
            HStack {
                Button(store.listening || store.starting ? "停止收听" : "开始收听") {
                    if store.listening || store.starting { store.stop() }
                    else { store.onShowWindow?(); store.start() }
                }.buttonStyle(.borderedProminent)
                Button("显示字幕") { store.onShowWindow?() }
                Button("预览字幕样式") { store.onPreviewWindow?() }
                Button("清空字幕") { store.clear() }
            }
            Text(store.status).font(.callout).foregroundStyle(ShiyiTheme.muted)
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.orange) }
            if let failure = store.captions.last?.failure {
                Text("本句翻译未完成：\(failure)").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("字幕大小")
                Slider(value: $preferences.voiceSubtitleSize, in: 16...56, step: 1).accessibilityLabel("字幕大小")
                Text("\(Int(VoiceSubtitleStyle.fontSize(preferences.voiceSubtitleSize))) pt").monospacedDigit().frame(width: 52)
            }
            HStack {
                Text("字幕透明度")
                Slider(value: Binding(get: { 1 - OverlayLayout.opacity(preferences.voiceSubtitleOpacity) },
                                      set: { preferences.voiceSubtitleOpacity = 1 - $0 }), in: 0...0.8)
                    .accessibilityLabel("字幕透明度")
                Text("\(Int(((1 - OverlayLayout.opacity(preferences.voiceSubtitleOpacity)) * 100).rounded()))%").monospacedDigit().frame(width: 52)
            }
            Text("字幕只显示原文和对应译文，可按住拖动。大小和透明度即时生效并保存；所有操作与设置都在主窗口。")
                .font(.caption).foregroundStyle(ShiyiTheme.muted)
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
            }
            Text("快捷键打开字幕并开始收听，再按关闭并停止；也可在这里开始/停止收听。首次使用会请求麦克风权限。语言在这里手动选择，独立于划词翻译；旧版 macOS 使用离线识别兼容模式。")
                .font(.caption).foregroundStyle(ShiyiTheme.muted)
            Link("TranslateGemma 模型与许可", destination: URL(string: "https://ollama.com/library/translategemma:4b")!)
                .font(.caption)
        }.padding(20).background(.white.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 16))
        .task { await model.refresh() }
    }
}
