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

    public init(id: UUID = UUID(), title: String, notes: String = "", isAllDay: Bool,
                start: Date, end: Date, tagID: UUID? = nil,
                planID: UUID? = nil, planTitle: String? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.isAllDay = isAllDay
        self.start = start; self.end = end; self.tagID = tagID
        self.planID = planID; self.planTitle = planTitle
    }

    /// 這個事件是某個規劃排出來的時段。
    public var isPlanned: Bool { planID != nil }
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, isAllDay, start, end, tagID, planID, planTitle
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
    }
}
