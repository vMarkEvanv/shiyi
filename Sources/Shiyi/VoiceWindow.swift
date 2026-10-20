import AppKit
import SwiftUI
import Carbon
import Combine
import QuartzCore

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

struct VoiceSubtitlePairState {
    private(set) var caption: VoiceCaption?
    mutating func update(_ captions: [VoiceCaption]) {
        guard !captions.isEmpty else { caption = nil; return }
        guard let ready = captions.last(where: { !$0.original.isEmpty && !$0.translation.isEmpty }) else { return }
        if caption == nil || ready.recordedAt >= caption!.recordedAt { caption = ready }
    }
}

/// A native surface owns both sizing and dragging, avoiding SwiftUI hit testing
/// and proposed-height feedback in a borderless non-key window.
private final class NativeSubtitleSurface: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private var bodyLayer: CALayer?
    private let backgroundLayer = CALayer()
    private var cueKey = ""
    private var content = ""
    private var cachedFont = 0.0
    private var cachedWidth: CGFloat = 0
    private var cachedBackground = -1.0
    private var cachedHeight: CGFloat = 64
    private var expired = false
    private var forceReveal = false
    private var expiry: DispatchWorkItem?
    private(set) var dragging = false
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        backgroundLayer.cornerRadius = 12
        layer?.addSublayer(backgroundLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        bodyLayer?.removeAllAnimations()
        layer?.sublayers?.filter { $0 !== bodyLayer && $0 !== backgroundLayer }.forEach { $0.removeFromSuperlayer() }
        dragging = true
        window?.performDrag(with: event)
        dragging = false
        onDragEnded?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    func reveal() { forceReveal = true }

    func update(original: String, translation: String, fontSize: Double, width: CGFloat,
                key: String, lifetime: TimeInterval?, backgroundOpacity: Double) -> CGFloat {
        let combined = original + "\n" + translation
        let isNewCue = key != cueKey
        let wasExpired = expired
        let changedText = combined != content
        guard isNewCue || changedText || forceReveal || cachedFont != fontSize || cachedWidth != width || cachedBackground != backgroundOpacity else { return cachedHeight }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let sourceFont = NSFont.systemFont(ofSize: max(13, fontSize * 0.75), weight: .medium)
        let targetFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
        let source = NSAttributedString(string: original.components(separatedBy: .newlines).joined(separator: " "), attributes: [.font: sourceFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph, .shadow: shadow])
        let target = NSAttributedString(string: translation.components(separatedBy: .newlines).joined(separator: " "), attributes: [.font: targetFont,
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow])
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        let textWidth = max(1, width - 48)
        // Reserve exactly one source line and one translation line. The panel
        // height changes only with font size, never when a translation arrives.
        let sourceHeight = ceil(sourceFont.ascender - sourceFont.descender + sourceFont.leading + 4)
        let targetHeight = ceil(targetFont.ascender - targetFont.descender + targetFont.leading + 4)
        let gap: CGFloat = 10
        let height = max(64, sourceHeight + targetHeight + gap + 36)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        if !original.isEmpty || !translation.isEmpty {
            source.draw(with: NSRect(x: 24, y: 18, width: textWidth, height: sourceHeight + 2), options: options)
            target.draw(with: NSRect(x: 24, y: 18 + sourceHeight + gap, width: textWidth, height: targetHeight + 2), options: options)
        }
        image.unlockFocus()
        var imageRect = NSRect(x: 0, y: 0, width: width, height: height)
        let next = CALayer()
        next.frame = imageRect
        next.contents = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)
        next.contentsScale = window?.backingScaleFactor ?? 2
        let previous = bodyLayer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backgroundLayer.frame = imageRect
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(backgroundOpacity).cgColor
        backgroundLayer.opacity = expired || original.isEmpty ? 0 : 1
        CATransaction.commit()
        layer?.addSublayer(next)
        bodyLayer = next
        if isNewCue || changedText || forceReveal {
            expired = false
            expiry?.cancel()
            if let lifetime, !original.isEmpty {
                let expectedKey = key
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, self.cueKey == expectedKey else { return }
                    self.dismissUp()
                }
                expiry = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: timer)
            }
        }
        let animate = isNewCue || forceReveal || (wasExpired && changedText)
        next.opacity = expired ? 0 : 1
        backgroundLayer.opacity = expired || original.isEmpty ? 0 : 1
        if !expired, !original.isEmpty, wasExpired || previous == nil || forceReveal {
            backgroundLayer.removeAllAnimations()
            backgroundLayer.add(motion(entering: true, upward: false), forKey: "background-enter")
        }
        if !expired, !original.isEmpty, animate {
            next.add(motion(entering: true, upward: true), forKey: "subtitle-enter")
        }
        if let previous {
            if animate, previous.opacity > 0 {
                previous.add(motion(entering: false, upward: true), forKey: "subtitle-exit")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { previous.removeFromSuperlayer() }
            } else { previous.removeFromSuperlayer() }
        }
        cueKey = key; content = combined; cachedFont = fontSize; cachedWidth = width; cachedHeight = height; cachedBackground = backgroundOpacity; forceReveal = false
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel([original, translation].filter { !$0.isEmpty }.joined(separator: "\n"))
        return height
    }

    private func motion(entering: Bool, upward: Bool) -> CAAnimationGroup {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = entering ? 0 : 1; fade.toValue = entering ? 1 : 0
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = entering && upward && !reduceMotion ? 8 : 0
        slide.toValue = !entering && upward && !reduceMotion ? -12 : 0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = reduceMotion || !upward ? 0.18 : (entering ? 0.3 : 0.25)
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.25, 1)
        group.fillMode = .forwards; group.isRemovedOnCompletion = entering
        return group
    }
    func dismissUp() {
        expiry?.cancel(); expiry = nil
        guard !expired else { return }
        expired = true
        backgroundLayer.opacity = 0
        backgroundLayer.add(motion(entering: false, upward: false), forKey: "background-exit")
        bodyLayer?.opacity = 0
        bodyLayer?.add(motion(entering: false, upward: true), forKey: "subtitle-exit")
        setAccessibilityLabel("")
    }
}

