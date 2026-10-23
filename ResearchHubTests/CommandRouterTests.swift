// 守命令路由（docs/ARCHITECTURE.md 第 3 節）：頁面先接、不接走視窗退路、⌘F 沒人接退到全 app 搜尋。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class CommandRouterTests: XCTestCase {
    private func recorder(_ accepts: Set<AppCommand>, into log: inout [String], name: String) -> ClosureCommandHandler {
        // 用 class 包住 log 的寫入，閉包才能逃逸
        let box = LogBox()
        let h = ClosureCommandHandler { cmd in
            box.lines.append("\(name):\(cmd)")
            return accepts.contains(cmd)
        }
        boxes.append(box)
        return h
    }
    private final class LogBox { var lines: [String] = [] }
    private var boxes: [LogBox] = []
    private var log: [String] { boxes.flatMap(\.lines) }

    func testTopPageHandlesFirst() {
        var scratch: [String] = []
        let router = CommandRouter()
        let home = recorder([], into: &scratch, name: "home")
        let note = recorder([.find], into: &scratch, name: "note")
        router.push(home)
        router.push(note)
        XCTAssertTrue(router.handle(.find))
        XCTAssertTrue(router.top === note)
        XCTAssertEqual(log, ["note:find"], "只有最上面的頁面被問到")
    }

    func testPopRestoresPreviousPage() {
        var scratch: [String] = []
        let router = CommandRouter()
        let page = recorder([.find], into: &scratch, name: "page")
        let sheet = recorder([.find], into: &scratch, name: "sheet")
        router.push(page); router.push(sheet)
        router.pop(sheet)
        XCTAssertTrue(router.top === page)
        router.handle(.find)
        XCTAssertEqual(log.last, "page:find")
    }

    func testFindFallsBackToGlobalSearchWhenNobodyTakesIt() {
        var scratch: [String] = []
        let router = CommandRouter()
        var fallbackCalls: [AppCommand] = []
        router.windowFallback = { cmd in fallbackCalls.append(cmd); return cmd == .globalSearch }
        let home = recorder([], into: &scratch, name: "home")   // router 只握 weak，測試要自己持住
        router.push(home)
        XCTAssertTrue(router.handle(.find))
        XCTAssertEqual(fallbackCalls, [.find, .globalSearch], "先問退路要不要 ⌘F，不要才退成 ⌘K")
        XCTAssertFalse(router.handle(.closeTab))
    }

    func testWindowFallbackHandlesWindowLevelCommands() {
        var scratch: [String] = []
        let router = CommandRouter()
        var opened = 0
        router.windowFallback = { cmd in
            if cmd == .newTab { opened += 1; return true }
            return false
        }
        let note = recorder([.find], into: &scratch, name: "note")
        router.push(note)
        XCTAssertTrue(router.handle(.newTab))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(log, ["note:newTab"], "頁面先被問，不接才到視窗")
    }

    func testDeallocatedHandlersAreSkipped() {
        let router = CommandRouter()
        var gone: ClosureCommandHandler? = ClosureCommandHandler { _ in true }
        router.push(gone!)
        gone = nil
        XCTAssertNil(router.top)
        XCTAssertFalse(router.handle(.find), "沒有退路、頁面也沒了 → false")
    }

    func testNoRouterWithoutPagesOrFallbackReturnsFalse() {
        XCTAssertFalse(CommandRouter().handle(.globalSearch))
    }
}
