#if os(macOS)
import Foundation
import Observation
import PDFKit

// MARK: - 資料模型（存在 <資料夾>/Papers/<Zotero key>/chat.json）

/// 回答裡的一則引文：模型宣稱「第 page 頁有這段原文」。
/// app 會拿論文抽出來的文字逐字比對，對得上才算 verified——幻覺最常見的樣子就是
/// 「引用了論文沒寫的話」或「頁碼亂掰」，這一步把它們標出來。
nonisolated struct PaperCitation: Codable, Hashable, Sendable {
    var page: Int
    var quote: String
    /// 原文裡真的找到了（找到的頁碼可能跟模型說的差一頁，以實際找到的為準）
    var verified: Bool
    var foundPage: Int?
}

nonisolated struct PaperChatMessage: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, error }
    var id = UUID()
    var role: Role
    var text: String
    /// 提問時引用的 PDF 選取文字與頁碼
    var quote: String?
    var quotePage: Int?
    /// 回答的 AI（例如「Claude Opus 5.5 · high」）
    var provider: String?
    var createdAt = Date()
    var citations: [PaperCitation]?
}

nonisolated struct PaperChatFile: Codable, Sendable {
    var zoteroKey: String
    var title: String
    var messages: [PaperChatMessage] = []
    /// 各 AI 的對話 session（接續追問時不必重送整篇論文）
    var sessions: [String: String] = [:]
}

/// 可以問的 AI 服務。都用使用者自己的訂閱：Claude Code CLI、Codex CLI（ChatGPT 帳號登入）。
nonisolated enum PaperProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, chatgpt
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "ChatGPT" }
    var cli: String { self == .claude ? "claude" : "codex" }
}

