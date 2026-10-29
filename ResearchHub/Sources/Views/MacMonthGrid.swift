#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// 日記分頁的月曆：會隨欄寬「長大」。欄位窄的時候每格只放得下色點與跨日細線；
/// 把分隔線拖寬，點就連續長成帶標題的色塊（TimeTree 式），中間的寬度是半長的膠囊、文字慢慢浮現——
/// 同一個元件、一個 0…1 的參數 `t`，不是兩種版面切換。
struct MacMonthGrid: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(FileSystemStore.self) private var store

    let displayedMonth: Date
    let selectedDay: Date
    /// 日記檔變了就 +1，讓勾掉的待辦即時反映成刪除線
    var revision = 0
    /// 本月有日記／筆記更新的日（day number）
    let journalDays: Set<Int>
    let noteDays: Set<Int>
    let onSelect: (Date) -> Void

    @State private var width: CGFloat = 0
    private let calendar = Calendar.current

    /// 格寬 ≤ narrow：全是點；≥ wide：全是色塊；中間線性過渡
    static let narrowCell: CGFloat = 36
    static let wideCell: CGFloat = 54
    static let maxLanes = 3
    private static let numberHeight: CGFloat = 20
    private static let rowSpacing: CGFloat = 4

    private var colWidth: CGFloat { max(width / 7, 1) }
    private var t: CGFloat {
        min(max((colWidth - Self.narrowCell) / (Self.wideCell - Self.narrowCell), 0), 1)
    }
    private var rowHeight: CGFloat { lerp(46, Self.numberHeight + CGFloat(Self.maxLanes) * 18 + 6, t) }

    var body: some View {
        let weeks = MonthLayout.weeks(for: displayedMonth, calendar: calendar)
        // GeometryReader 當容器：它回報的是父層「提案」的寬，不受子格子影響——
        // 放在 background 量的話，格子一旦撐大就縮不回去（縮窄分隔線時量到的仍是自己）
        GeometryReader { geo in
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    weekRow(week)
                        .frame(height: rowHeight)
                        .clipped()
                }
            }
            .frame(width: geo.size.width)
            .onChange(of: geo.size.width, initial: true) { _, new in width = new }
        }
        .frame(height: CGFloat(weeks.count) * rowHeight + CGFloat(max(weeks.count - 1, 0)) * Self.rowSpacing)
    }

    // MARK: - 一週

    private func weekRow(_ week: [Date]) -> some View {
        guard let first = week.first, let last = week.last else { return AnyView(EmptyView()) }
        let layout = MonthLayout.layout(
            week: week,
            events: eventStore.occurrences(from: first, to: last),
            color: { eventStore.tag(for: $0.tagID)?.color ?? .gray },
            done: { store.isPlannedEventDone($0, calendar: calendar) },
            maxLanes: Self.maxLanes, calendar: calendar)
        // 窄版的色點列：每天的單日事件照 lane 順序排成一排
        var dotIndex: [String: (index: Int, count: Int)] = [:]
        for col in 0..<7 {
            let singles = layout.items.filter { $0.startCol == col && $0.span == 1 && $0.isStart && $0.isEnd }
            for (i, item) in singles.enumerated() { dotIndex[item.id] = (i, singles.count) }
        }
        return AnyView(
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        dayCell(day, hidden: layout.hiddenPerDay[column(of: day, in: week)])
                            .frame(width: colWidth, height: rowHeight)
                    }
                }
                ForEach(layout.items) { item in
                    let rect = frame(for: item, dot: dotIndex[item.id])
                    pill(item)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                .allowsHitTesting(false)
            }
        )
    }

    /// 這一格在 t=0（點／細線）和 t=1（色塊）之間的位置，線性內插。
    private func frame(for item: WeekLayout.Item, dot: (index: Int, count: Int)?) -> CGRect {
        let wide = CGRect(
            x: colWidth * CGFloat(item.startCol) + 2,
            y: Self.numberHeight + CGFloat(item.lane) * 18,
            width: colWidth * CGFloat(item.span) - 4, height: 16)
        let narrow: CGRect
        if let dot {
            // 單日 → 4pt 色點，排在數字下方那一列（跨日細線的下面），置中
            let rowWidth = CGFloat(dot.count) * 6 - 2
            let x0 = colWidth * CGFloat(item.startCol) + (colWidth - rowWidth) / 2 + CGFloat(dot.index) * 6
            narrow = CGRect(x: x0, y: Self.numberHeight + CGFloat(Self.maxLanes) * 4 + 3, width: 4, height: 4)
        } else {
            // 跨日 → 3pt 細線，lane 對齊、相鄰日相連
            narrow = CGRect(
                x: colWidth * CGFloat(item.startCol) + (item.isStart ? 3 : 0),
                y: Self.numberHeight + CGFloat(item.lane) * 4,
                width: colWidth * CGFloat(item.span) - (item.isStart ? 3 : 0) - (item.isEnd ? 3 : 0), height: 3)
        }
        return CGRect(
            x: lerp(narrow.minX, wide.minX, t), y: lerp(narrow.minY, wide.minY, t),
            width: lerp(narrow.width, wide.width, t), height: lerp(narrow.height, wide.height, t))
    }

    private func pill(_ item: WeekLayout.Item) -> some View {
        let radius = lerp(2, 4, t)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: item.isStart ? radius : 0, bottomLeadingRadius: item.isStart ? radius : 0,
            bottomTrailingRadius: item.isEnd ? radius : 0, topTrailingRadius: item.isEnd ? radius : 0)
        // 膠囊長到三成就開始浮現文字，七成全亮
        let textOpacity = min(max((t - 0.3) / 0.4, 0), 1)
        // 單日有時間的：點是實心，長成色塊後變淡底色＋彩色字
        let fillOpacity = item.isSolid ? 1 : lerp(1, 0.18, t)
        // 以形狀為主體（沒有固有尺寸，剛好填滿給它的框），文字疊上去再用形狀裁切；
        // 若反過來拿 Text 當主體，它的最小尺寸會把 4pt 的點撐成一條
        return shape.fill(item.color.opacity(fillOpacity))
            .overlay(alignment: .leading) {
                Text(item.event.title)
                    .font(.system(size: 10, weight: .semibold))
                    .strikethrough(item.isDone)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(item.isSolid ? Color.white : item.color)
                    .opacity(textOpacity)
                    .padding(.horizontal, 4)
            }
            .clipShape(shape)
            .opacity(item.isDone ? 0.45 : 1)
    }

    private func dayCell(_ date: Date, hidden: Int) -> some View {
        let day = calendar.component(.day, from: date)
        let inMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)
        let indicator: Color? = journalDays.contains(day) ? .accentColor : (noteDays.contains(day) ? .secondary : nil)
        return Button {
            onSelect(date)
        } label: {
            ZStack(alignment: .top) {
                Text("\(day)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(inMonth ? Color.primary : Color.secondary.opacity(0.45))
                    .frame(height: Self.numberHeight)
                    .frame(maxWidth: .infinity)
                if let indicator, inMonth {
                    // 日記／筆記的小點：窄版在色點列最左邊；寬版縮到數字旁邊
                    Circle().fill(indicator).frame(width: 4, height: 4)
                        .offset(x: lerp(-(colWidth / 2) + 6, 12, t),
                                y: lerp(Self.numberHeight + CGFloat(Self.maxLanes) * 4 + 3, 8, t))
                }
                if hidden > 0 {
                    Text(verbatim: "+\(hidden)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 3)
                        .padding(.bottom, 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 1)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : .clear)
                    .padding(.horizontal, 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1)
                    .padding(.horizontal, 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func column(of date: Date, in week: [Date]) -> Int {
        guard let first = week.first else { return 0 }
        return min(max(calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? 0, 0), 6)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
#endif
