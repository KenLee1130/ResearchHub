// 守「規劃時段寫進日記最上面」（FileSystemStore.addPlannedEvents）：行的格式、
// 沒有規劃段就在檔首建一段並用 --- 隔開、已有規劃段就接在後面、同一行不重複、跨天分檔。
import XCTest
@testable import ResearchHub
@testable import HubStore
@testable import HubCore

final class PlanJournalTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testPlannedLineFormat() {
        let e = CalendarEvent(title: "期中考 複習 1/5", isAllDay: false, start: day(2026, 11, 1, 10), end: day(2026, 11, 1, 12))
        XCTAssertEqual(FileSystemStore.plannedLine(for: e), "- [ ] 10:00–12:00 期中考 複習 1/5 @est(2h)")
        let short = CalendarEvent(title: "約會", isAllDay: false, start: day(2026, 11, 1, 19), end: day(2026, 11, 1, 20, 30))
        XCTAssertEqual(FileSystemStore.plannedLine(for: short), "- [ ] 19:00–20:30 約會 @est(90m)")
        let allDay = CalendarEvent(title: "截止日", isAllDay: true, start: day(2026, 11, 1), end: day(2026, 11, 1))
        XCTAssertEqual(FileSystemStore.plannedLine(for: allDay), "- [ ] 截止日")
    }

    func testInsertCreatesSectionOrAppendsToExistingOne() {
        let fresh = FileSystemStore.insertingPlannedLines(["- [ ] 10:00–12:00 A @est(2h)"], into: "# 11/1\n- [ ] 讀 CFT\n")
        XCTAssertEqual(fresh, "- [ ] 10:00–12:00 A @est(2h)\n\n---\n\n# 11/1\n- [ ] 讀 CFT\n")

        let empty = FileSystemStore.insertingPlannedLines(["- [ ] 10:00–12:00 A @est(2h)"], into: "")
        XCTAssertEqual(empty, "- [ ] 10:00–12:00 A @est(2h)\n\n---\n")

        // 已有規劃段：接在最後一行後面，重複的那行跳過
        let appended = FileSystemStore.insertingPlannedLines(
            ["- [ ] 10:00–12:00 A @est(2h)", "- [ ] 14:00–15:00 B @est(1h)"], into: fresh)
        XCTAssertEqual(appended, "- [ ] 10:00–12:00 A @est(2h)\n- [ ] 14:00–15:00 B @est(1h)\n\n---\n\n# 11/1\n- [ ] 讀 CFT\n")

        // 檔首不是規劃段（先有內文才有 ---）→ 當成沒有規劃段，在最上面建新的
        let prose = "今天很累\n\n---\n\n- [ ] 其他"
        let inserted = FileSystemStore.insertingPlannedLines(["- [ ] 09:00–10:00 C @est(1h)"], into: prose)
        XCTAssertTrue(inserted.hasPrefix("- [ ] 09:00–10:00 C @est(1h)\n\n---\n\n今天很累"))
    }

    @MainActor
    func testAddPlannedEventsWritesEachDayAndShowsUpAsTodos() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        store.setRoot(root)
        let d1 = try XCTUnwrap(store.journalURL(for: day(2026, 11, 1)))
        try FileManager.default.createDirectory(at: d1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [ ] 讀 CFT\n".write(to: d1, atomically: true, encoding: .utf8)

        let events = [
            CalendarEvent(title: "期中考 複習 1/2", isAllDay: false, start: day(2026, 11, 1, 10), end: day(2026, 11, 1, 12)),
            CalendarEvent(title: "期中考 複習 2/2", isAllDay: false, start: day(2026, 11, 3, 10), end: day(2026, 11, 3, 12)),
        ]
        store.addPlannedEvents(events, calendar: calendar)
        store.addPlannedEvents(events, calendar: calendar) // 再跑一次不重複

        let t1 = try String(contentsOf: d1, encoding: .utf8)
        XCTAssertEqual(t1, "- [ ] 10:00–12:00 期中考 複習 1/2 @est(2h)\n\n---\n\n- [ ] 讀 CFT\n")
        let d3 = try XCTUnwrap(store.journalURL(for: day(2026, 11, 3)))
        XCTAssertEqual(try String(contentsOf: d3, encoding: .utf8), "- [ ] 10:00–12:00 期中考 複習 2/2 @est(2h)\n\n---\n")
        // 待辦索引看得到、@est 解析得出
        let todos = LibraryIndex.shared.todoLines(in: d1) ?? []
        XCTAssertEqual(todos.map(\.meta.cleanText), ["10:00–12:00 期中考 複習 1/2", "讀 CFT"])
        XCTAssertEqual(todos.first?.meta.estMinutes, 120)

        // 勾掉日記裡那一行 → 對應的事件算「完成」（行事曆畫刪除線）；另一天的不受影響
        XCTAssertFalse(store.isPlannedEventDone(events[0], calendar: calendar))
        try t1.replacingOccurrences(of: "- [ ] 10:00–12:00", with: "- [x] 10:00–12:00")
            .write(to: d1, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.isPlannedEventDone(events[0], calendar: calendar))
        XCTAssertFalse(store.isPlannedEventDone(events[1], calendar: calendar))
        XCTAssertEqual(FileSystemStore.plannedCleanText(for: events[0]), "10:00–12:00 期中考 複習 1/2")

        // 使用者自己寫的待辦，文字就是事件標題 → 勾掉也算
        try (try String(contentsOf: d3, encoding: .utf8) + "\n- [x] 期中考 複習 2/2 !high\n")
            .write(to: d3, atomically: true, encoding: .utf8)
        XCTAssertTrue(store.isPlannedEventDone(events[1], calendar: calendar))
    }
}
