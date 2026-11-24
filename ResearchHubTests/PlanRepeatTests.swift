// 規劃時段：段落設了重複，只重複到目標日（不無限重複）。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class PlanRepeatTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ offset: Int, hour: Int = 0) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: .now))!.addingTimeInterval(Double(hour) * 3600)
    }

    func testRepeatingSegmentsStopAtTheLastPlanDay() {
        var draft = PlanDraft(targetDay: day(10))
        draft.goal = "古電"
        var weekly = CalendarEvent(title: "x", isAllDay: false, start: day(1, hour: 10), end: day(1, hour: 12))
        weekly.repeatRule = EventRepeat(frequency: .weekly)
        let once = CalendarEvent(title: "y", isAllDay: false, start: day(2, hour: 10), end: day(2, hour: 12))
        var custom = CalendarEvent(title: "z", isAllDay: false, start: day(3, hour: 10), end: day(3, hour: 12))
        custom.repeatRule = EventRepeat(frequency: .daily, until: day(5))

        let final = PlanDraft.finalize([weekly, once, custom], titles: [:], draft: draft)
        XCTAssertEqual(final[0].repeatRule?.until, day(9), "不含目標日：重複到前一天")
        XCTAssertNil(final[1].repeatRule, "沒設重複的照舊")
        XCTAssertEqual(final[2].repeatRule?.until, day(5), "自己設過結束日的不動")

        draft.includeTargetDay = true
        XCTAssertEqual(PlanDraft.finalize([weekly], titles: [:], draft: draft)[0].repeatRule?.until, day(10))
    }
}
