import SwiftUI
import HubStore
import HubCore

// 「規劃」表單：一個目標（期中考、約會）＋目標日＋總時數＋每段長度 → 多段時段事件。
// 欄位與預覽列 Mac 的 `PlanSheet` 與 iPhone 的 `MobilePlanSheet` 共用（做法同 `EventFormFields`）；
// 外殼（sheet、按鈕）各平台自己排。排程邏輯在 HubCore 的 `PlanScheduler`。

// MARK: - 草稿

struct PlanDraft {
    var goal = ""
    /// 每段的稱呼（複習、準備…），可空。
    var sessionLabel = ""
    var tagID: UUID?
    /// 目標日：考試那天、約會那天。預設不在當天排。
    var targetDay: Date
    var includeTargetDay = false
    var totalHours: Double = 10
    var sessionMinutes = 120
    var maxPerDay = 2
    var preferred: PreferredTime = .auto
    /// 時段怎麼排：自動分配、每隔幾天一段、或自己一段段指定。
    var mode: Mode = .auto
    /// `.every` 用：每隔幾天一段。
    var repeatDays = 2

    enum Mode: String, CaseIterable, Identifiable {
        case auto, every, custom
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .auto: "自動分配"
            case .every: "每隔幾天一段"
            case .custom: "自己指定"
            }
        }
    }

    enum PreferredTime: String, CaseIterable, Identifiable {
        case auto, morning, afternoon, evening, earliest
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .auto: "自動（高產時段）"
            case .morning: "上午（09:00 起）"
            case .afternoon: "下午（14:00 起）"
            case .evening: "晚上（19:00 起）"
            case .earliest: "越早越好"
            }
        }

        /// `peak` 是蕃茄鐘統計出的高產時段起點；資料不足是 nil → 退成「越早越好」。
        func hour(peak: Int?) -> Int? {
            switch self {
            case .auto: peak
            case .morning: 9
            case .afternoon: 14
            case .evening: 19
            case .earliest: nil
            }
        }
    }

    static let sessionChoices = [30, 45, 60, 90, 120, 150, 180, 240]

    /// 從行事曆上選的那天開始：目標日預設一週後。
    static func initial(near day: Date, tag: EventTag?, calendar: Calendar = .current) -> PlanDraft {
        let today = calendar.startOfDay(for: .now)
        let base = max(calendar.startOfDay(for: day), today)
        let target = calendar.date(byAdding: .day, value: 7, to: base) ?? base
        return PlanDraft(tagID: tag?.id, targetDay: target)
    }

    var totalMinutes: Int { Int((totalHours * 60).rounded()) }

    var sessionCount: Int {
        guard totalMinutes > 0, sessionMinutes > 0 else { return 0 }
        return (totalMinutes + sessionMinutes - 1) / sessionMinutes
    }

    func firstDay(calendar: Calendar = .current) -> Date { calendar.startOfDay(for: .now) }

    func lastDay(calendar: Calendar = .current) -> Date {
        let target = calendar.startOfDay(for: targetDay)
        if includeTargetDay { return target }
        return calendar.date(byAdding: .day, value: -1, to: target) ?? target
    }

    /// 可排的天數（今天到最後一天，含）。0 代表目標日已經過了。
    func dayCount(calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day], from: firstDay(calendar: calendar), to: lastDay(calendar: calendar)).day ?? -1
        return max(days + 1, 0)
    }

    var isValid: Bool {
        let hasGoal = !goal.trimmingCharacters(in: .whitespaces).isEmpty
        if mode == .custom { return hasGoal && sessionMinutes > 0 && dayCount() > 0 }
        return hasGoal && sessionCount > 0 && dayCount() > 0
    }

    func request(peakHour: Int?, planID: UUID = UUID(), calendar: Calendar = .current) -> PlanRequest {
        var rules = PlanRules()
        rules.maxSessionsPerDay = maxPerDay
        rules.preferredStartHour = preferred.hour(peak: peakHour)
        return PlanRequest(
            goal: goal.trimmingCharacters(in: .whitespaces),
            sessionLabel: sessionLabel,
            planID: planID,
            tagID: tagID,
            firstDay: firstDay(calendar: calendar),
            lastDay: lastDay(calendar: calendar),
            totalMinutes: totalMinutes,
            sessionMinutes: sessionMinutes,
            rules: rules,
            spacing: mode == .every ? .everyDays(max(repeatDays, 1)) : .auto)
    }

    /// 跑排程：避開行事曆上已有的事件，偏好蕃茄鐘統計出的高產時段。
    @MainActor
    func schedule(eventStore: EventStore, pomodoro: PomodoroModel) -> PlanResult {
        let peak = pomodoro.productivityProfile(days: 60).peakWindowStart
        if mode == .custom {
            // 自己指定：先給一段當起點，之後用「加一段」逐段加
            var events: [CalendarEvent] = []
            events.append(newSession(after: events, existing: eventStore.events, peakHour: peak))
            return PlanResult(events: events, totalSessions: events.count)
        }
        return PlanScheduler.schedule(request(peakHour: peak), existing: eventStore.events)
    }

    /// 「加一段」：放在目前最後一段的隔天（沒有就今天），挑那天第一個空檔；
    /// 一路到目標日都沒空就放在隔天的偏好時刻，讓使用者自己調。
    func newSession(after events: [CalendarEvent], existing: [CalendarEvent], peakHour: Int?,
                    calendar: Calendar = .current) -> CalendarEvent {
        let request = request(peakHour: peakHour, planID: events.first?.planID ?? UUID(), calendar: calendar)
        let lastDay = request.lastDay
        var day = events.map(\.start).max().map { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) ?? $0 }
            ?? request.firstDay
        if day > lastDay { day = lastDay }
        var cursor = day
        var slot: DateInterval?
        while slot == nil, cursor <= lastDay {
            slot = PlanScheduler.firstSlot(on: cursor, request: request, existing: existing + events, calendar: calendar)
            if slot == nil, let next = calendar.date(byAdding: .day, value: 1, to: cursor) { cursor = next } else { break }
        }
        let start = slot?.start
            ?? calendar.date(bySettingHour: request.rules.preferredStartHour ?? 9, minute: 0, second: 0, of: day) ?? day
        let end = start.addingTimeInterval(Double(sessionMinutes) * 60)
        let number = events.count + 1
        return CalendarEvent(
            title: PlanScheduler.title(for: request, number: number, total: number),
            notes: PlanScheduler.notes(for: request, number: number, total: number),
            isAllDay: false, start: start, end: end, tagID: tagID,
            planID: request.planID, planTitle: request.goal)
    }

    /// 寫進行事曆前：依時間排序、重編「目標 i/n」，有自己取名字的那段用自己的名字。
    static func finalize(_ events: [CalendarEvent], titles: [UUID: String], draft: PlanDraft) -> [CalendarEvent] {
        var sorted = events
        renumber(&sorted, draft: draft)
        return sorted.map { event in
            var e = event
            let custom = (titles[event.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { e.title = custom }
            return e
        }
    }

    /// 使用者在預覽裡刪掉幾段後，剩下的重新編號（標題「3/5」→「3/4」、說明裡的合計跟著改）。
    static func renumber(_ events: inout [CalendarEvent], draft: PlanDraft) {
        events.sort { $0.start < $1.start }
        let total = events.count
        guard total > 0 else { return }
        var request = draft.request(peakHour: nil, planID: events[0].planID ?? UUID())
        request.totalMinutes = events.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }
        for i in events.indices {
            events[i].title = PlanScheduler.title(for: request, number: i + 1, total: total)
            events[i].notes = PlanScheduler.notes(for: request, number: i + 1, total: total)
        }
    }

    /// 這一段（使用者可能手動調過時間）有沒有撞到行事曆上既有的事件。
    static func conflicts(_ event: CalendarEvent, existing: [CalendarEvent]) -> CalendarEvent? {
        existing.first { other in
            !other.isAllDay && other.id != event.id && other.start < event.end && other.end > event.start
        }
    }
}

