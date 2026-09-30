import Foundation
import UserNotifications

/// 一行待辦（`- [ ]` 或 `- [x]`）解析後的結果。
nonisolated struct TodoLine: Sendable {
    let lineIndex: Int
    /// checkbox 後面的原始文字（含 !high / @due 標記）
    let text: String
    let done: Bool
    let meta: TodoMeta
    /// TodoMeta.dedupKey 要跑兩次 regex，播種時每行都會問，所以先算好
    let dedupKey: String
}

/// 整個資料夾的待辦索引：每個 .md 檔解析一次，結果留在記憶體裡，
/// 檔案的修改時間或大小變了才重新讀、重新解析那一個檔。
///
/// 以前首頁、日記、任務總覽每次需要待辦，都各自把全部筆記和日記從磁碟
/// 讀出來逐行解析（而且在主執行緒上）。現在重複掃描只剩下「問每個檔案
/// 的修改時間」，有變動的檔才會真的被讀。
///
/// 可以從任何執行緒呼叫（內部用鎖保護）。
nonisolated final class LibraryIndex: @unchecked Sendable {
    static let shared = LibraryIndex()

    private struct Entry {
        let modified: Date
        let size: Int
        /// 解析當天：@due(7/10)、@remind(09:00) 這類標記是相對「今天」解讀的，隔天要重算
        let parsedDay: Date
        let lines: [TodoLine]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// 這個檔裡的待辦行。檔案讀不到（例如還在 iCloud 上沒下載）回 nil。
    func todoLines(in url: URL) -> [TodoLine]? {
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
            return hit.lines
        }
        lock.unlock()

        guard let content = FileSystemStore.safeRead(url) else { return nil }
        let lines = Self.parse(content)
        lock.lock()
        entries[path] = Entry(modified: modified, size: size, parsedDay: today, lines: lines)
        lock.unlock()
        return lines
    }

    static func parse(_ content: String) -> [TodoLine] {
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
nonisolated enum LibraryScan {

    /// 開 app 時在背景把所有筆記與日記解析一遍，之後畫面要資料就都是現成的。
    static func warm(notes: URL?, journal: URL?) {
        for url in noteURLs(notes: notes) { _ = LibraryIndex.shared.todoLines(in: url) }
        for (url, _) in journalFiles(journal: journal) { _ = LibraryIndex.shared.todoLines(in: url) }
    }

    // MARK: 檔案清單

    /// 所有筆記檔（排除 assets/）
    static func noteURLs(notes: URL?) -> [URL] {
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
    static func journalFiles(journal: URL?) -> [(URL, Date)] {
        guard let journal,
              let enumerator = FileManager.default.enumerator(
                at: journal, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var result: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let day = df.date(from: url.deletingPathExtension().lastPathComponent)
            else { continue }
            result.append((url, day))
        }
        return result
    }

    /// 某日的日記檔路徑
    static func journalURL(for date: Date, journal: URL?) -> URL? {
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
    static func recentNotes(notes: URL?, limit: Int) -> [FileItem] {
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

    private static func items(in url: URL, includeDone: Bool) -> [FileSystemStore.TodoItem] {
        (LibraryIndex.shared.todoLines(in: url) ?? []).compactMap { line in
            if line.done && !includeDone { return nil }
            return FileSystemStore.TodoItem(
                noteURL: url, lineIndex: line.lineIndex, text: line.text,
                done: line.done, meta: line.meta)
        }
    }

    /// 彙整所有筆記中的 - [ ] / - [x]，依優先級（高→低）、到期日（近→遠）排序。
    static func noteTodos(notes: URL?, includeDone: Bool) -> [FileSystemStore.TodoItem] {
        var result: [FileSystemStore.TodoItem] = []
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
    static func markerTodos(notes: URL?, journal: URL?, includeDone: Bool) -> [FileSystemStore.TodoItem] {
        func hasDateMarkers(_ meta: TodoMeta) -> Bool {
            meta.due != nil || meta.from != nil || meta.everyWeekdays != nil
                || meta.onDates != nil || meta.remind != nil || meta.estMinutes != nil
        }
        var result: [FileSystemStore.TodoItem] = []
        for (url, _) in journalFiles(journal: journal) {
            result += items(in: url, includeDone: includeDone).filter { hasDateMarkers($0.meta) }
        }
        result += noteTodos(notes: notes, includeDone: includeDone).filter { hasDateMarkers($0.meta) }
        return result.sorted { ($0.meta.due ?? .distantFuture) < ($1.meta.due ?? .distantFuture) }
    }

    /// 關鍵字搜尋：日記＋筆記的待辦行（含已完成、含無標記的）。
    static func searchTodos(keyword: String, notes: URL?, journal: URL?) -> [FileSystemStore.TodoItem] {
        let q = keyword.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var result: [FileSystemStore.TodoItem] = []
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
    static func repeatedJournalTodos(journal: URL?, minCount: Int) -> [FileSystemStore.RepeatedTodo] {
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
            .map { FileSystemStore.RepeatedTodo(text: $0.key, dates: $0.value.sorted()) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.text.localizedStandardCompare(b.text) == .orderedAscending
            }
    }

    // MARK: 每日播種：@due/@from/@every 的獨立日副本 + @remind 通知

    /// 冪等播種（規則見 FileSystemStore.seedTodos 的說明）。
    static func seedTodos(for date: Date, generalTexts: [String], notes: URL?, journal: URL?) {
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
            if let content = FileSystemStore.safeRead(targetURL) {
                appendTodoLines(toSeed, existingContent: content, to: targetURL)
            } else if !exists {
                appendTodoLines(toSeed, existingContent: "", to: targetURL)
            }
        }
        if day == today {
            scheduleReminders(for: uncheckedMasters)
        }
    }

    /// @remind：未完成且時刻在未來的 → 排程推播（id 固定為內容，重排自動覆蓋）。
    private static func scheduleReminders(for raws: [String]) {
        let reminders: [(text: String, at: Date)] = raws.compactMap { raw in
            guard raw.contains("@remind") else { return nil }
            let meta = TodoMeta.parse(raw)
            guard let remind = meta.remind, remind > .now else { return nil }
            return (meta.cleanText, remind)
        }
        guard !reminders.isEmpty else { return }   // 不碰通知中心（也讓無 bundle 的測試環境能跑）
        let center = UNUserNotificationCenter.current()
        for r in reminders {
            let content = UNMutableNotificationContent()
            content.title = "⏰ \(r.text)"
            content.sound = .default
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: r.at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(
                identifier: "todo.remind.\(r.text)",
                content: content, trigger: trigger))
        }
    }

    /// 把待辦行（不含 checkbox 前綴）附加到日記檔尾端，項目之間留空行。
    static func appendTodoLines(_ raws: [String], existingContent: String, to url: URL) {
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
    struct HomeSnapshot: Sendable {
        var recentNotes: [FileItem] = []
        var todos: [FileSystemStore.TodoItem] = []
        var repeatedTodos: [FileSystemStore.RepeatedTodo] = []
        var noteCount = 0
        var journalPreview: String?
    }

    static func homeSnapshot(notes: URL?, journal: URL?, generalTexts: [String]) -> HomeSnapshot {
        // 先播種（可能會在今天的日記補上待辦），再讀
        seedTodos(for: .now, generalTexts: generalTexts, notes: notes, journal: journal)
        var snap = HomeSnapshot()
        snap.recentNotes = recentNotes(notes: notes, limit: 5)
        snap.todos = noteTodos(notes: notes, includeDone: false)
        snap.noteCount = noteURLs(notes: notes).count
        snap.repeatedTodos = repeatedJournalTodos(journal: journal, minCount: 2)
        if let url = journalURL(for: .now, journal: journal),
           let content = FileSystemStore.safeRead(url) {
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
