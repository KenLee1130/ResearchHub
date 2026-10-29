// 守事件重複規則（docs/ARCHITECTURE.md 5.3；CalendarEvent.swift 的 EventRepeat）：
// 每天／每週／每月／每年的展開、間隔、結束日、跨日實例、EventStore 的當天清單與 .ics RRULE、解碼容錯。
import XCTest
@testable import ResearchHub
@testable import HubStore
@testable import HubCore

final class EventRepeatTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ start: Date, hours: Double = 1, repeat rule: EventRepeat?) -> CalendarEvent {
        CalendarEvent(title: "x", isAllDay: false, start: start,
                      end: start.addingTimeInterval(hours * 3600), repeatRule: rule)
    }

    private func days(_ e: CalendarEvent, _ from: Date, _ to: Date) -> [String] {
        e.occurrences(from: from, to: to, calendar: calendar).map {
            let c = calendar.dateComponents([.month, .day], from: $0.start)
            return "\(c.month!)/\(c.day!)"
        }
    }

    func testDailyWeeklyWithIntervalAndUntil() {
        let daily = event(day(2026, 11, 1, 9), repeat: EventRepeat(frequency: .daily))
        XCTAssertEqual(days(daily, day(2026, 10, 30), day(2026, 11, 4)), ["11/1", "11/2", "11/3", "11/4"])

        let everyOtherDay = event(day(2026, 11, 1, 9), repeat: EventRepeat(frequency: .daily, interval: 2, until: day(2026, 11, 5)))
        XCTAssertEqual(days(everyOtherDay, day(2026, 11, 1), day(2026, 11, 10)), ["11/1", "11/3", "11/5"])

        let weekly = event(day(2026, 11, 2, 19), repeat: EventRepeat(frequency: .weekly)) // 週一
        XCTAssertEqual(days(weekly, day(2026, 11, 1), day(2026, 11, 30)), ["11/2", "11/9", "11/16", "11/23", "11/30"])
        let biweekly = event(day(2026, 11, 2, 19), repeat: EventRepeat(frequency: .weekly, interval: 2))
        XCTAssertEqual(days(biweekly, day(2026, 11, 1), day(2026, 11, 30)), ["11/2", "11/16", "11/30"])
        // 第一次之前沒有
        XCTAssertNil(weekly.occurrence(on: day(2026, 10, 26), calendar: calendar))
        // 實例的時間平移、id 相同
        let third = weekly.occurrence(on: day(2026, 11, 16), calendar: calendar)
        XCTAssertEqual(third?.id, weekly.id)
        XCTAssertEqual(third?.start, day(2026, 11, 16, 19))
        XCTAssertEqual(third?.end, day(2026, 11, 16, 20))
    }

    func testMonthlySkipsShortMonthsAndYearly() {
        let monthly31 = event(day(2026, 10, 31, 10), repeat: EventRepeat(frequency: .monthly))
        XCTAssertEqual(days(monthly31, day(2026, 10, 1), day(2027, 1, 31)), ["10/31", "12/31", "1/31"])
        let quarterly = event(day(2026, 1, 15, 10), repeat: EventRepeat(frequency: .monthly, interval: 3))
        XCTAssertEqual(days(quarterly, day(2026, 1, 1), day(2026, 12, 31)), ["1/15", "4/15", "7/15", "10/15"])
        let yearly = event(day(2026, 3, 8, 12), repeat: EventRepeat(frequency: .yearly))
        XCTAssertEqual(yearly.occurrences(from: day(2026, 1, 1), to: day(2029, 12, 31), calendar: calendar)
                        .map { calendar.component(.year, from: $0.start) }, [2026, 2027, 2028, 2029])
        XCTAssertNil(yearly.occurrence(on: day(2027, 3, 9), calendar: calendar))
    }

    func testMultiDayInstanceCoversEachDayButListsOnce() {
        // 週五 22:00 到週六 02:00、每週
        let overnight = CalendarEvent(title: "夜班", isAllDay: false,
                                      start: day(2026, 11, 6, 22), end: day(2026, 11, 7, 2),
                                      repeatRule: EventRepeat(frequency: .weekly))
        XCTAssertNotNil(overnight.occurrence(on: day(2026, 11, 13), calendar: calendar))
        XCTAssertNotNil(overnight.occurrence(on: day(2026, 11, 14), calendar: calendar))
        XCTAssertNil(overnight.occurrence(on: day(2026, 11, 15), calendar: calendar))
        XCTAssertEqual(days(overnight, day(2026, 11, 6), day(2026, 11, 20)), ["11/6", "11/13", "11/20"])
        // 不重複的事件照舊
        let once = event(day(2026, 11, 6, 22), repeat: nil)
        XCTAssertEqual(days(once, day(2026, 11, 1), day(2026, 11, 30)), ["11/6"])
    }

    @MainActor
    func testEventStoreListsInstancesAndKeepsSeriesStartOnEdit() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventStore(librarySync: LibrarySync())
        store.configure(rootURL: root)
        let weekly = CalendarEvent(title: "組會", isAllDay: false,
                                   start: day(2026, 11, 2, 14), end: day(2026, 11, 2, 15),
                                   repeatRule: EventRepeat(frequency: .weekly))
        store.add(weekly)
        store.add(CalendarEvent(title: "一次性", isAllDay: false, start: day(2026, 11, 9, 9), end: day(2026, 11, 9, 10)))

        XCTAssertEqual(store.events(on: day(2026, 11, 9), calendar: calendar).map(\.title), ["一次性", "組會"])
        XCTAssertEqual(store.events(on: day(2026, 11, 9), calendar: calendar).last?.start, day(2026, 11, 9, 14))
        XCTAssertEqual(store.occurrences(from: day(2026, 11, 1), to: day(2026, 11, 30), calendar: calendar).count, 5 + 1)

        // 從 11/16 的實例改時間成 15:00–16:30 → 系列第一天仍是 11/2
        var instance = try XCTUnwrap(store.events(on: day(2026, 11, 16), calendar: calendar).first { $0.id == weekly.id })
        instance.start = day(2026, 11, 16, 15)
        instance.end = day(2026, 11, 16, 16, 30)
        let fixed = store.applyingSeriesDates(instance, calendar: calendar)
        XCTAssertEqual(fixed.start, day(2026, 11, 2, 15))
        XCTAssertEqual(fixed.end, day(2026, 11, 2, 16, 30))

        // 檔案格式：repeat 只在有規則時出現，interval 1 不寫
        let text = try String(contentsOf: root.appendingPathComponent(".hub/events.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"repeat\""))
        XCTAssertTrue(text.contains("\"frequency\" : \"weekly\""))
        XCTAssertFalse(text.contains("\"interval\""))
        XCTAssertTrue(store.icsString().contains("RRULE:FREQ=WEEKLY"))
    }

    func testDecodeToleratesMissingAndUnknownRepeat() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plain = Data("""
        {"id":"7E0E7B7C-0E8E-4F7B-9C3B-000000000001","title":"x","isAllDay":false,
         "start":"2026-11-01T01:00:00Z","end":"2026-11-01T02:00:00Z"}
        """.utf8)
        XCTAssertNil(try decoder.decode(CalendarEvent.self, from: plain).repeatRule)
        let unknown = Data("""
        {"id":"7E0E7B7C-0E8E-4F7B-9C3B-000000000001","title":"x","isAllDay":false,
         "start":"2026-11-01T01:00:00Z","end":"2026-11-01T02:00:00Z","repeat":{"frequency":"lunar"}}
        """.utf8)
        XCTAssertNil(try decoder.decode(CalendarEvent.self, from: unknown).repeatRule)
        let biweekly = Data("""
        {"id":"7E0E7B7C-0E8E-4F7B-9C3B-000000000001","title":"x","isAllDay":false,
         "start":"2026-11-01T01:00:00Z","end":"2026-11-01T02:00:00Z",
         "repeat":{"frequency":"weekly","interval":2,"until":"2026-12-31T00:00:00Z"}}
        """.utf8)
        let rule = try decoder.decode(CalendarEvent.self, from: biweekly).repeatRule
        XCTAssertEqual(rule?.frequency, .weekly)
        XCTAssertEqual(rule?.interval, 2)
        XCTAssertNotNil(rule?.until)
    }
}
