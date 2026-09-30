import Foundation
import Observation
import Combine

/// 閱讀關卡（Reading Gate）：手機打開 IG / YouTube / Threads 等 app 時，
/// 由「捷徑」個人自動化導到 `researchhub://gate?app=<scheme>`；
/// 若關卡啟用中（蕃茄鐘工作階段，或手動開啟專注模式），
/// 就要先讀一篇 paper 的 abstract 並答對理解題才會放行回原本的 app。
///
/// 資料流（全部走 iCloud 資料夾，離線可用）：
///   • `.hub/focus_state.json`  — Mac 端蕃茄鐘寫入，手機端讀（判斷關卡要不要啟用）
///   • `.hub/claude/reading_gate.json` — Claude 預先從 Zotero 生成的題庫
///   • `.hub/claude/reading_gate_log.json` — 已通過紀錄（輪替用，兩邊都可寫）

// MARK: - 題庫資料結構

/// 一題理解題（單選）。
struct GateQuestion: Codable, Equatable {
    var q: String
    var options: [String]
    /// 正解在 options 裡的 index
    var answer: Int
    /// 答錯時顯示的說明（可省略）
    var explain: String?
}

/// 題庫裡的一篇 paper。
struct GatePaper: Codable, Equatable, Identifiable {
    /// 穩定 id：優先用 Zotero item key
    var id: String
    var title: String
    var authors: String?
    var year: String?
    var abstract: String
    var questions: [GateQuestion]
    /// 有值就在關卡畫面提供「在 Zotero 開啟」
    var zoteroKey: String?
}

struct GateBank: Codable {
    var updatedAt: Date?
    var papers: [GatePaper]
}

/// 已通過紀錄：paper id → 最後通過時間（輪替時優先挑最久沒讀的）。
struct GateLog: Codable {
    var passedAt: [String: Date] = [:]
    /// 累計通過次數（首頁之後可以拿來顯示成就）
    var totalPasses: Int = 0
}

// MARK: - 專注狀態（Mac 寫、手機讀）

/// `.hub/focus_state.json` 的內容。Mac 端蕃茄鐘每次狀態變動就覆寫一份，
/// 手機端讀它決定關卡要不要啟用（iCloud 同步通常數秒內到）。
struct GateFocusState: Codable {
    /// 蕃茄鐘正在跑
    var pomodoroActive: Bool = false
    /// 目前階段（work / shortBreak / longBreak）；只有 work 會啟用關卡
    var phase: String = "work"
    /// 這個階段的結束時刻——手機用它防「Mac 睡著沒寫收尾」的殘留狀態
    var phaseEndAt: Date?
    /// 使用者手動打開的專注模式（不靠蕃茄鐘）
    var manualGate: Bool = false
    /// 這顆蕃茄鐘開始前寫下的「這顆要做什麼」——關卡畫面用它把你拉回正事
    var plan: String = ""
    /// 今天第幾顆 / 一輪共幾顆（顯示用，缺就不顯示）
    var pomoIndex: Int?
    var pomoTotal: Int?
    var updatedAt: Date = .now

    /// 這個階段還剩多久（秒）；沒在跑或已過期回 nil。
    var remainingSeconds: Int? {
        guard pomodoroActive, let end = phaseEndAt else { return nil }
        let left = Int(end.timeIntervalSinceNow)
        return left > 0 ? left : nil
    }

    /// 這份狀態現在是否該啟用關卡。
    var gateActive: Bool {
        if manualGate { return true }
        guard pomodoroActive, phase == "work" else { return false }
        // 階段早該結束卻還寫著 active（Mac 睡著/當掉）→ 視為沒在跑，不要一直擋
        if let end = phaseEndAt, end < Date().addingTimeInterval(-300) { return false }
        return true
    }
}

// MARK: - Store

@MainActor
@Observable
final class ReadingGateStore {
    static let shared = ReadingGateStore()

