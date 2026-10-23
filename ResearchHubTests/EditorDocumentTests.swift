// 守 EditorDocument（mac 與 iPhone 共用的讀檔／自動存檔／外部改動重讀）：
// 空檔不落地、存檔後 dirty 歸零、換檔先寫出舊檔、附加文字、沒有檔案時清空。
import XCTest
@testable import ResearchHub

final class EditorDocumentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestFixtures.makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// FileWatcher 的寫入在背景佇列做、完成回主執行緒：等 onSaved 或 initialText 變了
    private func waitUntil(_ cond: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testOpenMissingFileStartsEmptyAndDoesNotCreateIt() async {
        let url = dir.appendingPathComponent("new.md")
        let doc = EditorDocument()
        doc.open(url)
        XCTAssertEqual(doc.text, "")
        XCTAssertFalse(doc.fileExisted)
        XCTAssertFalse(doc.isDirty)
        doc.saveNow()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "空內容的新檔不落地")
    }

    func testOpenExistingFileReadsContent() throws {
        let url = try TestFixtures.write("hello\n", at: "note.md", in: dir)
        let doc = EditorDocument()
        doc.open(url)
        XCTAssertEqual(doc.text, "hello\n")
        XCTAssertTrue(doc.fileExisted)
        XCTAssertFalse(doc.awaitingDownload)
    }

    func testSaveNowWritesAndClearsDirty() async throws {
        let url = dir.appendingPathComponent("new.md")
        let doc = EditorDocument()
        var saved = 0
        doc.onSaved = { saved += 1 }
        doc.open(url)
        doc.text = "- [ ] 讀 CFT"
        XCTAssertTrue(doc.isDirty)
        doc.saveNow()
        await waitUntil { !doc.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "- [ ] 讀 CFT")
        XCTAssertTrue(doc.fileExisted)
        XCTAssertEqual(saved, 1)
        doc.saveNow()   // 沒改動就不再寫
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(saved, 1)
    }

    func testAutosaveFiresAfterDelay() async throws {
        let url = try TestFixtures.write("a", at: "auto.md", in: dir)
        let doc = EditorDocument(autosaveDelay: 50_000_000)
        doc.open(url)
        doc.text = "ab"
        doc.scheduleAutosave()
        await waitUntil { !doc.isDirty }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ab")
    }

    func testSwitchFileWritesPreviousFileFirst() async throws {
        let a = try TestFixtures.write("A", at: "a.md", in: dir)
        let b = try TestFixtures.write("B", at: "b.md", in: dir)
        let doc = EditorDocument()
        doc.open(a)
        doc.text = "A2"
        doc.switchFile(to: b)
        XCTAssertEqual(doc.text, "B")
        XCTAssertEqual(doc.fileURL, b)
        await waitUntil { (try? String(contentsOf: a, encoding: .utf8)) == "A2" }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A2")
        XCTAssertFalse(doc.isDirty, "換檔後晚到的寫入回呼不能把舊檔狀態套到新檔")
    }

    func testAppendAddsNewlineOnlyWhenNeeded() {
        let doc = EditorDocument()
        doc.open(dir.appendingPathComponent("x.md"))
        doc.append("- [ ] a\n")
        XCTAssertEqual(doc.text, "- [ ] a\n")
        doc.text = "line"
        doc.append("- [ ] b\n")
        XCTAssertEqual(doc.text, "line\n- [ ] b\n")
    }

    func testOpenNilClearsEverything() throws {
        let url = try TestFixtures.write("hello", at: "note.md", in: dir)
        let doc = EditorDocument()
        doc.open(url)
        doc.open(nil)
        XCTAssertEqual(doc.text, "")
        XCTAssertNil(doc.fileURL)
        XCTAssertFalse(doc.fileExisted)
    }

    func testReloadIfCleanPicksUpExternalChangeButNotWhenDirty() async throws {
        let url = try TestFixtures.write("v1", at: "note.md", in: dir)
        let doc = EditorDocument()
        doc.open(url)
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        doc.reloadIfClean()
        await waitUntil { doc.text == "v2" }
        XCTAssertEqual(doc.text, "v2")

        doc.text = "mine"
        try "v3".write(to: url, atomically: true, encoding: .utf8)
        doc.reloadIfClean()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(doc.text, "mine", "本機有未存修改就以本機為準")
    }
}
