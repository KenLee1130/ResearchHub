import Foundation

/// 待辦的輕量標記語法（筆記、日記、一般待辦通用），全部可選：
///   - [ ] 讀 CFT @from(7/15) @due(7/25) @est(3h) !high @line(A)
/// 支援（白名單制，其餘 @ 開頭的內容一律當普通文字，不會誤傷信箱等）：
///   !high / !low            優先級（沒寫 = normal）
///   @due(7/10)              到期日（當年）；也接受 @due(2026-7-10)
///   @from(7/5)              開始日：項目在每日搬移時跳到這一天的日記，之後逐日跟隨
///   @est(3h / 45m / 90)     預估時長（純數字 = 分鐘），排時段時參考
///   @line(名字)             主線歸屬（如 A、B），週檢討分線統計用
enum TodoPriority: Int, Comparable, Hashable {
    case low = 0, normal = 1, high = 2
    static func < (a: TodoPriority, b: TodoPriority) -> Bool { a.rawValue < b.rawValue }
}

struct TodoMeta: Hashable {
    /// 去掉標記後的文字（顯示與比對用）
    let cleanText: String
    let priority: TodoPriority
    let due: Date?
    /// 開始日（@from）：未到之前項目停在那一天的日記，不出現在今天
    let from: Date?
    /// 預估時長（分鐘）
    let estMinutes: Int?
    /// 主線歸屬（@line(A) → "A"），沒標 = nil
    let line: String?

    /// 已過期（到期日在今天之前）
    var isOverdue: Bool {
        guard let due else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }

    static func parse(_ raw: String, calendar: Calendar = .current) -> TodoMeta {
        var text = raw
        var priority: TodoPriority = .normal
        var due: Date?
        var from: Date?
        var estMinutes: Int?
        var line: String?

        // !high / !low（不分大小寫、允許前後空白）
        if let r = text.range(of: #"(?i)!high\b"#, options: .regularExpression) {
            priority = .high
            text.removeSubrange(r)
        } else if let r = text.range(of: #"(?i)!low\b"#, options: .regularExpression) {
            priority = .low
            text.removeSubrange(r)
        }

        // @due(…)：M/d（當年）或 yyyy-M-d
        if let r = text.range(of: #"(?i)@due\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@due\("#, with: "", options: .regularExpression)
                .dropLast()
            due = Self.parseDate(String(inner), calendar: calendar)
            text.removeSubrange(r)
        }

        // @from(…)：開始日
        if let r = text.range(of: #"(?i)@from\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@from\("#, with: "", options: .regularExpression)
                .dropLast()
            from = Self.parseDate(String(inner), calendar: calendar)
            text.removeSubrange(r)
        }

        // @est(…)：預估時長
        if let r = text.range(of: #"(?i)@est\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@est\("#, with: "", options: .regularExpression)
                .dropLast()
            estMinutes = Self.parseDuration(String(inner))
            text.removeSubrange(r)
        }

        // @line(…)：主線歸屬
        if let r = text.range(of: #"(?i)@line\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@line\("#, with: "", options: .regularExpression)
                .dropLast()
                .trimmingCharacters(in: .whitespaces)
            line = inner.isEmpty ? nil : inner
            text.removeSubrange(r)
        }

        let clean = text
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return TodoMeta(cleanText: clean, priority: priority, due: due,
                        from: from, estMinutes: estMinutes, line: line)
    }

    /// "3h" / "45m" / "90"（分鐘）→ 分鐘數。
    private static func parseDuration(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix("h"), let v = Double(t.dropLast()) { return Int(v * 60) }
        if t.hasSuffix("m"), let v = Double(t.dropLast()) { return Int(v) }
        if let v = Double(t) { return Int(v) }
        return nil
    }

    private static func parseDate(_ s: String, calendar: Calendar) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        // yyyy-M-d 或 yyyy/M/d
        let full = t.components(separatedBy: CharacterSet(charactersIn: "-/"))
        if full.count == 3,
           let y = Int(full[0]), let m = Int(full[1]), let d = Int(full[2]),
           y > 2000 {
            return calendar.date(from: DateComponents(year: y, month: m, day: d))
        }
        // M/d 或 M-d → 當年
        if full.count == 2, let m = Int(full[0]), let d = Int(full[1]) {
            let year = calendar.component(.year, from: .now)
            return calendar.date(from: DateComponents(year: year, month: m, day: d))
        }
        return nil
    }
}
