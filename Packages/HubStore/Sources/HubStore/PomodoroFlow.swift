import Foundation

/// 一段時間（開始～結束）。無限模式的「非工作時段」、時間軸上的紅線都用它。
public struct PomodoroSpan: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var seconds: TimeInterval { max(end.timeIntervalSince(start), 0) }
}

/// 無限模式（正向計時）的狀態：開著就一直記，直到使用者按「結束」。
///
/// 畫面離開蕃茄鐘（切分頁、回桌面、鎖屏）或手動暫停的那段時間記成「非工作時間」，
/// 回來就接著記工作時間。全部以時刻記帳、不靠每秒累加，所以 app 被凍結在背景也算得對。
/// 純值型別、不碰 UserDefaults，方便測試。
public struct FlowTimer: Codable, Equatable, Sendable {
    public var startedAt: Date
    /// 已經結束的非工作時段
    public var awaySpans: [PomodoroSpan] = []
    /// 目前這段非工作時間從何時開始（nil = 正在工作）
    public var awaySince: Date?
    /// 畫面不在蕃茄鐘上
    public var offScreen = false
    /// 使用者按了暫停
    public var paused = false
    /// 這段記下的事（開始前寫的計畫是第一件；做到一半換事情就再記一件）
    public var items: [FlowItem] = []

    public init(startedAt: Date, plan: String = "") {
        self.startedAt = startedAt
        let text = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { items = [FlowItem(at: startedAt, text: text)] }
    }

    /// 現在在做的事（最後記的那件）
    public var plan: String { items.last?.text ?? "" }

    /// 寫進紀錄的「計畫」：每件一行（空的略過）
    public var planSummary: String {
        items.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 記下新的一件事。空字串、或跟現在這件一樣就不記，回傳 false。
    @discardableResult
    public mutating func record(_ text: String, at now: Date) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != plan else { return false }
        items.append(FlowItem(at: max(now, startedAt), text: t))
        return true
    }

    /// 改某一件的文字（打字中的空字串先留著，結束時才略過）
    public mutating func editItem(id: UUID, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text
    }

    public mutating func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
    }

    // 舊版存的是單一字串 `plan`（重啟續跑的快照）：讀得進來，轉成第一件
    private enum CodingKeys: String, CodingKey {
        case startedAt, awaySpans, awaySince, offScreen, paused, items, plan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        awaySpans = try c.decodeIfPresent([PomodoroSpan].self, forKey: .awaySpans) ?? []
        awaySince = try c.decodeIfPresent(Date.self, forKey: .awaySince)
        offScreen = try c.decodeIfPresent(Bool.self, forKey: .offScreen) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        if let items = try c.decodeIfPresent([FlowItem].self, forKey: .items) {
            self.items = items
        } else if let plan = try c.decodeIfPresent(String.self, forKey: .plan), !plan.isEmpty {
            items = [FlowItem(at: startedAt, text: plan)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(awaySpans, forKey: .awaySpans)
        try c.encodeIfPresent(awaySince, forKey: .awaySince)
        try c.encode(offScreen, forKey: .offScreen)
        try c.encode(paused, forKey: .paused)
        try c.encode(items, forKey: .items)
    }

    public var isAway: Bool { offScreen || paused }

    /// 畫面在不在蕃茄鐘上。
    public mutating func setOffScreen(_ off: Bool, at now: Date) {
        offScreen = off
        update(at: now)
    }

    public mutating func setPaused(_ on: Bool, at now: Date) {
        paused = on
        update(at: now)
    }

    /// 依兩個旗標開／關目前的非工作時段。
    private mutating func update(at now: Date) {
        let now = max(now, startedAt)
        if isAway, awaySince == nil {
            awaySince = now
        } else if !isAway, let since = awaySince {
            if now > since { awaySpans.append(PomodoroSpan(start: since, end: now)) }
            awaySince = nil
        }
    }

    /// 到 `now` 為止所有非工作時段（含還沒結束的那段）。
    public func allAwaySpans(until now: Date) -> [PomodoroSpan] {
        var spans = awaySpans
        if let since = awaySince, now > since { spans.append(PomodoroSpan(start: since, end: now)) }
        return spans
    }

    public func totalSeconds(at now: Date) -> TimeInterval { max(now.timeIntervalSince(startedAt), 0) }

    public func awaySeconds(at now: Date) -> TimeInterval {
        allAwaySpans(until: now).reduce(0) { $0 + $1.seconds }
    }

    public func workSeconds(at now: Date) -> TimeInterval {
        max(totalSeconds(at: now) - awaySeconds(at: now), 0)
    }

    /// 工作時段＝開始到現在扣掉非工作時段（時間軸畫紅線用）。
    public func workSpans(until now: Date) -> [PomodoroSpan] {
        PomodoroSpan.complement(of: allAwaySpans(until: now),
                                within: PomodoroSpan(start: startedAt, end: max(now, startedAt)))
    }
}

/// 無限模式中記下的一件事。
public struct FlowItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// 記下的時刻
    public var at: Date
    public var text: String

    public init(id: UUID = UUID(), at: Date, text: String) {
        self.id = id
        self.at = at
        self.text = text
    }
}

