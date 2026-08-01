import SwiftUI
import Combine
import UserNotifications

/// 管理 Research Hub 的根資料夾與目前瀏覽位置。
/// 筆記就是磁碟上的真實檔案：資料夾 = 目錄、筆記 = .md 檔。
@MainActor
final class FileSystemStore: ObservableObject {

    @Published private(set) var rootURL: URL?
    /// 從 Notes/ 開始的導航堆疊，最後一個是目前所在目錄。
    @Published private(set) var stack: [URL] = []
    @Published private(set) var items: [FileItem] = []
    @Published var errorMessage: String?

    // 跨分頁導航與全域搜尋
    @Published var requestedTab: AppTab?
    @Published var pendingOpenNote: URL?
    @Published var searchPresented = false
    /// researchhub://journal?date=… 要求開啟的日記日（JournalView 消化後清空）
    @Published var pendingJournalDate: Date?

    private static let bookmarkKey = "researchHub.rootBookmark"
    private let fm = FileManager.default

    init() {
        restoreRoot()
    }

    // MARK: - Root folder

    var notesURL: URL? {
        rootURL?.appendingPathComponent("Notes", isDirectory: true)
    }

    var journalURL: URL? {
        rootURL?.appendingPathComponent("Journal", isDirectory: true)
    }

    var currentURL: URL? { stack.last }

    /// 麵包屑：相對於 root 的路徑名稱。
    var breadcrumb: [(name: String, index: Int)] {
        stack.enumerated().map { (i, url) in (url.lastPathComponent, i) }
    }

    // security-scoped bookmark 的選項是 macOS 專屬；iOS 用預設選項即可
    // （文件挑選器給的 URL 同樣要 startAccessingSecurityScopedResource）。
    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    func setRoot(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        do {
            let data = try url.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        } catch {
            errorMessage = "無法儲存資料夾權限：\(error.localizedDescription)"
        }
        adopt(root: url)
    }

