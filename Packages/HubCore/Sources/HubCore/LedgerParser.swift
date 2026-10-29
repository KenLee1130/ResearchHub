import Foundation

/// 記帳：寫在日記任一行的 `@spend(金額, 類別)` 標記（docs/ARCHITECTURE.md 5.1）。
///   - 午餐 @spend(120, 餐費)
///   - [x] 買書 @spend(450, 書籍)
///   @spend(80)                  類別省略 → 歸「未分類」
/// 金額是純數字（可有小數；**不要**千分位逗號——逗號是類別分隔符）。
/// 一行可以有多個 @spend，各算一筆。類別只做去頭尾空白，大小寫比對交給 LedgerCategories。
public nonisolated struct LedgerEntry: Hashable, Sendable, Identifiable {
    /// 日記那天（startOfDay）
    public let day: Date
    public let amount: Double
    /// 類別原文（已 trim），沒寫 = LedgerParser.uncategorized
    public let category: String
    /// 這一行去掉 @spend、checkbox／bullet 前綴後的文字（顯示用）
    public let note: String
    public let lineIndex: Int

    public var id: String { "\(day.timeIntervalSince1970)#\(lineIndex)#\(amount)#\(category)" }

    public init(day: Date, amount: Double, category: String, note: String, lineIndex: Int) {
        self.day = day
        self.amount = amount
        self.category = category
        self.note = note
        self.lineIndex = lineIndex
    }
}

public nonisolated enum LedgerParser {
    /// 沒寫類別時的歸類名
    public static let uncategorized = "未分類"

    private static let pattern = try! NSRegularExpression(
        pattern: #"@spend\(\s*(-?\d+(?:\.\d+)?)\s*(?:,\s*([^)]*?)\s*)?\)"#,
        options: [.caseInsensitive])

    /// 一行裡的所有 @spend（金額, 類別?）。金額不是數字的寫法整個略過（照舊當普通文字）。
    public static func spends(inLine line: String) -> [(amount: Double, category: String?)] {
        let ns = line as NSString
        return pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let amount = Double(ns.substring(with: m.range(at: 1))) else { return nil }
            var category: String?
            if m.range(at: 2).location != NSNotFound {
                let raw = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                category = raw.isEmpty ? nil : raw
            }
            return (amount, category)
        }
    }

    /// 把 @spend(...) 從文字裡拿掉（待辦顯示用；TodoMeta.parse 也靠它）
    public static func strippingSpends(_ text: String) -> String {
        let ns = text as NSString
        return pattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// 整份日記 → 記帳條目
    public static func entries(in content: String, day: Date) -> [LedgerEntry] {
        var result: [LedgerEntry] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            guard line.localizedCaseInsensitiveContains("@spend(") else { continue }
            let spends = spends(inLine: line)
            guard !spends.isEmpty else { continue }
            let note = displayNote(strippingSpends(line))
            for s in spends {
                result.append(LedgerEntry(day: day, amount: s.amount,
                                          category: s.category ?? uncategorized,
                                          note: note, lineIndex: i))
            }
        }
        return result
    }

    /// 去掉 markdown 前綴（`- [ ]`、`- [x]`、`-`、`*`、`1.`）與多餘空白
    static func displayNote(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(?:[-*+]|\d+\.)\s+(?:\[[ xX\-]\]\s*)?"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// 類別白名單（`.hub/ledger-categories.json`：`{ "categories": ["餐費", …] }`）。
/// 比對不分大小寫、去頭尾空白；對得上就換成清單裡的寫法，對不上保留原文（不丟資料）。
public nonisolated struct LedgerCategories: Codable, Hashable, Sendable {
    public var categories: [String]

    public init(categories: [String]) { self.categories = categories }

    public static let `default` = LedgerCategories(
        categories: ["餐費", "交通", "居住", "日用", "書籍", "娛樂", "健康", "學習", "其他"])

    private enum CodingKeys: String, CodingKey { case categories }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
    }

    /// 寫在日記裡的類別 → 清單裡的正式名；不在清單就原樣回傳
    public func canonical(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return categories.first { $0.trimmingCharacters(in: .whitespaces).lowercased() == key }
            ?? raw.trimmingCharacters(in: .whitespaces)
    }

    public func contains(_ raw: String) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return categories.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == key }
    }
}

/// 一個月的彙總（首頁記帳卡用）
public nonisolated struct LedgerMonthSummary: Hashable, Sendable {
    public struct CategoryTotal: Hashable, Sendable {
        public let category: String
        public let total: Double
        public let count: Int
    }
    public struct MonthTotal: Hashable, Sendable {
        /// 該月 1 號
        public let month: Date
        public let total: Double
    }

    /// 本月 1 號
    public let month: Date
    public let total: Double
    public let count: Int
    /// 由大到小
    public let byCategory: [CategoryTotal]
    /// 上個月總額（沒資料 = 0）
    public let previousTotal: Double
    /// 最近幾個月（含本月，舊→新），沒資料的月份補 0
    public let trend: [MonthTotal]
    /// 清單外的類別（給使用者補進 ledger-categories.json 用）
    public let unknownCategories: [String]

    /// 跟上個月比的變化比例；上個月是 0 就 nil
    public var changeRatio: Double? {
        guard previousTotal > 0 else { return nil }
        return (total - previousTotal) / previousTotal
    }
}

public nonisolated enum LedgerStats {
    /// 彙總 `month` 所在的那個月；`trendMonths` 是趨勢要回看幾個月（含本月）。
    public static func summarize(_ entries: [LedgerEntry], month: Date,
                                 categories: LedgerCategories = .default,
                                 trendMonths: Int = 6,
                                 calendar: Calendar = .current) -> LedgerMonthSummary {
        let thisMonth = startOfMonth(month, calendar)
        let prevMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth

        var totalsByMonth: [Date: Double] = [:]
        var byCategory: [String: (total: Double, count: Int)] = [:]
        var unknown = Set<String>()
        var count = 0
        for e in entries {
            let m = startOfMonth(e.day, calendar)
            totalsByMonth[m, default: 0] += e.amount
            guard m == thisMonth else { continue }
            count += 1
            let cat = categories.canonical(e.category)
            if cat != LedgerParser.uncategorized, !categories.contains(cat) { unknown.insert(cat) }
            let cur = byCategory[cat] ?? (0, 0)
            byCategory[cat] = (cur.total + e.amount, cur.count + 1)
        }

        let trend: [LedgerMonthSummary.MonthTotal] = (0..<max(trendMonths, 1)).reversed().compactMap { back in
            guard let m = calendar.date(byAdding: .month, value: -back, to: thisMonth) else { return nil }
            return .init(month: m, total: totalsByMonth[m] ?? 0)
        }

        return LedgerMonthSummary(
            month: thisMonth,
            total: totalsByMonth[thisMonth] ?? 0,
            count: count,
            byCategory: byCategory
                .map { .init(category: $0.key, total: $0.value.total, count: $0.value.count) }
                .sorted { a, b in
                    if a.total != b.total { return a.total > b.total }
                    return a.category.localizedStandardCompare(b.category) == .orderedAscending
                },
            previousTotal: totalsByMonth[prevMonth] ?? 0,
            trend: trend,
            unknownCategories: unknown.sorted())
    }

    static func startOfMonth(_ date: Date, _ calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: c) ?? date
    }
}
