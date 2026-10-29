import SwiftUI
import HubCore

// 月檢視的版面計算（Mac 月曆欄與 iPhone 行事曆共用）：
// 整月切成週、每週的事件（含跨日與重複事件的實例）分 lane，放不下的記成「+N」。

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
        var span: Int { endCol - startCol + 1 }
        /// 跨日或全天 → 實心色塊；單日有時間的 → 淡底色＋彩色字
        var isSolid: Bool { event.isAllDay || span > 1 || !isStart || !isEnd }
    }
    let items: [Item]
    /// 放不下的事件數（每天）→「+N」
    let hiddenPerDay: [Int]
    let maxLanes: Int

    static let empty = WeekLayout(items: [], hiddenPerDay: Array(repeating: 0, count: 7), maxLanes: 0)
}

enum MonthLayout {
    /// 整月的週（每週 7 天，含上下月補齊的日子），週一開頭。
    static func weeks(for month: Date, calendar: Calendar = .current) -> [[Date]] {
        let first = calendar.startOfMonth(for: month)
        let weekday = calendar.component(.weekday, from: first) // 1 = Sun
        let lead = (weekday + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -lead, to: first),
              let dayCount = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let rows = Int(ceil(Double(lead + dayCount) / 7))
        return (0..<rows).map { r in
            (0..<7).compactMap { c in calendar.date(byAdding: .day, value: r * 7 + c, to: gridStart) }
        }
    }

    /// 把這週涵蓋的事件實例分 lane：同一欄先放開始早、跨得長、全天的；lane 用完的記進 hiddenPerDay。
    static func layout(week: [Date], events: [CalendarEvent], color: (CalendarEvent) -> Color,
                       maxLanes: Int, calendar: Calendar = .current) -> WeekLayout {
        guard let first = week.first, let last = week.last else { return .empty }
        func column(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: date)).day ?? 0
        }
        let sorted = events.sorted { a, b in
            let ca = column(a.start), cb = column(b.start)
            if ca != cb { return ca < cb }
            let sa = column(a.end) - ca, sb = column(b.end) - cb
            if sa != sb { return sa > sb }
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            return a.start < b.start
        }
        var laneEnds: [Int] = []
        var items: [WeekLayout.Item] = []
        var hidden = Array(repeating: 0, count: 7)
        for event in sorted {
            let startCol = max(0, column(event.start))
            let endCol = min(6, column(event.end))
            guard startCol <= endCol else { continue }
            let lane = laneEnds.firstIndex { $0 < startCol } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(endCol) } else { laneEnds[lane] = endCol }
            guard lane < maxLanes else {
                for c in startCol...endCol { hidden[c] += 1 }
                continue
            }
            items.append(WeekLayout.Item(
                event: event, lane: lane, startCol: startCol, endCol: endCol,
                isStart: calendar.startOfDay(for: event.start) >= first,
                isEnd: calendar.startOfDay(for: event.end) <= last,
                color: color(event)))
        }
        return WeekLayout(items: items, hiddenPerDay: hidden, maxLanes: maxLanes)
    }
}