    private func restoreRoot() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else { return }
        _ = url.startAccessingSecurityScopedResource()
        adopt(root: url)
    }

    private func adopt(root url: URL) {
        rootURL = url
        ensureLayout()
        // 讓 [[...]] 筆記引用知道要從哪裡掃描筆記
        NoteLinkIndex.shared.notesRoot = notesURL
        if let notes = notesURL {
            stack = [notes]
        }
        refresh()
    }

    /// 確保 Notes/ 與 Journal/ 存在，並讓 .hub/ 自帶資料契約文件。
    private func ensureLayout() {
        for url in [notesURL, journalURL].compactMap({ $0 }) {
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        writeHubContractIfNeeded()
    }

    /// .hub/README.md：機器可讀資料的接口說明。跟著資料夾走，
    /// 任何外部工具（AI agent、腳本、自動化）打開資料夾就知道怎麼整合，
    /// 不依賴特定機器上的文件。已存在就不覆寫（使用者可自行增修）。
    private func writeHubContractIfNeeded() {
        guard let root = rootURL else { return }
        let hub = root.appendingPathComponent(".hub", isDirectory: true)
        try? fm.createDirectory(at: hub, withIntermediateDirectories: true)
        let readme = hub.appendingPathComponent("README.md")
        guard !fm.fileExists(atPath: readme.path) else { return }
        try? Self.hubContract.write(to: readme, atomically: true, encoding: .utf8)
    }

    private static let hubContract = """
    # ResearchHub Data Contract

    This folder is the machine-readable interface of a ResearchHub library.
    External tools (AI agents, scripts, automations) may read and write these
    files directly — the app reloads them whenever its views refresh.
    All dates are ISO 8601. Missing JSON fields are tolerated.

    ## Files

    | Path | Contents |
    |---|---|
    | `events.json` | Calendar events + tags: `{tags: [{id,name,colorHex}], events: [{id,title,notes,isAllDay,start,end,tagID}]}` |
    | `todos.json` | Inbox tasks + trash: `{todos: [{id,text,createdAt,done,completedAt}], trash: [{id,text,occurrences,trashedAt,reason}]}` |
    | `claude/insights.json` | AI-written note shown on the home screen: `{updatedAt, message, schedule}`. `schedule` lines in the form `HH:MM–HH:MM task` can be turned into calendar events by the user with one click. |
    | `../Journal/yyyy/MM/yyyy-MM-dd.md` | Daily journal. Todos: `- [ ]` open, `- [x]` done, `- [-]` dropped. Items with `@due`/`@every` are seeded as an independent copy into each applicable day's journal — checking one day only records that day. Markers: `!high`/`!low`, `@due(M/d)`, `@from(M/d)`, `@every(mon,thu)`, `@on(M/d,M/d)` (exact dates only), `@remind(M/d HH:mm)`, `@est(3h)`, `@line(name)`. |
    | `../Notes/**/*.md` | Notes (plain Markdown, `[[wikilinks]]`, `$…$` math, `\\cite{…}` Zotero keys). `assets/` folders hold images. |
    | `../Pomodoro/pomodoro.json` | Focus sessions: `[{date,minutes,plan,done,startedAt?}]`. Legacy entries have no `startedAt`, empty plan/done, and a 12:00:00 timestamp — exclude them from time-of-day analytics. |

    ## Conventions for AI agents

    - A task line appearing unchecked in journals on 2+ days is "repeated";
      after 3 unfinished appearances the app suggests dropping it to trash.
    - Do not rewrite historical journal entries; append or edit today/tomorrow only.
    - Write `claude/insights.json` in the user's interface language.

    ## URL scheme

    - `researchhub://note?path=<path relative to Notes/>` — open a note
    - `researchhub://journal?date=YYYY-MM-DD` — open a journal day (omit date for today)
    """

    // MARK: - Listing & navigation

    func refresh() {
        // 筆記檔可能有增刪改名 → 讓 [[...]] 引用索引下次取用時重掃。
        NoteLinkIndex.shared.invalidate()
        guard let current = currentURL else {
            items = []
            return
        }
        do {
            let urls = try fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            items = urls.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                let isFolder = values?.isDirectory ?? false
                if !isFolder && url.pathExtension.lowercased() != "md" { return nil }
                // 貼圖附件資料夾不顯示在網格中
                if isFolder && url.lastPathComponent == "assets" { return nil }
                return FileItem(
                    url: url,
                    isFolder: isFolder,
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
            items = []
        }
    }

    func open(_ folder: FileItem) {
        guard folder.isFolder else { return }
        stack.append(folder.url)
        refresh()
    }

    func navigate(toBreadcrumbIndex index: Int) {
        guard index < stack.count else { return }
        stack = Array(stack.prefix(index + 1))
        refresh()
    }

    // MARK: - File operations

    func createFolder(named name: String) {
        guard let current = currentURL else { return }
        let url = uniqueURL(in: current, baseName: name.isEmpty ? "新資料夾" : name, ext: nil)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createNote(named name: String) {
        guard let current = currentURL else { return }
        let base = name.isEmpty ? "未命名筆記" : name
        let url = uniqueURL(in: current, baseName: base, ext: "md")
        let content = "# \(base)\n\n"
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let dir = item.url.deletingLastPathComponent()
        let dest = item.isFolder
            ? dir.appendingPathComponent(trimmed, isDirectory: true)
            : dir.appendingPathComponent(trimmed).appendingPathExtension(item.url.pathExtension)
        do {
            try fm.moveItem(at: item.url, to: dest)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trash(_ item: FileItem) {
        do {
            try fm.trashItem(at: item.url, resultingItemURL: nil)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 拖拉移動：把 sourceURL 移進 folder。
    func move(_ sourceURL: URL, into folder: FileItem) {
        guard folder.isFolder else { return }
        move(sourceURL, intoDirectory: folder.url)
    }

    /// 拖拉移動：把 sourceURL 移進任意目錄（資料夾圖示或麵包屑）。
    func move(_ sourceURL: URL, intoDirectory dir: URL) {
        guard sourceURL != dir else { return }
        // 不允許把資料夾移進自己的子目錄，也不需要移到原地
        if dir.path.hasPrefix(sourceURL.path + "/") { return }
        if sourceURL.deletingLastPathComponent().path == dir.path { return }
        let dest = dir.appendingPathComponent(sourceURL.lastPathComponent)
        guard !fm.fileExists(atPath: dest.path) else {
            errorMessage = "「\(dir.lastPathComponent)」內已有同名項目"
            return
        }
        do {
            try fm.moveItem(at: sourceURL, to: dest)
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 跨分頁開啟筆記

    /// 切到筆記分頁並導航到指定目錄。
    func reveal(directory: URL) {
        if let notes = notesURL {
            var chain: [URL] = [notes]
            if directory.path != notes.path, directory.path.hasPrefix(notes.path + "/") {
                var current = notes
                for comp in directory.path.dropFirst(notes.path.count + 1).split(separator: "/") {
                    current = current.appendingPathComponent(String(comp), isDirectory: true)
                    chain.append(current)
                }
            }
            stack = chain
            refresh()
        }
        requestedTab = .notes
    }

    /// 從任何分頁開啟筆記：切到筆記分頁、導航到所在資料夾、打開編輯器。
    func openNote(_ url: URL) {
        reveal(directory: url.deletingLastPathComponent())
        pendingOpenNote = url
    }

    // MARK: - 側欄檔案樹

    struct TreeNode: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        var children: [TreeNode]?

        var id: URL { url }
        var name: String {
            isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        }
    }

    /// Notes/ 的完整樹狀結構（資料夾在前、排除 assets）
    func noteTree() -> [TreeNode] {
        guard let notes = notesURL else { return [] }
        return treeChildren(of: notes, depth: 0)
    }

    private func treeChildren(of dir: URL, depth: Int) -> [TreeNode] {
        guard depth < 8,
              let urls = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var nodes: [TreeNode] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                guard url.lastPathComponent != "assets" else { continue }
                nodes.append(TreeNode(
                    url: url, isFolder: true,
                    children: treeChildren(of: url, depth: depth + 1)))
            } else if url.pathExtension.lowercased() == "md" {
                nodes.append(TreeNode(url: url, isFolder: false, children: nil))
            }
        }
        return nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - 全域掃描（首頁 / 搜尋用）

    /// 所有筆記檔（排除 assets/）
    func allNoteURLs() -> [URL] {
        guard let notes = notesURL,
              let enumerator = fm.enumerator(
                at: notes,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent != "assets" else { continue }
            urls.append(url)
        }
        return urls
    }

    /// 最近修改的筆記
    func recentNotes(limit: Int = 5) -> [FileItem] {
        allNoteURLs()
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return FileItem(url: url, isFolder: false, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { $0 }
    }

    struct TodoItem: Identifiable, Hashable {
        let noteURL: URL
        let lineIndex: Int
        /// 原始文字（含 !high / @due 標記）
        let text: String
        let done: Bool
        /// 解析後的標記（顯示用 cleanText、priority、due）
        let meta: TodoMeta

        var id: String { "\(noteURL.path)#\(lineIndex)" }
        var noteName: String { noteURL.deletingPathExtension().lastPathComponent }
    }

    /// 安全讀檔：iCloud 佔位檔（尚未下載到本機）同步讀取會阻塞到下載完成，
    /// 在 iOS 主執行緒上會被 watchdog 砍掉（0x8BADF00D 黑畫面閃退）。
    /// 尚未下載的檔案改成觸發背景下載、本次視為讀不到，下次掃描自然補上。
    nonisolated static func safeRead(_ url: URL) -> String? {
        if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = v.ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 彙整所有筆記中的 - [ ] / - [x]，依優先級（高→低）、到期日（近→遠）排序。
    func scanTodos(includeDone: Bool = false) -> [TodoItem] {
        var result: [TodoItem] = []
        for url in allNoteURLs() {
            guard let content = Self.safeRead(url) else { continue }
            for (i, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let done: Bool
                if trimmed.hasPrefix("- [ ]") { done = false }
                else if trimmed.lowercased().hasPrefix("- [x]") { done = true }
                else { continue }
                if done && !includeDone { continue }
                let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                result.append(TodoItem(
                    noteURL: url, lineIndex: i, text: text, done: done,
                    meta: TodoMeta.parse(text)))
            }
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

    /// 在原檔打勾 / 取消打勾
    func toggleTodo(_ item: TodoItem) {
        guard let content = Self.safeRead(item.noteURL) else { return }
        var lines = content.components(separatedBy: "\n")
        guard item.lineIndex < lines.count else { return }
        let line = lines[item.lineIndex]
        if item.done {
            lines[item.lineIndex] = line
                .replacingOccurrences(of: "- [x]", with: "- [ ]")
                .replacingOccurrences(of: "- [X]", with: "- [ ]")
        } else {
            lines[item.lineIndex] = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        }
        try? lines.joined(separator: "\n")
            .write(to: item.noteURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 每日播種：@due/@from/@every 的獨立日副本 + @remind 通知

    /// 冪等播種：把「這一天該出現」的待辦以獨立副本補進該天的日記（只限今天以後）。
    /// 每天的副本互相獨立——勾掉只代表那一天，隔天照樣出現，直到條件結束：
    ///   @due(D)         → 每天出現，直到 D（含）；搭配 @from(F) 則從 F 才開始
    ///   @from(F) 單獨用 → 只在 F 那天出現一次
    ///   @every(mon,…)   → 每逢指定星期幾出現
    /// 提前不想再出現：把該行的標記拿掉或刪掉該行。
    /// 母本來源：所有日記行（含已勾）、筆記未完成待辦、一般待辦（generalTexts）。
    /// 內容比對冪等，可重複呼叫；今天的呼叫順便為 @remind 排程推播。
    /// ⚠️ 必須在該天的日記編輯器載入之前呼叫（切換日期的動作裡、或編輯器開啟前）。
    func seedTodos(for date: Date, generalTexts: [String] = []) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let day = cal.startOfDay(for: date)
        guard day >= today, let targetURL = journalURL(for: day) else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let weekday = cal.component(.weekday, from: day)

        // 母本收集（同文字只留一份；journals 含已勾的行——每日進度型任務勾了明天照樣出現）
        var masters: [String] = []
        var uncheckedMasters: [String] = []
        var seen = Set<String>()
        func addMaster(_ raw: String, unchecked: Bool) {
            let key = TodoMeta.parse(raw).dedupKey
            guard !key.isEmpty else { return }
            if unchecked { uncheckedMasters.append(raw) }
            guard !seen.contains(key) else { return }
            seen.insert(key)
            masters.append(raw)
        }
        for (url, _) in journalFiles(dateFormatter: df) {
            guard let content = Self.safeRead(url) else { continue }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let unchecked = trimmed.hasPrefix("- [ ]")
                guard unchecked || trimmed.lowercased().hasPrefix("- [x]") else { continue }
                addMaster(
                    String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces),
                    unchecked: unchecked)
            }
        }
        for item in scanTodos() { addMaster(item.text, unchecked: true) }
        for text in generalTexts { addMaster(text, unchecked: true) }

        // 該天已有的（不重複播）
        let targetContent = Self.safeRead(targetURL) ?? ""
        var targetExisting = Set<String>()
        for line in targetContent.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") || trimmed.lowercased().hasPrefix("- [x]")
            else { continue }
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            targetExisting.insert(TodoMeta.parse(text).dedupKey)
        }

        var toSeed: [String] = []
        for raw in masters {
            let meta = TodoMeta.parse(raw)
            guard !targetExisting.contains(meta.dedupKey) else { continue }
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
            toSeed.append(raw)
            targetExisting.insert(meta.dedupKey)
        }
        if !toSeed.isEmpty {
            appendTodoLines(toSeed, existingContent: targetContent, to: targetURL)
        }
        if day == today {
            scheduleReminders(for: uncheckedMasters)
        }
    }

    /// @remind：未完成且時刻在未來的 → 排程推播（id 固定為內容，重排自動覆蓋）。
    private func scheduleReminders(for raws: [String]) {
        let reminders: [(text: String, at: Date)] = raws.compactMap { raw in
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
    private func appendTodoLines(_ raws: [String], existingContent: String, to url: URL) {
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content = existingContent
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        content += raws.map { "- [ ] \($0)" }.joined(separator: "\n\n") + "\n"
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 任務總覽（/list）

    /// 帶日期類標記（due/from/every/remind/est）的待辦（日記＋筆記），依到期日排序。
    /// includeDone = true 時連同已完成副本一起回傳（任務總覽用來顯示各天完成度）。
    func markerTodos(includeDone: Bool = false) -> [TodoItem] {
        func hasDateMarkers(_ meta: TodoMeta) -> Bool {
            meta.due != nil || meta.from != nil || meta.everyWeekdays != nil
                || meta.onDates != nil || meta.remind != nil || meta.estMinutes != nil
        }
        var result: [TodoItem] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        for (url, _) in journalFiles(dateFormatter: df) {
            guard let content = Self.safeRead(url) else { continue }
            for (i, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let done: Bool
                if trimmed.hasPrefix("- [ ]") { done = false }
                else if includeDone && trimmed.lowercased().hasPrefix("- [x]") { done = true }
                else { continue }
                let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let meta = TodoMeta.parse(text)
                guard hasDateMarkers(meta) else { continue }
                result.append(TodoItem(
                    noteURL: url, lineIndex: i, text: text, done: done, meta: meta))
            }
        }
        for item in scanTodos(includeDone: includeDone) where hasDateMarkers(item.meta) {
            result.append(item)
        }
        return result.sorted { ($0.meta.due ?? .distantFuture) < ($1.meta.due ?? .distantFuture) }
    }

    /// 關鍵字搜尋：全文掃描日記＋筆記的待辦行（含已完成、含無標記的）。
    /// 任務總覽用它回答「這個條目哪幾天做完了」。
    func searchTodos(keyword: String) -> [TodoItem] {
        let q = keyword.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var result: [TodoItem] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        for (url, _) in journalFiles(dateFormatter: df) {
            guard let content = Self.safeRead(url) else { continue }
            for (i, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let done: Bool
                if trimmed.hasPrefix("- [ ]") { done = false }
                else if trimmed.lowercased().hasPrefix("- [x]") { done = true }
                else { continue }
                let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text.localizedCaseInsensitiveContains(q) else { continue }
                result.append(TodoItem(
                    noteURL: url, lineIndex: i, text: text, done: done,
                    meta: TodoMeta.parse(text)))
            }
        }
        for item in scanTodos(includeDone: true)
        where item.text.localizedCaseInsensitiveContains(q) {
            result.append(item)
        }
        return result
    }

    /// 歸檔：把同一任務的所有每日副本（含各自的縮排子項目）彙整成
    /// Notes/Archive/<任務>.md。非破壞性——日記保持原樣，重複執行整份重新生成。
    @discardableResult
    func archiveTask(named cleanText: String, copies: [TodoItem]) -> URL? {
        guard let notes = notesURL else { return nil }
        let dir = notes.appendingPathComponent("Archive", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = cleanText
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let fileURL = dir.appendingPathComponent("\(safe.isEmpty ? "任務" : safe).md")

        var sections: [String] = []
        for copy in copies.sorted(by: { $0.noteName < $1.noteName }) {
            guard let content = Self.safeRead(copy.noteURL)
            else { continue }
            let lines = content.components(separatedBy: "\n")
            guard copy.lineIndex < lines.count else { continue }
            var block = [lines[copy.lineIndex]]
            // 緊接在後、縮排更深的行（子項目）一起帶走
            let baseIndent = lines[copy.lineIndex].prefix(while: { $0 == " " || $0 == "\t" }).count
            var j = copy.lineIndex + 1
            while j < lines.count {
                let l = lines[j]
                guard !l.trimmingCharacters(in: .whitespaces).isEmpty,
                      l.prefix(while: { $0 == " " || $0 == "\t" }).count > baseIndent
                else { break }
                block.append(l)
                j += 1
            }
            sections.append("""
            ## \(copy.noteName) \(copy.done ? "✓" : "—")

            \(block.joined(separator: "\n"))

            [開啟日記](researchhub://journal?date=\(copy.noteName))
            """)
        }
        let doc = """
        # \(cleanText)

        > 自動生成的任務歸檔（/list → 歸檔）。日記為原始紀錄，本檔可隨時重新生成。


        """ + sections.joined(separator: "\n\n") + "\n"
        try? doc.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// 任務總覽的列編輯：改寫（newText）或刪除（nil／空字串）一行待辦。
    /// 行內容已和掃描時不同就不動，避免蓋錯。呼叫端需確定該檔的編輯器沒開著。
    @discardableResult
    func updateTodoLine(_ item: TodoItem, newText: String?) -> Bool {
        guard let content = Self.safeRead(item.noteURL) else { return false }
        var lines = content.components(separatedBy: "\n")
        guard item.lineIndex < lines.count else { return false }
        let line = lines[item.lineIndex]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 已完成副本（- [x]）也允許改寫/刪除：任務總覽的編輯要套用到所有每日副本
        let low = trimmed.lowercased()
        guard low.hasPrefix("- [ ]") || low.hasPrefix("- [x]"),
              String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) == item.text
        else { return false }
        let clean = newText?.trimmingCharacters(in: .whitespaces) ?? ""
        if clean.isEmpty {
            lines.remove(at: item.lineIndex)
        } else if let range = line.range(of: item.text) {
            lines[item.lineIndex] = line.replacingCharacters(in: range, with: clean)
        } else {
            return false
        }
        try? lines.joined(separator: "\n").write(to: item.noteURL, atomically: true, encoding: .utf8)
        return true
    }

    /// 把一行待辦加到某天的日記（任務總覽「新增」用；呼叫端需確定該天編輯器沒開著）。
    func appendTodoLine(_ text: String, on date: Date) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let url = journalURL(for: date) else { return }
        let content = Self.safeRead(url) ?? ""
        appendTodoLines([t], existingContent: content, to: url)
    }

    // MARK: - 日記重複待辦

    /// 同一句待辦在多天日記重複出現（且都沒完成）的彙整。
    struct RepeatedTodo: Identifiable, Hashable {
        let text: String
        /// 出現且未完成的日記日期（由舊到新）
        let dates: [Date]
        var count: Int { dates.count }
        var id: String { text }
    }

    /// 掃描 Journal/ 中重複出現的未完成待辦：
    /// 同一句「- [ ] 文字」出現在 minCount 天以上的日記 → 回報次數。
    /// 比對時剝掉 !high / @due 標記，同一件事加不加標記都算同一件。
    func scanRepeatedJournalTodos(minCount: Int = 2) -> [RepeatedTodo] {
        var occurrences: [String: Set<Date>] = [:]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"

        for (url, day) in journalFiles(dateFormatter: df) {
            guard let content = Self.safeRead(url) else { continue }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ]") else { continue }
                let raw = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                let meta = TodoMeta.parse(raw)
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

    /// 放棄一句日記待辦：把所有日記中相同文字的「- [ ]」改成「- [-]」（已放棄，
    /// 之後不再列入待辦與重複統計），回傳改動的檔案數。
    @discardableResult
    func discardJournalTodos(matching text: String) -> Int {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var changed = 0

        for (url, _) in journalFiles(dateFormatter: df) {
            guard let content = Self.safeRead(url) else { continue }
            var lines = content.components(separatedBy: "\n")
            var dirty = false
            for i in lines.indices {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ]") else { continue }
                let raw = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard TodoMeta.parse(raw).cleanText == text else { continue }
                if let range = lines[i].range(of: "- [ ]") {
                    lines[i].replaceSubrange(range, with: "- [-]")
                    dirty = true
                }
            }
            if dirty {
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                changed += 1
            }
        }
        return changed
    }

    /// 某天日記裡還沒完成的待辦（原始文字，含標記），給規劃儀式搬移用。
    func unfinishedJournalTodos(on date: Date) -> [String] {
        guard let url = journalURL(for: date),
              let content = Self.safeRead(url) else { return [] }
        var result: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") else { continue }
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(text) }
        }
        return result
    }

    /// 所有日記檔與其日期（檔名 yyyy-MM-dd.md）。
    private func journalFiles(dateFormatter df: DateFormatter) -> [(URL, Date)] {
        guard let base = journalURL,
              let enumerator = fm.enumerator(
                at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
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
    func journalURL(for date: Date) -> URL? {
        guard let base = journalURL else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return base
            .appendingPathComponent(String(format: "%04d", comps.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 0), isDirectory: true)
            .appendingPathComponent("\(f.string(from: date)).md")
    }

    // MARK: - Helpers

    private func uniqueURL(in dir: URL, baseName: String, ext: String?) -> URL {
        func candidate(_ n: Int) -> URL {
            let name = n == 0 ? baseName : "\(baseName) \(n)"
            var url = dir.appendingPathComponent(name, isDirectory: ext == nil)
            if let ext { url = url.appendingPathExtension(ext) }
            return url
        }
        var n = 0
        while fm.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }
}
