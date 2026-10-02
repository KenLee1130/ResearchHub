import SwiftUI
import Observation
import Combine
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// MARK: - Models

struct EventTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String

    var color: Color { Color(hex: colorHex) }
}

struct CalendarEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// 詳細內容：這件事具體要做什麼。
    var notes: String = ""
    var isAllDay: Bool
    var start: Date
    var end: Date
    var tagID: UUID?
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id, title, notes, isAllDay, start, end, tagID
    }

    /// 舊版 events.json 沒有 notes 欄位 → 解碼時補空字串。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isAllDay = try c.decode(Bool.self, forKey: .isAllDay)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        tagID = try c.decodeIfPresent(UUID.self, forKey: .tagID)
    }
}

// MARK: - Store

/// 事件與標籤的儲存，落地於根資料夾的 .hub/events.json。
@MainActor
@Observable
final class EventStore {

    private(set) var events: [CalendarEvent] = []
    var tags: [EventTag] = [] {
        didSet { save() }
    }

    private var fileURL: URL?
    private var isLoading = false
    /// events.json 已確實讀到（或確定不存在）。iCloud 還沒下載完時是 false，這時不能存檔。
    private var ready = false
    /// 檔案還沒下載完時使用者就動了手：等檔案到了以 id 合併後再存
    private var editedWhileNotReady = false
    private var libraryObserver: AnyCancellable?

    private struct Payload: Codable {
        var tags: [EventTag]
        var events: [CalendarEvent]
    }

    static let defaultTags: [EventTag] = [
        EventTag(name: "研究", colorHex: "#378ADD"),
        EventTag(name: "會議", colorHex: "#EF9F27"),
        EventTag(name: "截止日", colorHex: "#E24B4A"),
        EventTag(name: "教學", colorHex: "#639922"),
        EventTag(name: "個人", colorHex: "#7F77DD")
    ]

    // MARK: - Setup

    func configure(rootURL: URL?) {
        guard let rootURL else {
            fileURL = nil
            events = []
            tags = []
            return
        }
        let dir = rootURL.appendingPathComponent(".hub", isDirectory: true)
        let target = dir.appendingPathComponent("events.json")
        // 每個主視窗（分頁）出現都會呼叫：同一個資料夾就不必重讀（重讀會讓所有視窗重畫、開分頁變慢）
        guard target.path != fileURL?.path else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = target
        ready = false
        editedWhileNotReady = false
        load()
        // 另一台裝置改了 events.json（或切回 app）→ 重讀
        libraryObserver = NotificationCenter.default
            .publisher(for: .rhLibraryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, LibrarySync.affects(note, self.fileURL) else { return }
                self.load()
            }
    }

    /// 從磁碟重讀。每次修改前也會先呼叫，避免拿舊的記憶體內容蓋掉另一台裝置剛寫的。
    private func load() {
        guard let fileURL else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var needsSave = false
        isLoading = true
        switch LibraryFileRead.read(fileURL) {
        case .data(let data):
            if let payload = try? decoder.decode(Payload.self, from: data) {
                if editedWhileNotReady {
                    tags = mergeByID(disk: payload.tags, local: tags)
                    events = mergeByID(disk: payload.events, local: events)
                    needsSave = true
                } else {
                    if tags != payload.tags { tags = payload.tags }
                    if events != payload.events { events = payload.events }
                }
                ready = true
            } else {
                ready = false   // 讀到一半的檔或壞檔：別覆寫
            }
        case .missing:
            if !editedWhileNotReady {
                tags = Self.defaultTags
                events = []
            }
            ready = true
            needsSave = true
        case .notDownloaded:
            ready = false
        }
        isLoading = false
        if needsSave {
            editedWhileNotReady = false
            save()
        }
    }

