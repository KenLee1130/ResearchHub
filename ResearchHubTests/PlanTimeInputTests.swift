// 守規劃預覽的日期／時間文字欄解析（SteppingDateFields.swift）：寬鬆輸入、保留另一半、拒絕不存在的日期。
import XCTest
@testable import ResearchHub

final class PlanTimeInputTests: XCTestCase {
    private var cal: Calendar { PlanTimeInput.calendar }
    private var base: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 13, minute: 30))! }

    func testParseDayKeepsTimeAndAcceptsShortForms() {
        let d = PlanTimeInput.parseDay("2026/11/5", base: base)!
        XCTAssertEqual(cal.dateComponents([.year, .month, .day, .hour, .minute], from: d),
                       DateComponents(year: 2026, month: 11, day: 5, hour: 13, minute: 30))
        XCTAssertEqual(cal.component(.month, from: PlanTimeInput.parseDay("11/5", base: base)!), 11)
        XCTAssertEqual(cal.component(.day, from: PlanTimeInput.parseDay("2026-11-05", base: base)!), 5)
        XCTAssertNil(PlanTimeInput.parseDay("2/30", base: base))
        XCTAssertNil(PlanTimeInput.parseDay("abc", base: base))
        XCTAssertEqual(PlanTimeInput.dayText(base), "2026/10/29")
    }

    func testParseTimeIs24hAndKeepsDay() {
        for (input, h, m) in [("9", 9, 0), ("13:30", 13, 30), ("1330", 13, 30), ("0815", 8, 15), ("23：45", 23, 45)] {
            let d = PlanTimeInput.parseTime(input, base: base)!
            XCTAssertEqual(cal.component(.hour, from: d), h, input)
            XCTAssertEqual(cal.component(.minute, from: d), m, input)
            XCTAssertEqual(cal.component(.day, from: d), 29, input)
        }
        XCTAssertNil(PlanTimeInput.parseTime("24:00", base: base))
        XCTAssertNil(PlanTimeInput.parseTime("9:60", base: base))
        XCTAssertEqual(PlanTimeInput.timeText(base), "13:30")
    }
}
