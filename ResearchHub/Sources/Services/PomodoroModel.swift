import SwiftUI
import AppKit
import Combine
import UserNotifications

/// 一顆已完成的蕃茄鐘紀錄(存進 <root>/Pomodoro/pomodoro.json)。
struct PomodoroSession: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date          // 完成時間
    var minutes: Int        // 這顆的長度(分)
    var plan: String        // 開始前的計畫(這顆要做什麼)
    var done: String        // 完成後記下實際做了什麼
    // 新欄位;舊紀錄缺這個 key,靠 Optional 讓 Codable 解碼為 nil(向下相容)。
    var startedAt: Date? = nil   // 這顆實際開始倒數的時刻(用來算真實專注時段)
}

/// 統計區間。
enum PomodoroStatsPeriod: String, CaseIterable, Identifiable {
    case thisWeek, lastWeek, thisMonth, thisYear
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thisWeek: return "本週"
        case .lastWeek: return "上週"
        case .thisMonth: return "本月"
        case .thisYear: return "今年"
        }
    }
}

/// 蕃茄鐘：work → 短休息，循環滿 N 顆後長休息。
/// 時長與循環數可在設定中調整（UserDefaults）。每顆完成會寫進 JSON 紀錄檔，
/// 含「計畫 / 完成內容」，統計(今日/本週/上週/本月/今年)都從紀錄推導。
@MainActor
final class PomodoroModel: ObservableObject {

    enum Phase {
        case work, shortBreak, longBreak

        var label: String {
            switch self {
            case .work: return "專注中"
            case .shortBreak: return "短休息"
            case .longBreak: return "長休息"
            }
        }
    }

    /// 一段結束時要彈出的小視窗類型。
    enum CompletionPrompt: Identifiable, Equatable {
        case workDone                  // 工作結束
        case breakDone(wasLong: Bool)  // 休息結束
        var id: String {
            switch self {
            case .workDone: return "workDone"
            case .breakDone(let wasLong): return "breakDone-\(wasLong)"
            }
        }
    }

    // MARK: - Settings keys（與 SettingsView 的 @AppStorage 對應）

    enum SettingsKey {
        static let workMinutes = "settings.workMinutes"
        static let shortBreakMinutes = "settings.shortBreakMinutes"
        static let longBreakMinutes = "settings.longBreakMinutes"
        static let cycleLength = "settings.cycleLength"
        // 完成小視窗各欄位是否「必填」(預設只有「繼續休息要多久」必填)。
        static let requireContinueWorkMinutes = "settings.pomo.requireContinueWorkMinutes" // 工作完→繼續工作:還要工作多久
        static let requireLastWorkNote = "settings.pomo.requireLastWorkNote"               // 工作完→開始休息:上一輪做了什麼
        static let requirePlannedNote = "settings.pomo.requirePlannedNote"                 // 休息完→繼續工作:預計做什麼
        static let requireExtendBreakMinutes = "settings.pomo.requireExtendBreakMinutes"   // 休息完→繼續休息:還要休息多久
    }

    private enum CountKey {
        static let total = "pomodoro.total"
        static let todayCount = "pomodoro.todayCount"
        static let todayDate = "pomodoro.todayDate"
        static let history = "pomodoro.history" // [yyyy-MM-dd: count]
        static let focusLog = "pomodoro.focusLog" // ["yyyy-MM-dd HH:mm [kind] text"]
    }

    // MARK: - State

    @Published private(set) var phase: Phase = .work
    @Published private(set) var remaining: Int = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var todayCount = 0
    @Published private(set) var totalCount = 0
    /// 本循環已完成的 work 顆數（0..<cycleLength）
    @Published private(set) var cyclePosition = 0
    /// 非 nil 時，RootView 會彈出完成小視窗讓使用者決定下一步。
    @Published var completionPrompt: CompletionPrompt?

    /// 已完成的蕃茄鐘紀錄(JSON 持久化)。
    @Published private(set) var sessions: [PomodoroSession] = []
    /// 目前(這顆)work 的計畫;顯示在計時器上,完成時寫進紀錄。
    @Published var currentPlan: String = ""

