import SwiftUI

enum ShiyiTheme {
    static let ink = Color(red: 0.14, green: 0.16, blue: 0.21)
    static let accent = Color(red: 0.38, green: 0.38, blue: 0.80)
    static let canvas = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let muted = Color(red: 0.47, green: 0.48, blue: 0.52)
    static let line = Color.black.opacity(0.07)
}

/// Read-only content. The separate native operation point is the only mouse target.
struct TranslationCardView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var preferences: Preferences

    init(store: AppStore) {
        self.store = store
        preferences = store.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "character.bubble.fill").foregroundStyle(ShiyiTheme.accent)
                Text(store.selection?.appName ?? "拾译")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(languagePair).font(.system(size: 10)).foregroundStyle(ShiyiTheme.muted)
                Spacer(minLength: 46)
            }
            .frame(height: 44)
            .padding(.horizontal, 17)
            Divider()
            if store.isOverlayExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(store.overlayBlocks.enumerated()), id: \.offset) { index, block in
                                Text(block)
                                    .font(.system(size: 15))
                                    .lineSpacing(5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(index)
                            }
                        }
                        .padding(17)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: store.overlayScrollIndex) { _, index in
                        proxy.scrollTo(index, anchor: .top)
                    }
                    .onChange(of: store.job?.id) { _, _ in proxy.scrollTo(0, anchor: .top) }
                }
            } else {
                compactResult
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            Text(store.isOverlayExpanded ? "在右上角操作点滚动浏览 · 右键复制或重试" : "鼠标可穿透 · 点击右上角操作点展开")
                .font(.system(size: 10))
                .foregroundStyle(ShiyiTheme.muted)
                .frame(height: 28)
                .padding(.horizontal, 17)
        }
        .frame(width: store.overlayWidth, height: store.overlayHeight)
        .background(ShiyiTheme.canvas)
        .foregroundStyle(ShiyiTheme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ShiyiTheme.line))
        .allowsHitTesting(false)
    }

    private var languagePair: String {
        let source = store.job?.source ?? preferences.source
        let target = store.job?.target ?? preferences.target
        return source.title + " → " + target.title
    }

    @ViewBuilder private var compactResult: some View {
        switch store.phase {
        case .idle:
            Text("选中文字，译文会更新在这里。")
                .font(.system(size: 16)).foregroundStyle(ShiyiTheme.muted)
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在翻译…").font(.system(size: 16, weight: .medium))
            }
        case .finished(let output):
            Text(output.translation).font(.system(size: 19, weight: .medium)).lineSpacing(4).lineLimit(4)
        case .failed(let message):
            Text(message).font(.system(size: 13)).foregroundStyle(.orange).lineLimit(4)
        }
    }
}
