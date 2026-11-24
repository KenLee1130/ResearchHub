// 有子項的待辦怎麼排進行事曆（使用者定的四條規則，見 HubStore `TodoTree`）。
import XCTest
@testable import HubCore
@testable import HubStore

@MainActor
final class TodoTreeTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: h, minute: m))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date) -> CalendarEvent {
        CalendarEvent(title: title, isAllDay: false, start: start, end: end)
    }

    private func todo(_ text: String, in content: String) -> TodoLine {
        LibraryIndex.parse(content).first { $0.meta.cleanText == text }!
    }

    /// 使用者實際的寫法：項目之間空一行、子項縮兩格
    private let journal = """
    - [ ] 14:30–15:30 專討 @est(1h)

    ---

    - [ ] 整理 code

      - [ ] 1. 寫成 html @est(1h)

      - [ ] 2. 整理 notebook @est(30m)

    GD 先讓 potential 粗糙一點
    """

    // MARK: 規則 1：拖母項 → 整組搬

    func testDraggingTheParentMovesTheWholeGroup() throws {
        let updated = try XCTUnwrap(FileSystemStore.schedulingTodo(
            todo("整理 code", in: journal), as: event("整理 code", at(10), at(11, 30)), in: journal))
        XCTAssertEqual(updated, """
        - [ ] 10:00–11:30 整理 code @est(90m)

          - [ ] 1. 寫成 html @est(1h)

          - [ ] 2. 整理 notebook @est(30m)

        - [ ] 14:30–15:30 專討 @est(1h)

        ---

        GD 先讓 potential 粗糙一點
        """)
    }

    func testGroupLengthIsTheSumOfTheChildrenWhenTheParentHasNoEst() {
        let lines = LibraryIndex.parse(journal)
        XCTAssertEqual(TodoTree.estimatedMinutes(of: todo("整理 code", in: journal), in: lines), 90)
        XCTAssertEqual(TodoTree.estimatedMinutes(of: todo("專討", in: journal.replacingOccurrences(of: "14:30–15:30 ", with: "")), in: lines), 60)
    }

    // MARK: 規則 2：只排部分子項 → 原地

    func testSchedulingOneChildKeepsItInPlace() throws {
        let updated = try XCTUnwrap(FileSystemStore.schedulingTodo(
            todo("1. 寫成 html", in: journal), as: event("1. 寫成 html", at(16), at(17)), in: journal))
        XCTAssertEqual(updated, journal.replacingOccurrences(
            of: "  - [ ] 1. 寫成 html @est(1h)", with: "  - [ ] 16:00–17:00 1. 寫成 html @est(1h)"))
    }

    // MARK: 規則 3：子項全排了 → 整組搬，照最早的子項排

    func testSchedulingTheLastChildMovesTheGroupSortedByItsEarliestChild() throws {
        let first = try XCTUnwrap(FileSystemStore.schedulingTodo(
            todo("1. 寫成 html", in: journal), as: event("1. 寫成 html", at(16), at(17)), in: journal))
        let both = try XCTUnwrap(FileSystemStore.schedulingTodo(
            todo("2. 整理 notebook", in: first), as: event("2. 整理 notebook", at(9), at(9, 30)), in: first))
        XCTAssertEqual(both, """
        - [ ] 整理 code

          - [ ] 16:00–17:00 1. 寫成 html @est(1h)

          - [ ] 09:00–09:30 2. 整理 notebook @est(30m)

        - [ ] 14:30–15:30 專討 @est(1h)

        ---

        GD 先讓 potential 粗糙一點
        """)
    }

    func testRetimingAChildInsideTheSectionKeepsItsIndent() throws {
        let text = "- [ ] 整理 code\n  - [ ] 09:00–10:00 子 @est(1h)\n\n---\n"
        let updated = try XCTUnwrap(FileSystemStore.retimingPlannedLine(
            from: event("子", at(9), at(10)), to: event("子", at(13), at(14)), in: text, calendar: calendar))
        XCTAssertEqual(updated, "- [ ] 整理 code\n  - [ ] 13:00–14:00 子 @est(1h)\n\n---\n")
    }

    // MARK: 時間軸清單

    func testUnscheduledListShowsTheTreeAndHidesScheduledGroups() {
        let rows = TodoTree.unscheduled(LibraryIndex.parse(journal))
        XCTAssertEqual(rows.map(\.todo.meta.cleanText), ["整理 code", "1. 寫成 html", "2. 整理 notebook"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
        XCTAssertEqual(rows.map(\.childCount), [2, 0, 0])

        let parentTimed = "- [ ] 10:00–11:00 整理 code\n  - [ ] 1. 寫成 html\n"
        XCTAssertTrue(TodoTree.unscheduled(LibraryIndex.parse(parentTimed)).isEmpty, "母項排了，子項跟著整組")

        let childrenTimed = "- [ ] 整理 code\n  - [ ] 10:00–11:00 甲\n  - [ ] 11:00–12:00 乙\n"
        XCTAssertTrue(TodoTree.unscheduled(LibraryIndex.parse(childrenTimed)).isEmpty, "子項全排了，母項不用再拖")
    }

    // MARK: 規則 4：子項全勾 → 母項勾

    func testCheckingTheLastChildChecksTheParentAndUncheckingReverts() {
        let lines = ["- [ ] 整理 code", "", "  - [x] 1. 寫成 html", "", "  - [x] 2. 整理 notebook", "", "下一段"]
        let checked = TodoTree.syncingParentChecks(lines, changed: 4)
        XCTAssertEqual(checked[0], "- [x] 整理 code")
        var unchecked = checked
        unchecked[2] = "  - [ ] 1. 寫成 html"
        XCTAssertEqual(TodoTree.syncingParentChecks(unchecked, changed: 2)[0], "- [ ] 整理 code")
        let partial = ["- [ ] 母", "  - [x] 甲", "  - [ ] 乙"]
        XCTAssertEqual(TodoTree.syncingParentChecks(partial, changed: 1), partial)
    }

    func testAutoCheckClimbsNestedLevels() {
        let lines = ["- [ ] 大", "  - [ ] 中", "    - [x] 小甲", "    - [x] 小乙", "  - [x] 中二"]
        let out = TodoTree.syncingParentChecks(lines, changed: 3)
        XCTAssertEqual(out[1], "  - [x] 中")
        XCTAssertEqual(out[0], "- [x] 大")
    }
}
