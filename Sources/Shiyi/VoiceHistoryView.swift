import SwiftUI

struct VoiceHistoryView: View {
    @ObservedObject var archive: VoiceTranscriptArchive
    @State private var selected: UUID?
    @State private var document = ""
    @State private var readError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Label("翻译记录", systemImage: "clock.arrow.circlepath").font(.headline)
            Text("每次开始收听建立一条本地记录，自动保存时间、语言对、原文与译文。清空屏幕字幕不会删除记录；不保存录音。")
                .font(.caption).foregroundStyle(ShiyiTheme.muted)
            Text(archive.pendingWrites > 0 ? "正在保存…" : "记录自动保存在本机")
                .font(.caption).foregroundStyle(ShiyiTheme.muted)
            if let error = archive.saveError { Text(error).font(.caption).foregroundStyle(.orange) }
            if archive.sessions.isEmpty {
                Text("开始一次语音翻译后，记录会出现在这里。")
                    .font(.callout).foregroundStyle(ShiyiTheme.muted)
            } else {
                Picker("收听记录", selection: $selected) {
                    Text("选择记录").tag(Optional<UUID>.none)
                    ForEach(archive.sessions) { row in Text(row.title).tag(Optional(row.id)) }
                }
                if let readError { Text(readError).font(.caption).foregroundStyle(.orange) }
                if !document.isEmpty {
                    ScrollView {
                        Text(String(document.prefix(12000)))
                            .font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(height: 220)
                    .background(ShiyiTheme.canvas).clipShape(RoundedRectangle(cornerRadius: 8))
                    if document.count > 12000 {
                        Text("此处预览前 12,000 字，导出会包含完整记录。")
                            .font(.caption).foregroundStyle(ShiyiTheme.muted)
                    }
                }
                HStack {
                    Button("导出 Markdown") { if let selected { Task { await archive.export(selected) } } }.disabled(selected == nil)
                    Button("打开保存文件夹") { archive.showFolder() }
                }
            }
        }
        .task {
            await archive.refresh()
            if selected == nil { selected = archive.sessions.first?.id }
        }
        .task(id: selected) { await reload() }
        .onChange(of: archive.sessions.first?.id) { _, id in if selected == nil { selected = id } }
        .onChange(of: archive.pendingWrites) { _, count in if count == 0 { Task { await reload() } } }
    }
    @MainActor private func reload() async {
        guard let selected else { document = ""; return }
        do {
            let session = try await archive.load(selected)
            guard self.selected == selected else { return }
            document = session.markdown; readError = nil
        } catch {
            guard self.selected == selected else { return }
            document = ""; readError = error.localizedDescription
        }
    }
}
