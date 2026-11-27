// 無限模式接力：Mac 與 iPhone 共用同一段（Pomodoro/flow.json）。
import XCTest
@testable import HubStore

final class FlowRelayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func shared(_ timer: FlowTimer, ended: Bool = false, by: String = "mac",
                        screens: [String: Bool] = ["mac": true], at time: Date? = nil) -> SharedFlow {
        SharedFlow(timer: timer, ended: ended, onScreen: screens, updatedBy: by, updatedAt: time ?? at(1))
    }

    private func incoming(_ s: SharedFlow, local: FlowTimer?, off: Bool = false,
                          mine: Date? = nil, canAdopt: Bool = true, now: Double = 5) -> FlowRelay.Action {
        FlowRelay.incoming(s, local: local, me: "iphone", localOffScreen: off,
                           localUpdatedAt: mine, canAdopt: canAdopt, now: at(now))
    }

    func testIdleDeviceTakesOverTheOtherDevicesFlow() {
        let remote = FlowTimer(startedAt: t0, plan: "寫作業")
        guard case .adopt(let timer, let screens) = incoming(shared(remote), local: nil) else {
            return XCTFail("應該接手")
        }
        XCTAssertEqual(timer.startedAt, t0)
        XCTAssertEqual(timer.plan, "寫作業")
        XCTAssertEqual(screens, ["mac": true, "iphone": true])
    }

    func testOwnWritesAreIgnored() {
        let s = shared(FlowTimer(startedAt: t0), by: "iphone")
        XCTAssertEqual(incoming(s, local: nil), .none)
    }

    func testDoesNotTakeOverWhileRunningClassicPomodoro() {
        XCTAssertEqual(incoming(shared(FlowTimer(startedAt: t0)), local: nil, canAdopt: false), .none)
    }

    func testDifferentFlowIsLeftAlone() {
        let mine = FlowTimer(startedAt: at(2))
        XCTAssertEqual(incoming(shared(FlowTimer(startedAt: t0)), local: mine), .none)
    }

    func testEndOnOtherDeviceEndsTheSameFlowHere() {
        let timer = FlowTimer(startedAt: t0)
        XCTAssertEqual(incoming(shared(timer, ended: true), local: timer), .end)
        // 別段結束了跟這台無關；沒在跑也不用做事
        XCTAssertEqual(incoming(shared(timer, ended: true), local: FlowTimer(startedAt: at(3))), .none)
        XCTAssertEqual(incoming(shared(timer, ended: true), local: nil), .none)
    }

    func testFollowsNewItemsRecordedOnTheOtherDevice() {
        let local = FlowTimer(startedAt: t0, plan: "A")
        var remote = local
        remote.record("B", at: at(3))
        guard case .adopt(let timer, _) = incoming(shared(remote, screens: ["mac": true, "iphone": true]),
                                                   local: local) else {
            return XCTFail("應該跟上")
        }
        XCTAssertEqual(timer.plan, "B")
    }

    func testOlderWriteArrivingLateDoesNotRevertLocalChange() {
        let local = FlowTimer(startedAt: t0, plan: "A")
        var remote = local
        remote.record("舊的", at: at(1))
        XCTAssertEqual(incoming(shared(remote, at: at(2)), local: local, mine: at(4)), .none)
    }

    func testAwayOnlyWhenEveryDeviceIsAway() {
        // Mac 在螢幕前、手機鎖了 → 還在工作
        let s = shared(FlowTimer(startedAt: t0), screens: ["mac": true])
        guard case .adopt(let t1, _) = incoming(s, local: nil, off: true) else { return XCTFail() }
        XCTAssertFalse(t1.offScreen)
        // 兩台都離開 → 從這刻開始算非工作時間
        let s2 = shared(FlowTimer(startedAt: t0), screens: ["mac": false])
        guard case .adopt(let t2, _) = incoming(s2, local: nil, off: true, now: 10) else { return XCTFail() }
        XCTAssertTrue(t2.offScreen)
        XCTAssertEqual(t2.awaySince, at(10))
    }

    func testForgottenFlowIsNotTakenOver() {
        let s = shared(FlowTimer(startedAt: t0))
        XCTAssertEqual(incoming(s, local: nil, now: 17 * 60), .none)
    }

    func testSharedFlowRoundTripsThroughJSON() throws {
        var timer = FlowTimer(startedAt: t0, plan: "A")
        timer.setPaused(true, at: at(2))
        let s = shared(timer, screens: ["mac": true, "iphone": false])
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode(SharedFlow.self, from: e.encode(s)), s)
    }

    func testRelayedFlowIsDrawnOnceOnTheTimeline() {
        let mac = PomodoroLiveState(device: "mac", active: true, kind: .flow, startedAt: at(0))
        let phone = PomodoroLiveState(device: "iphone", active: true, kind: .flow, startedAt: at(0))
        let spans = pomodoroFocusSpans(day: t0, sessions: [], live: [mac, phone], now: at(30))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.liveState?.device, "mac")
    }
}
