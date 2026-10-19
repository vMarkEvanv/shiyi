import SwiftUI

enum ShiyiTheme {
    static let ink = Color(red: 0.14, green: 0.16, blue: 0.21)
    static let accent = Color(red: 0.38, green: 0.38, blue: 0.80)
    static let canvas = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let muted = Color(red: 0.47, green: 0.48, blue: 0.52)
    static let line = Color.black.opacity(0.07)
}

struct TranslationCardView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var preferences: Preferences
    private var onHeightChange: ((CGFloat) -> Void)?
    @State private var sourceExpanded = false
    @State private var contentHeight: CGFloat = 180

    init(store: AppStore, onHeightChange: ((CGFloat) -> Void)? = nil) {
        self.store = store
        self.preferences = store.preferences
        self.onHeightChange = onHeightChange
    }

    private var engine: TranslationEngine { store.job?.engine ?? preferences.engine }
    private var selection: CapturedSelection? { store.job?.selection ?? store.selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(ShiyiTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let selection {
                        VStack(alignment: .leading, spacing: 7) {
                            Button {
                                sourceExpanded.toggle()
                            } label: {
                                HStack(spacing: 5) {
                                    Text("原文")
                                    Image(systemName: sourceExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .semibold))
                                    Spacer()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(ShiyiTheme.muted)
                            }
                            .buttonStyle(.plain)
                            Text(selection.text)
                                .font(.system(size: 13))
                                .foregroundStyle(ShiyiTheme.muted)
                                .lineLimit(sourceExpanded ? nil : 3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    result
                    contextIndicator
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: CardHeightKey.self, value: geometry.size.height)
                    }
                }
            }
            .frame(height: min(350, max(90, contentHeight)))
            .onPreferenceChange(CardHeightKey.self) { contentHeight = $0 }
            Divider().overlay(ShiyiTheme.line)
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(ShiyiTheme.canvas)
        .foregroundStyle(ShiyiTheme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ShiyiTheme.line))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TotalCardHeightKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(TotalCardHeightKey.self) { height in
            if height > 0 { onHeightChange?(height) }
        }
        .onChange(of: store.job?.id) { _, _ in sourceExpanded = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 14))
                .foregroundStyle(ShiyiTheme.accent)
            Text(selection?.appName ?? "拾译")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(engine.title)
                .font(.system(size: 10))
                .foregroundStyle(ShiyiTheme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.white.opacity(0.8), in: Capsule())
            Spacer(minLength: 2)
            Button { store.isPinned.toggle() } label: {
                Image(systemName: store.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(store.isPinned ? ShiyiTheme.accent : ShiyiTheme.muted)
            }
            .help(store.isPinned ? "取消固定" : "固定翻译卡片")
            Button { store.dismiss() } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(ShiyiTheme.muted)
            }
            .help("关闭（Esc）")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    @ViewBuilder private var result: some View {
        switch store.phase {
        case .idle:
            Text("选中文字，释义即刻出现。")
                .font(.system(size: 17, weight: .medium))
                .padding(.vertical, 8)
        case .loading:
            HStack(spacing: 11) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在翻译…")
                        .font(.system(size: 15, weight: .medium))
                    Text(engine == .system ? "首次使用可能需要下载语言。" : "结合你的场景，寻找贴切表达。")
                        .font(.system(size: 11))
                        .foregroundStyle(ShiyiTheme.muted)
                }
            }
            .padding(.vertical, 13)
        case .finished(let output):
            VStack(alignment: .leading, spacing: 14) {
                Text(output.translation)
                    .font(.system(size: 21, weight: .medium))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !output.detectedScene.isEmpty {
                    Text(output.detectedScene)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ShiyiTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ShiyiTheme.accent.opacity(0.07), in: Capsule())
                }
                if !output.explanation.isEmpty {
                    Text(output.explanation)
                        .font(.system(size: 12))
                        .lineSpacing(4)
                        .foregroundStyle(ShiyiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !output.alternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("也可以理解为")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ShiyiTheme.muted)
                        ForEach(Array(output.alternatives.enumerated()), id: \.offset) { _, alternative in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(ShiyiTheme.accent.opacity(0.5)).frame(width: 4, height: 4).padding(.top, 6)
                                Text(alternative).font(.system(size: 12)).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 9) {
                Label("这次未能完成翻译", systemImage: "exclamationmark.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.66, green: 0.34, blue: 0.20))
                Text(message)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .foregroundStyle(ShiyiTheme.muted)
                    .textSelection(.enabled)
                Button("重试") { store.retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.vertical, 5)
        }
    }

    private var contextIndicator: some View {
        let hasContext = engine == .contextual && preferences.sendContext && !(selection?.context.isEmpty ?? true)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: hasContext ? "text.alignleft" : "text.quote")
            Text(engine == .system ? "系统引擎仅翻译选中文字，不额外推理附近上下文。" : (hasContext ? "已附上附近上下文，供本次翻译参考。" : "本次仅依据选中文字和场景偏好翻译。"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10))
        .foregroundStyle(ShiyiTheme.muted)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { store.copyTranslation() } label: {
                Label("复制译文", systemImage: "doc.on.doc")
            }
            .disabled(!hasResult)
            if hasResult {
                Button { store.retry() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新翻译")
            }
            Spacer()
            if let selection, !selection.bundleID.isEmpty {
                Menu {
                    Button("在此应用中暂停自动划词") { store.blockCurrentApp() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多选项")
            }
            Button { store.onOpenSettings?() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("打开拾译设置")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(ShiyiTheme.muted)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    private var hasResult: Bool {
        if case .finished = store.phase { return true }
        return false
    }
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 180
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TotalCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
