import Foundation
import HubCore

/// 日記 → 行事曆：日記裡「- [ ] 16:00–18:00 讀 QIC CP」這種帶時段的待辦行，跟當天事件對齊。
///
/// 另一個方向（事件 → 日記）在 `FileSystemStore.addPlannedEvents`／`syncPlannedLine`；
/// 這裡補上反方向，讓使用者直接在日記打時段或改時段，時間軸與月曆就跟著動。
///
/// 純計算：吃日記文字與當天事件，吐出要做的事（建立／改時間／改名／刪除），由呼叫端套用。
/// 比對以標題為準（跟 `isEventDone` 同一口徑）；重複事件與全天事件不碰。
public enum JournalEventSync {
    /// 日記裡一行帶時段的待辦
    public struct TimedLine: Equatable, Sendable {
        public let title: String
        /// 從當天 00:00 起算的分鐘數
        public let startMinutes: Int
        public let endMinutes: Int
        /// 「這一行長這樣」的指紋：拿來認「打開那天之後有沒有被動過」
        public var key: String { "\(startMinutes)-\(endMinutes) \(title)" }
    }

    public enum Op: Equatable, Sendable {
        /// 新事件（`tagID` 留空，由呼叫端補預設標籤）
        case create(CalendarEvent)
        case retime(id: UUID, start: Date, end: Date)
        case rename(id: UUID, title: String)
        case delete(id: UUID)
    }

    public struct Result: Equatable, Sendable {
        public let ops: [Op]
        /// 這次看完之後，跟日記某一行對上的事件（含剛建立的）
        public let linked: Set<UUID>
    }

