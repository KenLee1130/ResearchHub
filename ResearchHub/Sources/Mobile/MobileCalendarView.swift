#if os(iOS)
import SwiftUI
import HubStore
import HubCore

/// 行事曆分頁：月曆（左右滑換月、點日期）＋ 當天事件；事件可新增／編輯／刪除，
/// 資料與 Mac 版同一份 `.hub/events.json`。這是之後「提前規劃」（考試複習、約會）的底座。
struct MobileCalendarView: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(FileSystemStore.self) private var store
    @Environment(MobileNavigation.self) private var nav
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    @State private var displayedMonth = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var eventSheet: MobileEventSheet?
    /// 當天日記的未完成待辦數（讓使用者知道那天「要做的事」不只事件）
    @State private var openTodoCount = 0
    @State private var icsFile: URL?

    private let calendar = Calendar.current
    private var weekColumns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 4), count: 7) }

    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    monthHeader
                    weekdayRow
                    monthGrid
                    Divider().padding(.top, 4)
                    dayAgenda
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("行事曆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("今天") { goToday() }
                        .disabled(calendar.isDateInToday(selectedDay)
                                  && calendar.isDate(displayedMonth, equalTo: .now, toGranularity: .month))
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let icsFile {
                        ShareLink(item: icsFile) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button {
                        eventSheet = .new(on: selectedDay, tag: eventStore.tags.first)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $eventSheet) { config in
                MobileEventEditor(draft: config.draft, isNew: config.isNew)
            }
            .onAppear {
                reloadTodoCount()
                refreshICS()
            }
            .onChange(of: selectedDay) { reloadTodoCount() }
            .onChange(of: eventStore.events) { refreshICS() }
            .onReceive(AppContainer.shared.librarySync.changes) { change in
                if change.affects(store.journalURL(for: selectedDay)) { reloadTodoCount() }
            }
            .refreshable {
                AppContainer.shared.librarySync.syncNow()
                reloadTodoCount()
            }
        }
    }

    // MARK: - 月曆

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            Spacer()
            Text(monthTitle)
                .font(.title3.weight(.semibold))
                .contentTransition(.numericText())
            Spacer()
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var weekdayRow: some View {
        LazyVGrid(columns: weekColumns, spacing: 4) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                Text(s)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var monthGrid: some View {
        let dots = eventStore.tagColorsByDay(inMonth: displayedMonth, maxPerDay: 3)
        return LazyVGrid(columns: weekColumns, spacing: 4) {
            ForEach(monthCells) { cell in
                if let day = cell.day {
                    dayCell(day, dots: dots[day] ?? [])
                } else {
                    Color.clear.frame(height: 48)
                }
            }
        }
        .contentShape(Rectangle())
        // 左右滑換月（上下滑交給外層 ScrollView）
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

    private func dayCell(_ day: Int, dots: [String]) -> some View {
        let date = dateFor(day: day)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)
        return Button {
            selectedDay = date
        } label: {
            VStack(spacing: 4) {
                Text("\(day)")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : Color.primary))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(isSelected ? Color.accentColor : .clear)
                    )
                HStack(spacing: 3) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, hex in
                        Circle().fill(Color(hex: hex)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 當天

    private var dayEvents: [CalendarEvent] { eventStore.events(on: selectedDay) }

    private var dayAgenda: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayTitle)
                    .font(.headline)
                Spacer()
                if openTodoCount > 0 {
                    Button {
                        // 跳到「今天」分頁看那天的待辦與日記
                        nav.showDay(selectedDay)
                    } label: {
                        Label("\(openTodoCount) 件待辦", systemImage: "checklist")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }

            if dayEvents.isEmpty {
                VStack(spacing: 8) {
                    Text("沒有事件")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Button {
                        eventSheet = .new(on: selectedDay, tag: eventStore.tags.first)
                    } label: {
                        Label("新增事件", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(dayEvents) { event in
                        Button {
                            eventSheet = MobileEventSheet(draft: event, isNew: false)
                        } label: {
                            MobileEventRow(event: event, tag: eventStore.tag(for: event.tagID), showNotes: true)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if event.id != dayEvents.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
            }
        }
    }

    // MARK: - Helpers

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: displayedMonth)
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return f.string(from: selectedDay)
    }

    /// 週一開頭的短星期名，跟隨 App 語言
    private var weekdaySymbols: [String] {
        var cal = Calendar.current
        cal.locale = appLocale
        let s = cal.veryShortWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    private struct DayCell: Identifiable {
        let id: Int
        let day: Int?
    }

    private var monthCells: [DayCell] {
        let days = calendar.range(of: .day, in: .month, for: displayedMonth)?.count ?? 30
        let weekday = calendar.component(.weekday, from: displayedMonth) // 1 = Sun
        let blanks = (weekday + 5) % 7
        var cells: [DayCell] = []
        cells.reserveCapacity(blanks + days)
        for i in 0..<blanks { cells.append(DayCell(id: -(i + 1), day: nil)) }
        for d in 1...days { cells.append(DayCell(id: d, day: d)) }
        return cells
    }

    private func dateFor(day: Int) -> Date {
        calendar.date(byAdding: .day, value: day - 1, to: displayedMonth) ?? displayedMonth
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

    private func reloadTodoCount() {
        guard let url = store.journalURL(for: selectedDay) else { openTodoCount = 0; return }
        openTodoCount = LibraryIndex.shared.todoLines(in: url)?.filter { !$0.done }.count ?? 0
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
#endif
