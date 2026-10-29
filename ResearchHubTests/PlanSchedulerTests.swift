// 守「規劃」功能（docs/ARCHITECTURE.md 5.3；PlanScheduler.swift、CalendarEvent.swift）：
// 段數計算、等距分配、避開既有事件與夜間、每天上限、今天已過的時間不排、
// 事件的 planID／planTitle 容錯解碼、EventStore 的整組刪除。
import XCTest
@testable import ResearchHub
@testable import HubStore
@testable import HubCore

final class PlanSchedulerTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func hm(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    private func dayOf(_ date: Date) -> Int { calendar.component(.day, from: date) }

    /// 11/1–11/7 排 10 小時、每段 2 小時；「現在」是 10/31 晚上，所以七天都是整天可用。
    private func midterm(rules: PlanRules = PlanRules()) -> PlanRequest {
        PlanRequest(goal: "期中考", sessionLabel: "複習", tagID: nil,
                    firstDay: day(2026, 11, 1), lastDay: day(2026, 11, 7),
                    totalMinutes: 600, sessionMinutes: 120, rules: rules)
    }
    private var eve: Date { day(2026, 10, 31, 21, 0) }

    // MARK: 段數與分配

    func testSessionCountRoundsUpAndLastSessionTakesRemainder() {
        XCTAssertEqual(PlanRequest(goal: "x", firstDay: .now, lastDay: .now, totalMinutes: 600, sessionMinutes: 120).sessionCount, 5)
        XCTAssertEqual(PlanRequest(goal: "x", firstDay: .now, lastDay: .now, totalMinutes: 600, sessionMinutes: 180).sessionCount, 4)
        XCTAssertEqual(PlanRequest(goal: "x", firstDay: .now, lastDay: .now, totalMinutes: 0, sessionMinutes: 60).sessionCount, 0)

        var request = midterm()
        request.sessionMinutes = 180 // 3,3,3,1
        let result = PlanScheduler.schedule(request, existing: [], now: eve, calendar: calendar)
        XCTAssertEqual(result.events.count, 4)
        XCTAssertEqual(result.events.last?.end.timeIntervalSince(result.events.last!.start), 3600)
        XCTAssertEqual(result.events.first?.end.timeIntervalSince(result.events.first!.start), 3 * 3600)
    }

    func testDistributeSpreadsEvenlyAndStacksExtrasNearDeadline() {
        XCTAssertEqual(PlanScheduler.distribute(5, over: Array(repeating: 2, count: 7)), [1, 0, 1, 1, 0, 1, 1])
        XCTAssertEqual(PlanScheduler.distribute(1, over: [2, 2, 2]), [0, 0, 1])
        XCTAssertEqual(PlanScheduler.distribute(3, over: [2, 2, 2]), [1, 1, 1])
        XCTAssertEqual(PlanScheduler.distribute(5, over: [2, 2, 2]), [1, 2, 2])
        // 容量不夠就排不完
        XCTAssertEqual(PlanScheduler.distribute(9, over: [1, 2, 0]), [1, 2, 0])
    }

    func testMidtermTenHoursInSevenDaysGivesFiveSessionsWithTitlesAndNotes() {
        let request = midterm()
        let result = PlanScheduler.schedule(request, existing: [], now: eve, calendar: calendar)
        XCTAssertEqual(result.totalSessions, 5)
        XCTAssertEqual(result.unplacedCount, 0)
        XCTAssertEqual(result.events.map(\.title), ["期中考 複習 1/5", "期中考 複習 2/5", "期中考 複習 3/5", "期中考 複習 4/5", "期中考 複習 5/5"])
        XCTAssertEqual(result.events.map { dayOf($0.start) }, [1, 3, 4, 6, 7])
        XCTAssertTrue(result.events.allSatisfy { $0.planID == request.planID && $0.planTitle == "期中考" && !$0.isAllDay })
        XCTAssertTrue(result.events.allSatisfy { $0.end.timeIntervalSince($0.start) == 2 * 3600 })
        // 沒有偏好時刻 → 當天最早（08:00）
        XCTAssertEqual(hm(result.events[0].start), "08:00")
        XCTAssertTrue(result.events[0].notes.contains("「期中考」規劃的第 1 段，共 5 段"))
        XCTAssertTrue(result.events[0].notes.contains("合計 10 小時，每段 2 小時"))
        XCTAssertEqual(PlanScheduler.title(for: PlanRequest(goal: "約會", firstDay: .now, lastDay: .now,
                                                            totalMinutes: 60, sessionMinutes: 60), number: 1, total: 1),
                       "約會 1/1")
    }

    // MARK: 規則

    func testPrefersPeakHourAndAvoidsExistingEvents() {
        var rules = PlanRules()
        rules.preferredStartHour = 20
        let request = midterm(rules: rules)
        // 11/1 晚上 20:00–21:00 已經有事 → 第一段不能從 20:00 開始；留 15 分鐘緩衝
        let dinner = CalendarEvent(title: "聚餐", isAllDay: false,
                                   start: day(2026, 11, 1, 20, 0), end: day(2026, 11, 1, 21, 0))
        // 全天的「截止日」不擋時間
        let allDay = CalendarEvent(title: "截止日", isAllDay: true,
                                   start: day(2026, 11, 3), end: day(2026, 11, 3))
        let result = PlanScheduler.schedule(request, existing: [dinner, allDay], now: eve, calendar: calendar)
        XCTAssertEqual(result.events.count, 5)
        let first = result.events[0]
        XCTAssertEqual(dayOf(first.start), 1)
        XCTAssertFalse(first.start < dinner.end.addingTimeInterval(15 * 60) && first.end > dinner.start.addingTimeInterval(-15 * 60),
                       "不可與既有事件（含緩衝）重疊：\(hm(first.start))–\(hm(first.end))")
        // 20:00 被擋，離 20:00 最近又放得下 2 小時的是 17:45（結束 19:45，離聚餐 15 分）
        XCTAssertEqual(hm(first.start), "17:45")
        // 沒被擋的那幾天就落在高產時段 20:00
        XCTAssertEqual(hm(result.events[1].start), "20:00")
        XCTAssertEqual(dayOf(result.events[1].start), 3)
        // 全部都在 08:00–23:00 之內
        for e in result.events {
            XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: e.start), 8)
            XCTAssertLessThanOrEqual(e.end, calendar.date(bySettingHour: 23, minute: 0, second: 0, of: e.start)!)
        }
    }

    func testNightWindowPushesLateSessionsEarlier() {
        var rules = PlanRules()
        rules.preferredStartHour = 22 // 22:00 起 2 小時會跨到 23:00 之後 → 退到 21:00
        let result = PlanScheduler.schedule(midterm(rules: rules), existing: [], now: eve, calendar: calendar)
        XCTAssertTrue(result.events.allSatisfy { hm($0.start) == "21:00" }, result.events.map { hm($0.start) }.description)
    }

    func testMaxSessionsPerDayAndTooShortRangeLeaveSessionsUnplaced() {
        var request = midterm()
        request.lastDay = day(2026, 11, 2) // 只剩兩天、每天最多 2 段 → 4 段，1 段排不進
        let result = PlanScheduler.schedule(request, existing: [], now: eve, calendar: calendar)
        XCTAssertEqual(result.events.count, 4)
        XCTAssertEqual(result.unplacedCount, 1)
        XCTAssertEqual(result.events.map { dayOf($0.start) }, [1, 1, 2, 2])
        // 同一天兩段之間至少 15 分鐘
        XCTAssertGreaterThanOrEqual(result.events[1].start.timeIntervalSince(result.events[0].end), 15 * 60)
        XCTAssertEqual(result.events.map(\.title).last, "期中考 複習 4/5")
    }

    func testTodaySkipsPastTimeAndRoundsToQuarterHour() {
        var request = midterm()
        request.firstDay = day(2026, 11, 1)
        request.lastDay = day(2026, 11, 1)
        request.totalMinutes = 120
        // 現在 11/1 10:07 → 加 15 分緩衝 = 10:22 → 對齊 10:30
        let result = PlanScheduler.schedule(request, existing: [], now: day(2026, 11, 1, 10, 7), calendar: calendar)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(hm(result.events[0].start), "10:30")
        // 今天已經太晚（22:30）→ 排不進
        let late = PlanScheduler.schedule(request, existing: [], now: day(2026, 11, 1, 22, 30), calendar: calendar)
        XCTAssertEqual(late.events.count, 0)
        XCTAssertEqual(late.unplacedCount, 1)
    }

    // MARK: 每隔幾天一段

    func testEveryDaysSpacingSkipsBusyDaysForward() {
        var request = midterm()
        request.totalMinutes = 480 // 4 段
        request.spacing = .everyDays(2)
        let free = PlanScheduler.schedule(request, existing: [], now: eve, calendar: calendar)
        XCTAssertEqual(free.events.map { dayOf($0.start) }, [1, 3, 5, 7])

        // 11/3 整天有事 → 那段順延到 11/4，之後照原節拍 11/5、11/7
        let busy = CalendarEvent(title: "出差", isAllDay: false,
                                 start: day(2026, 11, 3, 7, 0), end: day(2026, 11, 3, 23, 0))
        let shifted = PlanScheduler.schedule(request, existing: [busy], now: eve, calendar: calendar)
        XCTAssertEqual(shifted.events.map { dayOf($0.start) }, [1, 4, 5, 7])
        XCTAssertEqual(shifted.events.map(\.title).last, "期中考 複習 4/4")

        // 每隔 3 天、範圍不夠 → 排不完
        request.spacing = .everyDays(3)
        let short = PlanScheduler.schedule(request, existing: [], now: eve, calendar: calendar)
        XCTAssertEqual(short.events.map { dayOf($0.start) }, [1, 4, 7])
        XCTAssertEqual(short.unplacedCount, 1)
    }

    func testFirstSlotHonoursRulesAndExistingEvents() {
        var rules = PlanRules()
        rules.preferredStartHour = 14
        let request = midterm(rules: rules)
        let seminar = CalendarEvent(title: "Seminar", isAllDay: false,
                                    start: day(2026, 11, 2, 14, 0), end: day(2026, 11, 2, 16, 0))
        let slot = PlanScheduler.firstSlot(on: day(2026, 11, 2), request: request, existing: [seminar],
                                           now: eve, calendar: calendar)
        XCTAssertEqual(slot.map { hm($0.start) }, "11:45")
        XCTAssertNil(PlanScheduler.firstSlot(on: day(2026, 11, 2), request: request, existing: [],
                                             now: day(2026, 11, 2, 22, 30), calendar: calendar))
    }

    // MARK: 資料契約

    func testCalendarEventDecodesWithoutPlanFieldsAndOmitsThemWhenNil() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = Data("""
        {"id":"7E0E7B7C-0E8E-4F7B-9C3B-000000000001","title":"口試","isAllDay":true,
         "start":"2026-11-01T00:00:00Z","end":"2026-11-01T00:00:00Z"}
        """.utf8)
        let event = try decoder.decode(CalendarEvent.self, from: old)
        XCTAssertNil(event.planID)
        XCTAssertNil(event.planTitle)
        XCTAssertFalse(event.isPlanned)
        XCTAssertEqual(event.notes, "")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plain = String(decoding: try encoder.encode(event), as: UTF8.self)
        XCTAssertFalse(plain.contains("planID"))
        XCTAssertFalse(plain.contains("planTitle"))
        XCTAssertFalse(plain.contains("tagID"))

        let planID = UUID()
        let planned = CalendarEvent(title: "期中考 複習 1/5", isAllDay: false, start: .now, end: .now,
                                    planID: planID, planTitle: "期中考")
        let roundTrip = try decoder.decode(CalendarEvent.self, from: try encoder.encode(planned))
        XCTAssertEqual(roundTrip.planID, planID)
        XCTAssertEqual(roundTrip.planTitle, "期中考")
        XCTAssertTrue(roundTrip.isPlanned)
    }

    @MainActor
    func testEventStoreGroupsAndDeletesPlans() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventStore(librarySync: LibrarySync())
        store.configure(rootURL: root)

        let request = midterm()
        let plan = PlanScheduler.schedule(request, existing: [], now: eve, calendar: calendar)
        let other = CalendarEvent(title: "聚餐", isAllDay: false, start: day(2026, 11, 1, 20, 0), end: day(2026, 11, 1, 21, 0))
        store.add(other)
        store.add(contentsOf: plan.events)

        XCTAssertEqual(store.events.count, 6)
        XCTAssertEqual(store.events(inPlan: request.planID).map(\.title).first, "期中考 複習 1/5")
        XCTAssertEqual(store.events(inPlan: request.planID).count, 5)

        // 寫進檔案的格式帶 planID／planTitle，重讀得回來
        let url = root.appendingPathComponent(".hub/events.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"planTitle\" : \"期中考\""))
        let reloaded = EventStore(librarySync: LibrarySync())
        reloaded.configure(rootURL: root)
        XCTAssertEqual(reloaded.events(inPlan: request.planID).count, 5)

        store.deletePlan(request.planID)
        XCTAssertEqual(store.events.map(\.title), ["聚餐"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("planID"))
    }
}
