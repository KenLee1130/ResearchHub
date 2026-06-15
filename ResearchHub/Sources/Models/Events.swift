import SwiftUI
import AppKit
import Combine

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
    var isAllDay: Bool
    var start: Date
    var end: Date
    var tagID: UUID?
}

// MARK: - Store

/// 事件與標籤的儲存，落地於根資料夾的 .hub/events.json。
@MainActor
final class EventStore: ObservableObject {

    @Published private(set) var events: [CalendarEvent] = []
    @Published var tags: [EventTag] = [] {
        didSet { save() }
    }

    private var fileURL: URL?
    private var isLoading = false

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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("events.json")
        load()
    }

    private func load() {
        guard let fileURL else { return }
        isLoading = true
        defer { isLoading = false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? decoder.decode(Payload.self, from: data) {
            tags = payload.tags
            events = payload.events
        } else {
            tags = Self.defaultTags
            events = []
            save()
        }
    }

    private func save() {
        guard let fileURL, !isLoading else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Payload(tags: tags, events: events)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Events

    func add(_ event: CalendarEvent) {
        events.append(event)
        save()
    }

    func update(_ event: CalendarEvent) {
        if let i = events.firstIndex(where: { $0.id == event.id }) {
            events[i] = event
            save()
        }
    }

    func delete(_ event: CalendarEvent) {
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
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        tags.append(EventTag(name: trimmed, colorHex: color.hexString))
    }

    func deleteTag(_ tag: EventTag) {
        tags.removeAll { $0.id == tag.id }
        // 用到此標籤的事件改為無標籤
        for i in events.indices where events[i].tagID == tag.id {
            events[i].tagID = nil
        }
        save()
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
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#888888" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
