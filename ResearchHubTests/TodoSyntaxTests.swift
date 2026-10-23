// 守待辦標記語法（CLAUDE.md 的語法表；TodoSyntax.swift／LibraryIndex.parse）：
// !high、@due、@from、@every、@on、@remind、@est、@pomo、@line，以及 - [-] 已放棄不列入。
import XCTest
@testable import ResearchHub

final class TodoSyntaxTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private var thisYear: Int { calendar.component(.year, from: .now) }

    private func ymd(_ date: Date?) -> [Int]? {
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return [c.year!, c.month!, c.day!]
    }

    func testFullExampleFromSyntaxTable() throws {
        let m = TodoMeta.parse("讀 CFT @from(7/15) @due(7/25) @est(3h) !high @line(A)", calendar: calendar)
        XCTAssertEqual(m.cleanText, "讀 CFT")
        XCTAssertEqual(m.priority, .high)
        XCTAssertEqual(ymd(m.from), [thisYear, 7, 15])
        XCTAssertEqual(ymd(m.due), [thisYear, 7, 25])
        XCTAssertEqual(m.estMinutes, 180)
        XCTAssertEqual(m.line, "A")
        XCTAssertNil(m.everyWeekdays)
        XCTAssertNil(m.onDates)
        XCTAssertNil(m.remind)
        XCTAssertNil(m.pomoDone)
    }

    func testPriorityMarkers() throws {
        XCTAssertEqual(TodoMeta.parse("!low 整理桌面", calendar: calendar).priority, .low)
        XCTAssertEqual(TodoMeta.parse("!low 整理桌面", calendar: calendar).cleanText, "整理桌面")
        XCTAssertEqual(TodoMeta.parse("!HIGH 交稿", calendar: calendar).priority, .high)
        XCTAssertEqual(TodoMeta.parse("平常的事", calendar: calendar).priority, .normal)
        XCTAssertTrue(TodoPriority.low < TodoPriority.normal && TodoPriority.normal < TodoPriority.high)
    }

    func testDueAcceptsFullDate() throws {
        XCTAssertEqual(ymd(TodoMeta.parse("交報告 @due(2026-10-30)", calendar: calendar).due), [2026, 10, 30])
        XCTAssertEqual(ymd(TodoMeta.parse("交報告 @due(2026/1/5)", calendar: calendar).due), [2026, 1, 5])
    }

    func testEveryWeekdays() throws {
        let m = TodoMeta.parse("@every(mon,thu) 週會", calendar: calendar)
        XCTAssertEqual(m.everyWeekdays, [2, 5])
        XCTAssertEqual(m.cleanText, "週會")
        XCTAssertEqual(TodoMeta.parse("@every(Sunday, Sat) x", calendar: calendar).everyWeekdays, [1, 7])
        XCTAssertNil(TodoMeta.parse("@every(xyz) x", calendar: calendar).everyWeekdays)
    }

    func testOnDatesAreStartOfDay() throws {
        let m = TodoMeta.parse("@on(7/10,7/14) 跑實驗", calendar: calendar)
        let dates = try XCTUnwrap(m.onDates)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(Set(dates.compactMap(ymd)), [[thisYear, 7, 10], [thisYear, 7, 14]])
        for d in dates { XCTAssertEqual(calendar.startOfDay(for: d), d) }
        XCTAssertEqual(m.cleanText, "跑實驗")
    }

    func testRemindFormats() throws {
        let full = TodoMeta.parse("交報告 @remind(7/20 09:30)", calendar: calendar).remind
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(full))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [thisYear, 7, 20, 9, 30])

        let dayOnly = TodoMeta.parse("交報告 @remind(7/20)", calendar: calendar).remind
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(dayOnly)), 9)

        let timeOnly = TodoMeta.parse("交報告 @remind(14:05)", calendar: calendar).remind
        let t = calendar.dateComponents([.hour, .minute], from: try XCTUnwrap(timeOnly))
        XCTAssertEqual([t.hour, t.minute], [14, 5])
        XCTAssertTrue(calendar.isDateInToday(timeOnly!))

        XCTAssertNil(TodoMeta.parse("交報告 @remind(25:99)", calendar: calendar).remind)
    }

    func testEstimateDurations() throws {
        XCTAssertEqual(TodoMeta.parse("x @est(45m)", calendar: calendar).estMinutes, 45)
        XCTAssertEqual(TodoMeta.parse("x @est(90)", calendar: calendar).estMinutes, 90)
        XCTAssertEqual(TodoMeta.parse("x @est(1.5hr)", calendar: calendar).estMinutes, 90)
        XCTAssertEqual(TodoMeta.parse("x @est(30min)", calendar: calendar).estMinutes, 30)
        XCTAssertNil(TodoMeta.parse("x @est(abc)", calendar: calendar).estMinutes)
        XCTAssertEqual(TodoMeta.parseDuration("2 h"), 120)
    }

    func testPomoAndEstTogether() throws {
        let m = TodoMeta.parse("@pomo(2) 寫稿 @est(2h)", calendar: calendar)
        XCTAssertEqual(m.pomoDone, 2)
        XCTAssertEqual(m.estMinutes, 120)
        XCTAssertEqual(m.cleanText, "寫稿")
    }

    func testUnknownAtMarkersAreLeftAlone() throws {
        // 白名單制：信箱、@foo(bar) 都是普通文字
        let m = TodoMeta.parse("寄信給 ken@example.com @foo(bar)", calendar: calendar)
        XCTAssertEqual(m.cleanText, "寄信給 ken@example.com @foo(bar)")
        XCTAssertNil(m.due); XCTAssertNil(m.line); XCTAssertNil(m.estMinutes)
    }

    func testEmptyLineIsNil() throws {
        XCTAssertNil(TodoMeta.parse("x @line( )", calendar: calendar).line)
        XCTAssertEqual(TodoMeta.parse("x @line( B )", calendar: calendar).line, "B")
    }

    func testDedupKeyIgnoresEmphasisAndSpacing() throws {
        let a = TodoMeta.parse("**A @due(7/1)**", calendar: calendar)
        let b = TodoMeta.parse("**A**@due(7/1)", calendar: calendar)
        let c = TodoMeta.parse("A   ", calendar: calendar)
        XCTAssertEqual(a.dedupKey, "A")
        XCTAssertEqual(a.dedupKey, b.dedupKey)
        XCTAssertEqual(a.dedupKey, c.dedupKey)
    }

    func testIsOverdue() throws {
        // isOverdue 用 Calendar.current 比「今天」，所以這裡也用 .current 解析
        let current = Calendar.current
        let yesterday = current.date(byAdding: .day, value: -1, to: .now)!
        let f = DateFormatter(); f.calendar = current; f.timeZone = current.timeZone
        f.dateFormat = "yyyy-M-d"
        XCTAssertTrue(TodoMeta.parse("x @due(\(f.string(from: yesterday)))", calendar: current).isOverdue)
        XCTAssertFalse(TodoMeta.parse("x @due(\(f.string(from: .now)))", calendar: current).isOverdue)
        XCTAssertFalse(TodoMeta.parse("x", calendar: current).isOverdue)
    }

    func testJournalLinesSkipDroppedAndLegacyMarkers() throws {
        let content = """
        # 2026-10-23
        - [ ] 讀 CFT !high
        - [x] 回信
        - [X] 大寫也算完成
        - [-] 已放棄的事
        - [>] 早期遺留標記
        - [ ]
        隨便一行
        """
        let lines = LibraryIndex.parse(content)
        XCTAssertEqual(lines.map(\.text), ["讀 CFT !high", "回信", "大寫也算完成"])
        XCTAssertEqual(lines.map(\.done), [false, true, true])
        XCTAssertEqual(lines.map(\.lineIndex), [1, 2, 3])
        XCTAssertEqual(lines[0].meta.priority, .high)
        XCTAssertEqual(lines[0].dedupKey, "讀 CFT")
    }
}