    private func save() {
        guard let fileURL, !isLoading else { return }
        guard ready else {
            // 雲端那份還沒下載到：現在寫會蓋掉它。先記著，檔案到了合併再存。
            editedWhileNotReady = true
            LibrarySync.shared.syncNow()
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Payload(tags: tags, events: events)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Events

    func add(_ event: CalendarEvent) {
        load()
        events.append(event)
        save()
    }

    func update(_ event: CalendarEvent) {
        load()
        if let i = events.firstIndex(where: { $0.id == event.id }) {
            events[i] = event
            save()
        }
    }

    func delete(_ event: CalendarEvent) {
        load()
        events.removeAll { $0.id == event.id }
        save()
    }

    /// 某天涵蓋的事件（含跨日），全天優先、再按開始時間排序。
    func events(on day: Date, calendar: Calendar = .current) -> [CalendarEvent] {
        let target = calendar.startOfDay(for: day)
        return events
            .filter { event in
                let s = calendar.startOfDay(for: event.start)
                let e = calendar.startOfDay(for: event.end)
                return s <= target && target <= e
            }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
    }

    /// 整月各日的事件標籤顏色（日 → 前幾個顏色），給日曆畫點用。
    func tagColorsByDay(inMonth month: Date, calendar: Calendar = .current, maxPerDay: Int = 3) -> [Int: [Color]] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [:] }
        var result: [Int: [Color]] = [:]
        for day in range {
            guard let date = calendar.date(byAdding: .day, value: day - 1,
                                           to: calendar.startOfMonth(for: month)) else { continue }
            let dayEvents = events(on: date, calendar: calendar)
            guard !dayEvents.isEmpty else { continue }
            var colors: [Color] = []
            for event in dayEvents.prefix(maxPerDay) {
                colors.append(tag(for: event.tagID)?.color ?? .gray)
            }
            result[day] = colors
        }
        return result
    }

    // MARK: - Tags

    func tag(for id: UUID?) -> EventTag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    func addTag(name: String, color: Color) {
        load()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        tags.append(EventTag(name: trimmed, colorHex: color.hexString))
    }

    func deleteTag(_ tag: EventTag) {
        load()
        tags.removeAll { $0.id == tag.id }
        // 用到此標籤的事件改為無標籤
        for i in events.indices where events[i].tagID == tag.id {
            events[i].tagID = nil
        }
        save()
    }
}

// MARK: - iCalendar 匯出

extension EventStore {
    /// 全部事件 → 標準 .ics（RFC 5545），可匯入 Apple／Google 行事曆或任何行事曆 app。
    /// 時間用 floating local time（無時區後綴），符合個人行事曆的直覺。
    func icsString() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        func fmt(_ date: Date, dayOnly: Bool) -> String {
            df.dateFormat = dayOnly ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
            return df.string(from: date)
        }
        // SUMMARY/DESCRIPTION 的跳脫：\ ; , 換行
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: "\n", with: "\\n")
        }

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//ResearchHub//EN",
            "CALSCALE:GREGORIAN"
        ]
        let stamp = fmt(.now, dayOnly: false)
        let calendar = Calendar.current

        for event in events.sorted(by: { $0.start < $1.start }) {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.id.uuidString)@researchhub")
            lines.append("DTSTAMP:\(stamp)")
            if event.isAllDay {
                // 全天事件：DTEND 是「不含」的隔天
                let endNext = calendar.date(
                    byAdding: .day, value: 1,
                    to: calendar.startOfDay(for: event.end)) ?? event.end
                lines.append("DTSTART;VALUE=DATE:\(fmt(event.start, dayOnly: true))")
                lines.append("DTEND;VALUE=DATE:\(fmt(endNext, dayOnly: true))")
            } else {
                lines.append("DTSTART:\(fmt(event.start, dayOnly: false))")
                lines.append("DTEND:\(fmt(event.end, dayOnly: false))")
            }
            lines.append("SUMMARY:\(esc(event.title))")
            if !event.notes.isEmpty {
                lines.append("DESCRIPTION:\(esc(event.notes))")
            }
            if let tag = tag(for: event.tagID) {
                lines.append("CATEGORIES:\(esc(tag.name))")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Color ↔ hex

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    var hexString: String {
        #if canImport(AppKit)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#888888" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return "#888888" }
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        #endif
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
