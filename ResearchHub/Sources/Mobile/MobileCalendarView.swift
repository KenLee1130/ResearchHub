#if os(iOS)
import SwiftUI
import HubStore
import HubCore

/// 行事曆分頁：整頁月檢視（TimeTree 式）——每格直接放事件標題的色塊，跨日事件連成一條橫跨多格，
/// 週列把整個高度撐滿；點一天開當天清單，右下角「＋」新增。資料與 Mac 版同一份 `.hub/events.json`。
struct MobileCalendarView: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(FileSystemStore.self) private var store
    @Environment(MobileNavigation.self) private var nav
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    @State private var displayedMonth = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var eventSheet: MobileEventSheet?
    @State private var daySheet: DaySheet?
    @State private var showPlanSheet = false
    @State private var icsFile: URL?

    private let calendar = Calendar.current

    /// sheet(item:) 需要 Identifiable
    private struct DaySheet: Identifiable {
        let day: Date
        var id: Date { day }
    }

    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                monthHeader
                weekdayRow
                monthGrid
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottomTrailing) { addButton }
            .sheet(item: $eventSheet) { config in
                MobileEventEditor(draft: config.draft, isNew: config.isNew)
            }
            .sheet(item: $daySheet) { sheet in
                MobileDaySheet(day: sheet.day)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showPlanSheet) {
                MobilePlanSheet(draft: PlanDraft.initial(near: selectedDay, tag: eventStore.tags.first))
            }
            .onAppear { refreshICS() }
            .onChange(of: eventStore.events) { refreshICS() }
            .refreshable { AppContainer.shared.librarySync.syncNow() }
        }
    }

    // MARK: - 標題列

    private var monthHeader: some View {
        HStack(spacing: 12) {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            Text(monthTitle)
                .font(.title2.weight(.bold))
                .contentTransition(.numericText())
                .onTapGesture { goToday() }
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            Spacer()
            HStack(spacing: 4) {
                if !calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month) {
                    Button("今天") { goToday() }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
                Button {
                    showPlanSheet = true
                } label: {
                    Image(systemName: "calendar.badge.clock")
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("規劃")
                if let icsFile {
                    ShareLink(item: icsFile) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { i, s in
                Text(s)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(i == 6 ? Color.red.opacity(0.8) : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 月格

    private var monthGrid: some View {
        GeometryReader { geo in
            let weeks = monthWeeks
            let rowHeight = geo.size.height / CGFloat(weeks.count)
            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    MonthWeekRow(
                        days: week,
                        height: rowHeight,
                        displayedMonth: displayedMonth,
                        selectedDay: selectedDay,
                        layout: weekLayout(week, rowHeight: rowHeight),
                        onTap: { day in
                            selectedDay = day
                            daySheet = DaySheet(day: day)
                        })
                    .frame(height: rowHeight)
                    Divider()
                }
            }
        }
        .contentShape(Rectangle())
        // 左右滑換月
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    shiftMonth(v.translation.width < 0 ? 1 : -1)
                }
        )
        .id(displayedMonth)
        .transition(.opacity)
    }

    /// 右下角「＋」：在選到的那天（預設今天）新增事件
    private var addButton: some View {
        Button {
            eventSheet = .new(on: selectedDay, tag: eventStore.tags.first)
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityLabel("新增事件")
    }

    // MARK: - 版面：每週的事件色塊分 lane

    /// 整月的週（每週 7 天，含上下月補齊的日子），週一開頭。
    private var monthWeeks: [[Date]] {
        let first = calendar.startOfMonth(for: displayedMonth)
        let weekday = calendar.component(.weekday, from: first) // 1 = Sun
        let lead = (weekday + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -lead, to: first),
              let dayCount = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let rows = Int(ceil(Double(lead + dayCount) / 7))
        return (0..<rows).map { r in
            (0..<7).compactMap { c in calendar.date(byAdding: .day, value: r * 7 + c, to: gridStart) }
        }
    }

    private func weekLayout(_ week: [Date], rowHeight: CGFloat) -> WeekLayout {
        guard let first = week.first, let last = week.last else { return WeekLayout(items: [], hiddenPerDay: Array(repeating: 0, count: 7), maxLanes: 0) }
        let maxLanes = max(1, Int((rowHeight - MonthWeekRow.numberHeight - 4) / (MonthWeekRow.pillHeight + MonthWeekRow.pillSpacing)))
        let events = eventStore.occurrences(from: first, to: last)
            .sorted { a, b in
                let ca = column(of: a.start, in: week), cb = column(of: b.start, in: week)
                if ca != cb { return ca < cb }
                let sa = column(of: a.end, in: week) - ca, sb = column(of: b.end, in: week) - cb
                if sa != sb { return sa > sb }           // 跨得長的先
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
        var laneEnds: [Int] = []
        var items: [WeekLayout.Item] = []
        var hidden = Array(repeating: 0, count: 7)
        for event in events {
            let startCol = max(0, column(of: event.start, in: week))
            let endCol = min(6, column(of: event.end, in: week))
            guard startCol <= endCol else { continue }
            var lane = laneEnds.firstIndex { $0 < startCol } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(endCol) } else { laneEnds[lane] = endCol }
            if lane >= maxLanes {
                for c in startCol...endCol { hidden[c] += 1 }
                lane = -1
            }
            guard lane >= 0 else { continue }
            let dayStart = calendar.startOfDay(for: event.start)
            let dayEnd = calendar.startOfDay(for: event.end)
            items.append(WeekLayout.Item(
                event: event, lane: lane, startCol: startCol, endCol: endCol,
                isStart: dayStart >= first, isEnd: dayEnd <= last,
                color: eventStore.tag(for: event.tagID).map { Color(hex: $0.colorHex) } ?? .gray))
        }
        return WeekLayout(items: items, hiddenPerDay: hidden, maxLanes: maxLanes)
    }

    /// 日期落在這週的第幾欄（可能 < 0 或 > 6：跨週的事件）
    private func column(of date: Date, in week: [Date]) -> Int {
        guard let first = week.first else { return 0 }
        return calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? 0
    }

    // MARK: - Helpers

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: displayedMonth)
    }

    /// 週一開頭的短星期名，跟隨 App 語言
    private var weekdaySymbols: [String] {
        var cal = Calendar.current
        cal.locale = appLocale
        let s = cal.shortWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    private func shiftMonth(_ delta: Int) {
        guard let m = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { displayedMonth = m }
    }

    private func goToday() {
        withAnimation(.easeInOut(duration: 0.2)) {
            displayedMonth = calendar.startOfMonth(for: .now)
            selectedDay = calendar.startOfDay(for: .now)
        }
    }

    /// 匯出用的 .ics 先寫到暫存檔，ShareLink 才能分享成檔案
    private func refreshICS() {
        let text = eventStore.icsString()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchHub.ics")
        if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
            icsFile = url
        }
    }
}

// MARK: - 一週一列

/// 一週裡事件色塊的位置：第幾條 lane、從第幾欄到第幾欄。
struct WeekLayout {
    struct Item: Identifiable {
        let event: CalendarEvent
        let lane: Int
        let startCol: Int
        let endCol: Int
        /// 這一格是不是事件真正的開始／結束（不是就把那一側的圓角抹平，表示延續到上一週／下一週）
        let isStart: Bool
        let isEnd: Bool
        let color: Color
        var id: String { "\(event.id)-\(startCol)" }
    }
    let items: [Item]
    /// 放不下的事件數（每天）→「+N」
    let hiddenPerDay: [Int]
    let maxLanes: Int
}

struct MonthWeekRow: View {
    static let numberHeight: CGFloat = 22
    static let pillHeight: CGFloat = 16
    static let pillSpacing: CGFloat = 2

    let days: [Date]
    let height: CGFloat
    let displayedMonth: Date
    let selectedDay: Date
    let layout: WeekLayout
    let onTap: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        GeometryReader { geo in
            let colWidth = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                // 日期格（可點）
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayCell(day)
                            .frame(width: colWidth, height: height)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(day) }
                    }
                }
                // 事件色塊（疊在格子上，不吃點擊）
                ForEach(layout.items) { item in
                    pill(item)
                        .frame(width: colWidth * CGFloat(item.endCol - item.startCol + 1) - 4, height: Self.pillHeight)
                        .offset(x: colWidth * CGFloat(item.startCol) + 2,
                                y: Self.numberHeight + CGFloat(item.lane) * (Self.pillHeight + Self.pillSpacing))
                }
                .allowsHitTesting(false)
                // 放不下的「+N」
                ForEach(0..<7, id: \.self) { col in
                    if layout.hiddenPerDay[col] > 0 {
                        Text("+\(layout.hiddenPerDay[col])")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: colWidth - 4, height: 12, alignment: .leading)
                            .offset(x: colWidth * CGFloat(col) + 4,
                                    y: Self.numberHeight + CGFloat(layout.maxLanes) * (Self.pillHeight + Self.pillSpacing))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isSunday = calendar.component(.weekday, from: day) == 1
        return VStack(spacing: 0) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 13, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(
                    isToday ? Color.white
                    : !inMonth ? Color.secondary.opacity(0.5)
                    : isSunday ? Color.red.opacity(0.85)
                    : Color.primary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(isToday ? Color.accentColor : .clear))
                .overlay(Circle().strokeBorder(isSelected && !isToday ? Color.accentColor : .clear, lineWidth: 1.5))
                .frame(height: Self.numberHeight)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        // ignoresSafeAreaEdges: []：不然最後一列的底色會延伸到分頁列底下
        .background(isSelected ? Color.accentColor.opacity(0.06) : .clear, ignoresSafeAreaEdges: [])
    }

    private func pill(_ item: WeekLayout.Item) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: item.isStart ? 4 : 0, bottomLeadingRadius: item.isStart ? 4 : 0,
            bottomTrailingRadius: item.isEnd ? 4 : 0, topTrailingRadius: item.isEnd ? 4 : 0)
        let solid = item.event.isAllDay || item.endCol > item.startCol
        return Text(item.event.title)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(solid ? Color.white : item.color)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.pillHeight)
            .background(shape.fill(solid ? item.color : item.color.opacity(0.18)))
    }
}