@MainActor
final class VoiceWindowController: NSObject, NSWindowDelegate {
    private let store: VoiceTranslationStore
    private let window: OverlayPanel
    private let surface = NativeSubtitleSurface()
    private var observers = Set<AnyCancellable>()
    private var previewing = false
    private var pair = VoiceSubtitlePairState()
    private var closing = false
    private var hideTask: DispatchWorkItem?
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
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &observers)
        Publishers.MergeMany([
            store.preferences.$voiceSubtitleSize.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$voiceSubtitleOpacity.map { _ in () }.eraseToAnyPublisher(),
            store.preferences.$fadeEntireSubtitles.map { _ in () }.eraseToAnyPublisher(),
            store.$captions.map { _ in () }.eraseToAnyPublisher(),
            store.$subtitleCaption.map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: DispatchQueue.main).sink { [weak self] in self?.render() }.store(in: &observers)
    }
    private func render() {
        guard !surface.dragging else { return }
        let area = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? window.frame
        var frame = window.frame
        frame.size.width = min(frame.width, max(1, area.width - 24))
        if !previewing {
            pair.update(store.captions)
            if let live = store.subtitleCaption { pair.update([live]) }
        }
        let original = previewing ? "Good morning. The meeting starts at nine." : pair.caption?.original ?? ""
        let translation = previewing ? "早上好。会议将于上午九点开始。" : pair.caption?.translation ?? ""
        let key = previewing ? "preview" : (pair.caption?.id.uuidString ?? "empty")
        let lifetime: TimeInterval? = previewing ? nil : max(6, min(16, Double(max(original.count, translation.count)) * 0.10))
        let height = surface.update(original: original, translation: translation,
                                    fontSize: VoiceSubtitleStyle.fontSize(store.preferences.voiceSubtitleSize), width: frame.width, key: key, lifetime: lifetime,
                                    backgroundOpacity: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : store.preferences.fadeEntireSubtitles ? 0.85 : OverlayLayout.opacity(store.preferences.voiceSubtitleOpacity))
        frame.size.height = min(height, max(64, area.height - 24))
        if NSEvent.pressedMouseButtons == 0 {
            frame.origin.x = min(max(area.minX + 12, frame.minX), area.maxX - frame.width - 12)
            frame.origin.y = min(max(area.minY + 12, frame.minY), area.maxY - frame.height - 12)
        }
        window.setFrame(frame, display: true)
        window.alphaValue = store.preferences.fadeEntireSubtitles && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? OverlayLayout.opacity(store.preferences.voiceSubtitleOpacity) : 1
        surface.needsDisplay = true
    }
    func show() { hideTask?.cancel(); closing = false; previewing = false; surface.reveal(); render(); window.orderFrontRegardless() }
    func preview() { hideTask?.cancel(); closing = false; previewing = true; surface.reveal(); render(); window.orderFrontRegardless() }
    func toggle() {
        if window.isVisible && !closing { close() }
        else { show(); store.start() }
    }
    func close() {
        store.stop(cancelPending: true)
        closing = true
        surface.dismissUp()
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.window.orderOut(nil); self?.closing = false }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { store.stop(cancelPending: true); return true }
}

