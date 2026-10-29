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
        !goal.trimmingCharacters(in: .whitespaces).isEmpty && sessionCount > 0 && dayCount() > 0
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
            rules: rules)
    }

    /// 跑排程：避開行事曆上已有的事件，偏好蕃茄鐘統計出的高產時段。
    @MainActor
    func schedule(eventStore: EventStore, pomodoro: PomodoroModel) -> PlanResult {
        let peak = pomodoro.productivityProfile(days: 60).peakWindowStart
        return PlanScheduler.schedule(request(peakHour: peak), existing: eventStore.events)
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
            TextField("每段名稱（選填）", text: $draft.sessionLabel)
        }

        Section {
            DatePicker("目標日", selection: $draft.targetDay, in: calendar.startOfDay(for: .now)..., displayedComponents: [.date])
            Toggle("目標日當天也排", isOn: $draft.includeTargetDay)
        } footer: {
            Text(rangeSummary)
        }

        Section("時間") {
            Stepper(value: $draft.totalHours, in: 0.5...300, step: 0.5) {
                HStack {
                    Text("總時數")
                    Spacer()
                    Text(verbatim: hoursText(draft.totalHours))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Picker("每段長度", selection: $draft.sessionMinutes) {
                ForEach(PlanDraft.sessionChoices, id: \.self) { m in
                    Text(verbatim: minutesText(m)).tag(m)
                }
            }
            Stepper(value: $draft.maxPerDay, in: 1...6) {
                HStack {
                    Text("每天最多")
                    Spacer()
                    Text("\(draft.maxPerDay) 段")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Picker("偏好時段", selection: $draft.preferred) {
                ForEach(PlanDraft.PreferredTime.allCases) { p in
                    Text(p.title).tag(p)
                }
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

/// 候選時段一列：序號、可調的開始時間（結束跟著平移）、撞到既有事件時的警告。
struct PlanSessionRow: View {
    @Binding var event: CalendarEvent
    let conflict: CalendarEvent?
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.body)
                    .lineLimit(1)
                DatePicker("開始", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .font(.caption)
                HStack(spacing: 6) {
                    Text(verbatim: timeRange)
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

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "M/d (E) HH:mm"
        let t = DateFormatter()
        t.dateFormat = "HH:mm"
        return "\(f.string(from: event.start))–\(t.string(from: event.end))"
    }
}

/// 預覽上方的一句總結（排了幾段、幾段排不進去）。
struct PlanPreviewSummary: View {
    let placed: Int
    let unplaced: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("共 \(placed) 段，可逐段調時間或刪掉。")
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
