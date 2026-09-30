#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 日記分頁：左月曆、右當日日記編輯器。
/// 日記檔存於 Journal/yyyy/MM/yyyy-MM-dd.md，首次輸入內容時自動建檔。
struct JournalView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(EventStore.self) private var eventStore
    @Environment(GeneralTodoStore.self) private var generalStore
    @Environment(PomodoroModel.self) private var pomodoro

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var mode: EditorMode = .blocks
    /// 本月有日記的日（day number）
    @State private var journalDays: Set<Int> = []
    /// 本月有筆記更新的日 → 筆記名稱列表
    @State private var noteUpdates: [Int: [String]] = [:]
    /// 本月各日的事件標記（單日 = 點、跨日 = 線條）
    @State private var dayMarks: [Int: DayMarks] = [:]
    /// 事件編輯 sheet
    @State private var eventSheet: EventSheetConfig?
    /// /list 任務總覽（開著時暫時卸下編輯器：先存檔，讓總覽能安全改檔案）
    @State private var showTaskManager = false

    struct EventSheetConfig: Identifiable {
        let id = UUID()
        var draft: CalendarEvent
        var isNew: Bool
    }

    /// 跨日事件在某一天的線段
    struct BarSegment {
        let color: Color
        let isStart: Bool
        let isEnd: Bool
    }

    struct DayMarks {
        /// index = lane（最多 maxLanes 條），nil 表示該 lane 當天沒有線
        var bars: [BarSegment?] = Array(repeating: nil, count: JournalView.maxLanes)
        /// 單日事件的色點（最多 maxDots 個）
        var dots: [Color] = []
        /// 放不下的事件數（lane 滿的跨日 + 超過點數上限的單日）→ 顯示 +N
        var overflow = 0
    }

    static let maxLanes = 3
    private static let maxDots = 3

    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    private let calendar = Calendar.current

    /// 目前 App 語系對應的 Locale（供日曆星期/月份/日期文字跟著語言切換）。
    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    /// 星期列：固定用數字 1–7（週一=1 … 週日=7），不分語言、不會有英文重複字母的歧義。
    private let weekdaySymbols = ["1", "2", "3", "4", "5", "6", "7"]

    /// 月曆 7 欄版面（星期列與日期格共用同一組欄定義）。
    private let weekColumns = Array(repeating: GridItem(.flexible()), count: 7)

    var body: some View {
        Group {
            if store.rootURL == nil {
                Text("請先在「筆記」分頁選擇根資料夾")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    calendarPane
                        .frame(width: 280)
                    Divider()
                    journalPane
                }
            }
        }
        .navigationTitle("日記")
        .onAppear {
            refreshMonthData()
            consumePendingDate()
        }
        .onChange(of: store.pendingJournalDate) { consumePendingDate() }
        .onChange(of: displayedMonth) { refreshMonthData() }
        .onChange(of: selectedDay) { refreshMonthData() }
        .onChange(of: eventStore.events) { refreshMonthData() }
        // 手機寫的日記同步進來 → 月曆上的「有日記」標記跟著更新
        .onReceive(NotificationCenter.default.publisher(for: .rhLibraryDidChange)) { note in
            if LibrarySync.affects(note, store.journalURL) || LibrarySync.affects(note, store.notesURL) {
                refreshMonthData()
            }
        }
        .sheet(item: $eventSheet) { config in
            EventEditorSheet(draft: config.draft, isNew: config.isNew)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rhEditorCommand)) { note in
            guard let cmd = note.userInfo?["command"] as? String else { return }
            if cmd == "list" {
                showTaskManager = true
            } else if cmd.hasPrefix("go:") {
                // 編輯器內命令行的 /go：跳到那一天（同底部命令列）
                _ = handleQuickAction(.go(String(cmd.dropFirst(3))))
            }
        }
        .sheet(isPresented: $showTaskManager, onDismiss: refreshMonthData) {
            TaskManagerSheet()
        }
    }

    // MARK: - Calendar pane

    private var calendarPane: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthTitle)
                    .font(.headline)
                Spacer()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // 星期標題自成一個 grid，不與日期格混在同一個 LazyVGrid。
            LazyVGrid(columns: weekColumns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // 日期格：先把整月格子（前置空格 + 1…末日）建成一個陣列，
            // 用單一 ForEach 渲染，每格 id 唯一，避免互相吃掉。
            LazyVGrid(columns: weekColumns, spacing: 6) {
                ForEach(monthCells) { cell in
                    if let day = cell.day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 46)
                    }
                }
            }

            Button("回到今天") {
                displayedMonth = calendar.startOfMonth(for: .now)
                selectedDay = calendar.startOfDay(for: .now)
            }
            .font(.caption)

            HStack(spacing: 12) {
                legendDot(.accentColor, "日記")
                legendDot(.secondary, "筆記更新")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            Divider()

            HStack {
                Text("\(selectedDayShortTitle) 事件")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    exportICS()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("匯出全部事件為 .ics（可匯入系統行事曆／Google 日曆）")
                Button {
                    eventSheet = EventSheetConfig(draft: newEventDraft(), isNew: true)
                } label: {
                    Image(systemName: "plus")
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新增事件")
            }

            let dayEvents = eventStore.events(on: selectedDay)
            if dayEvents.isEmpty {
                Text("沒有事件")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(dayEvents) { event in
                            eventRow(event)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var selectedDayShortTitle: String {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: selectedDay)
    }

    private func dayCell(_ day: Int) -> some View {
        let date = dateFor(day: day)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)
        let hasJournal = journalDays.contains(day)
        let hasNotes = noteUpdates[day] != nil

        let marks = dayMarks[day] ?? DayMarks()

        return Button {
            seedBeforeShowing(date)
            selectedDay = date
        } label: {
            VStack(spacing: 2) {
                Text("\(day)")
                    .font(.callout)
                    .monospacedDigit()
                // 跨日事件線條（lane 對齊，相鄰日相連）
                VStack(spacing: 1) {
                    ForEach(0..<Self.maxLanes, id: \.self) { lane in
                        if lane < marks.bars.count, let bar = marks.bars[lane] {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(bar.color)
                                .frame(height: 3)
                                .padding(.leading, bar.isStart ? 3 : -5)
                                .padding(.trailing, bar.isEnd ? 3 : -5)
                        } else {
                            Color.clear.frame(height: 3)
                        }
                    }
                }
                HStack(spacing: 2) {
                    if hasJournal {
                        Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                    } else if hasNotes {
                        Circle().fill(Color.secondary).frame(width: 4, height: 4)
                    }
                    ForEach(Array(marks.dots.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                    // 顯示不下的事件數，不再靜默丟棄
                    if marks.overflow > 0 {
                        Text(verbatim: "+\(marks.overflow)")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func legendDot(_ color: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
        }
    }

    // MARK: - Journal pane

    private var journalPane: some View {
        VStack(spacing: 0) {
            // 放得下：時間收支整組跟標題同一列；放不下：折到第二列靠右
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    journalHeaderLeading
                    Spacer(minLength: 12)
                    timeBudgetBar
                    EditorModePicker(mode: $mode, available: [.blocks, .source])
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        journalHeaderLeading
                        Spacer(minLength: 12)
                        EditorModePicker(mode: $mode, available: [.blocks, .source])
                    }
                    HStack {
                        Spacer()
                        timeBudgetBar
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if showTaskManager {
                // 總覽開著：編輯器卸下（onDisappear 會先存檔），總覽可安全改日記檔
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = journalURL(for: selectedDay) {
                EditorCore(
                    fileURL: url, mode: $mode,
                    quickCmdBar: true,
                    onJournalCommand: handleQuickAction)
                    .id(url)
            }
        }
    }

    /// 標題列左半：日期切換鍵＋標題（一列/兩列佈局共用）
    private var journalHeaderLeading: some View {
        HStack(spacing: 12) {
            // 左右鍵：不用回月曆就能逐日切換
            HStack(spacing: 0) {
                Button {
                    shiftDay(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .help("前一天（⌘⌥←）")
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button {
                    shiftDay(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .help("後一天（⌘⌥→）")
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(dayTitle)
                        .font(.headline)
                        .fixedSize()
                    if !calendar.isDateInToday(selectedDay) {
                        Button("回到今天") {
                            selectedDay = calendar.startOfDay(for: .now)
                            displayedMonth = calendar.startOfMonth(for: .now)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
                if let names = noteUpdates[calendar.component(.day, from: selectedDay)],
                   calendar.isDate(selectedDay, equalTo: displayedMonth, toGranularity: .month) {
                    Text("當日筆記更新：\(names.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - 今日時間收支（標題列右側）

    private struct DayBudget {
        var estTotal = 0        // 全部待辦 @est 加總（分）
        var estRemaining = 0    // 未打勾的 @est 加總（分）
        var ranMinutes = 0      // 今天蕃茄鐘實際跑的分鐘
        var leftMinutes = 0     // 現在到午夜（分）
    }

    /// 只在「今天」且日記裡有帶 @est 的待辦時顯示。
    /// 打勾一項 → estRemaining 立刻少掉那項的估時，可對照 🍅 實跑。
    @ViewBuilder private var timeBudgetBar: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            if let b = todayBudget() {
                let h = { (m: Int) in Int((Double(m) / 60).rounded()) }
                let overloaded = b.estRemaining > b.leftMinutes
                let total = max(1, b.ranMinutes + max(b.leftMinutes, b.estRemaining))
                HStack(spacing: 8) {
                    Text("🍅 \(h(b.ranMinutes))h ・ 還需 \(h(b.estRemaining))h / 剩 \(h(b.leftMinutes))h")
                        .font(.caption)
                        .foregroundStyle(overloaded ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize()
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 150, height: 8)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(.green)
                                    .frame(width: 150 * CGFloat(b.ranMinutes) / CGFloat(total))
                                Rectangle()
                                    .fill(overloaded ? Color.red : .orange)
                                    .frame(width: 150 * CGFloat(min(b.estRemaining, total - b.ranMinutes)) / CGFloat(total))
                            }
                            .clipShape(Capsule())
                        }
                }
                .help("總需 \(h(b.estTotal))h・已完成 \(h(b.estTotal - b.estRemaining))h・已跑 \(h(b.ranMinutes))h・緩衝 \(h(b.leftMinutes - b.estRemaining))h")
            }
        }
    }

    /// 讀檔＋解析 @est 的快取（key = 路徑＋修改時間）。timeBudgetBar 是定時重繪的，
    /// 每次都同步讀 iCloud 檔案會在打字時卡主執行緒。
    @MainActor private static var estCache: (key: String, total: Int, remaining: Int)?

    /// 從日記檔算出 @est 總量與未完成量；檔案沒變就用快取。
    private func estMinutes(in url: URL) -> (total: Int, remaining: Int)? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)"
        if let c = Self.estCache, c.key == key {
            return c.total > 0 ? (c.total, c.remaining) : nil
        }
        guard let content = FileSystemStore.safeRead(url) else { return nil }
        var total = 0, remaining = 0
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let done: Bool
            if trimmed.hasPrefix("- [ ]") { done = false }
            else if trimmed.lowercased().hasPrefix("- [x]") { done = true }
            else { continue }
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let est = TodoMeta.parse(text).estMinutes else { continue }
            total += est
            if !done { remaining += est }
        }
        Self.estCache = (key, total, remaining)
        return total > 0 ? (total, remaining) : nil
    }

    private func todayBudget() -> DayBudget? {
        guard calendar.isDateInToday(selectedDay),
              let url = journalURL(for: selectedDay),
              let est = estMinutes(in: url)
        else { return nil }
        var b = DayBudget()
        b.estTotal = est.total
        b.estRemaining = est.remaining
        b.ranMinutes = pomodoro.sessions
            .filter { calendar.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.minutes }
        let midnight = calendar.startOfDay(for: .now).addingTimeInterval(86_400)
        b.leftMinutes = max(0, Int(midnight.timeIntervalSinceNow / 60))
        return b
    }

    // MARK: - 底部命令列的日記層級動作（/go /list）

    private func handleQuickAction(_ action: JournalQuickAction) -> Bool {
        switch action {
        case .list:
            showTaskManager = true
            return true
        case .go(let arg):
            guard let day = parseGoTarget(arg) else { return false }
            selectedDay = calendar.startOfDay(for: day)
            displayedMonth = calendar.startOfMonth(for: day)
            return true
        }
    }

    /// /go 的目標：空/today/今天、tomorrow/明天、yesterday/昨天、±n（相對目前顯示的那天）、
    /// M/d 或 yyyy-M-d（與 @due 同格式）。
    private func parseGoTarget(_ s: String) -> Date? {
        let t = s.lowercased()
        if t.isEmpty || t == "today" || t == "今天" { return .now }
        if t == "tomorrow" || t == "明天" {
            return calendar.date(byAdding: .day, value: 1, to: .now)
        }
        if t == "yesterday" || t == "昨天" {
            return calendar.date(byAdding: .day, value: -1, to: .now)
        }
        if t.range(of: #"^[+-]\d+$"#, options: .regularExpression) != nil, let n = Int(t) {
            return calendar.date(byAdding: .day, value: n, to: selectedDay)
        }
        return TodoMeta.parseDate(s, calendar: calendar)
    }

    // MARK: - Event rows

    private func eventRow(_ event: CalendarEvent) -> some View {
        let tag = eventStore.tag(for: event.tagID)
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tag?.color ?? .gray)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.callout)
                    .lineLimit(2)
                if !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(timeString(for: event))
                    if let tag {
                        Text(tag.name)
                            .foregroundStyle(tag.color)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill((tag?.color ?? .gray).opacity(0.10))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            eventSheet = EventSheetConfig(draft: event, isNew: false)
        }
    }

    private func newEventDraft() -> CalendarEvent {
        let start = calendar.date(
            bySettingHour: 9, minute: 0, second: 0, of: selectedDay) ?? selectedDay
        let end = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
        return CalendarEvent(
            title: "", isAllDay: false, start: start, end: end,
            tagID: eventStore.tags.first?.id)
    }

    private func timeString(for event: CalendarEvent) -> String {
        let sameDay = calendar.isDate(event.start, inSameDayAs: event.end)
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.dateFormat = "M/d"

        if event.isAllDay {
            let allDay = L("全天")
            return sameDay
                ? allDay
                : "\(day.string(from: event.start))–\(day.string(from: event.end)) \(allDay)"
        }
        if sameDay {
            return "\(time.string(from: event.start))–\(time.string(from: event.end))"
        }
        return "\(day.string(from: event.start)) \(time.string(from: event.start)) – "
            + "\(day.string(from: event.end)) \(time.string(from: event.end))"
    }

    // MARK: - Date helpers

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        // 依目前語系顯示「年 月」（中文：2026年6月；英文：June 2026）。
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: displayedMonth)
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return f.string(from: selectedDay) + " " + L("日記")
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
    }

    /// 週一開頭的前置空格數
    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: displayedMonth) // 1 = Sun
        return (weekday + 5) % 7
    }

    /// 月曆單格：day == nil 代表月初的前置空格。
    private struct DayCell: Identifiable {
        /// 空格用負數 id、日期用 1…31，彼此與星期標題都不會相撞。
        let id: Int
        let day: Int?
    }

    /// 一次建好整月格子：leadingBlanks 個空格 + 1…末日。
    /// 用單一陣列 + 單一 ForEach 渲染，跨月切換時 diff 穩定。
    private var monthCells: [DayCell] {
        var cells: [DayCell] = []
        cells.reserveCapacity(leadingBlanks + daysInMonth)
        for i in 0..<leadingBlanks {
            cells.append(DayCell(id: -(i + 1), day: nil))
        }
        for day in 1...daysInMonth {
            cells.append(DayCell(id: day, day: day))
        }
        return cells
    }

    private func dateFor(day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: displayedMonth) ?? displayedMonth
    }

    private func shiftMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = m
        }
    }

    /// 消化 researchhub://journal?date=… 的跳轉請求。
    private func consumePendingDate() {
        guard let date = store.pendingJournalDate else { return }
        store.pendingJournalDate = nil
        seedBeforeShowing(date)
        selectedDay = calendar.startOfDay(for: date)
        displayedMonth = calendar.startOfMonth(for: date)
    }

    /// 開某一天的日記之前，先把該天該出現的 @due/@every 副本補齊
    /// （今天以後才播；一定要在編輯器換檔前呼叫，避免和 autosave 打架）。
    private func seedBeforeShowing(_ date: Date) {
        store.seedTodos(
            for: date,
            generalTexts: generalStore.todos.filter { !$0.done }.map(\.text))
    }

    /// 逐日切換；跨月時月曆跟著翻頁。
    private func shiftDay(_ delta: Int) {
        guard let d = calendar.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        seedBeforeShowing(d)
        selectedDay = calendar.startOfDay(for: d)
        if !calendar.isDate(d, equalTo: displayedMonth, toGranularity: .month) {
            displayedMonth = calendar.startOfMonth(for: d)
        }
    }

    /// 匯出全部事件為 .ics 檔。
    private func exportICS() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ics") ?? .data]
        panel.nameFieldStringValue = "ResearchHub.ics"
        let ics = eventStore.icsString()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? ics.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func journalURL(for date: Date) -> URL? {
        guard let base = store.journalURL else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let name = f.string(from: date)
        let comps = calendar.dateComponents([.year, .month], from: date)
        let y = String(format: "%04d", comps.year ?? 0)
        let m = String(format: "%02d", comps.month ?? 0)
        return base
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
            .appendingPathComponent("\(name).md")
    }

    // MARK: - Month data

    private func refreshMonthData() {
        journalDays = scanJournalDays()
        noteUpdates = scanNoteUpdates()
        dayMarks = computeEventMarks()
    }

    /// 把本月事件整理成日曆標記：單日 → 點；跨日 → lane 線段（greedy 分配 lane 保持跨日對齊）。
    private func computeEventMarks() -> [Int: DayMarks] {
        var marks: [Int: DayMarks] = [:]
        let monthStart = calendar.startOfMonth(for: displayedMonth)
        guard let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count,
              let monthEnd = calendar.date(byAdding: .day, value: dayCount - 1, to: monthStart)
        else { return [:] }

        var laneEnds: [Date] = []

        for event in eventStore.events.sorted(by: { $0.start < $1.start }) {
            let s = calendar.startOfDay(for: event.start)
            let e = calendar.startOfDay(for: event.end)
            guard e >= monthStart, s <= monthEnd else { continue }
            let color = eventStore.tag(for: event.tagID)?.color ?? .gray

            // 單日 → 點；超過上限計入 +N
            if s == e {
                let day = calendar.component(.day, from: s)
                if marks[day, default: DayMarks()].dots.count < Self.maxDots {
                    marks[day, default: DayMarks()].dots.append(color)
                } else {
                    marks[day, default: DayMarks()].overflow += 1
                }
                continue
            }

            // 跨日 → 分配 lane；lane 滿了改記 +N（涵蓋的每一天都要算）
            var lane: Int
            if let free = laneEnds.firstIndex(where: { $0 < s }) {
                lane = free
            } else if laneEnds.count < Self.maxLanes {
                laneEnds.append(.distantPast)
                lane = laneEnds.count - 1
            } else {
                var d = max(s, monthStart)
                let last = min(e, monthEnd)
                while d <= last {
                    marks[calendar.component(.day, from: d), default: DayMarks()].overflow += 1
                    guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                    d = next
                }
                continue
            }
            laneEnds[lane] = e

            var d = max(s, monthStart)
            let last = min(e, monthEnd)
            while d <= last {
                let day = calendar.component(.day, from: d)
                var m = marks[day, default: DayMarks()]
                while m.bars.count < Self.maxLanes { m.bars.append(nil) }
                m.bars[lane] = BarSegment(
                    color: color,
                    isStart: calendar.isDate(d, inSameDayAs: s),
                    isEnd: calendar.isDate(d, inSameDayAs: e)
                )
                marks[day] = m
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }
        return marks
    }

    /// 本月有日記檔的日
    private func scanJournalDays() -> Set<Int> {
        guard let base = store.journalURL else { return [] }
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        let y = String(format: "%04d", comps.year ?? 0)
        let m = String(format: "%02d", comps.month ?? 0)
        let dir = base
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var days = Set<Int>()
        for url in files where url.pathExtension.lowercased() == "md" {
            // yyyy-MM-dd.md → day
            let stem = url.deletingPathExtension().lastPathComponent
            if let day = Int(stem.suffix(2)) {
                days.insert(day)
            }
        }
        return days
    }

    /// 本月每天更新過的筆記名稱
    private func scanNoteUpdates() -> [Int: [String]] {
        guard let notes = store.notesURL else { return [:] }
        guard let enumerator = FileManager.default.enumerator(
            at: notes,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [Int: [String]] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent != "assets" else { continue }
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            guard calendar.isDate(modified, equalTo: displayedMonth, toGranularity: .month)
            else { continue }
            let day = calendar.component(.day, from: modified)
            result[day, default: []].append(url.deletingPathExtension().lastPathComponent)
        }
        return result
    }
}

// （Calendar.startOfMonth 移到 Models/AppEnums.swift，跨平台共用）
#endif
