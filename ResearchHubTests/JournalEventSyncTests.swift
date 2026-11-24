// 守「日記 → 行事曆」的對齊（JournalEventSync）：在日記打時段會建事件、改時段會改事件時間、
// 改標題是改名而不是多一個事件、跟日記無關的事件不被動到、過去沒被動過的行不建事件、
// 離開那天時才清掉沒有對應行的事件、刪事件時把那一行退回沒排時段。
import XCTest
@testable import HubStore
@testable import HubCore

final class JournalEventSyncTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0, day: Int = 18) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    private func event(_ title: String, _ h1: Int, _ h2: Int, day: Int = 18) -> CalendarEvent {
        CalendarEvent(title: title, isAllDay: false, start: at(h1, day: day), end: at(h2, day: day))
    }

    private func plan(_ text: String, _ events: [CalendarEvent], linked: Set<UUID> = [],
                      untouched: Set<String> = [], removeOrphans: Bool = false) -> JournalEventSync.Result {
        JournalEventSync.plan(day: at(0), text: text, events: events, linked: linked,
                              untouched: untouched, removeOrphans: removeOrphans, calendar: calendar)
    }

    func testParsesTimedLines() {
        let text = """
        - [ ] 14:00–16:00 proposal-DCFT bootstrap 2/5 @est(2h)
        - [ ] 16:00-18:00 讀 QIC CP @est(2h) !high
        - [x] 9:30 ~ 10:00 開會
          - [ ] 21:00–24:00 子項目
        - [ ] 20:00-22:00
        - [-] 08:00–09:00 放棄的
        - [ ] 18:00–17:00 倒過來
        - [ ] 25:00–26:00 不存在的時間
        - [ ] 沒有時段
        不是待辦 10:00–11:00 文字
        """
        XCTAssertEqual(JournalEventSync.timedLines(in: text), [
            .init(title: "proposal-DCFT bootstrap 2/5", startMinutes: 840, endMinutes: 960),
            .init(title: "讀 QIC CP", startMinutes: 960, endMinutes: 1080),
            .init(title: "開會", startMinutes: 570, endMinutes: 600),
            .init(title: "子項目", startMinutes: 1260, endMinutes: 1440),
        ])
    }

    /// 使用者回報的那一天：兩行改了時間、一行是新打的、一行只有時間沒標題。
    func testRetimesExistingAndCreatesNew() {
        let sop = event("把 SOP 東西寫完", 10, 12), proposal = event("proposal-DCFT bootstrap 2/5", 13, 15)
        let text = """
        - [ ] 14:00–16:00 proposal-DCFT bootstrap 2/5 @est(2h)

        - [ ] 12:00–14:00 把 SOP 東西寫完 @est(2h)

        - [ ] 16:00-18:00 讀 QIC CP @est(2h)

        - [ ] 20:00-22:00 

        - [x] 加結報繳交
        """
        let result = plan(text, [sop, proposal, event("別天的", 16, 18, day: 19)])
        XCTAssertEqual(result.ops.count, 3)
        XCTAssertTrue(result.ops.contains(.retime(id: proposal.id, start: at(14), end: at(16))))
        XCTAssertTrue(result.ops.contains(.retime(id: sop.id, start: at(12), end: at(14))))
        guard case .create(let created)? = result.ops.last else { return XCTFail("應該建一個新事件") }
        XCTAssertEqual(created.title, "讀 QIC CP")
        XCTAssertEqual(created.start, at(16))
        XCTAssertEqual(created.end, at(18))
        XCTAssertFalse(created.isAllDay)
        XCTAssertEqual(result.linked, [sop.id, proposal.id, created.id])
    }

    func testAlignedDayIsANoOp() {
        let e = event("讀 QIC CP", 16, 18)
        let result = plan("- [x] 16:00–18:00 讀 QIC CP @est(2h)", [e])
        XCTAssertEqual(result.ops, [])
        XCTAssertEqual(result.linked, [e.id])
    }

    /// 打字打到一半停一下（「讀」先變成事件），接著把標題打完 → 改名，不是多一個事件。
    func testTitleEditRenamesLinkedEventInsteadOfDuplicating() {
        let e = event("讀", 16, 18)
        let result = plan("- [ ] 16:00-18:00 讀 QIC CP", [e], linked: [e.id])
        XCTAssertEqual(result.ops, [.rename(id: e.id, title: "讀 QIC CP")])
        XCTAssertEqual(result.linked, [e.id])
    }

    /// 行事曆上跟日記無關的事件，就算時段一模一樣也不會被改名。
    func testUnrelatedEventAtSameTimeIsNotRenamed() {
        let seminar = event("Seminar", 16, 18)
        let result = plan("- [ ] 16:00-18:00 讀 QIC CP", [seminar])
        XCTAssertEqual(result.ops.count, 1)
        guard case .create(let created)? = result.ops.first else { return XCTFail("應該另外建事件") }
        XCTAssertEqual(created.title, "讀 QIC CP")
        XCTAssertFalse(result.linked.contains(seminar.id))
    }

    func testRepeatingAndAllDayEventsAreLeftAlone() {
        var weekly = event("讀書會", 10, 12)
        weekly.repeatRule = EventRepeat(frequency: .weekly)
        let allDay = CalendarEvent(title: "截止日", isAllDay: true, start: at(0), end: at(0))
        let result = plan("- [ ] 14:00–15:00 讀書會\n- [ ] 09:00–10:00 截止日", [weekly, allDay],
                          linked: [weekly.id, allDay.id], removeOrphans: true)
        XCTAssertEqual(result.ops.count, 2)
        for op in result.ops {
            guard case .create = op else { return XCTFail("重複／全天事件不該被改或刪：\(op)") }
        }
    }

    /// 同名的兩段：各自對到時間相同的那個，改其中一段的時間只動那一個。
    func testDuplicateTitlesMatchByTimeFirst() {
        let morning = event("讀書", 10, 12), afternoon = event("讀書", 14, 16)
        let result = plan("- [ ] 15:00–17:00 讀書\n- [ ] 10:00–12:00 讀書", [morning, afternoon])
        XCTAssertEqual(result.ops, [.retime(id: afternoon.id, start: at(15), end: at(17))])
    }

    /// 打字途中不刪；離開那天時，對上過、現在沒有那一行的才刪。沒對上過的永遠不刪。
    func testOrphansAreRemovedOnlyOnLeaveAndOnlyIfLinked() {
        let mine = event("讀 QIC CP", 16, 18), unrelated = event("Seminar", 10, 12)
        let text = "- [ ] 讀 QIC CP @est(2h)"   // 時段被拿掉了
        XCTAssertEqual(plan(text, [mine, unrelated], linked: [mine.id]).ops, [])
        XCTAssertEqual(plan(text, [mine, unrelated], linked: [mine.id]).linked, [mine.id])
        let leaving = plan(text, [mine, unrelated], linked: [mine.id], removeOrphans: true)
        XCTAssertEqual(leaving.ops, [.delete(id: mine.id)])
        XCTAssertEqual(leaving.linked, [])
        XCTAssertEqual(plan(text, [mine, unrelated], removeOrphans: true).ops, [])
    }

    /// 過去的日子：打開時就在的行不建事件、不改時間；被動過（指紋變了）才同步。
    func testUntouchedLinesOnPastDaysAreLeftAlone() {
        let e = event("proposal 1/5", 16, 18)
        let text = "- [x] 14:45–15:45 proposal 1/5\n- [ ] 09:00–10:00 當時刪掉的事件"
        let untouched = Set(JournalEventSync.timedLines(in: text).map(\.key))
        let opened = plan(text, [e], untouched: untouched)
        XCTAssertEqual(opened.ops, [])
        XCTAssertEqual(opened.linked, [e.id])   // 仍然記得對上了，之後改那一行才跟得上

        let edited = plan("- [x] 15:00–16:00 proposal 1/5\n- [ ] 09:00–10:00 當時刪掉的事件", [e],
                          linked: opened.linked, untouched: untouched)
        XCTAssertEqual(edited.ops, [.retime(id: e.id, start: at(15), end: at(16))])
    }

    func testUnschedulingStripsOnlyTheTimeRangeOfTheMatchingLine() {
        let text = "- [ ] 14:00–16:00 proposal 2/5 @est(2h)\n  - [x] 16:00-18:00 讀 QIC CP @est(2h) !high\n- [ ] 讀 QIC CP"
        XCTAssertEqual(JournalEventSync.unscheduling(title: "讀 QIC CP", in: text),
                       "- [ ] 14:00–16:00 proposal 2/5 @est(2h)\n  - [x] 讀 QIC CP @est(2h) !high\n- [ ] 讀 QIC CP")
        XCTAssertNil(JournalEventSync.unscheduling(title: "沒有這行", in: text))
        XCTAssertNil(JournalEventSync.unscheduling(title: "", in: text))
        // 退回去之後就不再是時段行 → 不會被建回來
        let after = JournalEventSync.unscheduling(title: "proposal 2/5", in: text)!
        XCTAssertFalse(JournalEventSync.timedLines(in: after).contains { $0.title == "proposal 2/5" })
    }

    /// 回歸：規劃排了「每週」的段落也寫進日記；那天日記一打開就多建一個不重複的分身。
    func testLineCoveredByARepeatingOccurrenceIsNotDuplicated() {
        var weekly = event("古電 2/3", 10, 12, day: 11)          // 11/11 起每週，11/18 是其中一次
        weekly.repeatRule = EventRepeat(frequency: .weekly)
        XCTAssertEqual(plan("- [ ] 10:00–12:00 古電 2/3 @est(2h)", [weekly]).ops, [])

        var ended = weekly
        ended.repeatRule = EventRepeat(frequency: .weekly, until: at(0, day: 12))
        if case .create(let e)? = plan("- [ ] 10:00–12:00 古電 2/3", [ended]).ops.first {
            XCTAssertEqual(e.title, "古電 2/3", "重複已經結束的日子：照舊建事件")
        } else {
            XCTFail("應該建事件")
        }
    }
}
