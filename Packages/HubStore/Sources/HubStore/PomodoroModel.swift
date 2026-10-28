import Foundation
import HubCore
import Observation
import Combine

/// 蕃茄鐘要用到的系統服務（推播、提示音、把 app 帶到前景、app 結束前的通知）：
/// 這些是 UserNotifications／AppKit／UIKit，由 app 實作、建構時注入，HubStore 不碰。
@MainActor
public protocol PomodoroSystem: AnyObject {
    /// app 即將結束時呼叫 handler（存計時器快照）
    func observeTermination(_ handler: @escaping @MainActor () -> Void)
    /// 要求推播權限（並掛上前景也顯示橫幅的 delegate）
    func requestNotificationPermission()
    /// 預約 `seconds` 秒後的推播（同 id 會覆蓋）
    func scheduleNotification(id: String, title: String, body: String, after seconds: Int)
    func cancelNotification(id: String)
    /// 立刻推播（含即時提示音）
    func notify(title: String, body: String)
    /// 把 app 帶到前景（完成小視窗要彈出來）
    func bringToFront()
}

/// 一顆已完成的蕃茄鐘紀錄(存進 <root>/Pomodoro/pomodoro.json)。
public struct PomodoroSession: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var date: Date          // 完成時間
    public var minutes: Int        // 這顆的長度(分)
    public var plan: String        // 開始前的計畫(這顆要做什麼)
    public var done: String        // 完成後記下實際做了什麼
    // 新欄位;舊紀錄缺這個 key,靠 Optional 讓 Codable 解碼為 nil(向下相容)。
    public var startedAt: Date? = nil   // 這顆實際開始倒數的時刻(用來算真實專注時段)
}

