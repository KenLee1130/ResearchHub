import Foundation

// 「規劃」：給一個目標（期中考、約會）、目標日、想投入的總時數與每段長度，
// 排出多段時段事件。純邏輯、只依賴 Foundation；寫檔由 HubStore 的 `EventStore` 負責。

/// 排時段時遵守的規則。
public struct PlanRules: Hashable, Sendable {
    /// 一天最早幾點開始（含）。預設 08:00。
    public var dayStartHour: Int = 8
    /// 一天最晚幾點結束（不含）。預設 23:00，也就是避開 23:00–08:00。
    public var dayEndHour: Int = 23
    /// 每天最多排幾段。
    public var maxSessionsPerDay: Int = 2
    /// 偏好的開始時刻（整點）：有就盡量貼近它，沒有就取當天最早可用的時段。
    /// 呼叫端通常填 `PomodoroModel.productivityProfile(days:).peakWindowStart`；資料不足傳 nil。
    public var preferredStartHour: Int?
    /// 與既有事件、同天其他時段之間至少留幾分鐘。
    public var gapMinutes: Int = 15
    /// 開始時刻對齊到幾分鐘。
    public var granularityMinutes: Int = 15
    /// 全天事件是否擋住整天（預設不擋：「截止日」這種全天標記不該吃掉一整天）。
    public var allDayBlocks: Bool = false

    public init(dayStartHour: Int = 8, dayEndHour: Int = 23, maxSessionsPerDay: Int = 2,
                preferredStartHour: Int? = nil, gapMinutes: Int = 15,
                granularityMinutes: Int = 15, allDayBlocks: Bool = false) {
        self.dayStartHour = dayStartHour
        self.dayEndHour = dayEndHour
        self.maxSessionsPerDay = maxSessionsPerDay
        self.preferredStartHour = preferredStartHour
        self.gapMinutes = gapMinutes
        self.granularityMinutes = granularityMinutes
        self.allDayBlocks = allDayBlocks
    }
}

/// 時段怎麼分布在日期範圍裡。
public enum PlanSpacing: Hashable, Sendable {
    /// 平均分配：段數少就等距挑日子，多就往目標日堆（預設）。
    case auto
    /// 每隔 n 天一段（n = 1 就是每天）；那天排不進就順延到下一個有空的日子。
    case everyDays(Int)
}

/// 一次規劃的輸入。
public struct PlanRequest: Hashable, Sendable {
    /// 目標名稱，例如「期中考」。
    public var goal: String
    /// 每段的稱呼，例如「複習」；空字串就只用目標名。標題會是「期中考 複習 1/5」。
    public var sessionLabel: String = ""
    public var planID: UUID = UUID()
    public var tagID: UUID?
    /// 可以排的第一天（取當天 0 點）。
    public var firstDay: Date
    /// 可以排的最後一天（含；取當天 0 點）。目標日當天不想排就傳目標日的前一天。
    public var lastDay: Date
    public var totalMinutes: Int
    public var sessionMinutes: Int
    public var rules: PlanRules = PlanRules()
    public var spacing: PlanSpacing = .auto

    public init(goal: String, sessionLabel: String = "", planID: UUID = UUID(), tagID: UUID? = nil,
                firstDay: Date, lastDay: Date, totalMinutes: Int, sessionMinutes: Int,
                rules: PlanRules = PlanRules(), spacing: PlanSpacing = .auto) {
        self.goal = goal
        self.sessionLabel = sessionLabel
        self.planID = planID
        self.tagID = tagID
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.totalMinutes = totalMinutes
        self.sessionMinutes = sessionMinutes
        self.rules = rules
        self.spacing = spacing
    }

    /// 要排幾段：總時數 ÷ 每段，不整除就多一段（最後一段比較短）。
    public var sessionCount: Int {
        guard totalMinutes > 0, sessionMinutes > 0 else { return 0 }
        return (totalMinutes + sessionMinutes - 1) / sessionMinutes
    }
}

/// 規劃的結果：排好的事件，加上排不進去的段數（日期範圍太短或已經太滿）。
public struct PlanResult: Hashable, Sendable {
    public var events: [CalendarEvent]
    public var totalSessions: Int
    public var unplacedCount: Int { totalSessions - events.count }

    public init(events: [CalendarEvent], totalSessions: Int) {
        self.events = events
        self.totalSessions = totalSessions
    }
}

public enum PlanScheduler {

