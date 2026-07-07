import SwiftUI
import Combine

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
    | `../Journal/yyyy/MM/yyyy-MM-dd.md` | Daily journal. Todos: `- [ ]` open, `- [x]` done, `- [-]` dropped, `- [>]` migrated (items with a due date are carried forward to today's journal daily; old copies get `>`, sub-items stay as that day's progress log). Markers: `!high` / `!low` priority, `@due(M/d)`, `@line(name)`. |
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

    /// 彙整所有筆記中的 - [ ] / - [x]，依優先級（高→低）、到期日（近→遠）排序。
    func scanTodos(includeDone: Bool = false) -> [TodoItem] {
        var result: [TodoItem] = []
        for url in allNoteURLs() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
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
        guard let content = try? String(contentsOf: item.noteURL, encoding: .utf8) else { return }
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

    /// 所有帶 @due 的未完成待辦（筆記 + 全部日記），依到期日排序。
    /// 給日記頁「即將到期」區：項目會出現在今天～到期日之間每一天的日記上方。
    func dueTodos() -> [TodoItem] {
        var result = scanTodos().filter { $0.meta.due != nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        for (url, _) in journalFiles(dateFormatter: df) {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in content.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ]") else { continue }
                let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let meta = TodoMeta.parse(text)
                guard meta.due != nil else { continue }
                result.append(TodoItem(
                    noteURL: url, lineIndex: i, text: text, done: false, meta: meta))
            }
        }
        return result.sorted { ($0.meta.due ?? .distantFuture) < ($1.meta.due ?? .distantFuture) }
    }

    // MARK: - 到期待辦每日搬移（bullet journal migration）

    private static let migrationDayKey = "researchHub.lastDueMigrationDay"

    /// 把仍未完成的 @due 待辦搬進今天的日記（每天只跑一次）：
    /// - 舊日記裡的 live 副本（`- [ ]` 帶 @due）標成 `- [>]`（已搬移），
    ///   當天掛的子項進度留在原地；今天的日記出現唯一一份 live 副本。
    /// - `generalDueLines` 是一般待辦中帶 @due 的原始文字；實際搬入的會列在回傳值，
    ///   由呼叫端把它們從一般待辦移除。
    /// 必須在今天的日記編輯器載入「之前」呼叫（首頁 refresh、手機今天頁 load）。
    @discardableResult
    func migrateDueTodos(generalDueLines: [String] = []) -> [String] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let todayKey = df.string(from: .now)
        guard UserDefaults.standard.string(forKey: Self.migrationDayKey) != todayKey,
              let todayURL = journalURL(for: .now)
        else { return [] }
        let today = Calendar.current.startOfDay(for: .now)

        // 今天已有的 live 待辦（避免重複搬入）
        var todayContent = (try? String(contentsOf: todayURL, encoding: .utf8)) ?? ""
        var existing = Set<String>()
        for line in todayContent.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ]") else { continue }
            let text = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            existing.insert(TodoMeta.parse(text).cleanText)
        }

        // 舊日記的 live @due 項目：標 - [>]、收集要搬的原始文字（含標記）
        var carried: [String] = []
        for (url, day) in journalFiles(dateFormatter: df) where day < today {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lines = content.components(separatedBy: "\n")
            var dirty = false
            for i in lines.indices {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ]") else { continue }
                let raw = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                let meta = TodoMeta.parse(raw)
                guard meta.due != nil, !raw.isEmpty else { continue }
                if let range = lines[i].range(of: "- [ ]") {
                    lines[i].replaceSubrange(range, with: "- [>]")
                    dirty = true
                }
                if !existing.contains(meta.cleanText) {
                    carried.append(raw)
                    existing.insert(meta.cleanText)
                }
            }
            if dirty {
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }

        // 一般待辦的 @due：搬入今天，回報給呼叫端移除
        var migratedGenerals: [String] = []
        for text in generalDueLines {
            let meta = TodoMeta.parse(text)
            guard meta.due != nil else { continue }
            migratedGenerals.append(text)
            guard !existing.contains(meta.cleanText) else { continue }
            carried.append(text)
            existing.insert(meta.cleanText)
        }

        if !carried.isEmpty {
            try? fm.createDirectory(
                at: todayURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !todayContent.isEmpty && !todayContent.hasSuffix("\n") { todayContent += "\n" }
            if !todayContent.isEmpty { todayContent += "\n" }
            todayContent += carried.map { "- [ ] \($0)" }.joined(separator: "\n\n") + "\n"
            try? todayContent.write(to: todayURL, atomically: true, encoding: .utf8)
        }
        UserDefaults.standard.set(todayKey, forKey: Self.migrationDayKey)
        return migratedGenerals
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
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ]") else { continue }
                let raw = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                let text = TodoMeta.parse(raw).cleanText
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
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
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
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
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