// MARK: - 表單欄位

/// 放在 `Form` 裡用。
struct PlanFormFields: View {
    @Environment(EventStore.self) private var eventStore
    @Binding var draft: PlanDraft
    private let calendar = Calendar.current

    var body: some View {
        Section {
            TextField("目標", text: $draft.goal)
        } footer: {
            Text("每一段的名稱在預覽裡改；沒改的用「目標 1/5」這種編號。")
        }

        Section {
            DatePicker("目標日", selection: $draft.targetDay, in: calendar.startOfDay(for: .now)..., displayedComponents: [.date])
            Toggle("目標日當天也排", isOn: $draft.includeTargetDay)
        } footer: {
            Text(rangeSummary)
        }

        Section {
            Picker("排法", selection: $draft.mode) {
                ForEach(PlanDraft.Mode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            if draft.mode == .every {
                Stepper(value: $draft.repeatDays, in: 1...30) {
                    HStack {
                        Text("每隔")
                        Spacer()
                        Text("\(draft.repeatDays) 天一段")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            if draft.mode != .custom {
                Stepper(value: $draft.totalHours, in: 0.5...300, step: 0.5) {
                    HStack {
                        Text("總時數")
                        Spacer()
                        Text(verbatim: hoursText(draft.totalHours))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Picker("每段長度", selection: $draft.sessionMinutes) {
                ForEach(PlanDraft.sessionChoices, id: \.self) { m in
                    Text(verbatim: minutesText(m)).tag(m)
                }
            }
            if draft.mode == .auto {
                Stepper(value: $draft.maxPerDay, in: 1...6) {
                    HStack {
                        Text("每天最多")
                        Spacer()
                        Text("\(draft.maxPerDay) 段")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Picker("偏好時段", selection: $draft.preferred) {
                ForEach(PlanDraft.PreferredTime.allCases) { p in
                    Text(p.title).tag(p)
                }
            }
        } header: {
            Text("時間")
        } footer: {
            if draft.mode == .custom {
                Text("預覽裡用「加一段」逐段指定日期與時間，每段可以各自寫要做什麼。")
            }
        }

        Section {
            Picker("標籤", selection: $draft.tagID) {
                Text("無").tag(UUID?.none)
                ForEach(eventStore.tags) { tag in
                    HStack {
                        Circle().fill(tag.color).frame(width: 8, height: 8)
                        Text(tag.name)
                    }
                    .tag(Optional(tag.id))
                }
            }
        } footer: {
            Text("會避開既有事件與 23:00–08:00，每段之間至少留 15 分鐘。")
        }
    }

    private var rangeSummary: String {
        let days = draft.dayCount(calendar: calendar)
        guard days > 0 else { return L("目標日已經過了，請往後選。") }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("Md")
        let last = f.string(from: draft.lastDay(calendar: calendar))
        if draft.mode == .custom { return String(localized: "從今天到 \(last)，共 \(days) 天。") }
        return String(localized: "從今天到 \(last)，共 \(days) 天，會排 \(draft.sessionCount) 段。")
    }

    private func hoursText(_ h: Double) -> String {
        h == h.rounded() ? String(localized: "\(Int(h)) 小時") : String(localized: "\(h.formatted(.number.precision(.fractionLength(1)))) 小時")
    }

    private func minutesText(_ m: Int) -> String {
        if m % 60 == 0 { return String(localized: "\(m / 60) 小時") }
        if m < 60 { return String(localized: "\(m) 分鐘") }
        return String(localized: "\(m / 60) 小時 \(m % 60) 分鐘")
    }
}

// MARK: - 預覽列

/// 候選時段一列：序號、可改的名稱（空白＝用「目標 i/n」）、日期、開始／結束時間、撞到既有事件時的警告。
struct PlanSessionRow: View {
    let index: Int
    @Binding var event: CalendarEvent
    /// 使用者自己取的名稱；空白時顯示 `event.title`（自動編號）當提示
    @Binding var title: String
    let conflict: CalendarEvent?
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                TextField(event.title, text: $title)
                    .font(.body.weight(.medium))
                    .textFieldStyle(.plain)
                // 手機寬度塞不下三個選擇器：日期一行、開始–結束一行；Mac 一行排完
                #if os(iOS)
                DatePicker("日期", selection: startBinding, displayedComponents: [.date])
                    .labelsHidden()
                HStack(spacing: 6) {
                    DatePicker("開始", selection: startBinding, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                    Text(verbatim: "–").foregroundStyle(.secondary)
                    DatePicker("結束", selection: endBinding, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                    Spacer(minLength: 0)
                }
                #else
                // Mac：純文字欄、可以直接打；↑↓ 日期調一天、時間調 15 分鐘；24 小時制（SteppingDateFields.swift）
                HStack(spacing: 6) {
                    Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("前一天")
                    DayTextField(date: startBinding)
                    Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("後一天")
                    TimeTextField(date: startBinding)
                    Text(verbatim: "–").foregroundStyle(.secondary)
                    TimeTextField(date: endBinding)
                }
                .font(.caption)
                #endif
                HStack(spacing: 8) {
                    Text(verbatim: summary)
                    Picker(selection: repeatBinding) {
                        Text("不重複").tag(EventRepeat.Frequency?.none)
                        ForEach(EventRepeat.Frequency.allCases, id: \.self) { f in
                            Text(f.everyLabel).tag(Optional(f))
                        }
                    } label: {
                        Label(event.repeatRule?.label ?? L("不重複"), systemImage: "repeat")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    if let conflict {
                        Label("與「\(conflict.title)」重疊", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("刪掉這一段")
        }
        .padding(.vertical, 2)
    }

    private var minimumEnd: Date { event.start.addingTimeInterval(15 * 60) }

    /// 每段各自的重複：不重複／每天／每週／每月／每年（間隔 1、不設結束日；細節在事件編輯器改）
    private var repeatBinding: Binding<EventRepeat.Frequency?> {
        Binding(
            get: { event.repeatRule?.frequency },
            set: { f in event.repeatRule = f.map { EventRepeat(frequency: $0) } })
    }

    private func shiftDay(_ delta: Int) {
        guard let new = Calendar.current.date(byAdding: .day, value: delta, to: event.start) else { return }
        startBinding.wrappedValue = new
    }

    /// 改開始：結束跟著平移、長度不變。
    private var startBinding: Binding<Date> {
        Binding(
            get: { event.start },
            set: { new in
                let duration = event.end.timeIntervalSince(event.start)
                event.start = new
                event.end = new.addingTimeInterval(duration)
            })
    }

    /// 改結束：只動長度，至少 15 分鐘。
    private var endBinding: Binding<Date> {
        Binding(
            get: { event.end },
            set: { new in event.end = max(new, minimumEnd) })
    }

    private var summary: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MdE")
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        let h = minutes / 60, m = minutes % 60
        let length = m == 0 ? String(localized: "\(h) 小時")
            : h == 0 ? String(localized: "\(m) 分鐘") : String(localized: "\(h) 小時 \(m) 分鐘")
        return "\(f.string(from: event.start)) · \(length)"
    }
}

/// 預覽上方的一句總結（排了幾段、幾段排不進去）。
struct PlanPreviewSummary: View {
    let placed: Int
    let unplaced: Int
    var custom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(custom ? "共 \(placed) 段。用「加一段」再加；每段可以改名稱、日期與時間。"
                        : "共 \(placed) 段。每段可以改名稱、日期與時間，或刪掉；也可以再加。")
                .font(.callout)
            if unplaced > 0 {
                Label("有 \(unplaced) 段排不進去：日期太短或行事曆太滿，可以縮短每段、提高每天上限或改目標日。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 規劃小標（事件列用）

/// 「規劃 · 期中考」的小膠囊，放在事件列的標題旁。
struct PlanBadge: View {
    let title: String
    var color: Color = .gray

    var body: some View {
        Label(title, systemImage: "calendar.badge.clock")
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
