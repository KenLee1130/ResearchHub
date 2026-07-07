import Foundation

/// 待辦的輕量標記語法（筆記、日記、一般待辦通用），全部可選：
///   - [ ] 讀 CFT @due(7/10) !high @line(A)
/// 支援（白名單制，其餘 @ 開頭的內容一律當普通文字，不會誤傷信箱等）：
///   !high / !low            優先級（沒寫 = normal）
///   @due(7/10)              到期日（當年）；也接受 @due(2026-7-10)
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
        return TodoMeta(cleanText: clean, priority: priority, due: due, line: line)
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
