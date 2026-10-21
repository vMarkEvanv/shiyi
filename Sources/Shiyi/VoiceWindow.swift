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
    private(set) var visible: [VoiceCaption] = []
    var caption: VoiceCaption? { visible.last }
    mutating func update(_ captions: [VoiceCaption]) {
        guard !captions.isEmpty else { visible = []; return }
        var merged = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        for ready in captions where !ready.original.isEmpty && !ready.translation.isEmpty { merged[ready.id] = ready }
        visible = Array(merged.values.sorted {
            if $0.recordedAt == $1.recordedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.recordedAt < $1.recordedAt
        }.suffix(2))
    }
}

/// Fixed black container with clipped, independently moving text rows.
final class NativeSubtitleSurface: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    private let backgroundLayer = CALayer()
    private var rows: [UUID: CALayer] = [:]
    private var snapshots: [UUID: VoiceCaption] = [:]
    private var forceReveal = true
    private var cachedFont = 0.0
    private var cachedWidth: CGFloat = 0
    private var cachedCaptions: [VoiceCaption] = []
    private var cachedBackground = -1.0
    private var cachedHeight: CGFloat = 0
    private(set) var dragging = false
    var onDragEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 12
        backgroundLayer.cornerRadius = 12
        layer?.addSublayer(backgroundLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        dragging = true
        window?.performDrag(with: event)
        dragging = false
        onDragEnded?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    func reveal() { forceReveal = true }

    func update(captions: [VoiceCaption], fontSize: Double, width: CGFloat, backgroundOpacity: Double) -> CGFloat {
        if !forceReveal, cachedFont == fontSize, cachedWidth == width, cachedBackground == backgroundOpacity, cachedCaptions == captions { return cachedHeight }
        let sourceFont = NSFont.systemFont(ofSize: max(13, fontSize * 0.75), weight: .medium)
        let targetFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let sourceHeight = ceil(sourceFont.ascender - sourceFont.descender + sourceFont.leading + 4)
        let targetHeight = ceil(targetFont.ascender - targetFont.descender + targetFont.leading + 4)
        let pairHeight = sourceHeight + targetHeight + 8
        let step = pairHeight + 14
        let height = pairHeight * 2 + 14 + 36
        let styleChanged = cachedFont != fontSize || cachedWidth != width
        let visible = Array(captions.suffix(2))
        let ids = Set(visible.map(\.id))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backgroundLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(backgroundOpacity).cgColor
        backgroundLayer.opacity = 1
        if forceReveal { backgroundLayer.removeAllAnimations() }
        CATransaction.commit()
        for id in Array(rows.keys) where !ids.contains(id) {
            guard let old = rows.removeValue(forKey: id) else { continue }
            snapshots.removeValue(forKey: id)
            animate(old, toY: old.position.y - step, fade: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { old.removeFromSuperlayer() }
        }
        for (index, caption) in visible.enumerated() {
            let existing = rows[caption.id]
            let row = existing ?? CALayer()
            let oldTargetY = row.position.y
            let oldY = row.presentation()?.position.y ?? oldTargetY
            // A single pair starts in the bottom slot; the next pair pushes it up.
            let y = 18 + CGFloat(2 - visible.count + index) * step
            let frame = CGRect(x: 0, y: y, width: width, height: pairHeight)
            if existing == nil || snapshots[caption.id] != caption || styleChanged {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
                let source = NSAttributedString(string: caption.original.components(separatedBy: .newlines).joined(separator: " "), attributes: [.font: sourceFont, .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: paragraph, .shadow: shadow])
                let target = NSAttributedString(string: caption.translation.components(separatedBy: .newlines).joined(separator: " "), attributes: [.font: targetFont, .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow])
                let image = NSImage(size: NSSize(width: width, height: pairHeight))
                image.lockFocusFlipped(true)
                let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
                source.draw(with: CGRect(x: 24, y: 0, width: max(1, width - 48), height: sourceHeight + 2), options: options)
                target.draw(with: CGRect(x: 24, y: sourceHeight + 8, width: max(1, width - 48), height: targetHeight + 2), options: options)
                image.unlockFocus()
                var rect = CGRect(origin: .zero, size: image.size)
                CATransaction.begin(); CATransaction.setDisableActions(true)
                row.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                row.contentsScale = window?.backingScaleFactor ?? 2
                CATransaction.commit()
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            row.frame = frame; row.opacity = 1
            CATransaction.commit()
            if existing == nil {
                layer?.addSublayer(row)
                animate(row, fromY: row.position.y + step, toY: row.position.y, fade: true)
            } else if forceReveal || styleChanged {
                row.removeAllAnimations()
            } else if !styleChanged, abs(oldTargetY - row.position.y) > 0.5 {
                animate(row, fromY: oldY, toY: row.position.y, fade: nil)
            }
            rows[caption.id] = row; snapshots[caption.id] = caption
        }
        cachedFont = fontSize; cachedWidth = width; cachedCaptions = captions; cachedBackground = backgroundOpacity; cachedHeight = height; forceReveal = false
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        setAccessibilityLabel(visible.isEmpty ? "字幕窗口已打开，等待翻译" : visible.flatMap { [$0.original, $0.translation] }.joined(separator: "\n"))
        return height
    }
    private func animate(_ row: CALayer, fromY: CGFloat? = nil, toY: CGFloat, fade: Bool?) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let origin = fromY ?? row.presentation()?.position.y ?? row.position.y
        CATransaction.begin(); CATransaction.setDisableActions(true)
        row.position.y = toY
        if let fade { row.opacity = fade ? 1 : 0 }
        CATransaction.commit()
        var animations: [CAAnimation] = []
        if !reduce {
            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = origin; move.toValue = toY; animations.append(move)
        }
        if let fade {
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = fade ? 0 : (row.presentation()?.opacity ?? 1)
            opacity.toValue = fade ? 1 : 0; animations.append(opacity)
        }
        let group = CAAnimationGroup(); group.animations = animations
        group.duration = reduce ? 0.15 : 0.36
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.75, 0.25, 1)
        row.add(group, forKey: "subtitle-motion")
    }
    func dismissUp() {
        for row in rows.values { animate(row, toY: row.position.y - 24, fade: false) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backgroundLayer.opacity = 0
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.3
        backgroundLayer.add(fade, forKey: "close")
        setAccessibilityLabel("")
    }
}

@MainActor
final class VoiceWindowController: NSObject, NSWindowDelegate {
    private let store: VoiceTranslationStore
    private let window: OverlayPanel
    private let surface = NativeSubtitleSurface()
    private var observers = Set<AnyCancellable>()
    private static let previewFirst = UUID()
    private static let previewSecond = UUID()
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
            store.$captions.map { Array($0.filter { !$0.translation.isEmpty }.suffix(2)) }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            store.$subtitleCaption.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: DispatchQueue.main).sink { [weak self] in self?.render() }.store(in: &observers)
    }
    private func render() {
        guard !surface.dragging, !closing else { return }
        let area = window.screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? window.frame
        var frame = window.frame
        frame.size.width = min(frame.width, max(1, area.width - 24))
        if !previewing {
            pair.update(store.captions)
            if let live = store.subtitleCaption { pair.update([live]) }
        }
        let samples = [
            VoiceCaption(id: Self.previewFirst, original: "Good morning. The meeting starts at nine.", recordedAt: Date(timeIntervalSince1970: 1), translation: "早上好。会议将于上午九点开始。"),
            VoiceCaption(id: Self.previewSecond, original: "Please open the document before we begin.", recordedAt: Date(timeIntervalSince1970: 2), translation: "开始之前，请先打开文档。")
        ]
        let height = surface.update(captions: previewing ? samples : pair.visible,
                                    fontSize: VoiceSubtitleStyle.fontSize(store.preferences.voiceSubtitleSize), width: frame.width,
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
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
                        Text("Please open the document before we begin.")
                            .font(.system(size: max(13, preferences.voiceSubtitleSize * 0.75), weight: .medium)).foregroundStyle(.white.opacity(0.85)).padding(.top, 14)
                        Text("开始之前，请先打开文档。")
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
                    Text("默认只调背景，让文字保持清晰。字幕保留最近两段，每段原文一行、译文一行。黑框保持显示，只有关闭字幕时隐藏；超长内容在翻译记录中保留全文。")
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
                    Text("首次下载约 3.3GB 模型、175MB 推理组件和语音语言资源。只在使用时启动翻译服务，停止后约 30 秒释放模型并退出服务。再次开始可能需要重新加载。")
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
