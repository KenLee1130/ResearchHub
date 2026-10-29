import Foundation

// 行事曆事件與標籤的資料型別，落地於 `.hub/events.json`（讀寫在 HubStore 的 `EventStore`）。
// 放在 HubCore 是因為 `PlanScheduler` 要直接產出事件；純 Codable、只依賴 Foundation。

public struct EventTag: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var colorHex: String

    public init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id; self.name = name; self.colorHex = colorHex
    }
}

/// 事件的重複規則：每天／每週／每月／每年，每 `interval` 次一次，可設結束日（含）。
/// 檔案裡只存第一次的 `start`／`end`＋這個規則，顯示時由 app 展開每一次的實例（id 相同、時間平移）。
public struct EventRepeat: Codable, Hashable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case daily, weekly, monthly, yearly
    }
    public var frequency: Frequency
    /// 每幾天／週／月／年一次，至少 1。
    public var interval: Int = 1
    /// 最後一次不晚於這天（取當天）；nil = 一直重複。
    public var until: Date?

    public init(frequency: Frequency, interval: Int = 1, until: Date? = nil) {
        self.frequency = frequency
        self.interval = max(interval, 1)
        self.until = until
    }

    private enum CodingKeys: String, CodingKey { case frequency, interval, until }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Frequency.self, forKey: .frequency)
        interval = max(try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1, 1)
        until = try c.decodeIfPresent(Date.self, forKey: .until)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frequency, forKey: .frequency)
        if interval != 1 { try c.encode(interval, forKey: .interval) }
        try c.encodeIfPresent(until, forKey: .until)
    }
}

public struct CalendarEvent: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    /// 詳細內容：這件事具體要做什麼。
    public var notes: String = ""
    public var isAllDay: Bool
    public var start: Date
    public var end: Date
    public var tagID: UUID?
    /// 屬於哪一個「規劃」（同一個目標排出的多段時段共用一個 id）；一般事件為 nil。
    public var planID: UUID?
    /// 規劃的目標名稱（例如「期中考」），讓事件改名後仍看得出屬於哪個目標。
    public var planTitle: String?
    /// 重複規則；nil = 只發生一次。檔案鍵是 `repeat`。
    public var repeatRule: EventRepeat?

    public init(id: UUID = UUID(), title: String, notes: String = "", isAllDay: Bool,
                start: Date, end: Date, tagID: UUID? = nil,
                planID: UUID? = nil, planTitle: String? = nil, repeatRule: EventRepeat? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.isAllDay = isAllDay
        self.start = start; self.end = end; self.tagID = tagID
        self.planID = planID; self.planTitle = planTitle; self.repeatRule = repeatRule
    }

    /// 這個事件是某個規劃排出來的時段。
    public var isPlanned: Bool { planID != nil }
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, isAllDay, start, end, tagID, planID, planTitle
        case repeatRule = "repeat"
    }

    /// 舊版 events.json 沒有 notes／planID／planTitle 欄位 → 解碼時補預設值。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isAllDay = try c.decode(Bool.self, forKey: .isAllDay)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        tagID = try c.decodeIfPresent(UUID.self, forKey: .tagID)
        planID = try c.decodeIfPresent(UUID.self, forKey: .planID)
        planTitle = try c.decodeIfPresent(String.self, forKey: .planTitle)
        // 認不得的重複規則（未來的新頻率）當成不重複，不要讓整個檔案解碼失敗
        repeatRule = try? c.decodeIfPresent(EventRepeat.self, forKey: .repeatRule)
    }

    /// 自己寫 encode：nil 的可選欄位不寫進檔案，沒用到規劃的 events.json 跟舊版一模一樣。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encode(isAllDay, forKey: .isAllDay)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(tagID, forKey: .tagID)
        try c.encodeIfPresent(planID, forKey: .planID)
        try c.encodeIfPresent(planTitle, forKey: .planTitle)
        try c.encodeIfPresent(repeatRule, forKey: .repeatRule)
    }
}

// MARK: - 重複的展開

extension CalendarEvent {
    /// 跨幾天（單日 = 0）。
    func spanDays(calendar: Calendar) -> Int {
        let s = calendar.startOfDay(for: start), e = calendar.startOfDay(for: end)
        return max(calendar.dateComponents([.day], from: s, to: e).day ?? 0, 0)
    }

    /// `day`（取當天）是不是某一次的第一天。
    func isOccurrenceStart(_ day: Date, calendar: Calendar) -> Bool {
        let first = calendar.startOfDay(for: start)
        let day = calendar.startOfDay(for: day)
        guard day >= first else { return false }
        guard let rule = repeatRule else { return day == first }
        if let until = rule.until, day > calendar.startOfDay(for: until) { return false }
        let n = max(rule.interval, 1)
        switch rule.frequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: first, to: day).day ?? 0
            return days % n == 0
        case .weekly:
            let days = calendar.dateComponents([.day], from: first, to: day).day ?? 0
            return days % 7 == 0 && (days / 7) % n == 0
        case .monthly:
            let a = calendar.dateComponents([.year, .month, .day], from: first)
            let b = calendar.dateComponents([.year, .month, .day], from: day)
            guard a.day == b.day else { return false }   // 31 號在小月自然跳過
            let months = (b.year! - a.year!) * 12 + (b.month! - a.month!)
            return months % n == 0
        case .yearly:
            let a = calendar.dateComponents([.year, .month, .day], from: first)
            let b = calendar.dateComponents([.year, .month, .day], from: day)
            guard a.month == b.month, a.day == b.day else { return false }
            return (b.year! - a.year!) % n == 0
        }
    }

    /// 這個事件在某天的實例（含重複與跨日）；那天沒有就 nil。實例 id 相同、`start`／`end` 平移。
    public func occurrence(on day: Date, calendar: Calendar = .current) -> CalendarEvent? {
        let day = calendar.startOfDay(for: day)
        let first = calendar.startOfDay(for: start)
        for back in 0...spanDays(calendar: calendar) {
            guard let candidate = calendar.date(byAdding: .day, value: -back, to: day),
                  isOccurrenceStart(candidate, calendar: calendar) else { continue }
            return shifted(toStartDay: candidate, from: first, calendar: calendar)
        }
        return nil
    }

    /// `from`…`to`（含，取當天）之間的全部實例，依開始時間排序；跨日的實例只出現一次。
    public func occurrences(from: Date, to: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        var result: [CalendarEvent] = []
        var seen = Set<Date>()
        var day = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        while day <= last {
            if let o = occurrence(on: day, calendar: calendar), !seen.contains(o.start) {
                seen.insert(o.start)
                result.append(o)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted { $0.start < $1.start }
    }

    private func shifted(toStartDay day: Date, from first: Date, calendar: Calendar) -> CalendarEvent {
        let days = calendar.dateComponents([.day], from: first, to: day).day ?? 0
        guard days != 0 else { return self }
        var copy = self
        copy.start = calendar.date(byAdding: .day, value: days, to: start) ?? start
        copy.end = calendar.date(byAdding: .day, value: days, to: end) ?? end
        return copy
    }
}