struct VoiceSettingsView: View {
    @ObservedObject var store: VoiceTranslationStore
    @ObservedObject private var preferences: Preferences
    @ObservedObject private var model: LocalVoiceModel
    @State private var modelExpanded = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    init(store: VoiceTranslationStore) { self.store = store; preferences = store.preferences; model = store.model }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Picker("原文", selection: $preferences.voiceSource) {
                            ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Picker("译文", selection: $preferences.voiceTarget) {
                            ForEach(TranslationLanguage.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    HStack(spacing: 12) {
                        Button(store.listening || store.starting ? "停止收听" : "开始收听") {
                            if store.listening || store.starting { store.stop() }
                            else { store.onShowWindow?(); store.start() }
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("显示字幕") { store.onShowWindow?() }
                        Spacer()
                    }
                    Label(store.status, systemImage: store.listening ? "mic.fill" : "mic.slash")
                        .font(.callout).foregroundStyle(ShiyiTheme.muted)
                        .accessibilityLabel("麦克风状态：" + store.status)
                    if let error = store.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    if let failure = store.captions.last?.failure {
                        Text("本句翻译未完成：\(failure)").font(.callout).foregroundStyle(.orange)
                    }
                    Text("只收听麦克风，不保存录音。稳定片段先显示，整段定稿保存在翻译记录。")
                        .font(.callout).foregroundStyle(ShiyiTheme.muted)
                }.padding(12)
            } label: { Label("收听", systemImage: "mic") }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 8) {
                        Text("Good morning. The meeting starts at nine.")
                            .font(.system(size: max(13, preferences.voiceSubtitleSize * 0.75), weight: .medium)).foregroundStyle(.white.opacity(0.85))
                        Text("早上好。会议将于上午九点开始。")
                            .font(.system(size: preferences.voiceSubtitleSize, weight: .semibold)).foregroundStyle(.white)
                    }
                    .lineLimit(1).shadow(color: .black.opacity(0.8), radius: 1, y: 1)
                    .padding(18).frame(maxWidth: .infinity)
                    .background(.black.opacity(reduceTransparency ? 1 : preferences.fadeEntireSubtitles ? 0.85 : OverlayLayout.opacity(preferences.voiceSubtitleOpacity)), in: RoundedRectangle(cornerRadius: 12))
                    .opacity(reduceTransparency || !preferences.fadeEntireSubtitles ? 1 : OverlayLayout.opacity(preferences.voiceSubtitleOpacity))
                    .accessibilityLabel("字幕样式预览")
                    HStack {
                        Text("字幕大小").frame(width: 90, alignment: .leading)
                        Slider(value: $preferences.voiceSubtitleSize, in: 16...56, step: 1).accessibilityLabel("字幕大小")
                        Text("\(Int(VoiceSubtitleStyle.fontSize(preferences.voiceSubtitleSize))) pt").monospacedDigit().frame(width: 52)
                    }
                    HStack {
                        Text(preferences.fadeEntireSubtitles ? "整体透明度" : "背景透明度").frame(width: 90, alignment: .leading)
                        Slider(value: Binding(get: { 1 - OverlayLayout.opacity(preferences.voiceSubtitleOpacity) }, set: { preferences.voiceSubtitleOpacity = 1 - $0 }), in: 0...0.8).accessibilityLabel("字幕透明度")
                        Text("\(Int(((1 - OverlayLayout.opacity(preferences.voiceSubtitleOpacity)) * 100).rounded()))%").monospacedDigit().frame(width: 52)
                    }
                    Toggle("同时淡化文字", isOn: $preferences.fadeEntireSubtitles)
                    Text("默认只调背景，让文字保持清晰。字幕保持原文一行、译文一行；超长内容在翻译记录中保留全文。")
                        .font(.callout).foregroundStyle(ShiyiTheme.muted)
                    HStack {
                        Button("在屏幕上预览") { store.onPreviewWindow?() }
                        Button("清空字幕") { store.clear() }
                    }
                }.padding(12)
            } label: { Label("字幕样式", systemImage: "textformat.size") }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("打开／关闭字幕与收听", selection: $preferences.voiceShortcut) {
                        ForEach(VoiceShortcut.allCases) { Text($0.title).tag($0) }
                    }
                    if let message = store.shortcutError { Text(message).foregroundStyle(.orange) }
                    Text("再按快捷键关闭字幕并停止收听。已保存的内容可在左侧“翻译记录”查看。")
                        .font(.callout).foregroundStyle(ShiyiTheme.muted)
                }.padding(12)
            } label: { Label("快捷键", systemImage: "keyboard") }
            DisclosureGroup("本地模型 · " + (model.ready ? "已就绪" : "需要准备"), isExpanded: $modelExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Google TranslateGemma 4B · 本机运行，无 API 费用")
                    Text("首次下载约 3.3GB 模型、175MB 推理组件和语音语言资源。音频与文字不发送到云端翻译服务。")
                        .font(.callout).foregroundStyle(ShiyiTheme.muted)
                    Text(model.status).font(.callout).textSelection(.enabled)
                    if model.preparing { ProgressView(value: model.progress) }
                    HStack {
                        Button(model.ready ? "检查模型" : "准备免费模型") { model.prepare() }.disabled(model.preparing)
                        if model.preparing { Button("取消下载") { model.cancelPreparation() } }
                    }
                    Link("模型与许可", destination: URL(string: "https://ollama.com/library/translategemma:4b")!)
                }.padding(.top, 12)
            }
        }
        .task { await model.refresh(); modelExpanded = !model.ready }
    }
}