    private(set) var bank = GateBank(updatedAt: nil, papers: [])
    /// 手機本機的專注模式開關（不必等 iCloud，立刻生效）
    var localManual: Bool {
        get { UserDefaults.standard.bool(forKey: "gate.localManual") }
        set { UserDefaults.standard.set(newValue, forKey: "gate.localManual") }
    }
    /// 通過後的寬限期分鐘數（這段時間內再打開那些 app 不會再攔）
    var graceMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "gate.graceMinutes")
            return v > 0 ? v : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: "gate.graceMinutes") }
    }

    private var rootURL: URL?
    private var log = GateLog()
    private var libraryObserver: AnyCancellable?

    private init() {
        // Mac 端 Claude 更新了題庫、或另一台裝置記了通過紀錄 → 重讀
        libraryObserver = NotificationCenter.default
            .publisher(for: .rhLibraryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }
                if LibrarySync.affects(note, self.bankURL) || LibrarySync.affects(note, self.logURL) {
                    self.reload()
                }
            }
    }

    func configure(rootURL: URL?) {
        guard rootURL?.path != self.rootURL?.path else { return }
        self.rootURL = rootURL
        reload()
    }

    // MARK: 路徑

    private var hubURL: URL? { rootURL?.appendingPathComponent(".hub", isDirectory: true) }
    private var claudeDirURL: URL? {
        hubURL?.appendingPathComponent("claude", isDirectory: true)
    }
    private var bankURL: URL? {
        claudeDirURL?.appendingPathComponent("reading_gate.json")
    }
    private var logURL: URL? {
        claudeDirURL?.appendingPathComponent("reading_gate_log.json")
    }
    private var focusURL: URL? {
        hubURL?.appendingPathComponent("focus_state.json")
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: 讀寫

    /// 重讀題庫與通過紀錄（iCloud 檔案可能還沒下載，safeRead 會回 nil，下次再試）。
    func reload() {
        if let url = bankURL, let s = FileSystemStore.safeRead(url),
           let data = s.data(using: .utf8),
           let b = try? Self.decoder.decode(GateBank.self, from: data) {
            bank = b
        }
        if let url = logURL, let s = FileSystemStore.safeRead(url),
           let data = s.data(using: .utf8),
           let l = try? Self.decoder.decode(GateLog.self, from: data) {
            log = l
        }
    }

    /// 目前的專注狀態（讀 Mac 寫下的檔案）。讀不到就當沒啟用。
    func focusState() -> GateFocusState {
        guard let url = focusURL, let s = FileSystemStore.safeRead(url),
              let data = s.data(using: .utf8),
              let st = try? Self.decoder.decode(GateFocusState.self, from: data)
        else { return GateFocusState() }
        return st
    }

    /// 關卡現在是否該擋：iCloud 來的狀態，或手機本機的開關。
    func isGateActive() -> Bool {
        localManual || focusState().gateActive
    }

    /// Mac 端：蕃茄鐘/手動開關變動時寫入狀態檔。
    func writeFocusState(_ state: GateFocusState) {
        guard let url = focusURL, let hub = hubURL else { return }
        try? FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: 寬限期

    private let graceKey = "gate.graceUntil"

    var graceUntil: Date? {
        let t = UserDefaults.standard.double(forKey: graceKey)
        guard t > 0 else { return nil }
        let d = Date(timeIntervalSince1970: t)
        return d > .now ? d : nil
    }

    /// 現在放行嗎？（關卡沒啟用，或還在寬限期內）
    func shouldPassThrough() -> Bool {
        if graceUntil != nil { return true }
        return !isGateActive()
    }

    private func startGrace() {
        UserDefaults.standard.set(
            Date().addingTimeInterval(Double(graceMinutes) * 60).timeIntervalSince1970,
            forKey: graceKey)
    }

    /// 手動結束寬限期（設定裡的「立刻恢復攔截」）。
    func clearGrace() {
        UserDefaults.standard.removeObject(forKey: graceKey)
    }

    // MARK: 選題

    /// 挑一篇要讀的：優先沒讀過的，其次最久沒讀的。題庫空的話回 nil。
    func nextPaper() -> GatePaper? {
        let candidates = bank.papers.filter { !$0.abstract.isEmpty && !$0.questions.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let unread = candidates.filter { log.passedAt[$0.id] == nil }
        if !unread.isEmpty { return unread.randomElement() }
        return candidates.min {
            (log.passedAt[$0.id] ?? .distantPast) < (log.passedAt[$1.id] ?? .distantPast)
        }
    }

    /// 通過一篇：記錄、開始寬限期。
    func recordPass(_ paper: GatePaper) {
        reload()   // 先讀另一台裝置的通過紀錄，別蓋掉
        log.passedAt[paper.id] = .now
        log.totalPasses += 1
        startGrace()
        guard let url = logURL, let dir = claudeDirURL,
              let data = try? Self.encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    var totalPasses: Int { log.totalPasses }
}

// MARK: - 黑名單 app 目錄

/// 一個可以被關卡攔截的 app。
/// iOS 不允許列舉手機上安裝了哪些 app（沒有公開 API，官方 FamilyActivityPicker
/// 需要拿不到的 family-controls entitlement），所以改用「內建目錄 + canOpenURL 偵測」：
/// 只把「你手機上真的有裝」的列給你勾。找不到的 app 可以自己新增（名稱 + URL scheme）。
struct GateApp: Codable, Equatable, Identifiable, Hashable {
    /// URL scheme（不含 "://"），同時當 id 用
    var scheme: String
    var name: String
    /// 使用者自己加的（可刪）
    var custom: Bool = false

    var id: String { scheme }
    var openURL: URL? { URL(string: "\(scheme)://") }
}

extension GateApp {
    /// 內建目錄：常見的「一滑就是一小時」類 app。
    /// 這些 scheme 必須同時列在 Info.plist 的 LSApplicationQueriesSchemes，
    /// canOpenURL 才查得到（iOS 上限 50 個）。
    static let catalog: [GateApp] = [
        .init(scheme: "instagram", name: "Instagram"),
        .init(scheme: "barcelona", name: "Threads"),
        .init(scheme: "youtube", name: "YouTube"),
        .init(scheme: "twitter", name: "X (Twitter)"),
        .init(scheme: "snssdk1128", name: "TikTok"),
        .init(scheme: "fb", name: "Facebook"),
        .init(scheme: "reddit", name: "Reddit"),
        .init(scheme: "line", name: "LINE"),
        .init(scheme: "discord", name: "Discord"),
        .init(scheme: "tg", name: "Telegram"),
        .init(scheme: "whatsapp", name: "WhatsApp"),
        .init(scheme: "twitch", name: "Twitch"),
        .init(scheme: "netflix", name: "Netflix"),
        .init(scheme: "spotify", name: "Spotify"),
        .init(scheme: "pinterest", name: "Pinterest"),
        .init(scheme: "snapchat", name: "Snapchat"),
        .init(scheme: "linkedin", name: "LinkedIn"),
        .init(scheme: "bilibili", name: "bilibili"),
        .init(scheme: "xhsdiscover", name: "小紅書"),
        .init(scheme: "weibo", name: "微博"),
        .init(scheme: "ptt", name: "PTT"),
        .init(scheme: "dcard", name: "Dcard"),
        .init(scheme: "shopee", name: "蝦皮"),
        .init(scheme: "momoshop", name: "momo"),
        .init(scheme: "nflx", name: "Disney+"),
    ]
}

extension ReadingGateStore {
    private var blacklistKey: String { "gate.blacklist" }
    private var customAppsKey: String { "gate.customApps" }

    /// 使用者自訂新增的 app。
    var customApps: [GateApp] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customAppsKey),
                  let list = try? JSONDecoder().decode([GateApp].self, from: data)
            else { return [] }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: customAppsKey)
        }
    }

    /// 內建目錄 + 自訂的完整清單。
    var allKnownApps: [GateApp] { GateApp.catalog + customApps }

    /// 目前列入黑名單的 scheme。
    var blacklist: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: blacklistKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: blacklistKey) }
    }

    func isBlacklisted(_ scheme: String) -> Bool { blacklist.contains(scheme) }

    func setBlacklisted(_ scheme: String, _ on: Bool) {
        var b = blacklist
        if on { b.insert(scheme) } else { b.remove(scheme) }
        blacklist = b
    }

    func addCustomApp(name: String, scheme: String) {
        let clean = scheme
            .replacingOccurrences(of: "://", with: "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !clean.isEmpty, !allKnownApps.contains(where: { $0.scheme == clean }) else { return }
        customApps.append(GateApp(scheme: clean, name: name.isEmpty ? clean : name, custom: true))
        setBlacklisted(clean, true)   // 自己加的預設就是要擋的
    }

    func removeCustomApp(_ app: GateApp) {
        customApps.removeAll { $0.scheme == app.scheme }
        setBlacklisted(app.scheme, false)
    }

    /// 深連結帶進來的 app（researchhub://gate?app=instagram）對應到目錄裡的哪一個。
    func app(forScheme scheme: String) -> GateApp? {
        allKnownApps.first { $0.scheme == scheme }
    }
}