    private var timer: Timer?
    private var hasStartedPhase = false
    private let defaults = UserDefaults.standard
    /// 紀錄檔位置由筆記根目錄決定。
    private var rootURL: URL?
    /// 剛完成、等使用者補「完成內容」的那筆 session 索引。
    private var pendingSessionIndex: Int?
    /// 這顆 work 的長度(分),完成時寫進紀錄。
    private var activeWorkMinutes = 25
    /// 這顆 work 實際開始倒數的時刻,完成時寫進 session.startedAt。
    private var activeStartedAt: Date?

    init() {
        remaining = duration(of: .work)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        Task {
            try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: - 紀錄檔（JSON）

    /// 由 RootView 在取得/變更根目錄時呼叫:載入紀錄並重算統計。
    func configure(rootURL: URL?) {
        guard rootURL?.path != self.rootURL?.path else { return }
        self.rootURL = rootURL
        loadSessions()
    }

    private var sessionsFileURL: URL? {
        rootURL?
            .appendingPathComponent("Pomodoro", isDirectory: true)
            .appendingPathComponent("pomodoro.json")
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func loadSessions() {
        if let url = sessionsFileURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? Self.jsonDecoder.decode([PomodoroSession].self, from: data) {
            sessions = decoded.sorted { $0.date < $1.date }
        } else {
            // 首次:把舊的 UserDefaults 每日計數遷移成「只有顆數」的紀錄,保住統計。
            sessions = migratedSessionsFromDefaults()
            saveSessions()
        }
        recomputeCounts()
    }

    private func saveSessions() {
        guard let url = sessionsFileURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.jsonEncoder.encode(sessions) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 從舊版 UserDefaults 的 [yyyy-MM-dd: count] 產生補登紀錄(無計畫/完成內容)。
    private func migratedSessionsFromDefaults() -> [PomodoroSession] {
        let history = historyDict()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let mins = storedMinutes(SettingsKey.workMinutes, default: 25)
        var result: [PomodoroSession] = []
        for (day, count) in history where count > 0 {
            guard let date = f.date(from: day) else { continue }
            let noon = Calendar.current.date(
                bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            for _ in 0..<count {
                result.append(PomodoroSession(date: noon, minutes: mins, plan: "", done: ""))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    private func recomputeCounts() {
        let cal = Calendar.current
        todayCount = sessions.filter { cal.isDateInToday($0.date) }.count
        totalCount = sessions.count
    }

    /// 新增一筆完成紀錄,並記住索引以便稍後補「完成內容」。
    private func appendSession(minutes: Int, plan: String) {
        let s = PomodoroSession(
            date: .now, minutes: minutes,
            plan: plan.trimmingCharacters(in: .whitespacesAndNewlines),
            done: "",
            startedAt: activeStartedAt)
        sessions.append(s)
        pendingSessionIndex = sessions.count - 1
        activeStartedAt = nil            // 這顆已收帳,下一顆重新記起始時刻
        saveSessions()
        recomputeCounts()
    }

    /// 把使用者填的「這顆完成了什麼」寫回剛完成那筆。
    func recordDone(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = pendingSessionIndex, sessions.indices.contains(i) else { return }
        sessions[i].done = t
        saveSessions()
    }

    // MARK: - Settings

    private func storedMinutes(_ key: String, default def: Int) -> Int {
        let v = defaults.integer(forKey: key)
        return v > 0 ? v : def
    }

    var cycleLength: Int {
        max(1, min(12, storedMinutes(SettingsKey.cycleLength, default: 4)))
    }

    private func duration(of phase: Phase) -> Int {
        switch phase {
        case .work: return storedMinutes(SettingsKey.workMinutes, default: 25) * 60
        case .shortBreak: return storedMinutes(SettingsKey.shortBreakMinutes, default: 5) * 60
        case .longBreak: return storedMinutes(SettingsKey.longBreakMinutes, default: 15) * 60
        }
    }

    /// 設定變更時，若目前的鐘還沒開始跑，立即套用新時長。
    @objc private func settingsChanged() {
        Task { @MainActor in
            if !isRunning && !hasStartedPhase {
                remaining = duration(of: phase)
            }
            if cyclePosition >= cycleLength {
                cyclePosition = 0
            }
        }
    }

    // MARK: - Controls

    var timeString: String {
        String(format: "%02d:%02d", remaining / 60, remaining % 60)
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    /// 重設目前這顆鐘（不動循環進度）。
    func reset() {
        pause()
        hasStartedPhase = false
        activeStartedAt = nil           // 這顆作廢,別把起始時刻帶到下一顆
        remaining = duration(of: phase)
    }

    /// 整個循環歸零。
    func resetCycle() {
        pause()
        hasStartedPhase = false
        activeStartedAt = nil
        phase = .work
        cyclePosition = 0
        remaining = duration(of: .work)
    }

    private func start() {
        // 全新開始一顆 work 時,記住這顆的長度(分)與起始時刻,完成時寫進紀錄。
        // 暫停後再按開始不會覆寫(activeStartedAt 已有值),startedAt 仍是第一次坐下的時間。
        if phase == .work && !hasStartedPhase {
            activeWorkMinutes = max(1, remaining / 60)
            if activeStartedAt == nil { activeStartedAt = .now }
        }
        isRunning = true
        hasStartedPhase = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    private func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        guard remaining == 0 else { return }

        switch phase {
        case .work:
            appendSession(minutes: activeWorkMinutes, plan: currentPlan)
            cyclePosition += 1
            // 不自動接著倒數休息 —— 先停下,通知,並彈出小視窗讓使用者決定。
            pause()
            hasStartedPhase = false
            // 預載下一段休息的長度(暫停狀態),讓畫面看起來合理;真正要做什麼由彈窗決定。
            phase = (cyclePosition >= cycleLength) ? .longBreak : .shortBreak
            remaining = duration(of: phase)
            notify("🍅 完成一顆蕃茄", "要繼續工作,還是開始休息?")
            present(.workDone)

        case .shortBreak:
            pause()
            hasStartedPhase = false
            phase = .work
            remaining = duration(of: .work)
            notify("☕ 休息結束", "要開始工作,還是再休息一下?")
            present(.breakDone(wasLong: false))

        case .longBreak:
            pause()
            hasStartedPhase = false
            phase = .work
            remaining = duration(of: .work)
            notify("🧘 長休息結束", "要開始工作,還是再休息一下?")
            present(.breakDone(wasLong: true))
        }
    }

    /// 把 app 帶到前景並要求彈出完成小視窗。
    private func present(_ prompt: CompletionPrompt) {
        NSApp.activate(ignoringOtherApps: true)
        completionPrompt = prompt
    }

    // MARK: - 完成小視窗的動作

    /// 工作完成 →「繼續工作」:記下這顆完成內容,再開一顆(可給分鐘數與下一顆計畫)。
    func continueWorkAfterWork(doneNote: String, extraMinutes: Int?, nextPlan: String) {
        recordDone(doneNote)
        completionPrompt = nil
        currentPlan = nextPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .work
        remaining = extraMinutes.map { max(1, $0) * 60 } ?? duration(of: .work)
        hasStartedPhase = false
        start()
    }

    /// 工作完成 →「開始休息」:記下這顆完成內容,開始休息。
    func startBreakAfterWork(doneNote: String) {
        recordDone(doneNote)
        completionPrompt = nil
        currentPlan = ""
        let isLong = cyclePosition >= cycleLength
        phase = isLong ? .longBreak : .shortBreak
        remaining = duration(of: phase)
        hasStartedPhase = false
        start()
    }

    /// 工作完成 →「稍後再說」:記下完成內容後關掉視窗,不啟動下一段(離開電腦本身就是休息)。
    /// 下一段預設成 work、循環滿了則歸零;之後使用者自己按開始。
    func dismissAfterWork(doneNote: String) {
        recordDone(doneNote)
        completionPrompt = nil
        currentPlan = ""
        if cyclePosition >= cycleLength { cyclePosition = 0 }
        phase = .work
        remaining = duration(of: .work)
        hasStartedPhase = false
        // 刻意不呼叫 start():維持暫停。
    }

    /// 休息結束 →「繼續工作」:可給下一顆計畫與分鐘數。長休息後循環歸零。
    func continueWorkAfterBreak(nextPlan: String, extraMinutes: Int?, wasLong: Bool) {
        completionPrompt = nil
        if wasLong { cyclePosition = 0 }
        currentPlan = nextPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .work
        remaining = extraMinutes.map { max(1, $0) * 60 } ?? duration(of: .work)
        hasStartedPhase = false
        start()
    }

    /// 休息結束 →「繼續休息」(還要休息幾分鐘;留空時用預設短休息長度)。
    func extendBreak(minutes: Int?) {
        completionPrompt = nil
        phase = .shortBreak
        remaining = minutes.map { max(1, $0) * 60 } ?? duration(of: .shortBreak)
        hasStartedPhase = false
        start()
    }

    /// 休息結束 →「稍後再說」:關掉視窗不啟動;之後自己開始工作。
    func dismissAfterBreak(wasLong: Bool) {
        completionPrompt = nil
        if wasLong { cyclePosition = 0 }
        phase = .work
        remaining = duration(of: .work)
        hasStartedPhase = false
    }

    /// 讀舊版歷史字典（相容 defaults 字串值，僅用於首次資料遷移）
    private func historyDict() -> [String: Int] {
        let raw = defaults.dictionary(forKey: CountKey.history) ?? [:]
        return raw.compactMapValues { value in
            if let i = value as? Int { return i }
            if let s = value as? String { return Int(s) }
            return nil
        }
    }

    // MARK: - 統計（全部由 sessions 推導）

    func count(on date: Date) -> Int {
        let cal = Calendar.current
        return sessions.filter { cal.isDate($0.date, inSameDayAs: date) }.count
    }

    private func count(in interval: DateInterval) -> Int {
        sessions.filter { interval.contains($0.date) }.count
    }

    /// 某統計區間的總顆數。
    func total(_ period: PomodoroStatsPeriod) -> Int {
        guard let interval = interval(for: period) else { return 0 }
        return count(in: interval)
    }

    /// 本週（週一開頭）每天的顆數（首頁原本就有用到）。
    func weekCounts(locale: Locale = .autoupdatingCurrent)
        -> [(label: String, count: Int, isToday: Bool)] {
        dayBars(weekMondayContaining: .now, locale: locale)
    }

    /// 統計卡的長條資料：週/上週→7 天、本月→當月每天、今年→12 個月。
    func statBars(_ period: PomodoroStatsPeriod, locale: Locale = .autoupdatingCurrent)
        -> [(label: String, count: Int, isNow: Bool)] {
        let cal = Calendar.current
        switch period {
        case .thisWeek:
            return dayBars(weekMondayContaining: .now, locale: locale)
                .map { (label: $0.label, count: $0.count, isNow: $0.isToday) }
        case .lastWeek:
            let ref = cal.date(byAdding: .day, value: -7, to: .now) ?? .now
            return dayBars(weekMondayContaining: ref, locale: locale)
                .map { (label: $0.label, count: $0.count, isNow: $0.isToday) }
        case .thisMonth:
            return monthDayBars(for: .now)
        case .thisYear:
            return yearMonthBars(for: .now)
        }
    }

    private func interval(for period: PomodoroStatsPeriod) -> DateInterval? {
        let cal = Calendar.current
        let now = Date.now
        switch period {
        case .thisWeek:
            guard let monday = mondayStart(containing: now) else { return nil }
            return DateInterval(start: monday, duration: 7 * 86_400)
        case .lastWeek:
            let ref = cal.date(byAdding: .day, value: -7, to: now) ?? now
            guard let monday = mondayStart(containing: ref) else { return nil }
            return DateInterval(start: monday, duration: 7 * 86_400)
        case .thisMonth:
            return cal.dateInterval(of: .month, for: now)
        case .thisYear:
            return cal.dateInterval(of: .year, for: now)
        }
    }

    private func mondayStart(containing date: Date) -> Date? {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: day) // 1 = Sun
        let mondayOffset = (weekday + 5) % 7
        return cal.date(byAdding: .day, value: -mondayOffset, to: day)
    }

    private func dayBars(weekMondayContaining date: Date, locale: Locale)
        -> [(label: String, count: Int, isToday: Bool)] {
        let cal = Calendar.current
        // 週一開頭的極短星期符號（中：一二三…；英：M T W…），跟隨 App 語言。
        var symCal = Calendar.current
        symCal.locale = locale
        let syms = symCal.veryShortWeekdaySymbols
        let labels = (0..<7).map { syms[($0 + 1) % 7] }
        guard let monday = mondayStart(containing: date) else { return [] }
        return (0..<7).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i, to: monday) else { return nil }
            return (label: labels[i], count: count(on: day), isToday: cal.isDateInToday(day))
        }
    }

    private func monthDayBars(for date: Date) -> [(label: String, count: Int, isNow: Bool)] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: date),
              let range = cal.range(of: .day, in: .month, for: date) else { return [] }
        return range.compactMap { d in
            guard let day = cal.date(byAdding: .day, value: d - 1, to: interval.start)
            else { return nil }
            let label = (d == 1 || d % 5 == 0) ? "\(d)" : ""   // 標稀疏一點,避免太擠
            return (label: label, count: count(on: day), isNow: cal.isDateInToday(day))
        }
    }

    private func yearMonthBars(for date: Date) -> [(label: String, count: Int, isNow: Bool)] {
        let cal = Calendar.current
        guard let yearStart = cal.dateInterval(of: .year, for: date)?.start else { return [] }
        let nowMonth = cal.component(.month, from: .now)
        let nowYear = cal.component(.year, from: .now)
        let refYear = cal.component(.year, from: date)
        return (0..<12).compactMap { m in
            guard let monthStart = cal.date(byAdding: .month, value: m, to: yearStart),
                  let monthInterval = cal.dateInterval(of: .month, for: monthStart)
            else { return nil }
            let isNow = (refYear == nowYear) && (m + 1 == nowMonth)
            return (label: "\(m + 1)", count: count(in: monthInterval), isNow: isNow)
        }
    }

    /// 最近 N 筆完成紀錄(新到舊),給首頁回顧用。
    func recentSessions(limit: Int = 6) -> [PomodoroSession] {
        Array(sessions.suffix(limit).reversed())
    }

    // MARK: - 生產力分析

    /// 依「開始工作的時刻」統計的生產力輪廓。
    struct ProductivityProfile {
        /// hourCounts[h] = h:00–h:59 開始且完成的顆數
        var hourCounts: [Int] = Array(repeating: 0, count: 24)
        /// weekdayCounts[i] = 週一(0)…週日(6) 的顆數
        var weekdayCounts: [Int] = Array(repeating: 0, count: 7)
        /// 納入統計的顆數（排除舊資料補登）
        var sampleCount = 0

        /// 顆數最多的連續 2 小時窗（回傳起始小時），樣本太少回 nil。
        var peakWindowStart: Int? {
            guard sampleCount >= 10 else { return nil }
            var best = 0, bestSum = -1
            for h in 0..<23 {
                let s = hourCounts[h] + hourCounts[h + 1]
                if s > bestSum { bestSum = s; best = h }
            }
            return bestSum > 0 ? best : nil
        }

        /// 顆數最多的星期（0 = 週一），樣本太少回 nil。
        var peakWeekday: Int? {
            guard sampleCount >= 10 else { return nil }
            guard let m = weekdayCounts.max(), m > 0 else { return nil }
            return weekdayCounts.firstIndex(of: m)
        }
    }

    /// 計畫 vs 實際的執行統計（排除舊資料補登）。
    struct ExecutionStats {
        var sampleCount = 0
        /// 有寫「計畫」的顆數
        var plannedCount = 0
        /// 計畫、完成都有寫的顆數
        var bothCount = 0
        /// 其中「完成 == 計畫」（照計畫做完）的顆數
        var followedCount = 0
        /// 每個工作日第一顆的開始時刻（當天 0 點起算的分鐘），供平均
        var firstStartMinutes: [Int] = []

        /// 照計畫率：計畫和完成都有寫的顆之中，實際做的就是計畫的比例
        var followRate: Double? {
            bothCount >= 5 ? Double(followedCount) / Double(bothCount) : nil
        }
        /// 有計畫率
        var planRate: Double? {
            sampleCount >= 5 ? Double(plannedCount) / Double(sampleCount) : nil
        }
        /// 平均第一顆開始時刻
        var averageFirstStart: (hour: Int, minute: Int)? {
            guard firstStartMinutes.count >= 3 else { return nil }
            let avg = firstStartMinutes.reduce(0, +) / firstStartMinutes.count
            return (avg / 60, avg % 60)
        }
    }

    /// 最近 `days` 天的「計畫 vs 實際」統計。
    func executionStats(days: Int? = nil) -> ExecutionStats {
        let cal = Calendar.current
        var stats = ExecutionStats()
        let cutoff = days.flatMap { cal.date(byAdding: .day, value: -$0, to: .now) }
        var firstOfDay: [Date: Int] = [:] // 當天 0 點 → 最早開始分鐘

        for s in sessions {
            if let cutoff, s.date < cutoff { continue }
            if s.startedAt == nil && s.plan.isEmpty && s.done.isEmpty {
                let c = cal.dateComponents([.hour, .minute, .second], from: s.date)
                if c.hour == 12 && c.minute == 0 && c.second == 0 { continue } // 補登資料
            }
            stats.sampleCount += 1
            let hasPlan = !s.plan.isEmpty
            let hasDone = !s.done.isEmpty
            if hasPlan { stats.plannedCount += 1 }
            if hasPlan && hasDone {
                stats.bothCount += 1
                if s.done.trimmingCharacters(in: .whitespacesAndNewlines)
                    == s.plan.trimmingCharacters(in: .whitespacesAndNewlines) {
                    stats.followedCount += 1
                }
            }
            let started = s.startedAt
                ?? s.date.addingTimeInterval(-Double(s.minutes) * 60)
            let day = cal.startOfDay(for: started)
            let minute = cal.component(.hour, from: started) * 60
                + cal.component(.minute, from: started)
            firstOfDay[day] = min(firstOfDay[day] ?? Int.max, minute)
        }
        stats.firstStartMinutes = Array(firstOfDay.values)
        return stats
    }

    /// 統計最近 `days` 天（nil = 全部）每小時／每星期幾的完成顆數。
    /// 舊版遷移補登的紀錄（無 startedAt、無內容、正午 12:00 整）不列入，
    /// 免得 12 點被灌水成假的生產力高峰。
    func productivityProfile(days: Int? = nil) -> ProductivityProfile {
        let cal = Calendar.current
        var profile = ProductivityProfile()
        let cutoff = days.flatMap { cal.date(byAdding: .day, value: -$0, to: .now) }

        for s in sessions {
            if let cutoff, s.date < cutoff { continue }
            if s.startedAt == nil && s.plan.isEmpty && s.done.isEmpty {
                let c = cal.dateComponents([.hour, .minute, .second], from: s.date)
                if c.hour == 12 && c.minute == 0 && c.second == 0 { continue } // 補登資料
            }
            // 用實際開始時刻；沒有就用完成時刻回推這顆的長度。
            let started = s.startedAt
                ?? s.date.addingTimeInterval(-Double(s.minutes) * 60)
            profile.hourCounts[cal.component(.hour, from: started)] += 1
            let weekday = cal.component(.weekday, from: started) // 1 = Sun
            profile.weekdayCounts[(weekday + 5) % 7] += 1
            profile.sampleCount += 1
        }
        return profile
    }

    private func notify(_ title: String, _ body: String) {
        NSSound.beep() // 即時音效（通知被拒絕時仍有提示）
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 讓通知在 app 位於前景時也顯示橫幅（macOS 預設前景時不顯示）。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - 浮動面板（置頂於所有 app 之上的玻璃小窗）

@MainActor
final class PomodoroPanelController {
    static let shared = PomodoroPanelController()
    private var panel: NSPanel?

    func toggle(pomodoro: PomodoroModel) {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        let hosting = NSHostingController(
            rootView: PomodoroPanelView().environmentObject(pomodoro))
        let panel = NSPanel(contentViewController: hosting)
        // 無邊框：關閉鈕做在面板內，避免透明標題列的點擊穿透問題。
        // 不用 .utilityWindow —— 它會在 app 失焦時自動把面板藏起來,正是「切桌面後消失」的元兇。
        panel.styleMask = [.nonactivatingPanel, .borderless]
        panel.level = .floating
        // 出現在所有桌面、跟著 Space 不動、全螢幕也在;切換桌面/切到別的 app 都不消失。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false   // 關鍵:app 不在前景時也保持顯示,直到使用者自己關
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }
}

struct PomodoroPanelView: View {
    @EnvironmentObject private var pomodoro: PomodoroModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Text(pomodoro.timeString)
                .font(.system(size: 36, weight: .medium, design: .monospaced))
            Text(pomodoro.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            PomodoroPlanRow()
                .frame(maxWidth: 200)
            HStack(spacing: 18) {
                Button {
                    pomodoro.toggle()
                } label: {
                    Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                Button {
                    pomodoro.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3)
                        .padding(5)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<pomodoro.cycleLength, id: \.self) { i in
                    Capsule()
                        .fill(i < pomodoro.cyclePosition
                              ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(height: 4)
                }
            }
            .frame(width: 120)
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay(alignment: .topTrailing) {
            // 滑過面板時顯示關閉鈕
            Button {
                PomodoroPanelController.shared.close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .padding(8)
    }
}

// MARK: - 「這顆要做什麼」計畫列（計時器上顯示 / 點擊編輯）

/// work 階段顯示目前這顆的計畫;點一下用 popover 編輯。其他階段不顯示。
struct PomodoroPlanRow: View {
    @EnvironmentObject private var pomodoro: PomodoroModel
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if pomodoro.phase == .work {
            Button {
                draft = pomodoro.currentPlan
                editing = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "target").font(.caption2)
                    Group {
                        if pomodoro.currentPlan.isEmpty {
                            Text("這顆要做什麼？")
                        } else {
                            Text(pomodoro.currentPlan)
                        }
                    }
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(pomodoro.currentPlan.isEmpty ? .tertiary : .secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("這顆蕃茄鐘要做什麼").font(.headline)
                    TextField("例如：推導 crossing equation", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .frame(width: 260)
                        .onSubmit(commit)
                    HStack {
                        Spacer()
                        Button("完成", action: commit).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(14)
            }
        }
    }

    private func commit() {
        pomodoro.currentPlan = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
    }
}

// MARK: - Sidebar mini view

struct PomodoroMiniView: View {
    @EnvironmentObject private var pomodoro: PomodoroModel

    var body: some View {
        VStack(spacing: 6) {
            Text(pomodoro.timeString)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
            Text(LocalizedStringKey(pomodoro.phase.label))
                .font(.caption)
                .foregroundStyle(.secondary)

            PomodoroPlanRow()

            HStack(spacing: 14) {
                Button {
                    pomodoro.toggle()
                } label: {
                    Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                Button {
                    pomodoro.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .help("重設目前這顆；右鍵可將整個循環歸零")
                .contextMenu {
                    Button("整個循環歸零") { pomodoro.resetCycle() }
                }
                Button {
                    PomodoroPanelController.shared.toggle(pomodoro: pomodoro)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .help("浮動面板（置頂於其他視窗）")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // 循環進度條
            HStack(spacing: 3) {
                ForEach(0..<pomodoro.cycleLength, id: \.self) { i in
                    Capsule()
                        .fill(segmentColor(i))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            Text("第 \(min(pomodoro.cyclePosition + 1, pomodoro.cycleLength)) / \(pomodoro.cycleLength) 顆 · 今日 \(pomodoro.todayCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private func segmentColor(_ index: Int) -> Color {
        if index < pomodoro.cyclePosition {
            return .accentColor
        }
        if index == pomodoro.cyclePosition && pomodoro.phase == .work && pomodoro.isRunning {
            return .accentColor.opacity(0.4)
        }
        return .primary.opacity(0.15)
    }
}
