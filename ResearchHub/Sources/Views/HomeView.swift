import SwiftUI

/// 首頁 v2：今天的工作台。
/// Hero 大字日期 + 玻璃統計 chips；材質卡片：最近筆記、今日日記、今日事件、待辦彙整、週統計。
struct HomeView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @EnvironmentObject private var eventStore: EventStore

    @State private var recentNotes: [FileItem] = []
    @State private var todos: [FileSystemStore.TodoItem] = []
    @State private var todayJournalPreview: String?
    @State private var noteCount = 0
    @State private var animateBars = false
    @State private var statsPeriod: PomodoroStatsPeriod = .thisWeek

    var body: some View {
        Group {
            if store.rootURL == nil {
                Text("請先在「筆記」分頁選擇根資料夾")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle("首頁")
        .onAppear {
            refresh()
            animateBars = false
            withAnimation(.spring(duration: 0.7).delay(0.15)) {
                animateBars = true
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        recentCard
                        journalCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 14) {
                        todoCard
                        eventsCard
                        statsCard
                        pomodoroLogCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(22)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("\(greeting)，ShaoCheng。")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                statChip("flame", "今日 \(pomodoro.todayCount) 顆", .orange)
                statChip("calendar", "本週 \(weekTotal) 顆", .teal)
                statChip("doc.text", "\(noteCount) 篇筆記", .blue)
                statChip("checklist", "\(todos.count) 項待辦", .purple)
            }
            .padding(.top, 2)
        }
    }

    private func statChip(_ icon: String, _ text: String, _ color: Color) -> some View {
        Label {
            Text(text)
                .font(.callout.weight(.medium))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "早安"
        case 12..<18: return "午安"
        default: return "晚安"
        }
    }

    private var weekTotal: Int {
        pomodoro.weekCounts().reduce(0) { $0 + $1.count }
    }

    // MARK: - Card 容器

    private func card<Content: View>(
        _ icon: String, _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - 最近筆記

    private var recentCard: some View {
        card("clock", "最近筆記") {
            if recentNotes.isEmpty {
                emptyHint("還沒有筆記")
            } else {
                VStack(spacing: 3) {
                    ForEach(recentNotes) { note in
                        Button {
                            store.openNote(note.url)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(relativePath(of: note.url) + " · "
                                         + note.modified.formatted(.relative(presentation: .named)))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(HoverRow())
                    }
                }
            }
        }
    }

    private func relativePath(of url: URL) -> String {
        guard let notes = store.notesURL else { return "" }
        let dir = url.deletingLastPathComponent()
        if dir.path == notes.path { return "Notes" }
        return dir.lastPathComponent
    }

    // MARK: - 今日日記

    private var journalCard: some View {
        card("book", "今日日記") {
            Button {
                store.requestedTab = .journal
            } label: {
                Group {
                    if let preview = todayJournalPreview {
                        Text(preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    } else {
                        Label("還沒寫，點擊開始今天的記錄…", systemImage: "plus")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(HoverRow())
        }
    }

    // MARK: - 今日事件

    private var eventsCard: some View {
        let todayEvents = eventStore.events(on: .now)
        return Group {
            if !todayEvents.isEmpty {
                card("calendar.badge.clock", "今日事件") {
                    VStack(spacing: 5) {
                        ForEach(todayEvents) { event in
                            let tag = eventStore.tag(for: event.tagID)
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(tag?.color ?? .gray)
                                    .frame(width: 4, height: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(event.title)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(event.isAllDay
                                         ? "全天"
                                         : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if let tag {
                                    Text(tag.name)
                                        .font(.caption2)
                                        .foregroundStyle(tag.color)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 待辦

    private var todoCard: some View {
        card("checklist", "待辦事項") {
            if todos.isEmpty {
                emptyHint("全部完成了 🎉")
            } else {
                VStack(spacing: 2) {
                    ForEach(todos.prefix(10)) { todo in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    store.toggleTodo(todo)
                                    refresh()
                                }
                            } label: {
                                Image(systemName: "circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.secondary)
                                    .padding(3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                store.openNote(todo.noteURL)
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(todo.text)
                                        .font(.callout)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(todo.noteName)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .modifier(HoverRow())
                        }
                    }
                    if todos.count > 10 {
                        Text("還有 \(todos.count - 10) 項…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - 蕃茄鐘統計（本週／上週／本月／今年）

    private var statsCard: some View {
        card("chart.bar", "蕃茄鐘統計") {
            let bars = pomodoro.statBars(statsPeriod)
            let maxCount = max(bars.map(\.count).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $statsPeriod) {
                    ForEach(PomodoroStatsPeriod.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("\(pomodoro.total(statsPeriod)) 顆")
                    .font(.title3.weight(.semibold))

                VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: bars.count > 12 ? 2 : 8) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                            VStack(spacing: 3) {
                                Capsule()
                                    .fill(bar.isNow
                                          ? AnyShapeStyle(Color.accentColor)
                                          : AnyShapeStyle(Color.accentColor.opacity(0.4)))
                                    .frame(height: animateBars
                                           ? max(4, CGFloat(bar.count) / CGFloat(maxCount) * 56)
                                           : 4)
                                    .opacity(bar.count == 0 ? 0.15 : 1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 70, alignment: .bottom)
                    HStack(spacing: bars.count > 12 ? 2 : 8) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                            Text(bar.label)
                                .font(.caption2)
                                .foregroundStyle(bar.isNow ? .primary : .tertiary)
                                .frame(maxWidth: .infinity)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 最近的蕃茄鐘（回顧計畫 → 完成）

    private var pomodoroLogCard: some View {
        card("list.bullet.rectangle", "最近的蕃茄鐘") {
            let recent = pomodoro.recentSessions(limit: 6)
            if recent.isEmpty {
                emptyHint("還沒有完成紀錄")
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { s in
                        HStack(alignment: .top, spacing: 8) {
                            Text(s.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 78, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                if !s.done.isEmpty {
                                    Text(s.done).font(.caption).lineLimit(2)
                                } else if !s.plan.isEmpty {
                                    Text(s.plan).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                } else {
                                    Text("（未記錄內容）").font(.caption).foregroundStyle(.tertiary)
                                }
                                if !s.plan.isEmpty && !s.done.isEmpty {
                                    Text("計畫：\(s.plan)")
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    private func refresh() {
        recentNotes = store.recentNotes(limit: 5)
        todos = store.scanTodos()
        todayJournalPreview = loadJournalPreview()
        noteCount = store.allNoteURLs().count
    }

    private func loadJournalPreview() -> String? {
        guard let url = store.journalURL(for: .now),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let lines = content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(3)
        let preview = lines.joined(separator: " · ")
        return preview.isEmpty ? nil : preview
    }
}

/// 滑過高亮（所有可點列共用）
struct HoverRow: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.0))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
