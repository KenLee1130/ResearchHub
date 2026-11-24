// 日記分頁的時間軸：版面計算（HubCore `DayTimelineLayout`）與拖放後寫回日記
// （`FileSystemStore.schedulingTodo`）。畫面本身不測，這兩層是全部的邏輯。
import XCTest
@testable import ResearchHub
@testable import HubCore
@testable import HubStore

final class DayTimelineTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0, day: Int = 17) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(title: title, isAllDay: allDay, start: start, end: end)
    }

    private func make(_ events: [CalendarEvent], height: Double = 616,
                      rules: DayTimelineLayout.Rules = .init()) -> DayTimelineLayout {
        DayTimelineLayout.make(day: at(0), events: events, availableHeight: height, rules: rules, calendar: calendar)
    }

    // MARK: - 範圍

    func testDefaultRangeIs08To22AndFillsTheHeight() {
        let layout = make([event("讀書", at(14, 45), at(15, 45))])
        XCTAssertEqual(layout.startHour, 8)
        XCTAssertEqual(layout.endHour, 22)
        XCTAssertEqual(layout.pointsPerHour, 44, accuracy: 0.001, "616 ÷ 14 小時")
        XCTAssertFalse(layout.scrolls)
        XCTAssertEqual(layout.totalHeight, 616, accuracy: 0.001)
    }

    func testEarlyAndLateEventsStretchTheRangeAndCompressTheAxis() {
        let layout = make([
            event("早課", at(6, 30), at(7, 30)),
            event("聚餐", at(22, 30), at(23, 45)),
        ])
        XCTAssertEqual(layout.startHour, 6, "06:30 往下取整點")
        XCTAssertEqual(layout.endHour, 24, "23:45 往上取整點")
        XCTAssertEqual(layout.pointsPerHour, 616.0 / 18, accuracy: 0.001, "總高度不變，每小時變少")
        XCTAssertFalse(layout.scrolls)
    }

    func testAllDayAndEmptyAreIgnoredForTheRange() {
        let layout = make([event("截止", at(0), at(0), allDay: true), event("空", at(5), at(5))])
        XCTAssertEqual(layout.startHour, 8)
        XCTAssertTrue(layout.blocks.isEmpty, "全天與零長度的不進軸")
    }

    func testCrossMidnightOccurrenceIsClippedToTheDay() {
        // 前一天 22:00 開到今天 02:00 的實例 → 只取 00:00–02:00
        let layout = make([event("熬夜", at(22, day: 16), at(2))])
        XCTAssertEqual(layout.startHour, 0)
        XCTAssertEqual(layout.blocks.first?.start, at(0))
        XCTAssertEqual(layout.blocks.first?.end, at(2))
    }

    func testTooLittleHeightSwitchesToScrollingAtTheFloor() {
        let layout = make([], height: 100)
        XCTAssertTrue(layout.scrolls)
        XCTAssertEqual(layout.pointsPerHour, 24, "壓到下限就不再縮")
        XCTAssertEqual(layout.totalHeight, 24 * 14, accuracy: 0.001)
    }

    func testCustomDefaultRangeIsRespected() {
        let layout = make([], rules: .init(defaultStartHour: 10, defaultEndHour: 20))
        XCTAssertEqual(layout.startHour, 10)
        XCTAssertEqual(layout.endHour, 20)
    }

    // MARK: - 座標

    func testBlockPositionsFollowPointsPerHour() {
        let layout = make([event("讀書", at(14, 45), at(15, 45)), event("寫", at(16), at(18))])
        XCTAssertEqual(layout.blocks.count, 2)
        XCTAssertEqual(layout.blocks[0].y, 6.75 * 44, accuracy: 0.001)
        XCTAssertEqual(layout.blocks[0].height, 44, accuracy: 0.001)
        XCTAssertEqual(layout.blocks[1].y, 8 * 44, accuracy: 0.001)
        XCTAssertEqual(layout.blocks[1].height, 88, accuracy: 0.001)
        XCTAssertEqual(layout.y(for: at(9, 32)), (1 + 32.0 / 60) * 44, accuracy: 0.001)
        XCTAssertEqual(layout.y(for: at(3)), 0, "範圍外夾在兩端")
    }

    func testDateAtSnapsToQuarterHoursAndStaysInRange() {
        let layout = make([])
        XCTAssertEqual(layout.date(at: 110), at(10, 30), "110pt = 2.5 小時 → 10:30")
        XCTAssertEqual(layout.date(at: 118), at(10, 45), "118pt ≈ 10:41 → 對齊 10:45")
        XCTAssertEqual(layout.date(at: -50), at(8))
        XCTAssertEqual(layout.date(at: 9999), at(22))
    }

    // MARK: - 重疊與空檔

    func testOverlappingEventsShareColumns() {
        let layout = make([
            event("A", at(10), at(12)),
            event("B", at(11), at(13)),
            event("C", at(12), at(13)),   // 跟 A 不重疊，可以回到第一欄
            event("D", at(15), at(16)),   // 另一群
        ])
        let byTitle = Dictionary(uniqueKeysWithValues: layout.blocks.map { ($0.event.title, $0) })
        XCTAssertEqual(byTitle["A"]?.column, 0)
        XCTAssertEqual(byTitle["B"]?.column, 1)
        XCTAssertEqual(byTitle["C"]?.column, 0)
        XCTAssertEqual(byTitle["A"]?.columnCount, 2)
        XCTAssertEqual(byTitle["C"]?.columnCount, 2, "同一群共用欄數")
        XCTAssertEqual(byTitle["D"]?.columnCount, 1)
        XCTAssertEqual(layout.scheduledMinutes, 180 + 60, "重疊的不重複算")
    }

    func testGapsListOnlyLongEnoughHoles() {
        let layout = make([event("A", at(10), at(11)), event("B", at(11, 30), at(12)), event("C", at(15), at(16))])
        let gaps = layout.gaps.map { ($0.start, $0.end) }
        XCTAssertEqual(gaps.count, 3)
        XCTAssertEqual(gaps[0].0, at(8)); XCTAssertEqual(gaps[0].1, at(10))
        XCTAssertEqual(gaps[1].0, at(12)); XCTAssertEqual(gaps[1].1, at(15), "11:00–11:30 只有半小時，不列")
        XCTAssertEqual(gaps[2].0, at(16)); XCTAssertEqual(gaps[2].1, at(22))
    }

    // MARK: - 拖放後寫回日記

    private func todoLine(_ text: String, index: Int) -> TodoLine {
        let meta = TodoMeta.parse(text, calendar: calendar)
        return TodoLine(lineIndex: index, text: text, done: false, meta: meta, dedupKey: meta.cleanText)
    }

    func testSchedulingMovesTheLineIntoThePlannedSectionKeepingMarkers() {
        let content = "# 11/17\n- [x] 學貸\n- [ ] 期末考前安排 !high @line(A) @est(2h)\n- [ ] 卡費\n"
        let todo = todoLine("期末考前安排 !high @line(A) @est(2h)", index: 2)
        let event = event("期末考前安排", at(10, 30), at(11, 30))
        let updated = FileSystemStore.schedulingTodo(todo, as: event, in: content)
        XCTAssertEqual(updated,
                       "- [ ] 10:30–11:30 期末考前安排 @est(1h) !high @line(A)\n\n---\n\n# 11/17\n- [x] 學貸\n- [ ] 卡費\n",
                       "@est 依事件長度重算，其他標記保留；原行拿掉")
    }

    func testSchedulingFindsTheLineByTextWhenTheIndexIsStale() {
        let content = "- [ ] 新加的一行\n- [ ] 期末考前安排\n"
        let todo = todoLine("期末考前安排", index: 0)   // 編輯器行號已經不準
        let updated = FileSystemStore.schedulingTodo(todo, as: event("期末考前安排", at(10), at(11)), in: content)
        XCTAssertEqual(updated, "- [ ] 10:00–11:00 期末考前安排 @est(1h)\n\n---\n\n- [ ] 新加的一行\n")
    }

    func testSchedulingGivesUpWhenTheLineIsGone() {
        let todo = todoLine("已經不在了", index: 0)
        XCTAssertNil(FileSystemStore.schedulingTodo(todo, as: event("x", at(10), at(11)), in: "- [ ] 別的\n"))
        XCTAssertNil(FileSystemStore.schedulingTodo(todo, as: event("x", at(10), at(11)), in: "- [x] 已經不在了\n"),
                     "勾掉的不算")
    }

    /// 回歸：以前拖放是「叫編輯器存檔 → store 立刻讀檔改寫」，編輯器的非同步存檔晚一步落地就把 store 寫的蓋掉。
    /// 現在那天開在編輯器時改的是編輯器的文字：還沒存的那行與搬進規劃段的那行都要留在檔案裡。
    @MainActor
    func testSchedulingThroughTheEditorKeepsBothTheMoveAndUnsavedText() async throws {
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try TestFixtures.write("- [ ] 期末考前安排\n", at: "day.md", in: dir)
        let doc = EditorDocument()
        doc.open(url)
        doc.text += "- [ ] 剛打還沒存的一行\n"

        let todo = todoLine("期末考前安排", index: 0)
        let updated = try XCTUnwrap(FileSystemStore.schedulingTodo(todo, as: event("期末考前安排", at(10), at(11)), in: doc.text))
        doc.text = updated          // JournalView.scheduleTodo 走 EditorHandle.replaceText 做的事
        doc.saveNow()

        let expected = "- [ ] 10:00–11:00 期末考前安排 @est(1h)\n\n---\n\n- [ ] 剛打還沒存的一行\n"
        let deadline = Date().addingTimeInterval(3)
        while (try? String(contentsOf: url, encoding: .utf8)) != expected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
        XCTAssertEqual(doc.text, expected)
    }

    /// 編輯器沒掛著時走 store 直接改檔：要回報有沒有改到，呼叫端才知道該不該建事件。
    @MainActor
    func testStoreScheduleTodoReportsWhetherItChangedTheFile() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        store.setRoot(root)
        let url = try XCTUnwrap(store.journalURL(for: at(10)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [ ] 期末考前安排\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(store.scheduleTodo(todoLine("期末考前安排", index: 0),
                                         as: event("期末考前安排", at(10), at(11)), on: at(10)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "- [ ] 10:00–11:00 期末考前安排 @est(1h)\n\n---\n")
        XCTAssertFalse(store.scheduleTodo(todoLine("已經不在了", index: 0),
                                          as: event("已經不在了", at(13), at(14)), on: at(10)),
                       "找不到那一行 → false，呼叫端不建事件")
    }

    func testHasTimeRange() {
        XCTAssertTrue(FileSystemStore.hasTimeRange("10:00–12:00 期中考 複習 1/5"))
        XCTAssertTrue(FileSystemStore.hasTimeRange("9:00-10:30 約會"))
        XCTAssertFalse(FileSystemStore.hasTimeRange("期末考前安排"))
        XCTAssertFalse(FileSystemStore.hasTimeRange("10:00 開會"))
    }

    // MARK: - 拖色塊改時間

    func testMovingABlockKeepsItsLengthSnapsAndStaysInRange() throws {
        let layout = make([event("找意賠", at(9), at(10))])   // 44 pt／小時
        let block = try XCTUnwrap(layout.blocks.first)
        let moved = try XCTUnwrap(layout.moving(block, by: 66))
        XCTAssertEqual(moved.start, at(10, 30))
        XCTAssertEqual(moved.end, at(11, 30))
        XCTAssertNil(layout.moving(block, by: 5), "不到半格：對齊回原位 = 沒動")
        XCTAssertEqual(layout.moving(block, by: -500)?.start, at(8), "往上拖到頂")
        XCTAssertEqual(layout.moving(block, by: 5000)?.end, at(22), "往下拖到底")
    }

    func testResizingOnlyMovesTheEndAndKeepsAtLeastOneSlot() throws {
        let layout = make([event("找意賠", at(9), at(10))])
        let block = try XCTUnwrap(layout.blocks.first)
        let longer = try XCTUnwrap(layout.resizing(block, by: 44))
        XCTAssertEqual(longer.start, at(9))
        XCTAssertEqual(longer.end, at(11))
        XCTAssertEqual(layout.resizing(block, by: -200)?.end, at(9, 15), "最短一格")
    }

    func testCrossMidnightBlocksCannotBeDragged() throws {
        let layout = make([event("夜車", at(23, day: 16), at(1))])
        let block = try XCTUnwrap(layout.blocks.first)
        XCTAssertNil(layout.moving(block, by: 44))
        XCTAssertNil(layout.resizing(block, by: 44))
    }

    func testRetimingThePlannedLineKeepsCheckboxAndMarkers() throws {
        let text = "- [x] 09:00–10:00 找意賠 @est(1h) @line(A)\n\n---\n\n- [ ] 別的\n"
        let old = event("找意賠", at(9), at(10))
        let updated = try XCTUnwrap(FileSystemStore.retimingPlannedLine(
            from: old, to: event("找意賠", at(10, 30), at(11, 30)), in: text, calendar: calendar))
        XCTAssertEqual(updated, "- [x] 10:30–11:30 找意賠 @est(1h) @line(A)\n\n---\n\n- [ ] 別的\n")
        XCTAssertNil(FileSystemStore.retimingPlannedLine(
            from: old, to: event("找意賠", at(10, day: 18), at(11, day: 18)), in: text, calendar: calendar),
            "換天交給 syncPlannedLine")
        XCTAssertNil(FileSystemStore.retimingPlannedLine(
            from: event("沒有這行", at(9), at(10)), to: event("沒有這行", at(11), at(12)), in: text, calendar: calendar))
    }

    // MARK: - 從日記編輯器拖文字進時間軸

    func testDraggedEditorTextMatchesTodo() {
        let todos = LibraryIndex.parse("- [ ] 整理 code\n- [ ] 寫報告 @est(2h)\n")
        XCTAssertEqual(DayTimelineView.matchTodo("- [ ] 整理 code", in: todos)?.meta.cleanText, "整理 code")
        XCTAssertEqual(DayTimelineView.matchTodo("寫報告", in: todos)?.meta.cleanText, "寫報告")
        XCTAssertEqual(DayTimelineView.matchTodo("寫報告 @est(2h)\n下一行", in: todos)?.meta.cleanText, "寫報告")
        XCTAssertNil(DayTimelineView.matchTodo("完全不相干", in: todos))
        XCTAssertNil(DayTimelineView.matchTodo("  ", in: todos))
    }
}