    /// 排時段。`existing` 是行事曆上已有的事件（會避開）；`now` 之前的時間不排。
    ///
    /// 做法：先算每一天還有哪些空檔（扣掉既有事件、夜間、以及今天已經過去的時間），
    /// 再把 n 段平均分到有空的日子裡——段數比天數少就等距挑日子（第一段在第一天、
    /// 最後一段在最後一天），比天數多就每天輪流加一段，多出來的先堆在靠近目標日的那幾天。
    /// 同一天裡的時段盡量貼近 `rules.preferredStartHour`（高產時段）。
    public static func schedule(_ request: PlanRequest, existing: [CalendarEvent],
                                now: Date = .now, calendar: Calendar = .current) -> PlanResult {
        let total = request.sessionCount
        guard total > 0 else { return PlanResult(events: [], totalSessions: 0) }

        let firstDay = calendar.startOfDay(for: request.firstDay)
        let lastDay = calendar.startOfDay(for: request.lastDay)
        guard firstDay <= lastDay else { return PlanResult(events: [], totalSessions: total) }

        // 每一天各自能排出的時段（已依規則算好、依偏好排序）
        var days: [DaySlots] = []
        var cursor = firstDay
        while cursor <= lastDay {
            let slots = daySlots(on: cursor, request: request, existing: existing, now: now, calendar: calendar)
            if !slots.isEmpty { days.append(DaySlots(day: cursor, slots: slots)) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard !days.isEmpty else { return PlanResult(events: [], totalSessions: total) }

        var picked: [DateInterval] = []
        switch request.spacing {
        case .auto:
            // 每天分到幾段
            let quota = distribute(total, over: days.map(\.slots.count))
            for (i, day) in days.enumerated() {
                picked.append(contentsOf: day.slots.prefix(quota[i]))
            }
        case .everyDays(let step):
            picked = everyDays(max(step, 1), total: total, firstDay: firstDay, lastDay: lastDay,
                               days: days, calendar: calendar)
        }
        picked.sort { $0.start < $1.start }

        // 最後一段的長度是剩下的分鐘數
        let remainder = request.totalMinutes - (total - 1) * request.sessionMinutes
        var events: [CalendarEvent] = []
        for (index, slot) in picked.enumerated() {
            let number = index + 1
            let minutes = number == total ? remainder : request.sessionMinutes
            let end = slot.start.addingTimeInterval(Double(minutes) * 60)
            events.append(CalendarEvent(
                title: title(for: request, number: number, total: total),
                notes: notes(for: request, number: number, total: total),
                isAllDay: false,
                start: slot.start, end: end,
                tagID: request.tagID,
                planID: request.planID,
                planTitle: request.goal))
        }
        return PlanResult(events: events, totalSessions: total)
    }

    // MARK: - 標題與說明

    public static func title(for request: PlanRequest, number: Int, total: Int) -> String {
        let label = request.sessionLabel.trimmingCharacters(in: .whitespaces)
        let head = label.isEmpty ? request.goal : "\(request.goal) \(label)"
        return "\(head) \(number)/\(total)"
    }

    public static func notes(for request: PlanRequest, number: Int, total: Int) -> String {
        "「\(request.goal)」規劃的第 \(number) 段，共 \(total) 段"
            + "（合計 \(durationText(request.totalMinutes))，每段 \(durationText(request.sessionMinutes))）。"
    }

    static func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if m == 0 { return "\(h) 小時" }
        if h == 0 { return "\(m) 分鐘" }
        return "\(h) 小時 \(m) 分鐘"
    }

    /// 排一段時間裡的第一個可用時段（「自己指定」模式加一段時用）。
    public static func firstSlot(on day: Date, request: PlanRequest, existing: [CalendarEvent],
                                 now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        daySlots(on: day, request: request, existing: existing, now: now, calendar: calendar).first
    }

    // MARK: - 分配

    /// 每隔 `step` 天一段：第一天、第一天＋step、…；那天沒空就往後找，但不越過下一個節拍。
    static func everyDays(_ step: Int, total: Int, firstDay: Date, lastDay: Date,
                          days: [DaySlots], calendar: Calendar) -> [DateInterval] {
        var picked: [DateInterval] = []
        var beat = firstDay
        while picked.count < total, beat <= lastDay {
            let nextBeat = calendar.date(byAdding: .day, value: step, to: beat) ?? lastDay.addingTimeInterval(1)
            if let day = days.first(where: { $0.day >= beat && $0.day < nextBeat }),
               let slot = day.slots.first {
                picked.append(slot)
            }
            beat = nextBeat
        }
        return picked
    }

    /// 把 `total` 段分到各天，`capacity[i]` 是第 i 天最多能排幾段。
    /// 段數 ≤ 天數：等距挑日子（含頭尾）；段數 > 天數：先每天一段，再把多的從最後一天往前堆。
    static func distribute(_ total: Int, over capacity: [Int]) -> [Int] {
        let n = capacity.count
        var quota = Array(repeating: 0, count: n)
        guard n > 0, total > 0 else { return quota }

        var remaining = total
        if total < n {
            // 等距：第一段在第一天、最後一段在最後一天
            let indices: [Int] = total == 1
                ? [n - 1]
                : (0..<total).map { Int((Double($0) * Double(n - 1) / Double(total - 1)).rounded()) }
            for i in indices where quota[i] < capacity[i] {
                quota[i] += 1
                remaining -= 1
            }
        }
        // 輪流補：每一輪從最後一天往前，每天加一段（靠近目標日的先填滿）
        var progressed = true
        while remaining > 0 && progressed {
            progressed = false
            for i in stride(from: n - 1, through: 0, by: -1) where remaining > 0 && quota[i] < capacity[i] {
                quota[i] += 1
                remaining -= 1
                progressed = true
            }
        }
        return quota
    }

    // MARK: - 單日空檔

    struct DaySlots {
        let day: Date
        let slots: [DateInterval]
    }

    /// 某一天能排出的時段（最多 `maxSessionsPerDay` 段），依「貼近偏好時刻」的順序。
    static func daySlots(on day: Date, request: PlanRequest, existing: [CalendarEvent],
                         now: Date, calendar: Calendar) -> [DateInterval] {
        let rules = request.rules
        let length = request.sessionMinutes
        guard length > 0, rules.dayEndHour > rules.dayStartHour else { return [] }
        let dayStart = calendar.startOfDay(for: day)
        func time(_ minute: Int) -> Date { dayStart.addingTimeInterval(Double(minute) * 60) }
        func minute(_ date: Date) -> Int { Int(date.timeIntervalSince(dayStart) / 60) }

        let windowStart = rules.dayStartHour * 60
        let windowEnd = rules.dayEndHour * 60
        let gap = max(rules.gapMinutes, 0)

        // 忙碌區間（分鐘，含前後緩衝）
        var busy: [ClosedRange<Int>] = []
        let dayEndDate = time(24 * 60)
        for event in existing {
            if event.isAllDay && !rules.allDayBlocks { continue }
            guard event.start < dayEndDate, event.end > dayStart else { continue }
            let s = max(minute(event.start), 0) - gap
            let e = min(minute(event.end), 24 * 60) + gap
            busy.append(s...e)
        }
        // 今天：已經過去的時間不排（留一個緩衝）
        if now > dayStart {
            busy.append(Int.min...(minute(now) + gap))
        }

        var slots: [DateInterval] = []
        while slots.count < rules.maxSessionsPerDay {
            guard let start = bestStart(windowStart: windowStart, windowEnd: windowEnd, length: length,
                                        busy: busy, preferred: rules.preferredStartHour.map { $0 * 60 },
                                        granularity: max(rules.granularityMinutes, 1)) else { break }
            slots.append(DateInterval(start: time(start), duration: Double(length) * 60))
            busy.append((start - gap)...(start + length + gap))
        }
        return slots
    }

    /// 在 [windowStart, windowEnd) 裡找一個長 `length` 分鐘、不撞 `busy` 的開始時刻。
    /// 有偏好就挑離它最近的；沒有就挑最早的。
    static func bestStart(windowStart: Int, windowEnd: Int, length: Int, busy: [ClosedRange<Int>],
                          preferred: Int?, granularity: Int) -> Int? {
        // 空檔 = 窗口扣掉忙碌區間
        var free: [(Int, Int)] = [(windowStart, windowEnd)]
        for b in busy.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            var next: [(Int, Int)] = []
            for (s, e) in free {
                if b.upperBound <= s || b.lowerBound >= e { next.append((s, e)); continue }
                if b.lowerBound > s { next.append((s, b.lowerBound)) }
                if b.upperBound < e { next.append((b.upperBound, e)) }
            }
            free = next
        }
        // 每個空檔能放的開始時刻範圍 [lo, hi]
        var best: Int?
        var bestDistance = Int.max
        for (s, e) in free {
            let lo = roundUp(s, to: granularity)
            let hi = e - length
            guard lo <= hi else { continue }
            let candidate: Int
            if let preferred {
                candidate = min(max(preferred, lo), hi)
            } else {
                candidate = lo
            }
            let snapped = snap(candidate, lo: lo, hi: hi, granularity: granularity)
            let distance = preferred.map { abs(snapped - $0) } ?? snapped
            if distance < bestDistance { bestDistance = distance; best = snapped }
        }
        return best
    }

    private static func roundUp(_ value: Int, to granularity: Int) -> Int {
        let r = value % granularity
        return r == 0 ? value : value + (granularity - r)
    }

    /// 對齊到 granularity，但不能跑出 [lo, hi]（lo 已對齊；hi 不一定）。
    private static func snap(_ value: Int, lo: Int, hi: Int, granularity: Int) -> Int {
        let down = value - value % granularity
        if down >= lo { return down }
        return lo
    }
}
