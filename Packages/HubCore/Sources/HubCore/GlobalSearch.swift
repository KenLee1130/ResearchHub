import Foundation

/// 全 app 搜尋（⌘F）：日記、筆記、LaTeX 專案、論文、一般待辦。
///
/// 全部在背景執行緒跑（`search` 是 nonisolated），畫面只拿結果。
/// 檔案內容依「路徑＋修改時間」快取，打字時每次重搜不必重讀沒變的檔。
/// 比對：不分大小寫；空白分開的多個關鍵字要全部出現（AND）。
public nonisolated enum GlobalSearch {

    public enum Kind: Int, Sendable, CaseIterable {
        case journal, note, latex, paper, todo

        public var title: String {
            switch self {
            case .journal: return "日記"
            case .note: return "筆記"
            case .latex: return "LaTeX 專案"
            case .paper: return "論文"
            case .todo: return "待辦"
            }
        }

        public var icon: String {
            switch self {
            case .journal: return "book.closed"
            case .note: return "doc.text"
            case .latex: return "function"
            case .paper: return "books.vertical"
            case .todo: return "checklist"
            }
        }
    }

    /// 要點過去的地方
    public enum Target: Sendable, Hashable {
        case journal(Date)
        case note(URL)
        case latex(project: URL)
        case paper(key: String)
        case home
    }

    public struct Hit: Identifiable, Sendable, Hashable {
        public let id: String
        public let kind: Kind
        public let title: String
        /// 符合處前後的一段文字（標題就符合時可能是 nil）
        public let snippet: String?
        public let target: Target
    }

    /// 論文的可搜尋欄位（在主執行緒從 ZoteroItem 抽出來再丟到背景）
    public struct PaperEntry: Sendable {
        public let key: String
        public let title: String
        public let authors: String
        public let year: String
        public let venue: String
        public let abstract: String
        public let tags: [String]

        public init(key: String, title: String, authors: String, year: String,
                    venue: String, abstract: String, tags: [String]) {
            self.key = key; self.title = title; self.authors = authors; self.year = year
            self.venue = venue; self.abstract = abstract; self.tags = tags
        }
    }

    /// 每一類最多列幾筆（太多也看不完，而且列表會卡）
    public static let perKindLimit = 30

    public static func search(_ rawQuery: String, root: URL?,
                       papers: [PaperEntry], todos: [String]) -> [Hit] {
        let terms = rawQuery.lowercased()
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var hits: [Hit] = []

        // 日記：新的在前
        let journalDir = root?.appendingPathComponent("Journal", isDirectory: true)
        let titleFormat = DateFormatter()
        titleFormat.dateFormat = "yyyy/M/d（EEE）"
        titleFormat.locale = Locale(identifier: "zh_TW")
        var n = 0
        for (url, date) in JournalLayout.journalFiles(journal: journalDir).sorted(by: { $0.1 > $1.1 }) {
            if Task.isCancelled { return [] }
            guard n < perKindLimit, let text = cachedText(url),
                  let snippet = match(terms, in: text) else { continue }
            hits.append(Hit(id: "j:" + url.path, kind: .journal,
                            title: titleFormat.string(from: date) + " 日記",
                            snippet: snippet, target: .journal(date)))
            n += 1
        }

        // 筆記（.md）與 LaTeX 專案（.tex／.bib），檔名或內文符合都算
        let notesDir = root?.appendingPathComponent("Notes", isDirectory: true)
        var noteHits: [Hit] = [], latexHits: [Hit] = []
        if let notesDir, let walker = FileManager.default.enumerator(
            at: notesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var projectCache: [String: URL?] = [:]
            for case let url as URL in walker {
                if Task.isCancelled { return [] }
                let ext = url.pathExtension.lowercased()
                guard ["md", "tex", "bib"].contains(ext) else { continue }
                if url.deletingLastPathComponent().lastPathComponent == "assets" { continue }
                let project = enclosingProject(of: url, notes: notesDir, cache: &projectCache)
                if project == nil, ext != "md" { continue }
                if project != nil, latexHits.count >= perKindLimit { continue }
                if project == nil, noteHits.count >= perKindLimit { continue }

                let name = url.deletingPathExtension().lastPathComponent
                let nameMatches = terms.allSatisfy { name.lowercased().contains($0) }
                guard let text = cachedText(url) else { continue }
                let snippet = match(terms, in: text)
                guard nameMatches || snippet != nil else { continue }

                if let project {
                    let rel = url.path.replacingOccurrences(of: project.path + "/", with: "")
                    latexHits.append(Hit(id: "l:" + url.path, kind: .latex,
                                         title: project.lastPathComponent + " › " + rel,
                                         snippet: snippet, target: .latex(project: project)))
                } else {
                    noteHits.append(Hit(id: "n:" + url.path, kind: .note, title: name,
                                        snippet: snippet, target: .note(url)))
                }
            }
        }
        hits += noteHits + latexHits

        // 論文：標題、作者、年份、期刊、摘要、標籤
        n = 0
        for p in papers {
            if Task.isCancelled { return [] }
            guard n < perKindLimit else { break }
            let haystack = [p.title, p.authors, p.year, p.venue, p.abstract, p.tags.joined(separator: " ")]
                .joined(separator: "\n")
            guard terms.allSatisfy({ haystack.lowercased().contains($0) }) else { continue }
            // 標題／作者沒中才顯示摘要片段
            let head = [p.title, p.authors].joined(separator: " ").lowercased()
            let snippet = terms.allSatisfy({ head.contains($0) })
                ? [p.authors, p.year].filter { !$0.isEmpty }.joined(separator: " · ")
                : match(terms, in: p.abstract) ?? p.authors
            hits.append(Hit(id: "p:" + p.key, kind: .paper,
                            title: p.title.isEmpty ? "（無標題）" : p.title,
                            snippet: snippet, target: .paper(key: p.key)))
            n += 1
        }

        // 一般待辦（日記裡的待辦已經算在日記結果裡）
        n = 0
        for (i, t) in todos.enumerated() where n < perKindLimit {
            guard terms.allSatisfy({ t.lowercased().contains($0) }) else { continue }
            hits.append(Hit(id: "t:\(i)", kind: .todo, title: t, snippet: nil, target: .home))
            n += 1
        }
        return hits
    }

    // MARK: - 比對與片段

    /// 全部關鍵字都出現 → 回傳第一個關鍵字附近的一段文字（前後約 40 字、換行壓成空白）
    public static func match(_ terms: [String], in text: String) -> String? {
        let lower = text.lowercased()
        guard terms.allSatisfy({ lower.contains($0) }),
              let first = terms.first, let r = lower.range(of: first) else { return nil }
        // lowercased 可能改變字串長度（少數語言），用 utf16 offset 對回原字串比較穩
        let startOffset = lower.utf16.distance(from: lower.startIndex, to: r.lowerBound)
        let endOffset = lower.utf16.distance(from: lower.startIndex, to: r.upperBound)
        let ns = text as NSString
        let lo = max(0, startOffset - 40), hi = min(ns.length, endOffset + 40)
        guard lo < hi else { return nil }
        let piece = ns.substring(with: NSRange(location: lo, length: hi - lo))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (lo > 0 ? "…" : "") + piece + (hi < ns.length ? "…" : "")
    }

    /// url 在哪個 LaTeX 專案裡（沒有就 nil）。逐層往上找到 Notes 為止，結果快取。
    private static func enclosingProject(of url: URL, notes: URL,
                                         cache: inout [String: URL?]) -> URL? {
        var dir = url.deletingLastPathComponent()
        var visited: [String] = []
        while dir.path.hasPrefix(notes.path), dir.path != notes.path {
            if let known = cache[dir.path] {
                visited.forEach { cache[$0] = known }
                return known
            }
            visited.append(dir.path)
            if LatexProject.isProject(dir) {
                visited.forEach { cache[$0] = dir }
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        visited.forEach { cache[$0] = .some(nil) }
        return nil
    }

    // MARK: - 內容快取（路徑＋修改時間）

    private final class TextCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (Date, String)] = [:]

        func text(for url: URL) -> String? {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            lock.lock()
            if let (cached, text) = entries[url.path], cached == mtime {
                lock.unlock()
                return text
            }
            lock.unlock()
            // iCloud 還沒下載的檔：safeRead 會請系統去下載、這次先略過
            guard let text = ICloudFile.safeRead(url) else { return nil }
            lock.lock()
            entries[url.path] = (mtime, text)
            lock.unlock()
            return text
        }
    }

    private static let cache = TextCache()

    private static func cachedText(_ url: URL) -> String? { cache.text(for: url) }
}
