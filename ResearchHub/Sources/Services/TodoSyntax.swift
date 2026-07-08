import Foundation

/// 待辦的輕量標記語法（筆記、日記、一般待辦通用），全部可選：
///   - [ ] 讀 CFT @from(7/15) @due(7/25) @est(3h) !high @line(A)
/// 支援（白名單制，其餘 @ 開頭的內容一律當普通文字，不會誤傷信箱等）：
///   !high / !low            優先級（沒寫 = normal）
///   @due(7/10)              到期日：每天在日記自動出現獨立副本，直到到期日（含）
///   @from(7/5)              開始日：@due 副本從這天才開始出現；單獨用 = 只在那天出現一次
///   @every(mon,thu)         循環：每逢那幾天出現（mon/tue/wed/thu/fri/sat/sun）
///   @remind(7/20 09:00)     提醒：到時推播通知（也接受 M/d＝當天 09:00、HH:mm＝今天）
///   @est(3h / 45m / 90)     預估時長（純數字 = 分鐘），排時段時參考；日記裡渲染成蕃茄進度條
///   @pomo(2)                任務自己的進度（已投入幾顆），進度條 ＋/− 改的就是它，不動蕃茄鐘統計
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
    /// 開始日（@from）：@due 副本從這天才開始出現
    let from: Date?
    /// 循環（@every）：Calendar.weekday 集合（1 = Sun … 7 = Sat）
    let everyWeekdays: Set<Int>?
    /// 提醒時刻（@remind）
    let remind: Date?
    /// 預估時長（分鐘）
    let estMinutes: Int?
    /// 任務自身已投入的蕃茄顆數（@pomo）
    let pomoDone: Int?
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
        var everyWeekdays: Set<Int>?
        var remind: Date?
        var estMinutes: Int?
        var pomoDone: Int?
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

        // @every(…)：循環（週幾縮寫，逗號分隔）
        if let r = text.range(of: #"(?i)@every\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@every\("#, with: "", options: .regularExpression)
                .dropLast()
            everyWeekdays = Self.parseWeekdays(String(inner))
            text.removeSubrange(r)
        }

        // @remind(…)：提醒時刻
        if let r = text.range(of: #"(?i)@remind\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@remind\("#, with: "", options: .regularExpression)
                .dropLast()
            remind = Self.parseDateTime(String(inner), calendar: calendar)
            text.removeSubrange(r)
        }

        // @pomo(…)：任務自身進度
        if let r = text.range(of: #"(?i)@pomo\(([^)]*)\)"#, options: .regularExpression) {
            let inner = String(text[r])
                .replacingOccurrences(of: #"(?i)@pomo\("#, with: "", options: .regularExpression)
                .dropLast()
            pomoDone = Int(inner.trimmingCharacters(in: .whitespaces))
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
                        from: from, everyWeekdays: everyWeekdays, remind: remind,
                        estMinutes: estMinutes, pomoDone: pomoDone, line: line)
    }

    /// "mon,thu" → Calendar.weekday 集合（1 = Sun … 7 = Sat）。認不得的略過。
    private static func parseWeekdays(_ s: String) -> Set<Int>? {
        let map: [String: Int] = [
            "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
        ]
        var result = Set<Int>()
        for part in s.lowercased().components(separatedBy: ",") {
            let key = String(part.trimmingCharacters(in: .whitespaces).prefix(3))
            if let d = map[key] { result.insert(d) }
        }
        return result.isEmpty ? nil : result
    }

    /// 提醒時刻："M/d HH:mm"、"yyyy-M-d HH:mm"、"M/d"（當天 09:00）、"HH:mm"（今天）。
    private static func parseDateTime(_ s: String, calendar: Calendar) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)

        func time(_ s: String) -> (h: Int, m: Int)? {
            let c = s.components(separatedBy: ":")
            guard c.count == 2, let h = Int(c[0]), let m = Int(c[1]),
                  (0...23).contains(h), (0...59).contains(m) else { return nil }
            return (h, m)
        }

        if parts.count == 2, let day = parseDate(parts[0], calendar: calendar),
           let hm = time(parts[1]) {
            return calendar.date(bySettingHour: hm.h, minute: hm.m, second: 0, of: day)
        }
        if parts.count == 1 {
            if let hm = time(parts[0]) {   // 只有時間 = 今天
                return calendar.date(
                    bySettingHour: hm.h, minute: hm.m, second: 0,
                    of: calendar.startOfDay(for: .now))
            }
            if let day = parseDate(parts[0], calendar: calendar) {   // 只有日期 = 當天 09:00
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)
            }
        }
        return nil
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
