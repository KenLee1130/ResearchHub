import Foundation

/// 搜尋範圍（docs/ARCHITECTURE.md 第 4 節）：⌘F 是「以頁面為範圍的跨文件搜尋」，⌘K 是範圍＝全部。
/// 同一個引擎、四種範圍；呈現由各頁面決定（日記＝時間軸、論文＝兩段式、筆記＝合併列表、⌘K＝palette）。
public enum SearchScope: Sendable, Hashable {
    /// 日記頁：所有日記，依日期排序，不設筆數上限
    case journal
    /// 論文頁：論文（標題／作者／摘要／標籤）＋筆記
    case papersAndNotes
    /// 筆記頁：Notes/ 下的 .md，加上 LaTeX 專案裡的 .tex／.bib（排在筆記後面）
    case notes
    /// ⌘K palette：日記、筆記、LaTeX、論文、待辦，每類最多 `perKindLimit` 筆
    case all
}

/// 全 app 搜尋引擎（以前叫 GlobalSearch）。
///
/// 全部在背景執行緒跑（`search` 是 nonisolated），畫面只拿結果。
/// 檔案內容依「路徑＋修改時間」快取，打字時每次重搜不必重讀沒變的檔。
/// 比對：不分大小寫；空白分開的多個關鍵字要全部出現（AND）。
public nonisolated enum SearchEngine {

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
        /// 命中的是檔名、標題、內文（筆記內文／論文摘要等書目資料），還是論文的 PDF 全文
        public enum Field: Sendable, Hashable { case fileName, title, body, fullText }

        public let id: String
        public let kind: Kind
        public let title: String
        public let target: Target
        /// 主要命中欄位（筆記：檔名優先）
        public let field: Field
        /// 所有命中的欄位（同篇檔名、內文都中就有兩個，列表可標兩個標籤）
        public let fields: Set<Field>
        /// 內文命中：第一個關鍵字所在的行（0-based）；非內文命中為 0
        public let line: Int
        /// 內文命中：該行內的字元範圍（UTF-16 offset）；非內文命中為 0..<0
        public let range: Range<Int>
        /// 符合處前後的一段文字（標題就符合時可能是 nil）
        public let snippet: String?
        /// 日記：那一天（時間軸排序用）
        public let date: Date?

        public init(id: String, kind: Kind, title: String, target: Target,
                    field: Field = .body, fields: Set<Field>? = nil,
                    line: Int = 0, range: Range<Int> = 0..<0, snippet: String?, date: Date? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.target = target
            self.field = field; self.fields = fields ?? [field]
            self.line = line; self.range = range; self.snippet = snippet; self.date = date
        }
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
        /// PDF 全文（Zotero 的索引；還沒建好就 nil）。書目資料沒中才看它。
        public let fullText: String?

        public init(key: String, title: String, authors: String, year: String,
                    venue: String, abstract: String, tags: [String], fullText: String? = nil) {
            self.key = key; self.title = title; self.authors = authors; self.year = year
            self.venue = venue; self.abstract = abstract; self.tags = tags; self.fullText = fullText
        }
    }

    /// ⌘K 每一類最多列幾筆（太多也看不完，而且列表會卡）；其他範圍不設上限
    public static let perKindLimit = 30

    /// 內文命中的位置：行號（0-based）與行內範圍（UTF-16 offset），加上前後的片段
    public struct BodyMatch: Sendable, Hashable {
        public let line: Int
        public let range: Range<Int>
        public let snippet: String
    }

    // MARK: - 入口

    public static func search(_ rawQuery: String, scope: SearchScope, root: URL?,
                              papers: [PaperEntry] = [], todos: [String] = []) -> [Hit] {
        let terms = rawQuery.lowercased()
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        switch scope {
        case .all:
            return searchAll(terms, root: root, papers: papers, todos: todos)
        case .journal:
            return journalHits(terms, root: root, limit: nil)
        case .notes:
            let (notes, latex) = noteHits(terms, root: root, includeLatex: true, limit: nil)
            return notes + latex
        case .papersAndNotes:
            let papers = paperHits(terms, papers: papers, limit: nil)
            let notes = noteHits(terms, root: root, includeLatex: false, limit: nil).notes
            return papers + notes
        }
    }

    /// 舊的 ⌘K 行為（範圍＝全部，每類最多 30 筆）
    private static func searchAll(_ terms: [String], root: URL?,
                                  papers: [PaperEntry], todos: [String]) -> [Hit] {
        var hits: [Hit] = []
        hits += journalHits(terms, root: root, limit: perKindLimit)
        if Task.isCancelled { return [] }
        let (notes, latex) = noteHits(terms, root: root, includeLatex: true, limit: perKindLimit)
        hits += notes + latex
        if Task.isCancelled { return [] }
        hits += paperHits(terms, papers: papers, limit: perKindLimit)
        // 一般待辦（日記裡的待辦已經算在日記結果裡）
        var n = 0
        for (i, t) in todos.enumerated() where n < perKindLimit {
            guard terms.allSatisfy({ t.lowercased().contains($0) }) else { continue }
            hits.append(Hit(id: "t:\(i)", kind: .todo, title: t, target: .home, field: .title, snippet: nil))
            n += 1
        }
        return hits
    }

    // MARK: - 各類

    /// 日記：新的在前；每天最多一筆（第一個命中處）
    static func journalHits(_ terms: [String], root: URL?, limit: Int?) -> [Hit] {
        let journalDir = root?.appendingPathComponent("Journal", isDirectory: true)
        let titleFormat = DateFormatter()
        titleFormat.dateFormat = "yyyy/M/d（EEE）"
        titleFormat.locale = Locale(identifier: "zh_TW")
        var hits: [Hit] = []
        for (url, date) in JournalLayout.journalFiles(journal: journalDir).sorted(by: { $0.1 > $1.1 }) {
            if Task.isCancelled { return [] }
            if let limit, hits.count >= limit { break }
            guard let text = cachedText(url), let m = bodyMatch(terms, in: text) else { continue }
            hits.append(Hit(id: "j:" + url.path, kind: .journal,
                            title: titleFormat.string(from: date) + " 日記",
                            target: .journal(date), field: .body,
                            line: m.line, range: m.range, snippet: m.snippet, date: date))
        }
        return hits
    }

    /// 筆記（.md）與 LaTeX 專案（.tex／.bib），檔名或內文符合都算。
    /// 筆記範圍：檔名命中排前、內文命中排後；同篇兩者都中合併成一筆（fields 有兩個）。
    static func noteHits(_ terms: [String], root: URL?, includeLatex: Bool,
                         limit: Int?) -> (notes: [Hit], latex: [Hit]) {
        let notesDir = root?.appendingPathComponent("Notes", isDirectory: true)
        var noteHits: [Hit] = [], latexHits: [Hit] = []
        guard let notesDir, let walker = FileManager.default.enumerator(
            at: notesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return ([], []) }
        var projectCache: [String: URL?] = [:]
        for case let url as URL in walker {
            if Task.isCancelled { return ([], []) }
            let ext = url.pathExtension.lowercased()
            guard ["md", "tex", "bib"].contains(ext) else { continue }
            if url.deletingLastPathComponent().lastPathComponent == "assets" { continue }
            let project = enclosingProject(of: url, notes: notesDir, cache: &projectCache)
            if project != nil, !includeLatex { continue }
            if project == nil, ext != "md" { continue }
            if let limit {
                if project != nil, latexHits.count >= limit { continue }
                if project == nil, noteHits.count >= limit { continue }
            }

            let name = url.deletingPathExtension().lastPathComponent
            let nameMatches = terms.allSatisfy { name.lowercased().contains($0) }
            guard let text = cachedText(url) else { continue }
            let m = bodyMatch(terms, in: text)
            guard nameMatches || m != nil else { continue }
            var fields: Set<Hit.Field> = []
            if nameMatches { fields.insert(.fileName) }
            if m != nil { fields.insert(.body) }

            if let project {
                let rel = url.path.replacingOccurrences(of: project.path + "/", with: "")
                latexHits.append(Hit(id: "l:" + url.path, kind: .latex,
                                     title: project.lastPathComponent + " › " + rel,
                                     target: .latex(project: project),
                                     field: nameMatches ? .fileName : .body, fields: fields,
                                     line: m?.line ?? 0, range: m?.range ?? 0..<0, snippet: m?.snippet))
            } else {
                noteHits.append(Hit(id: "n:" + url.path, kind: .note, title: name,
                                    target: .note(url),
                                    field: nameMatches ? .fileName : .body, fields: fields,
                                    line: m?.line ?? 0, range: m?.range ?? 0..<0, snippet: m?.snippet))
            }
        }
        // 檔名命中排前、內文命中排後（穩定排序，各自維持走訪順序）
        let ordered = noteHits.enumerated().sorted { a, b in
            let ka = a.element.field == .fileName ? 0 : 1, kb = b.element.field == .fileName ? 0 : 1
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        return (ordered, latexHits)
    }

    /// 論文：標題、作者、年份、期刊、摘要、標籤，書目沒中再看 PDF 全文。
    /// 排序：標題／作者命中 → 其他書目欄位命中 → 全文命中（各組內維持原順序）。
    static func paperHits(_ terms: [String], papers: [PaperEntry], limit: Int?) -> [Hit] {
        var head: [Hit] = [], meta: [Hit] = [], body: [Hit] = []
        for p in papers {
            if Task.isCancelled { return [] }
            if let limit, head.count + meta.count + body.count >= limit { break }
            let haystack = [p.title, p.authors, p.year, p.venue, p.abstract, p.tags.joined(separator: " ")]
                .joined(separator: "\n").lowercased()
            let title = p.title.isEmpty ? "（無標題）" : p.title
            let byline = [p.authors, p.year].filter { !$0.isEmpty }.joined(separator: " · ")
            if terms.allSatisfy({ haystack.contains($0) }) {
                // 標題／作者沒中才顯示摘要片段
                let headText = [p.title, p.authors].joined(separator: " ").lowercased()
                let headMatch = terms.allSatisfy { headText.contains($0) }
                let hit = Hit(id: "p:" + p.key, kind: .paper, title: title,
                              target: .paper(key: p.key), field: headMatch ? .title : .body,
                              snippet: headMatch ? byline : (match(terms, in: p.abstract) ?? p.authors))
                if headMatch { head.append(hit) } else { meta.append(hit) }
            } else if let text = p.fullText, let m = bodyMatch(terms, in: text) {
                body.append(Hit(id: "p:" + p.key, kind: .paper, title: title,
                                target: .paper(key: p.key), field: .fullText,
                                line: m.line, range: m.range, snippet: m.snippet))
            }
        }
        return head + meta + body
    }

    // MARK: - 比對與片段

    /// 全部關鍵字都出現 → 回傳第一個關鍵字附近的一段文字（前後約 40 字、換行壓成空白）
    public static func match(_ terms: [String], in text: String) -> String? {
        bodyMatch(terms, in: text)?.snippet
    }

    /// 全部關鍵字都出現 → 第一個關鍵字的行號、行內範圍與片段
    public static func bodyMatch(_ terms: [String], in text: String) -> BodyMatch? {
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
        let snippet = (lo > 0 ? "…" : "") + piece + (hi < ns.length ? "…" : "")
        // 行號與行內範圍
        let before = ns.substring(to: min(startOffset, ns.length))
        let line = before.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let lineStart = (before as NSString).range(of: "\n", options: .backwards).location
        let base = lineStart == NSNotFound ? 0 : lineStart + 1
        return BodyMatch(line: line, range: (startOffset - base)..<(endOffset - base), snippet: snippet)
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
