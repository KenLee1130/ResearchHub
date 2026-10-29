import Foundation
import HubCore

/// 一行待辦（`- [ ]` 或 `- [x]`）解析後的結果。
public nonisolated struct TodoLine: Sendable {
    public let lineIndex: Int
    /// checkbox 後面的原始文字（含 !high / @due 標記）
    public let text: String
    public let done: Bool
    public let meta: TodoMeta
    /// TodoMeta.dedupKey 要跑兩次 regex，播種時每行都會問，所以先算好
    public let dedupKey: String
}

/// 整個資料夾的待辦索引：每個 .md 檔解析一次，結果留在記憶體裡，
/// 檔案的修改時間或大小變了才重新讀、重新解析那一個檔。
///
/// 以前首頁、日記、任務總覽每次需要待辦，都各自把全部筆記和日記從磁碟
/// 讀出來逐行解析（而且在主執行緒上）。現在重複掃描只剩下「問每個檔案
/// 的修改時間」，有變動的檔才會真的被讀。
///
/// 可以從任何執行緒呼叫（內部用鎖保護）。
public nonisolated final class LibraryIndex: @unchecked Sendable {
    /// 模組內部的快取（LibraryScan 的靜態函式共用），不對外；不是可注入的相依。
    static let shared = LibraryIndex()

    private struct Entry {
        let modified: Date
        let size: Int
        /// 解析當天：@due(7/10)、@remind(09:00) 這類標記是相對「今天」解讀的，隔天要重算
        let parsedDay: Date
        let lines: [TodoLine]
        /// 這個檔裡的 @spend（day 先填佔位，ledgerEntries(in:day:) 回傳時換成日記那天）
        let ledger: [LedgerEntry]
        /// 本地啟發式分類（日記回顧用；旁車檔 journal-meta.json 的 kind 會覆寫）
        let kind: JournalKind
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// 這個檔裡的待辦行。檔案讀不到（例如還在 iCloud 上沒下載）回 nil。
    public func todoLines(in url: URL) -> [TodoLine]? {
        entry(for: url)?.lines
    }

    /// 這個檔（日記）裡的記帳條目，`day` 是日記那天。讀不到回 nil。
    public func ledgerEntries(in url: URL, day: Date) -> [LedgerEntry]? {
        entry(for: url)?.ledger.map {
            LedgerEntry(day: day, amount: $0.amount, category: $0.category,
                        note: $0.note, lineIndex: $0.lineIndex)
        }
    }

    /// 這個檔（日記）是流水帳還是心得（本地啟發式；讀不到回 nil）。
    public func journalKind(in url: URL) -> JournalKind? {
        entry(for: url)?.kind
    }

    private func entry(for url: URL) -> Entry? {
        let path = url.path
        var probe = url
        probe.removeAllCachedResourceValues()
        let values = try? probe.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? -1
        let today = Calendar.current.startOfDay(for: .now)

        lock.lock()
        if let hit = entries[path], hit.modified == modified, hit.size == size,
           hit.parsedDay == today {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let content = ICloudFile.safeRead(url) else { return nil }
        let entry = Entry(modified: modified, size: size, parsedDay: today,
                          lines: Self.parse(content),
                          ledger: LedgerParser.entries(in: content, day: .distantPast),
                          kind: JournalClassifier.classify(content))
        lock.lock()
        entries[path] = entry
        lock.unlock()
        return entry
    }

    public static func parse(_ content: String) -> [TodoLine] {
        var result: [TodoLine] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let done: Bool
            if trimmed.hasPrefix("- [ ]") { done = false }
            else if trimmed.lowercased().hasPrefix("- [x]") { done = true }
            else { continue }
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let meta = TodoMeta.parse(text)
            result.append(TodoLine(lineIndex: i, text: text, done: done,
                                   meta: meta, dedupKey: meta.dedupKey))
        }
        return result
    }
}

/// 全資料夾的掃描（待辦、重複待辦、每日播種…）。
/// 全部是不綁主執行緒的純函式：畫面在背景算好再一次換上，打字和捲動不會被擋。
public nonisolated enum LibraryScan {

    /// 開 app 時在背景把所有筆記與日記解析一遍，之後畫面要資料就都是現成的。
    public static func warm(notes: URL?, journal: URL?) {
        for url in noteURLs(notes: notes) { _ = LibraryIndex.shared.todoLines(in: url) }
        for (url, _) in journalFiles(journal: journal) { _ = LibraryIndex.shared.todoLines(in: url) }
    }

    // MARK: 側欄檔案樹

    /// Notes/ 的完整樹狀結構（資料夾在前、排除 assets）
    public static func noteTree(notes: URL?) -> [LibraryTreeNode] {
        guard let notes else { return [] }
        return treeChildren(of: notes, depth: 0)
    }

    private static func treeChildren(of dir: URL, depth: Int) -> [LibraryTreeNode] {
        guard depth < 8,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var nodes: [LibraryTreeNode] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                guard url.lastPathComponent != "assets" else { continue }
                // LaTeX 專案是「一個資料夾＝一篇筆記」，所以當成葉節點，不展開裡面的 .tex
                if LatexProject.isProject(url) {
                    nodes.append(LibraryTreeNode(url: url, isFolder: false,
                                                          isProject: true, children: nil))
                    continue
                }
                nodes.append(LibraryTreeNode(
                    url: url, isFolder: true,
                    children: treeChildren(of: url, depth: depth + 1)))
            } else if url.pathExtension.lowercased() == "md" {
                nodes.append(LibraryTreeNode(url: url, isFolder: false, children: nil))
            }
        }
        return nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: 檔案清單

    /// 所有筆記檔（排除 assets/）
    public static func noteURLs(notes: URL?) -> [URL] {
        guard let notes,
              let enumerator = FileManager.default.enumerator(
                at: notes, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent != "assets" else { continue }
            urls.append(url)
        }
        return urls
    }

    /// 所有日記檔與其日期（檔名 yyyy-MM-dd.md）。
    public static func journalFiles(journal: URL?) -> [(URL, Date)] { JournalLayout.journalFiles(journal: journal) }

    /// 某日的日記檔路徑
    public static func journalURL(for date: Date, journal: URL?) -> URL? {
        guard let journal else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return journal
            .appendingPathComponent(String(format: "%04d", comps.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 0), isDirectory: true)
            .appendingPathComponent("\(f.string(from: date)).md")
    }

    /// 最近修改的筆記
    public static func recentNotes(notes: URL?, limit: Int) -> [FileItem] {
        noteURLs(notes: notes)
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return FileItem(url: url, isFolder: false, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: 待辦

    private static func items(in url: URL, includeDone: Bool) -> [LibraryTodoItem] {
        (LibraryIndex.shared.todoLines(in: url) ?? []).compactMap { line in
            if line.done && !includeDone { return nil }
            return LibraryTodoItem(
                noteURL: url, lineIndex: line.lineIndex, text: line.text,
                done: line.done, meta: line.meta)
        }
    }

    /// 彙整所有筆記中的 - [ ] / - [x]，依優先級（高→低）、到期日（近→遠）排序。
    public static func noteTodos(notes: URL?, includeDone: Bool) -> [LibraryTodoItem] {
        var result: [LibraryTodoItem] = []
        for url in noteURLs(notes: notes) {
            result += items(in: url, includeDone: includeDone)
        }
        return result.sorted { a, b in
            if a.meta.priority != b.meta.priority { return a.meta.priority > b.meta.priority }
            switch (a.meta.due, b.meta.due) {
            case let (x?, y?): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
    }

    /// 帶日期類標記（due/from/every/remind/est）的待辦（日記＋筆記），依到期日排序。
    public static func markerTodos(notes: URL?, journal: URL?, includeDone: Bool) -> [LibraryTodoItem] {
        func hasDateMarkers(_ meta: TodoMeta) -> Bool {
            meta.due != nil || meta.from != nil || meta.everyWeekdays != nil
                || meta.onDates != nil || meta.remind != nil || meta.estMinutes != nil
        }
        var result: [LibraryTodoItem] = []
        for (url, _) in journalFiles(journal: journal) {
            result += items(in: url, includeDone: includeDone).filter { hasDateMarkers($0.meta) }
        }
        result += noteTodos(notes: notes, includeDone: includeDone).filter { hasDateMarkers($0.meta) }
        return result.sorted { ($0.meta.due ?? .distantFuture) < ($1.meta.due ?? .distantFuture) }
    }

    /// 關鍵字搜尋：日記＋筆記的待辦行（含已完成、含無標記的）。
    public static func searchTodos(keyword: String, notes: URL?, journal: URL?) -> [LibraryTodoItem] {
        let q = keyword.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var result: [LibraryTodoItem] = []
        for (url, _) in journalFiles(journal: journal) {
            result += items(in: url, includeDone: true)
                .filter { $0.text.localizedCaseInsensitiveContains(q) }
        }
        result += noteTodos(notes: notes, includeDone: true)
            .filter { $0.text.localizedCaseInsensitiveContains(q) }
        return result
    }

    /// Journal/ 中重複出現的未完成待辦：同一句出現在 minCount 天以上 → 回報次數。
    /// 比對時剝掉 !high / @due 標記，同一件事加不加標記都算同一件。
    public static func repeatedJournalTodos(journal: URL?, minCount: Int) -> [RepeatedTodo] {
        var occurrences: [String: Set<Date>] = [:]
        for (url, day) in journalFiles(journal: journal) {
            for line in LibraryIndex.shared.todoLines(in: url) ?? [] where !line.done {
                let meta = line.meta
                // @due/@every/@from 是刻意每天出現的副本，不是拖延，不列入重複統計
                guard meta.due == nil, meta.everyWeekdays == nil, meta.from == nil,
                      meta.onDates == nil else { continue }
                let text = meta.cleanText
                guard !text.isEmpty else { continue }
                occurrences[text, default: []].insert(day)
            }
        }
        return occurrences
            .filter { $0.value.count >= minCount }
            .map { RepeatedTodo(text: $0.key, dates: $0.value.sorted()) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.text.localizedStandardCompare(b.text) == .orderedAscending
            }
    }

    // MARK: 每日播種：@due/@from/@every 的獨立日副本 + @remind 通知

    /// 冪等播種（規則見 FileSystemStore.seedTodos 的說明）。
    public static func seedTodos(for date: Date, generalTexts: [String], notes: URL?, journal: URL?) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let day = cal.startOfDay(for: date)
        guard day >= today, let targetURL = journalURL(for: day, journal: journal) else { return }
        let weekday = cal.component(.weekday, from: day)

        // 母本收集（同文字只留一份；journals 含已勾的行——每日進度型任務勾了明天照樣出現）
        var masters: [(raw: String, meta: TodoMeta, key: String)] = []
        var uncheckedMasters: [String] = []
        var seen = Set<String>()
        func addMaster(_ raw: String, meta: TodoMeta, key: String, unchecked: Bool) {
            guard !key.isEmpty else { return }
            if unchecked { uncheckedMasters.append(raw) }
            guard !seen.contains(key) else { return }
            seen.insert(key)
            masters.append((raw, meta, key))
        }
        for (url, _) in journalFiles(journal: journal) {
            for line in LibraryIndex.shared.todoLines(in: url) ?? [] {
                addMaster(line.text, meta: line.meta, key: line.dedupKey, unchecked: !line.done)
            }
        }
        for url in noteURLs(notes: notes) {
            for line in LibraryIndex.shared.todoLines(in: url) ?? [] where !line.done {
                addMaster(line.text, meta: line.meta, key: line.dedupKey, unchecked: true)
            }
        }
        for text in generalTexts {
            let meta = TodoMeta.parse(text)
            addMaster(text, meta: meta, key: meta.dedupKey, unchecked: true)
        }

        var toSeed: [String] = []
        // 大多數日子沒有東西要播：先只看索引，確定要寫檔才去讀那天日記的全文
        var targetExisting = Set((LibraryIndex.shared.todoLines(in: targetURL) ?? []).map(\.dedupKey))
        for master in masters {
            let meta = master.meta
            guard !targetExisting.contains(master.key) else { continue }
            let from = meta.from.map { cal.startOfDay(for: $0) }
            var shouldSeed = false
            if let due = meta.due.map({ cal.startOfDay(for: $0) }) {
                shouldSeed = day <= due && (from ?? .distantPast) <= day
            } else if let from {
                shouldSeed = from == day
            }
            if let days = meta.everyWeekdays, days.contains(weekday) {
                shouldSeed = true
            }
            if let dates = meta.onDates, dates.contains(day) {
                shouldSeed = true   // @on：只在列出的那幾天出現（不連續工作）
            }
            guard shouldSeed else { continue }
            toSeed.append(master.raw)
            targetExisting.insert(master.key)
        }
        if !toSeed.isEmpty {
            // 那天的日記在 iCloud 上但還沒下載到：不能當成空的寫回去，這次先不播
            let exists = FileManager.default.fileExists(atPath: targetURL.path)
            if let content = ICloudFile.safeRead(targetURL) {
                appendTodoLines(toSeed, existingContent: content, to: targetURL)
            } else if !exists {
                appendTodoLines(toSeed, existingContent: "", to: targetURL)
            }
        }
        if day == today {
            scheduleReminders(for: uncheckedMasters)
        }
    }

    /// 一則要排程的 @remind 提醒
    public struct Reminder: Sendable, Hashable {
        public let text: String
        public let at: Date
    }

    /// 推播由 app 接手（UserNotifications 不進 HubStore）：app 啟動時指定；沒指定就不排。
    nonisolated(unsafe) public static var reminderScheduler: (@Sendable ([Reminder]) -> Void)?

    /// @remind：未完成且時刻在未來的 → 交給 reminderScheduler（id 固定為內容，重排自動覆蓋）。
    private static func scheduleReminders(for raws: [String]) {
        let reminders: [Reminder] = raws.compactMap { raw in
            guard raw.contains("@remind") else { return nil }
            let meta = TodoMeta.parse(raw)
            guard let remind = meta.remind, remind > .now else { return nil }
            return Reminder(text: meta.cleanText, at: remind)
        }
        guard !reminders.isEmpty else { return }   // 不碰通知中心（也讓無 bundle 的測試環境能跑）
        reminderScheduler?(reminders)
    }

    /// 把待辦行（不含 checkbox 前綴）附加到日記檔尾端，項目之間留空行。
    public static func appendTodoLines(_ raws: [String], existingContent: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content = existingContent
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        content += raws.map { "- [ ] \($0)" }.joined(separator: "\n\n") + "\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: 首頁

    /// 首頁需要的全部資料，一次在背景算好。
    public struct HomeSnapshot: Sendable {
        public var recentNotes: [FileItem] = []
        public var todos: [LibraryTodoItem] = []
        public var repeatedTodos: [RepeatedTodo] = []
        public var noteCount = 0
        public var journalPreview: String?
        /// 全部日記的 @spend 條目（首頁記帳卡再按月彙總）
        public var ledger: [LedgerEntry] = []
    }

    /// 全部日記的記帳條目（舊→新、同一天照行號）。
    public static func ledgerEntries(journal: URL?) -> [LedgerEntry] {
        journalFiles(journal: journal)
            .sorted { $0.1 < $1.1 }
            .flatMap { LibraryIndex.shared.ledgerEntries(in: $0.0, day: $0.1) ?? [] }
    }

    public static func homeSnapshot(notes: URL?, journal: URL?, generalTexts: [String]) -> HomeSnapshot {
        // 先播種（可能會在今天的日記補上待辦），再讀
        seedTodos(for: .now, generalTexts: generalTexts, notes: notes, journal: journal)
        var snap = HomeSnapshot()
        snap.recentNotes = recentNotes(notes: notes, limit: 5)
        snap.todos = noteTodos(notes: notes, includeDone: false)
        snap.noteCount = noteURLs(notes: notes).count
        snap.repeatedTodos = repeatedJournalTodos(journal: journal, minCount: 2)
        snap.ledger = ledgerEntries(journal: journal)
        if let url = journalURL(for: .now, journal: journal),
           let content = ICloudFile.safeRead(url) {
            let preview = content
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(3)
                .joined(separator: " · ")
            snap.journalPreview = preview.isEmpty ? nil : preview
        }
        return snap
    }
}
