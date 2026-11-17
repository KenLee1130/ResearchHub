import Foundation

/// 日記分頁「今天的時間軸」的版面：一天的事件 → 每一塊的位置與高度。
///
/// 純計算、不碰畫面。三件事在這裡決定，view 只負責畫：
///   1. **範圍自適應**：預設 08–22；有更早或更晚的事件就往外延伸到整點。
///   2. **壓縮不捲動**：軸的總高度固定＝給的高度，每小時的點數＝高度 ÷ 小時數；
///      壓到 `minPointsPerHour` 以下才改成可捲動（這時每小時固定用下限值）。
///   3. **重疊排欄**：時間重疊的事件並排成幾欄，不互相蓋住。
///
/// 全天事件不進軸（月曆欄的清單已經列了）；跨日的實例只取落在當天的那一段。
public struct DayTimelineLayout: Equatable, Sendable {
    /// 軸上的一塊：一個事件（或它落在當天的那一段）。
    public struct Block: Identifiable, Equatable, Sendable {
        public var id: UUID { event.id }
        public let event: CalendarEvent
        /// 落在當天的實際區間（跨日的已裁到當天）
        public let start: Date
        public let end: Date
        /// 距軸頂的點數與高度
        public let y: Double
        public let height: Double
        /// 重疊時的欄位：第 `column` 欄，共 `columnCount` 欄
        public let column: Int
        public let columnCount: Int

        public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    }

    /// 兩塊之間（或範圍兩端）的空檔，只列夠長的。
    public struct Gap: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let y: Double
        public let height: Double