/// 無限模式結束時給使用者看的總結。
public struct FlowSummary: Identifiable, Equatable, Sendable {
    public var id: Date { endedAt }
    public let startedAt: Date
    public let endedAt: Date
    public let workSeconds: TimeInterval
    public let awaySeconds: TimeInterval
    public let plan: String
    /// 寫進 pomodoro.json 的那筆（工作不到一分鐘就不記，nil）
    public let sessionID: UUID?
    /// 這段記下的事（空的已略過）
    public var items: [FlowItem] = []

    public var totalSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

extension PomodoroSpan {
    /// `range` 扣掉 `holes` 之後剩下的幾段（holes 可重疊、可超出範圍）。
    public static func complement(of holes: [PomodoroSpan], within range: PomodoroSpan) -> [PomodoroSpan] {
        var result: [PomodoroSpan] = []
        var cursor = range.start
        for hole in holes.sorted(by: { $0.start < $1.start }) {
            let s = max(hole.start, range.start), e = min(hole.end, range.end)
            guard e > s else { continue }
            if s > cursor { result.append(PomodoroSpan(start: cursor, end: s)) }
            cursor = max(cursor, e)
        }
        if range.end > cursor { result.append(PomodoroSpan(start: cursor, end: range.end)) }
        return result
    }

    /// 裁到 [from, to) 內；裁完沒長度回 nil。
    public func clipped(from: Date, to: Date) -> PomodoroSpan? {
        let s = max(start, from), e = min(end, to)
        return e > s ? PomodoroSpan(start: s, end: e) : nil
    }
}

// MARK: - 跨裝置的「正在專注」狀態

/// 每台裝置把自己「現在有沒有在專注」寫進 `Pomodoro/live-<裝置>.json`，
/// 另一台的時間軸讀它畫出還在進行中的紅線（完成的那幾顆走 pomodoro.json）。
/// 一台一個檔，兩台同時開也不會互相蓋掉。
public struct PomodoroLiveState: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case classic, flow }

    public var device: String
    /// 是否有一段工作正在進行（經典模式：work 階段倒數中；無限模式：開著）
    public var active: Bool
    public var kind: Kind
    public var startedAt: Date?
    /// 無限模式：已結束的非工作時段與目前這段的開始
    public var awaySpans: [PomodoroSpan] = []
    public var awaySince: Date?
    /// 經典模式：這段的結束時刻（過了就當作沒在跑）
    public var phaseEndAt: Date?
    /// 這段要做什麼（開始時填的計畫；舊檔沒有）
    public var plan: String?
    public var updatedAt: Date

    public init(device: String, active: Bool, kind: Kind, startedAt: Date?,
                awaySpans: [PomodoroSpan] = [], awaySince: Date? = nil,
                phaseEndAt: Date? = nil, plan: String? = nil, updatedAt: Date = .now) {
        self.device = device; self.active = active; self.kind = kind; self.startedAt = startedAt
        self.awaySpans = awaySpans; self.awaySince = awaySince
        self.phaseEndAt = phaseEndAt; self.plan = plan; self.updatedAt = updatedAt
    }

    /// 到 `now` 為止這段的工作時段；不在跑、或是殘留（另一台當掉沒收尾）的回空。
    public func workSpans(at now: Date) -> [PomodoroSpan] {
        guard active, let start = startedAt, start < now else { return [] }
        switch kind {
        case .classic:
            // 倒數早就該結束卻還寫著 active → 殘留
            guard let end = phaseEndAt, end > now.addingTimeInterval(-120) else { return [] }
            return [PomodoroSpan(start: start, end: min(now, end))]
        case .flow:
            // 無限模式超過 16 小時沒收尾，當作忘了關
            guard now.timeIntervalSince(start) < 16 * 3600 else { return [] }
            var holes = awaySpans
            if let since = awaySince, now > since { holes.append(PomodoroSpan(start: since, end: now)) }
            return PomodoroSpan.complement(of: holes, within: PomodoroSpan(start: start, end: now))
        }
    }
}

/// 時間軸上的一段紅線。
public struct FocusSpan: Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// 還在進行中（畫成延伸到現在、末端有圓點）
    public let live: Bool
    /// 來自哪筆完成的紀錄（點紅線看當時做了什麼、聽了什麼）
    public var sessionID: UUID? = nil
    /// 來自哪台裝置正在跑的那段
    public var liveState: PomodoroLiveState? = nil

    public init(start: Date, end: Date, live: Bool,
                sessionID: UUID? = nil, liveState: PomodoroLiveState? = nil) {
        self.start = start; self.end = end; self.live = live
        self.sessionID = sessionID; self.liveState = liveState
    }
}

