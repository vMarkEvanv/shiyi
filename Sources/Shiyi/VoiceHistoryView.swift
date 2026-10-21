import SwiftUI

private struct VoiceHistorySearch: Hashable { let query: String; let revision: Int }

struct VoiceHistoryView: View {
    @ObservedObject var archive: VoiceTranscriptArchive
    @State private var selected: UUID?
    @State private var session: VoiceTranscriptSession?
    @State private var query = ""
    @State private var matches: Set<UUID>?
    @State private var searching = false
    @State private var searchToken = UUID()
    @State private var searchRevision = 0
    @State private var readError: String?
    @State private var renaming = false
    @State private var name = ""
    private var rows: [VoiceTranscriptSummary] { archive.sessions.filter { matches == nil || matches!.contains($0.id) } }
    private var days: [Date] { Array(Set(rows.map { Calendar.current.startOfDay(for: $0.startedAt) })).sorted(by: >) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、原文或译文", text: $query).textFieldStyle(.plain).accessibilityLabel("搜索翻译记录")
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            }.padding(10).background(ShiyiTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            if archive.sessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有翻译记录").font(.headline)
                    Text("开始语音翻译后，原文与译文会自动保存在本机。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(days, id: \.self) { day in
                            Section(day.formatted(date: .abbreviated, time: .omitted)) {
                                ForEach(rows.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) { row in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.name ?? row.startedAt.formatted(date: .omitted, time: .shortened)).font(.headline).lineLimit(1)
                                        Text(row.source.title + " → " + row.target.title).font(.callout)
                                        Text("\(row.count) 段 · " + (row.endedAt == nil ? "收听中" : "已结束")).font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 5).tag(row.id)
                                }
                            }
                        }
                        if rows.isEmpty { Text("没有匹配的记录").foregroundStyle(.secondary) }
                    }.listStyle(.sidebar).frame(minWidth: 165, idealWidth: 190, maxWidth: 240)
                    VStack(alignment: .leading, spacing: 12) {
                        if let session, session.id == selected {
                            HStack {
                                Text(session.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Button { name = session.name ?? ""; renaming = true } label: { Image(systemName: "pencil") }.help("重命名记录").accessibilityLabel("重命名记录")
                                Button("导出") { Task { await archive.export(session.id) } }.help("导出完整 Markdown")
                            }
                            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + session.source.title + " → " + session.target.title)
                                .font(.callout).foregroundStyle(.secondary)
                            if let end = session.endedAt {
                                Text("时长 \(max(0, Int(end.timeIntervalSince(session.startedAt))) / 60) 分 \(max(0, Int(end.timeIntervalSince(session.startedAt))) % 60) 秒 · \(session.captions.count) 段")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 22) {
                                    ForEach(session.captions) { caption in
                                        VStack(alignment: .leading, spacing: 7) {
                                            Text(caption.recordedAt.formatted(date: .omitted, time: .standard)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                            Text(caption.original).font(.callout).foregroundStyle(.secondary)
                                            Text(caption.translation.isEmpty ? "未完成翻译" : caption.translation).font(.body)
                                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(.trailing, 8)
                            }.id(session.id)
                        } else {
                            Text(readError ?? "选择一条收听记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.padding(.leading, 16).frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Label(archive.pendingWrites > 0 ? "正在保存…" : "已保存在本机 · 不保存录音", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开文件夹") { archive.showFolder() }
            }
            if let error = archive.saveError ?? readError { Text(error).font(.callout).foregroundStyle(.orange) }
        }
        .task { await archive.refresh(); if selected == nil { selected = archive.sessions.first?.id } }
        .task(id: selected) { await reload() }
        .task(id: VoiceHistorySearch(query: query, revision: searchRevision)) {
            if !query.isEmpty {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
            await search()
        }
        .onChange(of: archive.sessions) { _, _ in searchRevision += 1; if selected == nil { selected = archive.sessions.first?.id } }
        .onChange(of: archive.pendingWrites) { _, count in
            if count == 0 { searchRevision += 1; Task { await reload() } }
        }
        .onDisappear { searchToken = UUID() }
        .sheet(isPresented: $renaming) {
            VStack(alignment: .leading, spacing: 16) {
                Text("重命名记录").font(.headline)
                TextField("留空使用默认名称", text: $name).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { renaming = false }.keyboardShortcut(.cancelAction)
                    Button("保存") {
                        guard let selected else { return }
                        Task {
                            do { try await archive.rename(selected, to: name); renaming = false; await reload() }
                            catch { readError = error.localizedDescription; renaming = false }
                        }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 360)
        }
    }
    @MainActor private func reload() async {
        guard let selected else { session = nil; return }
        do {
            let value = try await archive.load(selected)
            guard self.selected == selected else { return }
            session = value; readError = nil
        } catch {
            guard self.selected == selected else { return }
            session = nil; readError = error.localizedDescription
        }
    }
    @MainActor private func search() async {
        let token = UUID(); searchToken = token
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            matches = nil; searching = false
            if selected == nil { selected = archive.sessions.first?.id }
            return
        }
        searching = true
        var found = Set<UUID>()
        for row in archive.sessions {
            guard !Task.isCancelled, searchToken == token, query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
            if let value = try? await archive.load(row.id), value.matches(requested) { found.insert(row.id) }
        }
        guard !Task.isCancelled, searchToken == token, query.trimmingCharacters(in: .whitespacesAndNewlines) == requested else { return }
        matches = found; searching = false
        if selected == nil || !found.contains(selected!) { selected = archive.sessions.first(where: { found.contains($0.id) })?.id }
    }
}
