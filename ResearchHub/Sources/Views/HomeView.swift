#if os(macOS)
import SwiftUI

/// 首頁 v2：今天的工作台。
/// Hero 大字日期 + 玻璃統計 chips；材質卡片：最近筆記、今日日記、今日事件、待辦彙整、週統計。
struct HomeView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var generalStore: GeneralTodoStore
    @AppStorage("settings.userName") private var userName = ""
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    @State private var recentNotes: [FileItem] = []
    @State private var todos: [FileSystemStore.TodoItem] = []
    @State private var todayJournalPreview: String?
    @State private var noteCount = 0
    @State private var animateBars = false
    @State private var statsPeriod: PomodoroStatsPeriod = .thisWeek
    @State private var newGeneralTodo = ""
    @State private var repeatedTodos: [FileSystemStore.RepeatedTodo] = []
    @State private var showTrash = false
    @State private var scheduleFeedback: String?
    @State private var showPlanning = false
    /// 展開顯示全文的一般待辦
    @State private var expandedTodos: Set<UUID> = []

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
        .sheet(isPresented: $showTrash) {
            TodoTrashSheet()
        }
        .sheet(isPresented: $showPlanning, onDismiss: refresh) {
            PlanningSheet()
        }
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
                        generalTodoCard
                        recentCard
                        journalCard
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 14) {
                        weeklyCard
                        todoCard
                        eventsCard
                        statsCard
                        productivityCard
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
            greetingLine
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                statChip("flame", "今日 \(pomodoro.todayCount) 顆", .orange)
                statChip("calendar", "本週 \(weekTotal) 顆", .teal)
                statChip("doc.text", "\(noteCount) 篇筆記", .blue)
                statChip("checklist", "\(todos.count + generalStore.todos.filter { !$0.done }.count) 項待辦", .purple)

                Spacer()

                // 晚間規劃儀式：寫明天的日記 + 看節奏 + 搬未完成
                Button {
                    showPlanning = true
                } label: {
                    Label("規劃明天", systemImage: "moon.stars")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.indigo)
                .glassEffect(.regular, in: .capsule)
                .help("晚間儀式：規劃明天要做的事")
            }
            .padding(.top, 2)
        }
    }

    private func statChip(_ icon: String, _ text: LocalizedStringKey, _ color: Color) -> some View {
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

    /// 問候語 +（可選）使用者在設定填的名字。名字留空就只顯示問候語。
    private var greetingLine: Text {
        let g = Text(greeting)
        let trimmed = userName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? g : g + Text(verbatim: " \(trimmed)")
    }

    private var greeting: LocalizedStringKey {
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
        _ icon: String, _ title: LocalizedStringKey,
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
                                    Group {
                                        if event.isAllDay {
                                            Text("全天")
                                        } else {
                                            Text(verbatim: "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                                        }
                                    }
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

    // MARK: - 一般待辦 + Claude 觀察

    /// 還沒決定哪天做的任務，存在 .hub/todos.json；
    /// 下方是 Claude 觀察區：重複出現的日記待辦 + 鼓勵訊息 + 垃圾桶。
    private var generalTodoCard: some View {
        card("tray.full", "一般待辦") {
            VStack(alignment: .leading, spacing: 10) {
                // 輸入列
                HStack(spacing: 8) {
                    TextField("想到但還沒排時間的事…", text: $newGeneralTodo)
                        .textFieldStyle(.plain)
                        .onSubmit(addGeneralTodo)
                    Button(action: addGeneralTodo) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(newGeneralTodo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )

                // 待辦列表
                let open = generalStore.todos.filter { !$0.done }
                if open.isEmpty {
                    emptyHint("腦袋清空了，想到什麼就丟進來")
                } else {
                    VStack(spacing: 2) {
                        ForEach(open) { todo in
                            generalTodoRow(todo)
                        }
                    }
                }

                Divider()

                claudeSection
            }
        }
    }

    private func generalTodoRow(_ todo: GeneralTodo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    generalStore.toggle(todo)
                }
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let expanded = expandedTodos.contains(todo.id)
            VStack(alignment: .leading, spacing: 0) {
                let meta = TodoMeta.parse(todo.text)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    todoBadges(meta)
                    Text(meta.cleanText)
                        .font(.callout)
                        .lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(todo.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // 點文字也能展開/收合
            .onTapGesture { toggleExpanded(todo) }

            // 展開/收合全文
            Button {
                toggleExpanded(todo)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .foregroundStyle(.tertiary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收合" : "顯示全部內容")

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    generalStore.moveToTrash(todo, reason: L("手動放棄"))
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("放棄，移到垃圾桶")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .modifier(HoverRow())
    }

    private func addGeneralTodo() {
        generalStore.add(newGeneralTodo)
        newGeneralTodo = ""
    }

    private func toggleExpanded(_ todo: GeneralTodo) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expandedTodos.contains(todo.id) {
                expandedTodos.remove(todo.id)
            } else {
                expandedTodos.insert(todo.id)
            }
        }
    }

    /// Claude 觀察區：insights 訊息 + 重複出現的日記待辦。
    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Claude 觀察", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Spacer()
                Button {
                    showTrash = true
                } label: {
                    Label("垃圾桶（\(generalStore.trash.count)）", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            // 鼓勵 / 觀察訊息：優先顯示 Claude 寫入的 insights，沒有就用內建訊息。
            Text(encouragement)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let updated = generalStore.insights?.updatedAt {
                Text("— Claude · \(updated.formatted(.dateTime.month().day()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Claude 依日記待辦 + 蕃茄鐘習慣排的今日時段建議
            if let schedule = generalStore.insights?.schedule, !schedule.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("今日排程建議", systemImage: "calendar.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                        Spacer()
                        // 一鍵把「HH:MM–HH:MM 內容」各行建成今天的事件
                        if let feedback = scheduleFeedback {
                            Text(feedback)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if !Self.parseScheduleItems(schedule).isEmpty {
                            Button {
                                addScheduleToCalendar(schedule)
                            } label: {
                                Label("加入行事曆", systemImage: "calendar.badge.plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.teal)
                            .help("把每一行建成今天的行事曆事件（已存在的不重複加）")
                        }
                    }
                    Text(schedule)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.teal.opacity(0.08))
                )
            }

            if !repeatedTodos.isEmpty {
                VStack(spacing: 4) {
                    ForEach(repeatedTodos) { item in
                        repeatedTodoRow(item)
                    }
                }
            }
        }
    }

    private var encouragement: String {
        if let message = generalStore.insights?.message, !message.isEmpty {
            return message
        }
        if repeatedTodos.isEmpty {
            return L("目前沒有一直被往後推的事，狀態很好，繼續保持！")
        }
        return L("有 \(repeatedTodos.count) 件事在日記裡重複出現。太重要就拆小一點今天做一步；不重要就放心丟掉——丟掉也是一種完成。")
    }

    private func repeatedTodoRow(_ item: FileSystemStore.RepeatedTodo) -> some View {
        let overdue = item.count >= 3
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.caption)
                .foregroundStyle(overdue ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text)
                    .font(.callout)
                    .lineLimit(2)
                Group {
                    if overdue {
                        Text("已加入 \(item.count) 次都沒完成——放下它，或今天就做掉")
                    } else {
                        Text("已加入 \(item.count) 次")
                    }
                }
                .font(.caption)
                .foregroundStyle(overdue ? .red : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    generalStore.add(item.text)
                    store.discardJournalTodos(matching: item.text)
                    refresh()
                }
            } label: {
                Image(systemName: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收進一般待辦（日記裡的複本標為已放棄）")

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    generalStore.trashItem(
                        text: item.text,
                        occurrences: item.count,
                        reason: L("加入 \(item.count) 次未完成"))
                    store.discardJournalTodos(matching: item.text)
                    refresh()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("放棄，移到垃圾桶")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((overdue ? Color.red : Color.orange).opacity(0.07))
        )
    }

    // MARK: - 本週檢視（時段執行率即時算；artifact/空轉由週日檢討寫入 weekly.json）

    /// 排時段用的事件標籤名（照 2026~2027 計畫的週節奏分類）。
    private static let blockTagNames: Set<String> = ["大塊", "固定", "碎片"]

    private var weeklyCard: some View {
        let (executed, planned) = weekExecution()
        let lastReview = generalStore.weekly.last
        return card("checkmark.seal", "本週檢視") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    execStat("時段執行率",
                             planned > 0 ? "\(executed)/\(planned)" : "—",
                             planned == 0 || executed * 5 >= planned * 4 ? .green : .orange)
                    if let last = lastReview {
                        execStat("上週 artifact", "\(last.artifacts)",
                                 last.artifacts > 0 ? .green : .red)
                        if last.idleWeeks > 0 {
                            execStat("連續空轉", "\(last.idleWeeks) 週", .red)
                        }
                        if let referee = last.refereeOpen {
                            execStat("referee 剩", "\(referee)", referee == 0 ? .green : .orange)
                        }
                    }
                }
                if planned == 0 {
                    Text("把時段排進行事曆並掛「大塊／固定／碎片」標籤，這裡就會即時比對蕃茄鐘算執行率。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("每週日 21:00 Claude 做完整週檢討（四個數字 + R1–R5），寫進計畫檔與這裡。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 本週（週一起）已到時間的排定時段中，窗口內有蕃茄鐘的比例。
    private func weekExecution() -> (executed: Int, planned: Int) {
        let cal = Calendar.current
        let now = Date.now
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today) // 1 = Sun
        guard let monday = cal.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)
        else { return (0, 0) }

        let blocks = eventStore.events.filter { event in
            guard let tag = eventStore.tag(for: event.tagID),
                  Self.blockTagNames.contains(tag.name) else { return false }
            return event.start >= monday && event.start <= now
        }
        guard !blocks.isEmpty else { return (0, 0) }

        // 時段窗口（前後放寬 15 分鐘）內有任何一顆蕃茄鐘開始 → 算有執行
        let starts: [Date] = pomodoro.sessions.map { s in
            s.startedAt ?? s.date.addingTimeInterval(-Double(s.minutes) * 60)
        }
        let executed = blocks.filter { event in
            let from = event.start.addingTimeInterval(-900)
            let to = event.end.addingTimeInterval(900)
            return starts.contains { $0 >= from && $0 <= to }
        }.count
        return (executed, blocks.count)
    }

    // MARK: - 待辦

    private var todoCard: some View {
        card("checklist", "筆記待辦") {
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
                                    HStack(spacing: 5) {
                                        todoBadges(todo.meta)
                                        Text(todo.meta.cleanText)
                                            .font(.callout)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
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
            let bars = pomodoro.statBars(statsPeriod, locale: appLocale)
            let maxCount = max(bars.map(\.count).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $statsPeriod) {
                    ForEach(PomodoroStatsPeriod.allCases) { p in
                        Text(LocalizedStringKey(p.label)).tag(p)
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

    // MARK: - 生產力分析（最近 60 天：哪個時段/星期幾最能完成蕃茄鐘）

    private var productivityCard: some View {
        let profile = pomodoro.productivityProfile(days: 60)
        return Group {
            if profile.sampleCount >= 10 {
                card("chart.xyaxis.line", "生產力分析") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let summary = productivitySummary(profile) {
                            Text(summary)
                                .font(.callout.weight(.medium))
                        }

                        // 24 小時分佈
                        let maxHour = max(profile.hourCounts.max() ?? 1, 1)
                        VStack(spacing: 3) {
                            HStack(alignment: .bottom, spacing: 2) {
                                ForEach(0..<24, id: \.self) { h in
                                    Capsule()
                                        .fill(isPeakHour(h, profile)
                                              ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(Color.accentColor.opacity(0.35)))
                                        .frame(height: animateBars
                                               ? max(3, CGFloat(profile.hourCounts[h]) / CGFloat(maxHour) * 44)
                                               : 3)
                                        .opacity(profile.hourCounts[h] == 0 ? 0.15 : 1)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(height: 48, alignment: .bottom)
                            HStack(spacing: 2) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(h % 6 == 0 ? "\(h)" : "")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }

                        // 星期分佈
                        let maxDay = max(profile.weekdayCounts.max() ?? 1, 1)
                        let dayLabels = weekdayTiny
                        HStack(spacing: 8) {
                            ForEach(0..<7, id: \.self) { i in
                                VStack(spacing: 3) {
                                    Capsule()
                                        .fill(profile.peakWeekday == i
                                              ? AnyShapeStyle(Color.teal)
                                              : AnyShapeStyle(Color.teal.opacity(0.35)))
                                        .frame(height: animateBars
                                               ? max(3, CGFloat(profile.weekdayCounts[i]) / CGFloat(maxDay) * 28)
                                               : 3)
                                        .opacity(profile.weekdayCounts[i] == 0 ? 0.15 : 1)
                                    Text(dayLabels[i])
                                        .font(.caption2)
                                        .foregroundStyle(profile.peakWeekday == i ? .primary : .tertiary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 44, alignment: .bottom)

                        // 計畫 vs 實際
                        let exec = pomodoro.executionStats(days: 60)
                        HStack(spacing: 8) {
                            if let rate = exec.followRate {
                                execStat("照計畫完成", "\(Int(rate * 100))%",
                                         rate >= 0.7 ? .green : .orange)
                            }
                            if let rate = exec.planRate {
                                execStat("開工前有計畫", "\(Int(rate * 100))%",
                                         rate >= 0.7 ? .green : .orange)
                            }
                            if let first = exec.averageFirstStart {
                                execStat("平均第一顆",
                                         String(format: "%02d:%02d", first.hour, first.minute),
                                         .blue)
                            }
                        }

                        Text("最近 60 天 · \(profile.sampleCount) 顆（依開始時刻統計）")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func execStat(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    private func isPeakHour(_ h: Int, _ profile: PomodoroModel.ProductivityProfile) -> Bool {
        guard let start = profile.peakWindowStart else { return false }
        return h == start || h == start + 1
    }

    private func productivitySummary(_ profile: PomodoroModel.ProductivityProfile) -> String? {
        var parts: [String] = []
        if let h = profile.peakWindowStart {
            parts.append(L("最專注時段 \(h):00–\(h + 2):00"))
        }
        if let d = profile.peakWeekday {
            parts.append(L("\(weekdayShort[d]) 完成最多"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    /// 週一開頭的極短星期符號（中：一二三…；英：M T W…），跟隨 App 語言。
    private var weekdayTiny: [String] {
        var cal = Calendar.current
        cal.locale = appLocale
        let s = cal.veryShortWeekdaySymbols // [日, 一, …] / [S, M, …]
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    /// 週一開頭的短星期名（中：週一…；英：Mon…），句子裡用。
    private var weekdayShort: [String] {
        var cal = Calendar.current
        cal.locale = appLocale
        let s = cal.shortWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    /// 解析排程建議中的「HH:MM–HH:MM 內容」行（其他行忽略）。
    static func parseScheduleItems(_ schedule: String) -> [(start: DateComponents, end: DateComponents, title: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d{1,2}):(\d{2})\s*[–—\-~]\s*(\d{1,2}):(\d{2})\s+(.+)$"#)
        else { return [] }
        var items: [(DateComponents, DateComponents, String)] = []
        for line in schedule.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func int(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? 0 }
            let title = ns.substring(with: m.range(at: 5))
                .trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            items.append((
                DateComponents(hour: int(1), minute: int(2)),
                DateComponents(hour: int(3), minute: int(4)),
                title
            ))
        }
        return items
    }

    /// 把排程建議建成今天的行事曆事件；同名同時段已存在就跳過。
    private func addScheduleToCalendar(_ schedule: String) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var added = 0
        for item in Self.parseScheduleItems(schedule) {
            guard let start = cal.date(
                    bySettingHour: item.start.hour ?? 0,
                    minute: item.start.minute ?? 0, second: 0, of: today),
                  var end = cal.date(
                    bySettingHour: item.end.hour ?? 0,
                    minute: item.end.minute ?? 0, second: 0, of: today)
            else { continue }
            if end <= start { // 跨午夜（23:30–00:30）→ 結束算隔天
                end = cal.date(byAdding: .day, value: 1, to: end) ?? end
            }
            let exists = eventStore.events.contains {
                $0.title == item.title && $0.start == start
            }
            guard !exists else { continue }
            eventStore.add(CalendarEvent(
                title: item.title,
                notes: L("來自 Claude 排程建議"),
                isAllDay: false, start: start, end: end,
                tagID: eventStore.tags.first { $0.name == "研究" }?.id))
            added += 1
        }
        scheduleFeedback = added > 0
            ? L("已加入 \(added) 件事件 ✓")
            : L("事件都已存在")
    }

    /// !high / !low / @due 的顯示徽章（到期日過了變紅）。
    @ViewBuilder
    private func todoBadges(_ meta: TodoMeta) -> some View {
        if meta.priority == .high {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("高優先")
        } else if meta.priority == .low {
            Image(systemName: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("低優先")
        }
        if let due = meta.due {
            Text(due.formatted(.dateTime.month(.defaultDigits).day()))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(meta.isOverdue
                                   ? Color.red.opacity(0.15)
                                   : Color.orange.opacity(0.12)))
                .foregroundStyle(meta.isOverdue ? .red : .orange)
        }
        if let line = meta.line {
            Text(verbatim: line)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
                .foregroundStyle(.blue)
        }
        // @from 還沒到 → 顯示「▸ 日期」（項目在等開始日）
        if let from = meta.from, from > Calendar.current.startOfDay(for: .now) {
            Text(verbatim: "▸ " + from.formatted(.dateTime.month(.defaultDigits).day()))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.teal.opacity(0.12)))
                .foregroundStyle(.teal)
        }
        if let est = meta.estMinutes {
            Text(verbatim: est % 60 == 0 ? "\(est / 60)h" : "\(est)m")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.gray.opacity(0.15)))
                .foregroundStyle(.secondary)
        }
        if meta.everyWeekdays != nil {
            Image(systemName: "repeat")
                .font(.caption2)
                .foregroundStyle(.purple)
        }
        if let remind = meta.remind {
            Text(verbatim: "🔔" + remind.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    private func refresh() {
        generalStore.reload() // Claude 可能直接改過 .hub 的 JSON → 重讀
        // 每日一次：@due/@from/@every 的獨立日副本播進今天的日記 + @remind 排通知
        store.seedTodayTodos(
            generalTexts: generalStore.todos.filter { !$0.done }.map(\.text))
        recentNotes = store.recentNotes(limit: 5)
        todos = store.scanTodos()
        todayJournalPreview = loadJournalPreview()
        noteCount = store.allNoteURLs().count
        repeatedTodos = store.scanRepeatedJournalTodos()
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

/// 待辦垃圾桶：存放放棄的待辦（含重複多次沒做的日記待辦），可救回或永久刪除。
struct TodoTrashSheet: View {
    @EnvironmentObject private var generalStore: GeneralTodoStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("待辦垃圾桶", systemImage: "trash")
                    .font(.headline)
                Spacer()
                if !generalStore.trash.isEmpty {
                    Button("清空", role: .destructive) {
                        generalStore.clearTrash()
                    }
                    .font(.caption)
                }
            }
            .padding(14)

            Divider()

            if generalStore.trash.isEmpty {
                Text("垃圾桶是空的")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(generalStore.trash) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.text)
                                        .font(.callout)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(item.trashedAt.formatted(.dateTime.month().day()))
                                        if item.occurrences > 1 {
                                            Text("曾加入 \(item.occurrences) 次")
                                        }
                                        if !item.reason.isEmpty {
                                            Text(item.reason)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    generalStore.restore(item)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("救回到一般待辦")

                                Button(role: .destructive) {
                                    generalStore.deleteFromTrash(item)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("永久刪除")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .modifier(HoverRow())
                        }
                    }
                    .padding(10)
                }
            }

            Divider()

            HStack {
                Text("放棄不是失敗——是把時間留給更重要的事。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("關閉") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 420, height: 440)
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
#endif
