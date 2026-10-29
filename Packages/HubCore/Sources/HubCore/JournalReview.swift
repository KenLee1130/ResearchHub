import Foundation

// 日記回顧（docs/ARCHITECTURE.md 5.2）：
// - 旁車檔 `.hub/journal-meta.json`：`{ "2026-10-11": { "kind": "log"|"reflective", "mood": -2..2, "themes": [...] } }`，
//   由 Claude（或任何外部工具）寫；app 只讀。檔裡有的欄位覆寫 app 自己的啟發式分類。
// - `JournalClassifier`：本地第一層分類，沒有旁車資料時決定一天是流水帳還是心得。

/// 一天的日記是「流水帳」（待辦／清單為主）還是「心得」（散文、有情緒）。
public nonisolated enum JournalKind: String, Codable, Sendable, Hashable {
    case log
    case reflective
}

/// 旁車檔裡一天的資料（每個欄位都可缺）。
public nonisolated struct JournalDayMeta: Codable, Sendable, Hashable {
    public var kind: JournalKind?
    /// -2（很糟）… 0 … 2（很好）；超出範圍的值讀進來會夾住
    public var mood: Int?
    public var themes: [String]

    public init(kind: JournalKind? = nil, mood: Int? = nil, themes: [String] = []) {
        self.kind = kind
        self.mood = mood.map { max(-2, min(2, $0)) }
        self.themes = themes
    }

    private enum CodingKeys: String, CodingKey { case kind, mood, themes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 認不得的 kind 字串當沒寫，不要讓整個檔解不開
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { JournalKind(rawValue: $0) }
        mood = (try? c.decodeIfPresent(Int.self, forKey: .mood)).map { max(-2, min(2, $0)) }
        themes = (try? c.decodeIfPresent([String].self, forKey: .themes)) ?? []
    }

    public var isEmpty: Bool { kind == nil && mood == nil && themes.isEmpty }
}

/// 整個旁車檔：日期字串（yyyy-MM-dd）→ 該天資料。
public nonisolated enum JournalMetaFile {
    public typealias Contents = [String: JournalDayMeta]

    public static func decode(_ data: Data) -> Contents? {
        try? JSONDecoder().decode(Contents.self, from: data)
    }

    public static func encode(_ contents: Contents) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(contents)
    }

    /// 旁車檔的鍵（yyyy-MM-dd，跟日記檔名一樣）
    public static func key(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func day(from key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

/// 本地啟發式分類（第一層；旁車檔的 kind 會覆寫）。
/// 待辦行佔比高且短 → log；散文多、有第一人稱情緒詞 → reflective。
public nonisolated enum JournalClassifier {
    public struct Analysis: Sendable, Hashable {
        public let kind: JournalKind
        /// 待辦／清單行佔非空行的比例
        public let listRatio: Double
        /// 散文（非標題、非清單、非待辦）的字元數
        public let proseChars: Int
        /// 命中的情緒／第一人稱詞數
        public let emotionHits: Int
        /// 散文行（去掉前綴、trim），摘錄用
        public let proseLines: [String]
    }

    /// 中英文情緒詞與第一人稱片語（小寫比對；中文直接子字串）
    static let emotionWords: [String] = [
        "我覺得", "我感覺", "我想", "覺得", "感覺", "開心", "快樂", "難過", "焦慮", "好累", "很累", "煩",
        "興奮", "期待", "害怕", "擔心", "沮喪", "挫折", "滿足", "感謝", "後悔", "希望", "壓力", "無力",
        "迷惘", "安心", "放鬆", "生氣", "失望", "驕傲", "幸福", "孤單", "想念", "反省", "領悟",
        "i feel", "i felt", "i think", "i'm ", "i am ", "frustrat", "anxious", "happy", "tired",
        "excited", "worried", "grateful", "stressed", "proud", "sad", "lonely", "relieved", "hope",
    ]

    public static func analyze(_ content: String) -> Analysis {
        var listLines = 0
        var nonEmpty = 0
        var proseLines: [String] = []
        var proseChars = 0
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            nonEmpty += 1
            if line.hasPrefix("#") { continue }   // 標題不算散文也不算清單
            // 分隔線（---、***、___）不是散文
            if line.range(of: #"^([-*_])\1{2,}$"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^(?:[-*+]|\d+\.)\s+(?:\[[ xX\-]\]\s*)?"#, options: .regularExpression) != nil
                || line.hasPrefix("> [!") {
                listLines += 1
                continue
            }
            // 表格、程式碼圍欄、圖片不是散文；引用（>）去掉符號後算散文
            if line.hasPrefix("|") || line.hasPrefix("```") || line.hasPrefix("![") { continue }
            let text = line.hasPrefix(">") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            proseLines.append(text)
            proseChars += text.count
        }
        let prose = proseLines.joined(separator: "\n").lowercased()
        let hits = emotionWords.reduce(0) { $0 + (prose.contains($1) ? 1 : 0) }
        let listRatio = nonEmpty == 0 ? 0 : Double(listLines) / Double(nonEmpty)

        let reflective = proseChars >= 120 && (hits >= 1 || proseChars >= 400) && listRatio < 0.7
        return Analysis(kind: reflective ? .reflective : .log,
                        listRatio: listRatio, proseChars: proseChars,
                        emotionHits: hits, proseLines: proseLines)
    }

    public static func classify(_ content: String) -> JournalKind { analyze(content).kind }

    /// 回顧頁的摘錄：散文行優先，沒有散文就退回待辦文字；最多 `limit` 字。
    public static func excerpt(_ content: String, limit: Int = 200) -> String {
        let a = analyze(content)
        var lines = a.proseLines
        if lines.isEmpty {
            lines = content.components(separatedBy: "\n")
                .map { LedgerParser.displayNote($0) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let joined = lines.joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