// MARK: - 當天清單（sheet）

/// 點一天開的清單：事件（點了編輯）、待辦數（跳今天分頁）、新增事件。
struct MobileDaySheet: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(FileSystemStore.self) private var store
    @Environment(MobileNavigation.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    let day: Date
    @State private var eventSheet: MobileEventSheet?
    @State private var openTodoCount = 0

    private let calendar = Calendar.current
    private var events: [CalendarEvent] { eventStore.events(on: day) }

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    Text("沒有事件")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(events) { event in
                        Button {
                            eventSheet = MobileEventSheet(draft: event, isNew: false)
                        } label: {
                            MobileEventRow(event: event, tag: eventStore.tag(for: event.tagID), showNotes: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Button {
                        eventSheet = .new(on: day, tag: eventStore.tags.first)
                    } label: {
                        Label("新增事件", systemImage: "plus")
                    }
                    if openTodoCount > 0 {
                        Button {
                            dismiss()
                            nav.showDay(day)
                        } label: {
                            Label("\(openTodoCount) 件待辦", systemImage: "checklist")
                        }
                    }
                }
            }
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $eventSheet) { config in
                MobileEventEditor(draft: config.draft, isNew: config.isNew)
            }
            .onAppear { reloadTodoCount() }
        }
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.locale = AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return f.string(from: day)
    }

    private func reloadTodoCount() {
        guard let url = store.journalURL(for: day) else { openTodoCount = 0; return }
        openTodoCount = LibraryIndex.shared.todoLines(in: url)?.filter { !$0.done }.count ?? 0
    }
}
#endif
