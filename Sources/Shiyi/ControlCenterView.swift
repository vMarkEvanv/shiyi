import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var voiceStore: VoiceTranslationStore
    @ObservedObject private var preferences: Preferences
    @AppStorage("controlCenterPage") private var pageRaw = "reading"
    @State private var showReadingHelp = false
    private var page: Page { Page(rawValue: pageRaw) ?? .reading }
    @State private var keyStatus = ""

    private enum Page: String, CaseIterable, Identifiable {
        case reading, voice, history, preferences
        var id: String { rawValue }
        var title: String {
            switch self {
            case .reading: return "划词翻译"
            case .voice: return "语音翻译"
            case .history: return "翻译记录"
            case .preferences: return "设置"
            }
        }
        var symbol: String {
            switch self {
            case .reading: return "character.cursor.ibeam"
            case .voice: return "waveform"
            case .history: return "clock.arrow.circlepath"
            case .preferences: return "gearshape"
            }
        }
    }

    init(store: AppStore, voiceStore: VoiceTranslationStore) {
        self.voiceStore = voiceStore
        self.store = store
        self.preferences = store.preferences
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "character.bubble.fill").foregroundStyle(ShiyiTheme.accent)
                    Text("拾译").font(.title3.weight(.semibold))
                    Spacer()
                }.padding(20)
                List(selection: Binding<Page?>(get: { page }, set: { if let value = $0 { pageRaw = value.rawValue } })) {
                    ForEach([Page.reading, .voice, .history]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }.listStyle(.sidebar)
                Divider()
                Button { pageRaw = Page.preferences.rawValue } label: {
                    Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(page == .preferences ? ShiyiTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(10).keyboardShortcut(",", modifiers: .command)
            }.navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 230)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader.padding(.horizontal, 24).padding(.vertical, 20)
                Divider()
                if page == .history {
                    VoiceHistoryView(archive: voiceStore.archive).padding(20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if page == .reading { readingPage }
                            else if page == .voice { VoiceSettingsView(store: voiceStore) }
                            else { preferencesPage }
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ShiyiTheme.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 600)
        .background {
            if !store.isOverlayVisible { SystemTranslationHost(store: store).accessibilityHidden(true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShiyiOpenPreferences"))) { _ in pageRaw = Page.preferences.rawValue }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShiyiOpenVoice"))) { _ in pageRaw = Page.voice.rawValue }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(page.title).font(.title2.weight(.semibold))
            Text(page == .reading ? "划选或粘贴文字，查看翻译。" : page == .voice ? "麦克风实时翻译 · 识别与翻译均在本机完成" : page == .history ? "完整保留每次收听的原文与译文。" : "浮窗、翻译服务与隐私偏好")
                .font(.callout).foregroundStyle(ShiyiTheme.muted)
        }
    }

    @ViewBuilder private var readingPage: some View {
        if !store.permissionGranted { permissionCard }
        overlayStatusCard
        card {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label("随手翻译", systemImage: "text.cursor")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("也可以粘贴试一试")
                        .font(.system(size: 12))
                        .foregroundStyle(ShiyiTheme.muted)
                }
                ZStack(alignment: .topLeading) {
                    if store.manualText.isEmpty {
                        Text("粘贴一句话，或一个想弄懂的词…")
                            .font(.system(size: 13))
                            .foregroundStyle(ShiyiTheme.muted.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $store.manualText)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(height: 104)
                }
                .padding(7)
                .background(ShiyiTheme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    languagePairControls
                    Spacer()
                    Button { store.translateManual() } label: {
                        HStack(spacing: 7) {
                            Text("翻译")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        readingResult
        DisclosureGroup("划词浮窗怎么用？", isExpanded: $showReadingHelp) {
            Text("按 \(preferences.overlayShortcut.title) 打开浮窗，再划选文字。正文可穿透，操作点支持点击展开、拖动、右键复制与滚动。再按快捷键隐藏。也可按 ⌘C 后松开 ⌘，3 秒内按 T 翻译。")
                .font(.callout).foregroundStyle(ShiyiTheme.muted).padding(.top, 8)
        }
    }

    @ViewBuilder private var readingResult: some View {
        switch store.phase {
        case .idle:
            card {
                HStack(spacing: 13) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(ShiyiTheme.accent)
                        .font(.system(size: 25, weight: .light))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("等待翻译")
                            .font(.system(size: 14, weight: .medium))
                        Text(preferences.engine == .system ? "当前使用系统翻译，无需填写 API 密钥。" : "当前使用 AI 语境翻译，可参考附近段落和场景。")
                            .font(.system(size: 12))
                            .foregroundStyle(ShiyiTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5)
            }
        case .loading:
            card {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("正在翻译…").font(.system(size: 13, weight: .medium))
                        Text("系统翻译首次使用时可能需要下载语言。")
                            .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                    }
                    Spacer()
                }
            }
        case .finished(let output):
            card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("译文").font(.system(size: 10, weight: .medium)).foregroundStyle(ShiyiTheme.muted)
                        Spacer()
                        Button { store.copyTranslation() } label: { Label("复制", systemImage: "doc.on.doc") }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(ShiyiTheme.accent)
                    }
                    Text(output.translation)
                        .font(.system(size: 18, weight: .medium))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                    if !output.explanation.isEmpty {
                        Text(output.explanation)
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .foregroundStyle(ShiyiTheme.muted)
                            .textSelection(.enabled)
                    }
                }
            }
        case .failed(let message):
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("这次未能完成翻译", systemImage: "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                    Text(message).font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted).textSelection(.enabled)
                    Button("再试一次") { store.retry() }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var preferencesPage: some View {
        overlaySettingsCard
        card {
            VStack(alignment: .leading, spacing: 17) {
                sectionTitle("阅读方式", symbol: "cursorarrow.rays")
                Toggle(isOn: $preferences.autoTranslate) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选中文字后自动翻译").font(.system(size: 12, weight: .medium))
                        Text("浮窗唤出后生效；隐藏浮窗时暂停自动取词。")
                            .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Toggle("复制后按 T 翻译", isOn: $preferences.copyThenTranslate)
                    .toggleStyle(.switch).controlSize(.small)
                Text("按 ⌘C 复制文字，松开 ⌘，3 秒内单独按 T。触发后显示浮窗；其他按键会取消等待，不额外读取上下文。")
                    .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                Divider()
                HStack {
                    Text("翻译语言").font(.system(size: 12))
                    Spacer()
                    languagePairControls
                }
                Text("按你选择的原文语言翻译，不自动识别。此设置也适用于其他应用中的划词。")
                    .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
            }
        }
        card {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("翻译引擎", symbol: "sparkles")
                Picker("翻译引擎", selection: $preferences.engine) {
                    ForEach(TranslationEngine.allCases) { engine in Text(engine.title).tag(engine) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if preferences.engine == .system {
                    Label {
                        Text("由 macOS 提供翻译，无需 API 密钥。仅翻译选中文字，不额外推理附近上下文。首次使用可能需要下载语言。")
                            .lineSpacing(4)
                    } icon: {
                        Image(systemName: "laptopcomputer")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(ShiyiTheme.muted)
                } else {
                    contextualSettings
                }
            }
        }
        card {
            VStack(alignment: .leading, spacing: 13) {
                sectionTitle("不打扰这些应用", symbol: "moon")
                Text("每行一个应用 Bundle ID，在这些应用中暂停自动划词。")
                    .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                TextEditor(text: $preferences.excludedBundleIDs)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 62)
                    .padding(7)
                    .background(ShiyiTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .topLeading) {
                        if preferences.excludedBundleIDs.isEmpty {
                            Text("com.apple.Terminal")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ShiyiTheme.muted.opacity(0.65))
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        permissionCard
    }

    private var overlayStatusCard: some View {
        card {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(ShiyiTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isOverlayVisible ? "浮窗已常驻置顶" : "按 \(preferences.overlayShortcut.title) 唤出浮窗")
                        .font(.system(size: 12, weight: .semibold))
                    Text("透明度、位置和快捷键在设置中调整。")
                        .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                }
                Spacer()
                Button(store.isOverlayVisible ? "隐藏浮窗" : "显示浮窗") {
                    if store.isOverlayVisible { store.dismiss() } else { store.showOverlay() }
                }
                .controlSize(.small)
            }
        }
    }

    private var overlaySettingsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("常驻浮窗", symbol: "rectangle.on.rectangle")
                HStack {
                    Text("显示/隐藏快捷键").font(.system(size: 12))
                    Spacer()
                    Picker("显示/隐藏快捷键", selection: $preferences.overlayShortcut) {
                        ForEach(OverlayShortcut.allCases) { shortcut in Text(shortcut.title).tag(shortcut) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                if let error = store.shortcutError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                HStack {
                    Text(preferences.fadeEntireOverlay ? "整体透明度" : "背景透明度").font(.system(size: 12))
                    Slider(value: Binding(get: { 1 - preferences.overlayOpacity }, set: { preferences.overlayOpacity = 1 - $0 }), in: 0...0.8)
                        .accessibilityLabel("浮窗透明度")
                    Text("\(Int(((1 - preferences.overlayOpacity) * 100).rounded()))%")
                        .font(.system(size: 11, design: .monospaced)).frame(width: 38, alignment: .trailing)
                }
                Toggle("同时淡化文字", isOn: $preferences.fadeEntireOverlay)
                    .help("关闭时只调整背景透明度，让文字保持清晰。")
                HStack {
                    Text("显示屏幕").font(.system(size: 12))
                    Spacer()
                    Picker("显示屏幕", selection: $preferences.overlayScreenID) {
                        ForEach(store.availableDisplays) { display in Text(display.title).tag(display.id) }
                    }
                    .labelsHidden().frame(width: 230)
                }
                HStack {
                    Text("水平位置").font(.system(size: 12)).frame(width: 52)
                    Text("左").font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                    Slider(value: $preferences.overlayHorizontal, in: 0...1).accessibilityLabel("浮窗水平位置")
                    Text("右").font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                }
                HStack {
                    Text("垂直位置").font(.system(size: 12)).frame(width: 52)
                    Text("上").font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                    Slider(value: $preferences.overlayVertical, in: 0...1).accessibilityLabel("浮窗垂直位置")
                    Text("下").font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                }
                HStack {
                    Button("恢复默认位置") { preferences.resetOverlayPosition() }.controlSize(.small)
                    Spacer()
                    Button(store.isOverlayVisible ? "隐藏浮窗" : "显示浮窗") {
                        if store.isOverlayVisible { store.dismiss() } else { store.showOverlay() }
                    }
                    .controlSize(.small)
                }
                Text("浮窗默认鼠标穿透，右上角操作点始终可点击。左键展开或收起，按住拖动可改变位置，右键复制或重试，在操作点上滚动可浏览长译文。展开时操作点不移动，切换应用不会关闭浮窗。")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(ShiyiTheme.muted)
            }
        }
    }

    private var contextualSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("服务地址 · HTTPS")
                TextField("https://api.example.com/v1", text: $preferences.endpoint)
                    .textFieldStyle(.roundedBorder)
                Text("兼容 Chat Completions 的服务根地址，通常以 /v1 结尾。")
                    .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("模型名称")
                TextField("填写服务支持的模型 ID", text: $preferences.model)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("API 密钥")
                HStack(spacing: 8) {
                    SecureField("填写后点击保存", text: $preferences.apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("保存密钥") {
                        do {
                            try preferences.saveAPIKey()
                            keyStatus = preferences.apiKey.isEmpty ? "已移除保存的密钥。" : "已保存到此 Mac 的钥匙串。"
                        } catch {
                            keyStatus = "保存失败：\(error.localizedDescription)"
                        }
                    }
                    .controlSize(.small)
                }
                Text(keyStatus.isEmpty ? "密钥保存在此 Mac 的钥匙串，修改后请点击保存。" : keyStatus)
                    .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
            }
            Divider()
            Toggle(isOn: $preferences.sendContext) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参考附近上下文").font(.system(size: 12, weight: .medium))
                    Text("支持时，附上选区附近的文字和文档标题。")
                        .font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            HStack {
                Text("阅读场景").font(.system(size: 12))
                Spacer()
                Picker("阅读场景", selection: $preferences.scene) {
                    ForEach(["自动", "日常", "技术", "学术", "商务"], id: \.self) { scene in Text(scene).tag(scene) }
                }
                .labelsHidden().frame(width: 155)
            }
            Label {
                Text("AI 模式会把选中文字及开启的附近上下文发往你配置的服务。请根据阅读内容选择是否开启。")
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.up.right.square")
            }
            .font(.system(size: 12))
            .foregroundStyle(ShiyiTheme.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShiyiTheme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var permissionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: store.permissionGranted ? "checkmark.shield" : "hand.raised")
                        .foregroundStyle(store.permissionGranted ? ShiyiTheme.accent : .orange)
                        .font(.system(size: 19))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.permissionGranted ? "已允许辅助功能取词" : "先允许拾译读取选中文字")
                            .font(.system(size: 12, weight: .semibold))
                        Text(store.permissionGranted ? "可以在其他应用中选中文字。部分 PDF、网页和应用可能不提供选区。" : "前往“系统设置 → 隐私与安全性 → 辅助功能”，启用拾译。若开关已开却仍未授权，请移除列表中的旧拾译，再用“+”添加当前应用。粘贴翻译无需此权限。")
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .foregroundStyle(ShiyiTheme.muted)
                    }
                }
                HStack(spacing: 10) {
                    if !store.permissionGranted {
                        Button("授权辅助功能") { store.requestPermission() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    Button("打开系统设置") { store.openAccessibilitySettings() }.controlSize(.small)
                    if !store.permissionGranted {
                        Button("检查授权") { store.refreshPermission() }.controlSize(.small)
                        Button("显示当前应用") { store.revealApplication() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private var languagePairControls: some View {
        HStack(spacing: 7) {
            Text("从").font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
            Picker("原文语言", selection: $preferences.source) {
                ForEach(TranslationLanguage.allCases) { language in Text(language.title).tag(language) }
            }
            .labelsHidden().frame(width: 100)
            Button { preferences.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.plain).help("交换原文语言与目标语言")
            Text("到").font(.system(size: 12)).foregroundStyle(ShiyiTheme.muted)
            Picker("目标语言", selection: $preferences.target) {
                ForEach(TranslationLanguage.allCases) { language in Text(language.title).tag(language) }
            }
            .labelsHidden().frame(width: 100)
        }
        .controlSize(.small)
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(ShiyiTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ShiyiTheme.line))
    }
}
