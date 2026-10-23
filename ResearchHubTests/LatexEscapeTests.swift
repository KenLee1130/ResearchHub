// 守 commit a79f34a：專案名稱有底線等特殊字元時，新建的 LaTeX 專案一建好就編不過。
import XCTest
@testable import ResearchHub

final class LatexEscapeTests: XCTestCase {
    private var parent: URL!

    override func setUpWithError() throws {
        parent = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    func testUnderscoreIsEscaped() {
        XCTAssertEqual(LatexProject.escapeText("test_gpt"), "test\\_gpt")
    }

    func testAllSpecialCharactersAreEscaped() {
        XCTAssertEqual(LatexProject.escapeText("a&b%c$d#e{f}g"), "a\\&b\\%c\\$d\\#e\\{f\\}g")
        XCTAssertEqual(LatexProject.escapeText("x~y^z"), "x\\textasciitilde{}y\\textasciicircum{}z")
        XCTAssertEqual(LatexProject.escapeText("a\\b"), "a\\textbackslash{}b")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(LatexProject.escapeText("CFT bootstrap 筆記 2026"), "CFT bootstrap 筆記 2026")
        XCTAssertEqual(LatexProject.escapeText(""), "")
    }

    func testNewProjectTemplateEscapesTitleButKeepsFolderName() throws {
        let folder = try LatexProject.create(in: parent, name: "test_gpt")
        XCTAssertEqual(folder.lastPathComponent, "test_gpt")
        let main = try String(contentsOf: folder.appendingPathComponent("main.tex"), encoding: .utf8)
        XCTAssertTrue(main.contains("\\title{test\\_gpt}"), main)
        XCTAssertFalse(main.contains("\\title{test_gpt}"))
        // 建好就是一個可辨識的專案，主檔記在設定裡
        XCTAssertEqual(LatexProject.mainFile(in: folder)?.lastPathComponent, "main.tex")
        XCTAssertEqual(LatexProject.settings(of: folder).main, "main.tex")
    }

    func testNewProjectAvoidsNameCollision() throws {
        let first = try LatexProject.create(in: parent, name: "paper")
        let second = try LatexProject.create(in: parent, name: "paper")
        XCTAssertEqual(first.lastPathComponent, "paper")
        XCTAssertEqual(second.lastPathComponent, "paper 2")
    }
}