        public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    }

    /// 可調的規則；預設值就是設計稿上的數字。
    public struct Rules: Equatable, Sendable {
        /// 沒有更早的事件時，軸從幾點開始
        public var defaultStartHour: Int
        /// 沒有更晚的事件時，軸到幾點結束
        public var defaultEndHour: Int
        /// 每小時最少幾點；再壓就改捲動
        public var minPointsPerHour: Double
        /// 空檔至少幾分鐘才列出來
        public var minGapMinutes: Int

        public init(defaultStartHour: Int = 8, defaultEndHour: Int = 22,
                    minPointsPerHour: Double = 24, minGapMinutes: Int = 60) {
            self.defaultStartHour = min(max(defaultStartHour, 0), 23)
            self.defaultEndHour = min(max(defaultEndHour, self.defaultStartHour + 1), 24)
            self.minPointsPerHour = max(minPointsPerHour, 1)
            self.minGapMinutes = max(minGapMinutes, 1)
        }
    }

    /// 這一天（當天 00:00）
    public let day: Date
    /// 軸的範圍（整點；`endHour` 最大 24）
    public let startHour: Int
    public let endHour: Int
    /// 每小時幾點
    public let pointsPerHour: Double
    /// 壓到下限了，view 要用 ScrollView
    public let scrolls: Bool
    public let blocks: [Block]
    public let gaps: [Gap]

    private let calendar: Calendar

    public var totalHeight: Double { Double(endHour - startHour) * pointsPerHour }
    /// 每個整點（標籤用；24 代表午夜，顯示時取 `% 24`）
    public var hours: [Int] { Array(startHour..<endHour) }
    /// 已排進軸的總分鐘（重疊的不重複算）
    public var scheduledMinutes: Int {
        mergedIntervals(blocks).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
    }

    // MARK: - 建立

    public static func make(day: Date, events: [CalendarEvent], availableHeight: Double,
                            rules: Rules = Rules(), calendar: Calendar = .current) -> DayTimelineLayout {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)

        // 1. 裁到當天、丟掉全天與裁完沒長度的
        let clipped: [(event: CalendarEvent, start: Date, end: Date)] = events.compactMap { event in
            guard !event.isAllDay else { return nil }
            let s = max(event.start, dayStart), e = min(event.end, dayEnd)
            guard e > s else { return nil }
            return (event, s, e)
        }
        .sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.end > b.end   // 同時開始的，長的排前面才能佔第一欄
        }

        // 2. 範圍：預設值往外撐到涵蓋最早／最晚的事件
        func hourFraction(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 3600 }
        var startHour = rules.defaultStartHour
        var endHour = rules.defaultEndHour
        if let earliest = clipped.map(\.start).min() {
            startHour = min(startHour, Int(hourFraction(earliest).rounded(.down)))
        }
        if let latest = clipped.map(\.end).max() {
            endHour = max(endHour, Int(hourFraction(latest).rounded(.up)))
        }
        startHour = max(startHour, 0)
        endHour = min(max(endHour, startHour + 1), 24)

        // 3. 每小時幾點：高度 ÷ 小時數，壓到下限就改捲動
        let hours = Double(endHour - startHour)
        var pointsPerHour = max(availableHeight, 0) / hours
        var scrolls = false
        if pointsPerHour < rules.minPointsPerHour {
            pointsPerHour = rules.minPointsPerHour
            scrolls = true
        }
        func y(_ date: Date) -> Double { (hourFraction(date) - Double(startHour)) * pointsPerHour }

        // 4. 重疊排欄：同一群（區間連在一起）裡貪婪找第一個空的欄
        var blocks: [Block] = []
        var pending: [(event: CalendarEvent, start: Date, end: Date, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd: Date?
        func flush() {
            let count = max(columnEnds.count, 1)
            for p in pending {
                blocks.append(Block(event: p.event, start: p.start, end: p.end,
                                    y: y(p.start), height: y(p.end) - y(p.start),
                                    column: p.column, columnCount: count))
            }
            pending = []
            columnEnds = []
        }
        for item in clipped {
            if let end = clusterEnd, item.start >= end { flush(); clusterEnd = nil }
            let column = columnEnds.firstIndex { $0 <= item.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(item.end) } else { columnEnds[column] = item.end }
            pending.append((item.event, item.start, item.end, column))
            clusterEnd = max(clusterEnd ?? item.end, item.end)
        }
        flush()

        // 5. 空檔：範圍頭尾與各群之間，夠長的才列
        let rangeStart = dayStart.addingTimeInterval(Double(startHour) * 3600)
        let rangeEnd = dayStart.addingTimeInterval(Double(endHour) * 3600)
        var gaps: [Gap] = []
        var cursor = rangeStart
        for busy in mergedIntervals(blocks) + [(start: rangeEnd, end: rangeEnd)] {
            let gapEnd = min(busy.start, rangeEnd)
            if gapEnd.timeIntervalSince(cursor) >= Double(rules.minGapMinutes) * 60 {
                gaps.append(Gap(start: cursor, end: gapEnd, y: y(cursor), height: y(gapEnd) - y(cursor)))
            }
            cursor = max(cursor, busy.end)
        }

        return DayTimelineLayout(day: dayStart, startHour: startHour, endHour: endHour,
                                 pointsPerHour: pointsPerHour, scrolls: scrolls,
                                 blocks: blocks, gaps: gaps, calendar: calendar)
    }

    // MARK: - 座標 ↔ 時間

    /// 某個時刻在軸上的位置（超出範圍就夾在兩端）。
    public func y(for date: Date) -> Double {
        let hours = date.timeIntervalSince(day) / 3600 - Double(startHour)
        return min(max(hours, 0), Double(endHour - startHour)) * pointsPerHour
    }

    /// 軸上某個位置對應的時刻，對齊到 `snapMinutes`（拖放用），夾在範圍內。
    public func date(at y: Double, snapMinutes: Int = 15) -> Date {
        let snap = Double(max(snapMinutes, 1)) * 60
        let seconds = (Double(startHour) + min(max(y, 0), totalHeight) / pointsPerHour) * 3600
        let snapped = (seconds / snap).rounded() * snap
        let clamped = min(max(snapped, Double(startHour) * 3600), Double(endHour) * 3600)
        return day.addingTimeInterval(clamped)
    }

    /// 這一天的結束（隔天 00:00），拖放時算結束時間不要超過它。
    public var dayEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    // MARK: - Equatable（Calendar 不比）

    public static func == (lhs: DayTimelineLayout, rhs: DayTimelineLayout) -> Bool {
        lhs.day == rhs.day && lhs.startHour == rhs.startHour && lhs.endHour == rhs.endHour
            && lhs.pointsPerHour == rhs.pointsPerHour && lhs.scrolls == rhs.scrolls
            && lhs.blocks == rhs.blocks && lhs.gaps == rhs.gaps
    }
}

/// 把區間合併成不重疊的幾段（已依開始時間排序）。
private func mergedIntervals(_ blocks: [DayTimelineLayout.Block]) -> [(start: Date, end: Date)] {
    var result: [(start: Date, end: Date)] = []
    for b in blocks.sorted(by: { $0.start < $1.start }) {
        if let last = result.last, b.start <= last.end {
            result[result.count - 1].end = max(last.end, b.end)
        } else {
            result.append((b.start, b.end))
        }
    }
    return result
}
