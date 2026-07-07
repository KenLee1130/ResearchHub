#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 日記分頁：左月曆、右當日日記編輯器。
/// 日記檔存於 Journal/yyyy/MM/yyyy-MM-dd.md，首次輸入內容時自動建檔。
struct JournalView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var generalStore: GeneralTodoStore

    @State private var displayedMonth: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var mode: EditorMode = .blocks
    /// 本月有日記的日（day number）
    @State private var journalDays: Set<Int> = []
    /// 本月有筆記更新的日 → 筆記名稱列表
    @State private var noteUpdates: [Int: [String]] = [:]
    /// 本月各日的事件標記（單日 = 點、跨日 = 線條）
    @State private var dayMarks: [Int: DayMarks] = [:]
    /// 全庫帶 @due 的未完成待辦（顯示在今天～到期日間每天的日記上方）
    @State private var dueTodos: [FileSystemStore.TodoItem] = []
    /// 事件編輯 sheet
    @State private var eventSheet: EventSheetConfig?

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
        .sheet(item: $eventSheet) { config in
            EventEditorSheet(draft: config.draft, isNew: config.isNew)
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
                Spacer()
                EditorModePicker(mode: $mode, available: [.blocks, .source])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            dueSection

            if let url = journalURL(for: selectedDay) {
                EditorCore(fileURL: url, mode: $mode)
                    .id(url)
            }
        }
    }

    // MARK: - 即將到期（@due 的項目自動出現在今天～到期日的每一天）

    /// 這一天要顯示的到期項目：未完成、到期日 ≥ 這一天；今天的頁面另外收留已過期的。
    private func isDueVisible(_ due: Date, on day: Date, today: Date) -> Bool {
        let d = calendar.startOfDay(for: due)
        return day <= d || (day == today && d < today)
    }

    @ViewBuilder
    private var dueSection: some View {
        let day = calendar.startOfDay(for: selectedDay)
        let today = calendar.startOfDay(for: .now)
        // 只顯示在今天以後的日記頁（翻舊日記不打擾）
        if day >= today {
            let selfURL = journalURL(for: selectedDay)
            let fileItems = dueTodos.filter { item in
                guard let due = item.meta.due else { return false }
                // 這一天日記自己寫的待辦已在編輯器裡，不重複列
                return item.noteURL != selfURL && isDueVisible(due, on: day, today: today)
            }
            let generalItems = generalStore.todos.filter { todo in
                guard !todo.done, let due = TodoMeta.parse(todo.text).due else { return false }
                return isDueVisible(due, on: day, today: today)
            }
            if !fileItems.isEmpty || !generalItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("即將到期", systemImage: "hourglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(fileItems) { item in
                        dueRow(text: item.meta.cleanText, due: item.meta.due!,
                               source: item.noteName, today: today) {
                            store.toggleTodo(item)
                            refreshMonthData()
                        }
                    }
                    ForEach(generalItems) { todo in
                        let meta = TodoMeta.parse(todo.text)
                        dueRow(text: meta.cleanText, due: meta.due!,
                               source: L("一般待辦"), today: today) {
                            generalStore.toggle(todo)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.05))
                Divider()
            }
        }
    }

    private func dueRow(
        text: String, due: Date, source: String, today: Date,
        onToggle: @escaping () -> Void
    ) -> some View {
        let overdue = calendar.startOfDay(for: due) < today
        return HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(text)
                .font(.callout)
                .lineLimit(1)
            Text(due.formatted(.dateTime.month(.defaultDigits).day()))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(overdue
                    ? Color.red.opacity(0.15) : Color.orange.opacity(0.12)))
                .foregroundStyle(overdue ? .red : .orange)
            Spacer(minLength: 0)
            Text(verbatim: source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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
        selectedDay = calendar.startOfDay(for: date)
        displayedMonth = calendar.startOfMonth(for: date)
    }

    /// 逐日切換；跨月時月曆跟著翻頁。
    private func shiftDay(_ delta: Int) {
        guard let d = calendar.date(byAdding: .day, value: delta, to: selectedDay) else { return }
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
        dueTodos = store.dueTodos()
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