    /// 日記文字裡帶時段的待辦行（已放棄的 `- [-]`、沒有標題的、時間不合理的都不算）。
    public static func timedLines(in text: String) -> [TimedLine] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let body = todoBody(of: line), !line.hasPrefix("- [-]") else { return nil }
            return timedLine(TodoMeta.parse(body).cleanText)
        }
    }

    /// 「16:00-18:00 讀 QIC CP」→ 標題與起訖分鐘；不是這個格式回 nil。
    static func timedLine(_ cleanText: String) -> TimedLine? {
        let text = cleanText.trimmingCharacters(in: .whitespaces)
        let ns = text as NSString
        guard let m = timeRangeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? -1 }
        let (h1, m1, h2, m2) = (int(1), int(2), int(3), int(4))
        let title = ns.substring(with: m.range(at: 5)).trimmingCharacters(in: .whitespaces)
        let start = h1 * 60 + m1, end = h2 * 60 + m2
        guard (0...23).contains(h1), (0...59).contains(m1), (0...24).contains(h2), (0...59).contains(m2),
              end <= 24 * 60, end > start, !title.isEmpty else { return nil }
        return TimedLine(title: title, startMinutes: start, endMinutes: end)
    }

    /// `- [ ] 文字`／`- [x] 文字` → 文字；不是待辦行回 nil。
    private static func todoBody(of line: String) -> String? {
        guard line.count >= 6, line.hasPrefix("- ["), line.dropFirst(4).hasPrefix("] ") else { return nil }
        return String(line.dropFirst(6))
    }

    private static let timeRangeRegex =
        try! NSRegularExpression(pattern: #"^(\d{1,2}):(\d{2})\s*[–\-~]\s*(\d{1,2}):(\d{2})\s+(.+)$"#)

    /// 比對日記與當天事件，回傳要做的事。
    ///
    /// - Parameters:
    ///   - events: 全部事件皆可，這裡只挑「當天開始、有時間、不重複」的來比。
    ///   - linked: 這次打開這天以來，曾經跟日記某一行對上的事件。只有它們可以被改名或刪除——
    ///     行事曆上跟日記無關的事件，就算時間一樣也不會被動到。
    ///   - untouched: 打開這天時就已經在的行（`TimedLine.key`）。過去的日子用：沒被動過的行
    ///     不建事件也不改時間，免得翻舊日記就把當時刪掉的事件變回來。
    ///   - removeOrphans: 離開這一天時才給 true——對上過、現在日記裡已經沒有那一行的事件就刪掉。
    ///     打字途中不刪（時間改到一半時那一行暫時不是合法時段）。
    public static func plan(day: Date, text: String, events: [CalendarEvent],
                            linked: Set<UUID> = [], untouched: Set<String> = [],
                            removeOrphans: Bool = false, calendar: Calendar = .current) -> Result {
        let dayStart = calendar.startOfDay(for: day)
        func minutes(_ date: Date) -> Int { Int((date.timeIntervalSince(dayStart) / 60).rounded()) }
        func date(_ minutes: Int) -> Date {
            calendar.date(byAdding: .minute, value: minutes, to: dayStart) ?? dayStart.addingTimeInterval(Double(minutes) * 60)
        }
        func title(_ event: CalendarEvent) -> String { event.title.trimmingCharacters(in: .whitespaces) }
        func sameTime(_ event: CalendarEvent, _ line: TimedLine) -> Bool {
            minutes(event.start) == line.startMinutes && minutes(event.end) == line.endMinutes
        }

        var free = events.filter {
            !$0.isAllDay && $0.repeatRule == nil && calendar.isDate($0.start, inSameDayAs: dayStart)
        }
        var linkedNow = linked.intersection(free.map(\.id))
        var ops: [Op] = []

        // 1a. 標題與時間都一樣：已經對齊
        var pending: [TimedLine] = []
        for line in timedLines(in: text) {
            if let i = free.firstIndex(where: { title($0) == line.title && sameTime($0, line) }) {
                linkedNow.insert(free.remove(at: i).id)
            } else {
                pending.append(line)
            }
        }
        // 1b. 標題一樣、時間不同：日記改了時間 → 事件跟著改
        var unmatched: [TimedLine] = []
        for line in pending {
            if let i = free.firstIndex(where: { title($0) == line.title }) {
                let event = free.remove(at: i)
                linkedNow.insert(event.id)
                if !untouched.contains(line.key) {
                    ops.append(.retime(id: event.id, start: date(line.startMinutes), end: date(line.endMinutes)))
                }
            } else {
                unmatched.append(line)
            }
        }
        // 2. 沒有同名事件：同一個時段上有「對上過、現在標題不見了」的事件 → 是改名；否則是新的一段
        for line in unmatched {
            if let i = free.firstIndex(where: { linkedNow.contains($0.id) && sameTime($0, line) }) {
                ops.append(.rename(id: free.remove(at: i).id, title: line.title))
            } else if !untouched.contains(line.key) {
                let event = CalendarEvent(title: line.title, isAllDay: false,
                                          start: date(line.startMinutes), end: date(line.endMinutes))
                ops.append(.create(event))
                linkedNow.insert(event.id)
            }
        }
        // 3. 對上過、現在日記裡沒有那一行了
        if removeOrphans {
            for event in free where linkedNow.contains(event.id) {
                ops.append(.delete(id: event.id))
                linkedNow.remove(event.id)
            }
        }
        return Result(ops: ops, linked: linkedNow)
    }

    /// 把這個事件在日記裡對應的那一行「退回沒排時段」：拿掉行首的時間範圍，其他不動。
    /// 刪事件時用——那一行留著時段的話，下次對齊又會把事件建回來。找不到對應的行回 nil。
    public static func unscheduling(title: String, in text: String) -> String? {
        let wanted = title.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { raw in
            guard let body = todoBody(of: raw.trimmingCharacters(in: .whitespaces)) else { return false }
            return timedLine(TodoMeta.parse(body).cleanText)?.title == wanted
        }), let range = lines[i].range(of: #"\d{1,2}:\d{2}\s*[–\-~]\s*\d{1,2}:\d{2}\s+"#, options: .regularExpression)
        else { return nil }
        lines[i].removeSubrange(range)
        return lines.joined(separator: "\n")
    }
}
