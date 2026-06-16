import SwiftUI

/// 日記分頁：左月曆、右當日日記編輯器。
/// 日記檔存於 Journal/yyyy/MM/yyyy-MM-dd.md，首次輸入內容時自動建檔。
struct JournalView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var eventStore: EventStore

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
        /// index = lane（最多 2 條），nil 表示該 lane 當天沒有線
        var bars: [BarSegment?] = [nil, nil]
        /// 單日事件的色點（最多 3 個）
        var dots: [Color] = []
    }

    private static let maxLanes = 2

    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    private let calendar = Calendar.current

    /// 目前 App 語系對應的 Locale（供日曆星期/月份/日期文字跟著語言切換）。
    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    /// 依目前語系顯示星期縮寫（週一開頭）。
    private var weekdaySymbols: [String] {
        var c = Calendar.current
        c.locale = appLocale
        let s = c.veryShortWeekdaySymbols                  // 週日開頭
        return Array(s.dropFirst()) + [s[0]]               // 轉成週一開頭
    }

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
        .onAppear(perform: refreshMonthData)
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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(0..<leadingBlanks, id: \.self) { _ in
                    Color.clear.frame(height: 30)
                }
                ForEach(1...daysInMonth, id: \.self) { day in
                    dayCell(day)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayTitle)
                        .font(.headline)
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

            if let url = journalURL(for: selectedDay) {
                EditorCore(fileURL: url, mode: $mode)
                    .id(url)
            }
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
            let allDay = String(localized: "全天")
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
        return f.string(from: selectedDay) + " " + String(localized: "日記")
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
    }

    /// 週一開頭的前置空格數
    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: displayedMonth) // 1 = Sun
        return (weekday + 5) % 7
    }

    private func dateFor(day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: displayedMonth) ?? displayedMonth
    }

    private func shiftMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = m
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

            // 單日 → 點
            if s == e {
                let day = calendar.component(.day, from: s)
                if marks[day, default: DayMarks()].dots.count < 3 {
                    marks[day, default: DayMarks()].dots.append(color)
                }
                continue
            }

            // 跨日 → 分配 lane
            var lane: Int
            if let free = laneEnds.firstIndex(where: { $0 < s }) {
                lane = free
            } else if laneEnds.count < Self.maxLanes {
                laneEnds.append(.distantPast)
                lane = laneEnds.count - 1
            } else {
                continue // lane 滿了，忽略（極端情況）
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

// MARK: - Calendar helper

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}