/// 一個可選的模型，以及它支援的思考強度（effort）。
nonisolated struct PaperModel: Hashable, Identifiable, Sendable {
    let id: String          // 傳給 CLI 的模型名
    let label: String
    let efforts: [String]
    let defaultEffort: String

    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// Claude Code 支援的模型（舊版 CLI 不認得新模型——2026-10-01 從 2.1.161 更新後才能用 Opus 5.5／Fable 5.1）
    static let claude: [PaperModel] = [
        .init(id: "claude-opus-5-5", label: "Opus 5.5", efforts: claudeEfforts, defaultEffort: "high"),
        .init(id: "claude-fable-5-1", label: "Fable 5.1", efforts: claudeEfforts, defaultEffort: "high"),
        .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5", efforts: claudeEfforts, defaultEffort: "high"),
        .init(id: "claude-haiku-4-5", label: "Haiku 4.5", efforts: claudeEfforts, defaultEffort: "medium"),
    ]
    /// ChatGPT 帳號能用哪些模型由小幫手讀 Codex 的模型清單（helper models）；讀不到時用這份
    static let chatgptFallback: [PaperModel] = [
        .init(id: "gpt-5.6-sol", label: "GPT-5.6-Sol",
              efforts: ["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "medium"),
        .init(id: "gpt-5.5", label: "GPT-5.5",
              efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
    ]

    /// 解析 helper models 的輸出（slug \t 名稱 \t effort1,effort2 \t 預設）
    static func parseCodex(_ output: String) -> [PaperModel] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty, !f[0].contains("=") else { return nil }
            let efforts = f[2].split(separator: ",").map(String.init)
            return PaperModel(id: f[0], label: f[1], efforts: efforts,
                              defaultEffort: f[3].isEmpty ? (efforts.first ?? "medium") : f[3])
        }
    }
}

/// 一次提問用哪個 AI、哪個模型、多強的思考
nonisolated struct PaperAIChoice: Sendable {
    var provider: PaperProvider
    var model: PaperModel
    var effort: String
    var label: String { "\(provider.label) \(model.label) · \(effort)" }
}

/// ChatGPT 帳號能選的模型（跟 Codex 要一次，記在 UserDefaults，下次開 app 先用舊的）
@Observable
@MainActor
final class PaperModelCatalog {
    static let shared = PaperModelCatalog()
    private(set) var chatgpt: [PaperModel]
    @ObservationIgnored private var loaded = false
    private static let cacheKey = "paperChat.codexModels"

    private init() {
        let cached = UserDefaults.standard.string(forKey: Self.cacheKey).map(PaperModel.parseCodex) ?? []
        chatgpt = cached.isEmpty ? PaperModel.chatgptFallback : cached
    }

    func refresh() {
        guard !loaded else { return }
        loaded = true
        LatexCompiler.runHelper(["models"]) { [weak self] output, _ in
            let models = PaperModel.parseCodex(output)
            guard let self, !models.isEmpty else { return }
            self.chatgpt = models
            UserDefaults.standard.set(output, forKey: Self.cacheKey)
        }
    }
}

// MARK: - 論文文字（分頁）

/// 從 PDF 抽出每一頁的文字。提問時整篇（附頁碼）交給 AI，核對引文也靠它。
nonisolated enum PaperText {
    static func pages(from data: Data) -> [String] {
        guard let doc = PDFDocument(data: data) else { return [] }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    /// 給 AI 看的全文：每頁前面標 [p.N]。太長的論文截斷（避免超出模型的上下文）。
    static func promptText(_ pages: [String], limit: Int = 350_000) -> String {
        var out = ""
        for (i, page) in pages.enumerated() {
            let chunk = "\n\n[p.\(i + 1)]\n" + page
            if out.count + chunk.count > limit {
                out += "\n\n[…論文後面的頁數太長，已省略…]"
                break
            }
            out += chunk
        }
        return out
    }

    /// 比對用的正規化：PDF 抽出的文字常有連字（ﬁ）、斷行連字號、怪空白，
    /// 模型引用時又會把它們寫成正常字。全部攤平再比。
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        let replacements: [(String, String)] = [
            ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl"),
            ("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("−", "-"),
        ]
        for (a, b) in replacements { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "-\n", with: "")
        return String(t.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(Character.init))
    }

    /// 寬鬆比對用：只留字母與數字。PDF 抽字常把數學符號弄丟（√ 不見、∆ 變怪字），
    /// 而模型引用時會寫回正確的符號——這種不是幻覺，不該被標成找不到。
    static func loose(_ s: String) -> String {
        String(normalize(s).unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.map(Character.init))
    }

    /// 找引文實際在哪一頁（先看模型說的那頁，再看前後一頁，最後全篇；也看跨頁的接縫）。
    /// 引文用「…」省略中間時，各段都要找得到。太短的引文（< 20 字元）不算數——
    /// 「OPE coefficients」這種到處都有的片語，找得到也證明不了什麼。
    static func locate(quote: String, claimedPage: Int, in pages: [String],
                       normalized: [String]) -> Int? {
        let raw = quote.components(separatedBy: "…").flatMap { $0.components(separatedBy: "...") }
        let strictParts = raw.map(normalize).filter { $0.count >= 6 }
        let looseParts = raw.map(loose).filter { $0.count >= 6 }
        guard strictParts.reduce(0, { $0 + $1.count }) >= 20 else { return nil }
        let looseText = normalized.map { s in
            String(s.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }.map(Character.init))
        }
        var order = [claimedPage, claimedPage - 1, claimedPage + 1]
        order += Array(1...max(1, pages.count)).filter { !order.contains($0) }
        // 一頁的文字，加上下一頁開頭一小段（引文常常剛好跨頁）
        func window(_ texts: [String], _ p: Int) -> String {
            texts[p - 1] + (p < texts.count ? String(texts[p].prefix(400)) : "")
        }
        for p in order where p >= 1 && p <= normalized.count {
            let w = window(normalized, p)
            if strictParts.allSatisfy({ w.contains($0) }) { return p }
        }
        for p in order where p >= 1 && p <= looseText.count {
            let w = window(looseText, p)
            if !looseParts.isEmpty, looseParts.allSatisfy({ w.contains($0) }) { return p }
        }
        return nil
    }

    /// 解析回答裡的引文標記 [p.3「…」]，逐一核對。
    static func citations(in answer: String, pages: [String], normalized: [String]) -> [PaperCitation] {
        guard let re = try? NSRegularExpression(pattern: #"\[p\.?\s*(\d+)\s*[「"“](.+?)[」"”]\s*\]"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = answer as NSString
        return re.matches(in: answer, range: NSRange(location: 0, length: ns.length)).map { m in
            let page = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let quote = ns.substring(with: m.range(at: 2))
            let found = locate(quote: quote, claimedPage: page, in: pages, normalized: normalized)
            return PaperCitation(page: page, quote: quote, verified: found != nil, foundPage: found)
        }
    }
}

// MARK: - 一篇論文的問答

@Observable
@MainActor
final class PaperChatSession {
    let zoteroKey: String
    let title: String
    private(set) var chat: PaperChatFile
    /// 正在產生中的回答（串流）
    private(set) var streamingText = ""
    private(set) var isAsking = false
    private(set) var pagesReady = false

    @ObservationIgnored private var pages: [String] = []
    @ObservationIgnored private var normalizedPages: [String] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(item: ZoteroItem, root: URL?) {
        zoteroKey = item.key
        title = item.title
        let dir = root.map { Self.paperDir(root: $0, key: item.key) }
        fileURL = dir?.appendingPathComponent("chat.json")
        if let fileURL, let text = FileSystemStore.safeRead(fileURL),
           let loaded = try? JSONDecoder.iso.decode(PaperChatFile.self, from: Data(text.utf8)) {
            chat = loaded
        } else {
            chat = PaperChatFile(zoteroKey: item.key, title: item.title)
        }
    }

    /// <資料夾>/Papers/<Zotero key>/：問答紀錄、中文版 PDF 都放這裡（跟著 iCloud 走）
    static func paperDir(root: URL, key: String) -> URL {
        root.appendingPathComponent("Papers", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// PDF 載入後在背景抽文字
    func loadPaper(_ data: Data) {
        Task {
            let extracted = await Task.detached(priority: .userInitiated) { () -> ([String], [String]) in
                let p = PaperText.pages(from: data)
                return (p, p.map(PaperText.normalize))
            }.value
            pages = extracted.0
            normalizedPages = extracted.1
            pagesReady = !pages.isEmpty
        }
    }

    func clear() {
        chat.messages = []
        chat.sessions = [:]
        save()
    }

    // MARK: 提問

    func ask(_ question: String, quote: String?, quotePage: Int?, ai: PaperAIChoice) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking else { return }
        chat.messages.append(PaperChatMessage(role: .user, text: q, quote: quote, quotePage: quotePage))
        save()

        let session = chat.sessions[ai.provider.rawValue]
        let prompt = buildPrompt(question: q, quote: quote, quotePage: quotePage,
                                 ai: ai, firstTurn: session == nil)
        let work = workDir
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try? Self.systemPrompt.write(to: work.appendingPathComponent("system.txt"),
                                     atomically: true, encoding: .utf8)
        try? prompt.write(to: work.appendingPathComponent("prompt.txt"),
                          atomically: true, encoding: .utf8)
        let out = work.appendingPathComponent("out.jsonl")
        try? FileManager.default.removeItem(at: out)

        isAsking = true
        streamingText = ""
        startPolling(out, ai: ai)
        LatexCompiler.runHelper(["ask", ai.provider.cli, work.path, ai.model.id, session ?? "-", ai.effort]) { [weak self] output, error in
            guard let self else { return }
            self.pollTask?.cancel()
            let fields = LatexCompiler.parseFields(output)
            let parsed = Self.parse(out: out, provider: ai.provider)
            if let sid = parsed.session { self.chat.sessions[ai.provider.rawValue] = sid }
            if let answer = parsed.answer, !answer.isEmpty {
                let cites = PaperText.citations(in: answer, pages: self.pages,
                                                normalized: self.normalizedPages)
                self.chat.messages.append(PaperChatMessage(
                    role: .assistant, text: answer, provider: ai.label, citations: cites))
            } else {
                // 接續的 session 失效（例如被清掉了）→ 下次重開新對話
                if session != nil { self.chat.sessions[ai.provider.rawValue] = nil }
                let detail = error?.localizedDescription ?? fields["ERR"]
                    ?? parsed.error ?? (fields["TIMEOUT"] == "1" ? "超過 5 分鐘沒有回應" : "沒有收到回答")
                self.chat.messages.append(PaperChatMessage(
                    role: .error, text: "\(ai.label) 沒有回答：\(detail)", provider: ai.label))
            }
            self.streamingText = ""
            self.isAsking = false
            self.save()
        }
    }

    /// 容器裡的工作資料夾（小幫手不能碰 iCloud，題目和回覆都在這裡交換）
    private var workDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("papers/\(zoteroKey)", isDirectory: true)
    }

    /// 防幻覺的規則。重點是「每個關於論文的說法都要附逐字引文」，app 會核對。
    static let systemPrompt = """
    你是研究論文的閱讀助理。使用者正在讀一篇論文，論文全文（每頁前面標了 [p.N]）在第一則訊息裡。
    規則：
    1. 用繁體中文回答；術語第一次出現時附英文原文。數學用 LaTeX（行內 $...$，獨立式 $$...$$）。
    2. 關於「這篇論文說了什麼」的每個重點，都要附上引文，格式必須是 [p.頁碼「英文原文逐字片段」]。
       引文必須從論文一字不改地複製（可用 … 省略中間），長度 5 到 30 個英文字；不要翻譯引文。
    3. 論文裡找不到根據的，直接說「論文中沒有提到」，不要猜。
    4. 需要用到論文以外的背景知識時，可以講，但必須在那段開頭標「（背景知識，非論文內容）」，且不要附引文。
    5. 不確定的地方要說不確定。回答精簡，先給結論再解釋。
    """

    private func buildPrompt(question: String, quote: String?, quotePage: Int?,
                             ai: PaperAIChoice, firstTurn: Bool) -> String {
        var parts: [String] = []
        if firstTurn {
            if ai.provider == .chatgpt { parts.append(Self.systemPrompt) }   // Codex 沒有 system prompt 參數
            parts.append("論文標題：\(title)\n\n=== 論文全文開始 ===\(PaperText.promptText(pages))\n=== 論文全文結束 ===")
            // 換一個 AI 接手時，讓它知道之前問過什麼（例如請它給第二意見）
            let history = chat.messages.dropLast().suffix(8).filter { $0.role != .error }
            if !history.isEmpty {
                let lines = history.map { m in
                    (m.role == .user ? "使用者：" : "助理（\(m.provider ?? "AI")）：") + m.text
                }
                parts.append("=== 先前的問答（供參考，可能有錯，請以論文為準） ===\n" + lines.joined(separator: "\n\n"))
            }
        }
        if let quote, !quote.isEmpty {
            parts.append("我選取的段落（第 \(quotePage.map(String.init) ?? "?") 頁）：\n「\(quote)」")
        }
        parts.append("問題：\(question)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: 串流

    private func startPolling(_ out: URL, ai: PaperAIChoice) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let provider = ai.provider
                let partial = await Task.detached { Self.parse(out: out, provider: provider).partial }.value
                guard let self, !Task.isCancelled else { return }
                if partial != self.streamingText { self.streamingText = partial }
            }
        }
    }

    private struct Parsed: Sendable {
        var partial = ""
        var answer: String?
        var session: String?
        var error: String?
    }

    /// 讀小幫手寫出的 JSON lines（Claude 的 stream-json／Codex 的 exec --json）。
    nonisolated private static func parse(out: URL, provider: PaperProvider) -> Parsed {
        var r = Parsed()
        guard let text = try? String(contentsOf: out, encoding: .utf8) else { return r }
        for line in text.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let type = d["type"] as? String
            if provider == .chatgpt {
                if type == "thread.started" { r.session = d["thread_id"] as? String }
                if type == "item.completed", let item = d["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let t = item["text"] as? String {
                    r.answer = (r.answer.map { $0 + "\n\n" } ?? "") + t
                    r.partial = r.answer ?? ""
                }
                if type == "error" || type == "turn.failed" {
                    r.error = (d["message"] as? String)
                        ?? ((d["error"] as? [String: Any])?["message"] as? String) ?? "Codex 回報錯誤"
                }
            } else {
                if type == "stream_event", let ev = d["event"] as? [String: Any],
                   ev["type"] as? String == "content_block_delta",
                   let delta = ev["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                    r.partial += t
                }
                if type == "result" {
                    r.session = d["session_id"] as? String
                    if d["is_error"] as? Bool == true {
                        r.error = (d["result"] as? String) ?? "Claude 回報錯誤"
                    } else {
                        r.answer = d["result"] as? String
                    }
                }
            }
        }
        return r
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = chat
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.isoPretty.encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

extension JSONDecoder {
    nonisolated static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    nonisolated static var isoPretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
#endif
