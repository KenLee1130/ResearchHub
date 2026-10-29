// 守 iPhone「今天」分頁依賴的 store 行為：原生待辦列直接改日記檔
// （打勾、放棄單行、快速新增、搬到明天），不經過網頁編輯器。
import XCTest
@testable import ResearchHub
@testable import HubStore
@testable import HubCore

final class MobileTodayTests: XCTestCase {
    private var root: URL!
    private var store: FileSystemStore!
    private let calendar = Calendar.current

    @MainActor
    override func setUpWithError() throws {
        root = try TestFixtures.makeTempDir()
        store = FileSystemStore(noteLinks: NoteLinkIndex(), librarySync: LibrarySync())
        store.setRoot(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func items(on date: Date) throws -> [LibraryTodoItem] {
        let url = try XCTUnwrap(store.journalURL(for: date))
        return (LibraryIndex.shared.todoLines(in: url) ?? []).map {
            LibraryTodoItem(noteURL: url, lineIndex: $0.lineIndex, text: $0.text,
                            done: $0.done, meta: $0.meta)
        }
    }

    @MainActor
    func testAbandonTodoMarksOnlyThatLine() throws {
        let day = calendar.startOfDay(for: .now)
        let url = try XCTUnwrap(store.journalURL(for: day))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [ ] 讀 CFT\n\n- [ ] 寫作業 !high\n\n- [x] 回信\n".write(to: url, atomically: true, encoding: .utf8)
        let todos = try items(on: day)
        XCTAssertEqual(todos.map(\.meta.cleanText), ["讀 CFT", "寫作業", "回信"])

        XCTAssertTrue(store.abandonTodo(todos[1]))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "- [ ] 讀 CFT\n\n- [-] 寫作業 !high\n\n- [x] 回信\n")
        // 已放棄的行不再是待辦；其他行不動
        XCTAssertEqual(try items(on: day).map(\.meta.cleanText), ["讀 CFT", "回信"])
        // 已完成的行不能「放棄」
        XCTAssertFalse(store.abandonTodo(todos[2]))
    }

    @MainActor
    func testQuickAddThenToggleAndMoveToTomorrow() throws {
        let day = calendar.startOfDay(for: .now)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))

        store.appendTodoLine("複習期中考 @est(2h) !high", on: day)
        var todos = try items(on: day)
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].meta.cleanText, "複習期中考")
        XCTAssertEqual(todos[0].meta.estMinutes, 120)
        XCTAssertEqual(todos[0].meta.priority, .high)

        store.toggleTodo(todos[0])
        todos = try items(on: day)
        XCTAssertTrue(todos[0].done)
        store.toggleTodo(todos[0])
        todos = try items(on: day)
        XCTAssertFalse(todos[0].done)

        // 搬到明天 = 明天多一份原文（含標記），今天這行變已放棄
        store.appendTodoLine(todos[0].text, on: tomorrow)
        store.abandonTodo(todos[0])
        XCTAssertEqual(try items(on: day).count, 0)
        let moved = try items(on: tomorrow)
        XCTAssertEqual(moved.map(\.text), ["複習期中考 @est(2h) !high"])
    }
}