/// 統計區間。
public enum PomodoroStatsPeriod: String, CaseIterable, Identifiable {
    case thisWeek, lastWeek, thisMonth, thisYear
    public var id: String { rawValue }
    public var label: String {
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
@Observable
public final class PomodoroModel {

    public enum Phase: String {
        case work, shortBreak, longBreak

        public var label: String {
            switch self {
            case .work: return "專注中"
            case .shortBreak: return "短休息"
            case .longBreak: return "長休息"
            }
        }
    }

    /// 一段結束時要彈出的小視窗類型。
    public enum CompletionPrompt: Identifiable, Equatable {
        case workDone                  // 工作結束
        case breakDone(wasLong: Bool)  // 休息結束
        public var id: String {
            switch self {
            case .workDone: return "workDone"
            case .breakDone(let wasLong): return "breakDone-\(wasLong)"
            }
        }
    }

    // MARK: - Settings keys（與 SettingsView 的 @AppStorage 對應）

    public enum SettingsKey {
        public static let workMinutes = "settings.workMinutes"
        public static let shortBreakMinutes = "settings.shortBreakMinutes"
        public static let longBreakMinutes = "settings.longBreakMinutes"
        public static let cycleLength = "settings.cycleLength"
        // 完成小視窗各欄位是否「必填」(預設只有「繼續休息要多久」必填)。
        public static let requireContinueWorkMinutes = "settings.pomo.requireContinueWorkMinutes" // 工作完→繼續工作:還要工作多久
        public static let requireLastWorkNote = "settings.pomo.requireLastWorkNote"               // 工作完→開始休息:上一輪做了什麼
        public static let requirePlannedNote = "settings.pomo.requirePlannedNote"                 // 休息完→繼續工作:預計做什麼
        public static let requireExtendBreakMinutes = "settings.pomo.requireExtendBreakMinutes"   // 休息完→繼續休息:還要休息多久
    }

    private enum CountKey {
        static let total = "pomodoro.total"
        static let todayCount = "pomodoro.todayCount"
        static let todayDate = "pomodoro.todayDate"
        static let history = "pomodoro.history" // [yyyy-MM-dd: count]
        static let focusLog = "pomodoro.focusLog" // ["yyyy-MM-dd HH:mm [kind] text"]
        static let savedTimer = "pomodoro.savedTimer" // 重啟續跑用的計時器快照
    }

    // MARK: - State

    public private(set) var phase: Phase = .work
    /// 每秒跳動的倒數獨立放在 clock。PomodoroModel 是 ObservableObject，任何
    /// 一變，所有觀察者（根畫面、首頁、日記…共 8 個）整個 body 重算；
    /// 以前 remaining 放在這裡，蕃茄鐘一跑整個 app 就每秒全部重畫——打字卡頓、
    /// 背景也吃掉 50% CPU（系統有 cpu_resource 報告）。現在只有真的顯示倒數的
    /// PomodoroCountdownText 觀察 clock。
    public let clock = PomodoroClock()
    public private(set) var remaining: Int {
        get { clock.remaining }
        set { if clock.remaining != newValue { clock.remaining = newValue } }
    }
    public private(set) var isRunning = false
    public private(set) var todayCount = 0
    public private(set) var totalCount = 0
    /// 本循環已完成的 work 顆數（0..<cycleLength）
    public private(set) var cyclePosition = 0
    /// 非 nil 時，RootView 會彈出完成小視窗讓使用者決定下一步。
    public var completionPrompt: CompletionPrompt?

    /// 已完成的蕃茄鐘紀錄(JSON 持久化)。
    public private(set) var sessions: [PomodoroSession] = [] {
        didSet { dayCounts = nil }
    }
    /// 每天幾顆（startOfDay → 顆數）。統計圖每次重畫會問幾十次「某天幾顆」，
    /// 以前每問一次就把幾百筆紀錄全掃一遍做日曆比較，首頁重畫一次要 20–40 毫秒。
    @ObservationIgnored private var dayCounts: [Date: Int]?
    /// 目前(這顆)work 的計畫;顯示在計時器上,完成時寫進紀錄。
    public var currentPlan: String = ""

    private var timer: Timer?
    private var hasStartedPhase = false
    private let defaults = UserDefaults.standard
    /// 紀錄檔位置由筆記根目錄決定。
    private var rootURL: URL?
    /// 剛完成、等使用者補「完成內容」的那筆 session（用 id：重讀檔案後索引會變）。
    private var pendingSessionID: UUID?
    /// pomodoro.json 已確實讀到（或確定不存在）。iCloud 還沒下載完時是 false，這時不能存檔。
    private var sessionsReady = false
    /// 檔案還沒下載完時就有新紀錄：等檔案到了以 id 合併後再存
    private var editedWhileNotReady = false
    private var libraryObserver: AnyCancellable?
    /// 這顆 work 的長度(分),完成時寫進紀錄。
    private var activeWorkMinutes = 25
    /// 這顆 work 實際開始倒數的時刻,完成時寫進 session.startedAt。
    private var activeStartedAt: Date?

    private let librarySync: LibrarySync
    private let readingGate: ReadingGateStore
    private let system: PomodoroSystem

    public init(librarySync: LibrarySync, readingGate: ReadingGateStore, system: PomodoroSystem) {
        self.librarySync = librarySync
        self.readingGate = readingGate
        self.system = system
        remaining = duration(of: .work)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        // app 結束前把計時器快照存起來，重啟後續跑
        system.observeTermination { [weak self] in self?.saveTimerState() }
        system.requestNotificationPermission()

        restoreTimerState()
    }

    // MARK: - 計時器快照（重啟 app 後續跑）

    /// 存下目前計時器的完整狀態。正在跑的靠 phaseEndAt（結束時刻）還原，
    /// 所以重啟耗掉的時間也會正確扣掉。
    private func saveTimerState() {
        var d: [String: Any] = [
            "phase": phase.rawValue,
            "remaining": remaining,
            "isRunning": isRunning,
            "hasStartedPhase": hasStartedPhase,
            "cyclePosition": cyclePosition,
            "currentPlan": currentPlan,
            "activeWorkMinutes": activeWorkMinutes,
        ]
        d["phaseEndAt"] = phaseEndAt?.timeIntervalSince1970 ?? 0
        d["activeStartedAt"] = activeStartedAt?.timeIntervalSince1970 ?? 0
        defaults.set(d, forKey: CountKey.savedTimer)
        writeFocusState()
    }

    /// 把「現在是否在專注」寫進 .hub/focus_state.json，讓手機端的閱讀關卡讀得到
    /// （計時狀態本身在 UserDefaults，是本機的，跨不到 iPhone）。
    /// 一併帶上這顆的計畫，關卡跳出來時可以提醒使用者現在該做什麼。
    private func writeFocusState() {
        let state = GateFocusState(
            pomodoroActive: isRunning,
            phase: phase.rawValue,
            phaseEndAt: phaseEndAt,
            manualGate: defaults.bool(forKey: "gate.manualGate"),
            plan: currentPlan,
            pomoIndex: min(cyclePosition + 1, cycleLength),
            pomoTotal: cycleLength,
            updatedAt: .now)
        readingGate.writeFocusState(state)
    }

    /// 設定裡的「專注模式」手動開關（不靠蕃茄鐘也能啟用手機端關卡）。
    public var manualGate: Bool {
        get { defaults.bool(forKey: "gate.manualGate") }
        set {
            defaults.set(newValue, forKey: "gate.manualGate")
            writeFocusState()
        }
    }

    /// 啟動時還原快照。原本在跑 → 依結束時刻回推剩餘秒數接著跑；
    /// 重啟期間就到期的，一秒內走正常完成流程（彈完成小視窗、記錄照寫）。
    private func restoreTimerState() {
        guard let d = defaults.dictionary(forKey: CountKey.savedTimer),
              let raw = d["phase"] as? String,
              let savedPhase = Phase(rawValue: raw) else { return }
        phase = savedPhase
        cyclePosition = d["cyclePosition"] as? Int ?? 0
        currentPlan = d["currentPlan"] as? String ?? ""
        hasStartedPhase = d["hasStartedPhase"] as? Bool ?? false
        activeWorkMinutes = d["activeWorkMinutes"] as? Int ?? 25
        if let t = d["activeStartedAt"] as? Double, t > 0 {
            activeStartedAt = Date(timeIntervalSince1970: t)
        }
        let wasRunning = d["isRunning"] as? Bool ?? false
        if wasRunning, let end = d["phaseEndAt"] as? Double, end > 0 {
            remaining = max(0, Int(
                Date(timeIntervalSince1970: end).timeIntervalSinceNow.rounded(.up)))
            start()
        } else {
            remaining = d["remaining"] as? Int ?? duration(of: savedPhase)
        }
    }

    // MARK: - 紀錄檔（JSON）

    /// 由 RootView 在取得/變更根目錄時呼叫:載入紀錄並重算統計。
    public func configure(rootURL: URL?) {
        guard rootURL?.path != self.rootURL?.path else { return }
        self.rootURL = rootURL
        sessionsReady = false
        editedWhileNotReady = false
        loadSessions()
        readingGate.configure(rootURL: rootURL)
        // 另一台裝置記了蕃茄鐘（或切回 app）→ 重讀
        libraryObserver = librarySync.changes
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, change.affects(self.sessionsFileURL) else { return }
                self.loadSessions()
            }
        #if os(macOS)
        writeFocusState()   // Mac 是狀態的來源；開 app 就先落地一次
        #endif
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

    /// 從磁碟重讀。新增紀錄前也會先呼叫，避免拿舊的記憶體內容蓋掉另一台裝置剛寫的。
    private func loadSessions() {
        guard let url = sessionsFileURL else { return }
        switch LibraryFileRead.read(url) {
        case .data(let data):
            guard let decoded = try? Self.jsonDecoder.decode([PomodoroSession].self, from: data)
            else {
                // 讀到一半的檔或壞檔：絕不能用「遷移紀錄」覆寫幾百筆歷史
                sessionsReady = false
                return
            }
            let disk = decoded.sorted { $0.date < $1.date }
            sessionsReady = true
            if editedWhileNotReady {
                editedWhileNotReady = false
                sessions = mergeByID(disk: disk, local: sessions).sorted { $0.date < $1.date }
                saveSessions()
            } else if disk != sessions {
                sessions = disk
            }
        case .missing:
            // 首次:把舊的 UserDefaults 每日計數遷移成「只有顆數」的紀錄,保住統計。
            let migrated = migratedSessionsFromDefaults()
            sessions = mergeByID(disk: migrated, local: editedWhileNotReady ? sessions : [])
                .sorted { $0.date < $1.date }
            sessionsReady = true
            editedWhileNotReady = false
            saveSessions()
        case .notDownloaded:
            sessionsReady = false
        }
        recomputeCounts()
    }

    private func saveSessions() {
        guard let url = sessionsFileURL else { return }
        guard sessionsReady else {
            // 雲端那份還沒下載到：現在寫會蓋掉整份歷史。先記著，檔案到了合併再存。
            editedWhileNotReady = true
            librarySync.syncNow()
            return
        }
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
        loadSessions()   // 另一台裝置可能剛記過一顆：先讀最新的再加
        sessions.append(s)
        pendingSessionID = s.id
        activeStartedAt = nil            // 這顆已收帳,下一顆重新記起始時刻
        saveSessions()
        recomputeCounts()
    }

    /// 把使用者填的「這顆完成了什麼」寫回剛完成那筆。
    public func recordDone(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        loadSessions()
        guard let id = pendingSessionID,
              let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].done = t
        saveSessions()
    }

    // MARK: - Settings

    private func storedMinutes(_ key: String, default def: Int) -> Int {
        let v = defaults.integer(forKey: key)
        return v > 0 ? v : def
    }

    public var cycleLength: Int {
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

    public var timeString: String { clock.timeString }

    public func toggle() {
        isRunning ? pause() : start()
    }

    /// 重設目前這顆鐘（不動循環進度）。
    public func reset() {
        pause()
        hasStartedPhase = false
        activeStartedAt = nil           // 這顆作廢,別把起始時刻帶到下一顆
        remaining = duration(of: phase)
        saveTimerState()
    }

    /// 整個循環歸零。
    public func resetCycle() {
        pause()
        hasStartedPhase = false
        activeStartedAt = nil
        phase = .work
        cyclePosition = 0
        remaining = duration(of: .work)
        saveTimerState()
    }

    /// 這一段倒數的結束時刻。倒數以它為準（而不是每秒 -1），
    /// 所以 app 進背景（iOS）或 Mac 睡眠後回來，時間仍然正確。
    private var phaseEndAt: Date?

    private func start() {
        // 全新開始一顆 work 時,記住這顆的長度(分)與起始時刻,完成時寫進紀錄。
        // 暫停後再按開始不會覆寫(activeStartedAt 已有值),startedAt 仍是第一次坐下的時間。
        if phase == .work && !hasStartedPhase {
            activeWorkMinutes = max(1, remaining / 60)
            if activeStartedAt == nil { activeStartedAt = .now }
        }
        isRunning = true
        hasStartedPhase = true
        phaseEndAt = Date.now.addingTimeInterval(TimeInterval(remaining))
        scheduleEndNotification()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        saveTimerState()
    }

    private func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        phaseEndAt = nil
        cancelEndNotification()
        saveTimerState()
    }

    // MARK: - 結束時刻的預約通知（app 不在前景／手機鎖屏時也會響）

    private static let endNotificationID = "pomodoro.phaseEnd"

    private func scheduleEndNotification() {
        cancelEndNotification()
        guard remaining > 1 else { return }
        let (title, body): (String, String)
        switch phase {
        case .work: (title, body) = ("🍅 完成一顆蕃茄", "要繼續工作,還是開始休息?")
        case .shortBreak: (title, body) = ("☕ 休息結束", "要開始工作,還是再休息一下?")
        case .longBreak: (title, body) = ("🧘 長休息結束", "要開始工作,還是再休息一下?")
        }
        system.scheduleNotification(id: Self.endNotificationID, title: title, body: body, after: remaining)
    }

    private func cancelEndNotification() {
        system.cancelNotification(id: Self.endNotificationID)
    }

    // MARK: - Tick

    private func tick() {
        if let end = phaseEndAt {
            // 以結束時刻回推,背景/睡眠回來會自動追上
            remaining = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        } else if remaining > 0 {
            remaining -= 1
        }
        guard remaining <= 0 else { return }
        phaseEndAt = nil

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
        saveTimerState()   // pause() 存的是切換前的狀態,這裡再存一次切換後的
    }

    /// 把 app 帶到前景並要求彈出完成小視窗。
    private func present(_ prompt: CompletionPrompt) {
        system.bringToFront()
        completionPrompt = prompt
    }

    // MARK: - 完成小視窗的動作

    /// 工作完成 →「繼續工作」:記下這顆完成內容,再開一顆(可給分鐘數與下一顆計畫)。
    public func continueWorkAfterWork(doneNote: String, extraMinutes: Int?, nextPlan: String) {
        recordDone(doneNote)
        completionPrompt = nil
        currentPlan = nextPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .work
        remaining = extraMinutes.map { max(1, $0) * 60 } ?? duration(of: .work)
        hasStartedPhase = false
        start()
    }

    /// 工作完成 →「開始休息」:記下這顆完成內容,開始休息。
    public func startBreakAfterWork(doneNote: String) {
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
    public func dismissAfterWork(doneNote: String) {
        recordDone(doneNote)
        completionPrompt = nil
        currentPlan = ""
        if cyclePosition >= cycleLength { cyclePosition = 0 }
        phase = .work
        remaining = duration(of: .work)
        hasStartedPhase = false
        // 刻意不呼叫 start():維持暫停。
        saveTimerState()
    }

    /// 休息結束 →「繼續工作」:可給下一顆計畫與分鐘數。長休息後循環歸零。
    public func continueWorkAfterBreak(nextPlan: String, extraMinutes: Int?, wasLong: Bool) {
        completionPrompt = nil
        if wasLong { cyclePosition = 0 }
        currentPlan = nextPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .work
        remaining = extraMinutes.map { max(1, $0) * 60 } ?? duration(of: .work)
        hasStartedPhase = false
        start()
    }

    /// 休息結束 →「繼續休息」(還要休息幾分鐘;留空時用預設短休息長度)。
    public func extendBreak(minutes: Int?) {
        completionPrompt = nil
        phase = .shortBreak
        remaining = minutes.map { max(1, $0) * 60 } ?? duration(of: .shortBreak)
        hasStartedPhase = false
        start()
    }

    /// 休息結束 →「稍後再說」:關掉視窗不啟動;之後自己開始工作。
    public func dismissAfterBreak(wasLong: Bool) {
        completionPrompt = nil
        if wasLong { cyclePosition = 0 }
        phase = .work
        remaining = duration(of: .work)
        hasStartedPhase = false
        saveTimerState()
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

    public func count(on date: Date) -> Int {
        let cal = Calendar.current
        if dayCounts == nil {
            var counts: [Date: Int] = [:]
            for s in sessions { counts[cal.startOfDay(for: s.date), default: 0] += 1 }
            dayCounts = counts
        }
        return dayCounts?[cal.startOfDay(for: date)] ?? 0
    }

    private func count(in interval: DateInterval) -> Int {
        sessions.filter { interval.contains($0.date) }.count
    }

    /// 某統計區間的總顆數。
    public func total(_ period: PomodoroStatsPeriod) -> Int {
        guard let interval = interval(for: period) else { return 0 }
        return count(in: interval)
    }

    /// 本週（週一開頭）每天的顆數（首頁原本就有用到）。
    public func weekCounts(locale: Locale = .autoupdatingCurrent)
        -> [(label: String, count: Int, isToday: Bool)] {
        dayBars(weekMondayContaining: .now, locale: locale)
    }

    /// 統計卡的長條資料：週/上週→7 天、本月→當月每天、今年→12 個月。
    public func statBars(_ period: PomodoroStatsPeriod, locale: Locale = .autoupdatingCurrent)
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
    public func recentSessions(limit: Int = 6) -> [PomodoroSession] {
        Array(sessions.suffix(limit).reversed())
    }

    // MARK: - 生產力分析

    /// 依「開始工作的時刻」統計的生產力輪廓。
    public struct ProductivityProfile {
        /// hourCounts[h] = h:00–h:59 開始且完成的顆數
        public var hourCounts: [Int] = Array(repeating: 0, count: 24)
        /// weekdayCounts[i] = 週一(0)…週日(6) 的顆數
        public var weekdayCounts: [Int] = Array(repeating: 0, count: 7)
        /// 納入統計的顆數（排除舊資料補登）
        public var sampleCount = 0

        /// 顆數最多的連續 2 小時窗（回傳起始小時），樣本太少回 nil。
        public var peakWindowStart: Int? {
            guard sampleCount >= 10 else { return nil }
            var best = 0, bestSum = -1
            for h in 0..<23 {
                let s = hourCounts[h] + hourCounts[h + 1]
                if s > bestSum { bestSum = s; best = h }
            }
            return bestSum > 0 ? best : nil
        }

        /// 顆數最多的星期（0 = 週一），樣本太少回 nil。
        public var peakWeekday: Int? {
            guard sampleCount >= 10 else { return nil }
            guard let m = weekdayCounts.max(), m > 0 else { return nil }
            return weekdayCounts.firstIndex(of: m)
        }
    }

    /// 計畫 vs 實際的執行統計（排除舊資料補登）。
    public struct ExecutionStats {
        public var sampleCount = 0
        /// 有寫「計畫」的顆數
        public var plannedCount = 0
        /// 計畫、完成都有寫的顆數
        public var bothCount = 0
        /// 其中「完成 == 計畫」（照計畫做完）的顆數
        public var followedCount = 0
        /// 每個工作日第一顆的開始時刻（當天 0 點起算的分鐘），供平均
        public var firstStartMinutes: [Int] = []

        /// 照計畫率：計畫和完成都有寫的顆之中，實際做的就是計畫的比例
        public var followRate: Double? {
            bothCount >= 5 ? Double(followedCount) / Double(bothCount) : nil
        }
        /// 有計畫率
        public var planRate: Double? {
            sampleCount >= 5 ? Double(plannedCount) / Double(sampleCount) : nil
        }
        /// 平均第一顆開始時刻
        public var averageFirstStart: (hour: Int, minute: Int)? {
            guard firstStartMinutes.count >= 3 else { return nil }
            let avg = firstStartMinutes.reduce(0, +) / firstStartMinutes.count
            return (avg / 60, avg % 60)
        }
    }

    /// 最近 `days` 天的「計畫 vs 實際」統計。
    public func executionStats(days: Int? = nil) -> ExecutionStats {
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
    public func productivityProfile(days: Int? = nil) -> ProductivityProfile {
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
        system.notify(title: title, body: body)
    }
}