extension PomodoroSession {
    /// 這筆紀錄的工作時段。無限模式扣掉非工作時段；舊紀錄沒有開始時刻就用完成時刻回推長度。
    /// 舊版遷移補登的（正午 12:00 整、沒內容、沒開始時刻）不是真的時段，回空。
    public func workSpans(calendar: Calendar = .current) -> [PomodoroSpan] {
        if startedAt == nil && plan.isEmpty && done.isEmpty {
            let c = calendar.dateComponents([.hour, .minute, .second], from: date)
            if c.hour == 12 && c.minute == 0 && c.second == 0 { return [] }
        }
        let start = startedAt ?? date.addingTimeInterval(-Double(minutes) * 60)
        guard date > start else { return [] }
        let range = PomodoroSpan(start: start, end: date)
        guard let away = awaySpans, !away.isEmpty else { return [range] }
        return PomodoroSpan.complement(of: away, within: range)
    }

    /// 是無限模式記下來的
    public var isFlow: Bool { kind == PomodoroLiveState.Kind.flow.rawValue }
}

/// 某天的紅線：完成的紀錄＋各裝置還在進行中的那段，裁到當天。
public func pomodoroFocusSpans(day: Date, sessions: [PomodoroSession], live: [PomodoroLiveState],
                               now: Date, calendar: Calendar = .current) -> [FocusSpan] {
    let dayStart = calendar.startOfDay(for: day)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
    var result: [FocusSpan] = []
    for s in sessions {
        // 粗篩：完成時刻離這天太遠的不看
        guard s.date > dayStart, s.date.timeIntervalSince(dayEnd) < 86_400 else { continue }
        for span in s.workSpans(calendar: calendar) {
            if let c = span.clipped(from: dayStart, to: dayEnd) {
                result.append(FocusSpan(start: c.start, end: c.end, live: false, sessionID: s.id))
            }
        }
    }
    // 接力中兩台跑的是同一段（同一個開始時刻）：只畫一次，以排在前面的（這台）為準
    var drawnFlows = Set<Date>()
    for state in live {
        if state.kind == .flow, state.active, let start = state.startedAt {
            guard drawnFlows.insert(start).inserted else { continue }
        }
        let spans = state.workSpans(at: now)
        for (i, span) in spans.enumerated() {
            if let c = span.clipped(from: dayStart, to: dayEnd) {
                // 最後一段延伸到現在的才算「進行中」
                let isLast = i == spans.count - 1 && span.end >= now.addingTimeInterval(-1)
                result.append(FocusSpan(start: c.start, end: c.end, live: isLast, liveState: state))
            }
        }
    }
    return result.sorted { $0.start < $1.start }
}

// MARK: - 無限模式接力（Mac ↔ iPhone 共用同一段）

/// `Pomodoro/flow.json`：正在跑的那段無限模式，兩台共用。
/// 一台按開始，另一台打開就接著同一段（同一個開始時刻、同一份記下的事）；
/// 任一台按結束，寫紀錄的是按的那台，另一台看到 `ended` 就收掉。
/// 同一段用 `timer.startedAt` 認。
public struct SharedFlow: Codable, Equatable, Sendable {
    public var timer: FlowTimer
    public var ended: Bool
    /// 各裝置現在在不在螢幕前；全部都離開才算非工作時間
    public var onScreen: [String: Bool]
    public var updatedBy: String
    public var updatedAt: Date

    public init(timer: FlowTimer, ended: Bool = false, onScreen: [String: Bool],
                updatedBy: String, updatedAt: Date = .now) {
        self.timer = timer; self.ended = ended; self.onScreen = onScreen
        self.updatedBy = updatedBy; self.updatedAt = updatedAt
    }

    /// 比內容（不比誰寫的、何時寫的）：內容一樣就不用再寫檔
    public func sameContent(as other: SharedFlow) -> Bool {
        timer == other.timer && ended == other.ended && onScreen == other.onScreen
    }
}

public enum FlowRelay {
    /// 另一台寫來的共用狀態，這台該怎麼做。
    public enum Action: Equatable, Sendable {
        case none
        /// 換成這份（接手另一台的那段，或同一段的最新內容）
        case adopt(FlowTimer, onScreen: [String: Bool])
        /// 另一台按了結束
        case end
    }

    /// 無限模式超過這麼久沒收尾，當作忘了關，不接手
    public static let staleAfter: TimeInterval = 16 * 3600

    /// - localUpdatedAt: 這台最後一次改這段的時刻；比它舊的（iCloud 晚到的）不套用，免得蓋回去
    public static func incoming(_ shared: SharedFlow, local: FlowTimer?, me: String,
                                localOffScreen: Bool, localUpdatedAt: Date?,
                                canAdopt: Bool, now: Date) -> Action {
        guard shared.updatedBy != me else { return .none }
        let same = local?.startedAt == shared.timer.startedAt
        if shared.ended { return same ? .end : .none }
        if same, let mine = localUpdatedAt, shared.updatedAt <= mine { return .none }
        guard now.timeIntervalSince(shared.timer.startedAt) < staleAfter else { return .none }
        guard same || (local == nil && canAdopt) else { return .none }
        var screens = shared.onScreen
        screens[me] = !localOffScreen
        var timer = shared.timer
        let away = !screens.values.contains(true)
        if timer.offScreen != away { timer.setOffScreen(away, at: now) }
        if same, timer == local, screens == shared.onScreen { return .none }
        return .adopt(timer, onScreen: screens)
    }
}
