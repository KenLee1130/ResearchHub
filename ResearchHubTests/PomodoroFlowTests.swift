// 無限模式（正向計時）的記帳與時間軸紅線。全部用固定時刻，不碰 UserDefaults。
import XCTest
@testable import HubStore

final class PomodoroFlowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testLeavingScreenCountsAsAwayTime() {
        var f = FlowTimer(startedAt: at(0), plan: "讀 CFT")
        f.setOffScreen(true, at: at(20))     // 切去看訊息
        f.setOffScreen(false, at: at(25))
        f.setOffScreen(true, at: at(50))     // 還在外面

        XCTAssertEqual(f.totalSeconds(at: at(60)), 3600)
        XCTAssertEqual(f.awaySeconds(at: at(60)), 15 * 60)
        XCTAssertEqual(f.workSeconds(at: at(60)), 45 * 60)
        XCTAssertEqual(f.workSpans(until: at(60)),
                       [PomodoroSpan(start: at(0), end: at(20)), PomodoroSpan(start: at(25), end: at(50))])
    }

    func testPauseAndOffScreenOverlapIsOneAwaySpan() {
        var f = FlowTimer(startedAt: at(0))
        f.setPaused(true, at: at(10))
        f.setOffScreen(true, at: at(12))     // 暫停中又離開畫面：同一段
        f.setOffScreen(false, at: at(18))
        XCTAssertTrue(f.isAway)              // 還在暫停
        f.setPaused(false, at: at(20))
        XCTAssertFalse(f.isAway)
        XCTAssertEqual(f.awaySpans, [PomodoroSpan(start: at(10), end: at(20))])
        XCTAssertEqual(f.workSeconds(at: at(30)), 20 * 60)
    }

    func testFlowSurvivesCodableRoundTrip() throws {
        var f = FlowTimer(startedAt: at(0), plan: "x")
        f.setOffScreen(true, at: at(5))
        let data = try JSONEncoder().encode(f)
        XCTAssertEqual(try JSONDecoder().decode(FlowTimer.self, from: data), f)
    }

    func testComplementClipsAndMergesHoles() {
        let range = PomodoroSpan(start: at(0), end: at(60))
        let holes = [PomodoroSpan(start: at(-10), end: at(5)),
                     PomodoroSpan(start: at(30), end: at(40)),
                     PomodoroSpan(start: at(35), end: at(45)),
                     PomodoroSpan(start: at(55), end: at(90))]
        XCTAssertEqual(PomodoroSpan.complement(of: holes, within: range),
                       [PomodoroSpan(start: at(5), end: at(30)), PomodoroSpan(start: at(45), end: at(55))])
    }

    func testFocusSpansFromSessionsAndLiveStates() {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.startOfDay(for: at(0))
        let classic = PomodoroSession(date: at(25), minutes: 25, plan: "a", done: "", startedAt: at(0))
        // 沒開始時刻的舊紀錄：用完成時刻回推長度
        let legacy = PomodoroSession(date: at(120), minutes: 25, plan: "b", done: "")
        let flow = PomodoroSession(date: at(240), minutes: 50, plan: "", done: "", startedAt: at(180),
                                   kind: "flow", awaySpans: [PomodoroSpan(start: at(200), end: at(210))])
        // 另一台正在跑的無限模式，目前離開畫面中
        let remote = PomodoroLiveState(device: "iphone", active: true, kind: .flow, startedAt: at(300),
                                       awaySince: at(320))
        // 這台正在倒數
        let local = PomodoroLiveState(device: "mac", active: true, kind: .classic, startedAt: at(330),
                                      phaseEndAt: at(355))

        let spans = pomodoroFocusSpans(day: day, sessions: [classic, legacy, flow],
                                       live: [local, remote], now: at(340), calendar: cal)
        XCTAssertEqual(spans, [
            FocusSpan(start: at(0), end: at(25), live: false, sessionID: classic.id),
            FocusSpan(start: at(95), end: at(120), live: false, sessionID: legacy.id),
            FocusSpan(start: at(180), end: at(200), live: false, sessionID: flow.id),
            FocusSpan(start: at(210), end: at(240), live: false, sessionID: flow.id),
            FocusSpan(start: at(300), end: at(320), live: false, liveState: remote),   // 離開畫面那段不畫
            FocusSpan(start: at(330), end: at(340), live: true, liveState: local),
        ].filter { cal.isDate($0.start, inSameDayAs: day) })
    }

    func testStaleLiveStatesAreIgnored() {
        // 倒數早就結束卻還寫著 active（那台當掉沒收尾）
        let stale = PomodoroLiveState(device: "mac", active: true, kind: .classic,
                                      startedAt: at(0), phaseEndAt: at(25))
        XCTAssertTrue(stale.workSpans(at: at(60)).isEmpty)
        // 無限模式開超過 16 小時
        let forgotten = PomodoroLiveState(device: "iphone", active: true, kind: .flow, startedAt: at(0))
        XCTAssertTrue(forgotten.workSpans(at: at(17 * 60)).isEmpty)
        XCTAssertFalse(forgotten.workSpans(at: at(60)).isEmpty)
    }

    func testMigratedPlaceholderSessionsHaveNoSpan() {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 1; c.hour = 12
        let noon = Calendar.current.date(from: c)!
        let migrated = PomodoroSession(date: noon, minutes: 25, plan: "", done: "")
        XCTAssertTrue(migrated.workSpans().isEmpty)
    }

    func testOldRecordsStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"2026-11-01T10:00:00Z","minutes":25,"plan":"p","done":"d"}]"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let s = try d.decode([PomodoroSession].self, from: Data(json.utf8))
        XCTAssertNil(s[0].kind)
        XCTAssertNil(s[0].tracks)
        XCTAssertFalse(s[0].isFlow)
    }
}
