// 守 SearchEngine（第 4 節）：不分大小寫、多關鍵字 AND、四種範圍、內文命中的行號與範圍。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class SearchEngineTests: XCTestCase {
    func testMatchIsCaseInsensitive() throws {
        XCTAssertNotNil(SearchEngine.match(["cft"], in: "I read CFT today"))
        XCTAssertNotNil(SearchEngine.match(["bootstrap"], in: "Conformal BOOTSTRAP notes"))
    }

    func testAllTermsMustAppear() throws {
        let text = "CFT bootstrap: crossing equations"
        XCTAssertNotNil(SearchEngine.match(["cft", "crossing"], in: text))
        XCTAssertNil(SearchEngine.match(["cft", "modular"], in: text))
        XCTAssertNil(SearchEngine.match(["nothing"], in: text))
    }

    func testEmptyTermsNeverMatch() throws {
        XCTAssertNil(SearchEngine.match([], in: "anything"))
    }

    func testSnippetSurroundsFirstTermAndCollapsesNewlines() throws {
        let text = String(repeating: "x", count: 100) + "\nhello\nworld " + String(repeating: "y", count: 100)
        let snippet = try XCTUnwrap(SearchEngine.match(["hello", "world"], in: text))
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
        XCTAssertTrue(snippet.hasSuffix("…"), snippet)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertTrue(snippet.contains("hello world"), snippet)
    }

    func testSnippetHasNoEllipsisAtTextBoundaries() throws {
        let snippet = try XCTUnwrap(SearchEngine.match(["short"], in: "short note"))
        XCTAssertEqual(snippet, "short note")
    }

    func testSnippetKeepsOriginalCasing() throws {
        let snippet = try XCTUnwrap(SearchEngine.match(["cft"], in: "Read CFT."))
        XCTAssertEqual(snippet, "Read CFT.")
    }

    func testSearchAppliesSameRulesAcrossKinds() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFixtures.write("- [ ] 讀 CFT Bootstrap 論文\n", at: "Journal/2026/10/2026-10-20.md", in: root)
        try TestFixtures.write("today nothing\n", at: "Journal/2026/10/2026-10-21.md", in: root)
        try TestFixtures.write("crossing equations", at: "Notes/Physics/CFT bootstrap.md", in: root)
        try TestFixtures.write("unrelated", at: "Notes/Misc/cooking.md", in: root)
        let papers = [SearchEngine.PaperEntry(key: "P1", title: "Solving the 3d Ising CFT", authors: "Kos",
                                              year: "2014", venue: "JHEP", abstract: "bootstrap", tags: []),
                      SearchEngine.PaperEntry(key: "P2", title: "Other", authors: "", year: "",
                                              venue: "", abstract: "", tags: [])]
        let hits = SearchEngine.search("cft BOOTSTRAP", scope: .all, root: root, papers: papers,
                                       todos: ["buy cft bootstrap book", "buy milk"])
        XCTAssertEqual(hits.filter { $0.kind == .journal }.count, 1)
        XCTAssertEqual(hits.filter { $0.kind == .note }.map(\.title), ["CFT bootstrap"])
        XCTAssertEqual(hits.filter { $0.kind == .paper }.map(\.title), ["Solving the 3d Ising CFT"])
        XCTAssertEqual(hits.filter { $0.kind == .todo }.map(\.title), ["buy cft bootstrap book"])
        XCTAssertTrue(SearchEngine.search("   ", scope: .all, root: root, papers: papers, todos: ["x"]).isEmpty)
    }

    func testBodyMatchReportsLineAndRange() throws {
        let text = "first line\nsecond Line with CFT here\nthird"
        let m = try XCTUnwrap(SearchEngine.bodyMatch(["cft"], in: text))
        XCTAssertEqual(m.line, 1)
        XCTAssertEqual(m.range, 17..<20)
        let line = text.components(separatedBy: "\n")[m.line] as NSString
        XCTAssertEqual(line.substring(with: NSRange(m.range)), "CFT")
        let first = try XCTUnwrap(SearchEngine.bodyMatch(["first"], in: text))
        XCTAssertEqual(first.line, 0); XCTAssertEqual(first.range, 0..<5)
    }

    func testJournalScopeReturnsEveryDayNewestFirstWithoutLimit() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for d in 1...35 {
            let day = String(format: "2026-03-%02d", (d % 28) + 1)
            let month = d > 28 ? "04" : "03"
            let name = d > 28 ? String(format: "2026-04-%02d", d - 28) : day
            try TestFixtures.write("- [ ] bootstrap \(d)\n", at: "Journal/2026/\(month)/\(name).md", in: root)
        }
        try TestFixtures.write("nothing here\n", at: "Journal/2026/05/2026-05-01.md", in: root)
        let hits = SearchEngine.search("bootstrap", scope: .journal, root: root)
        XCTAssertEqual(hits.count, 35, "日記範圍不設 30 筆上限")
        XCTAssertTrue(hits.allSatisfy { $0.kind == .journal && $0.date != nil })
        let dates = hits.compactMap(\.date)
        XCTAssertEqual(dates, dates.sorted(by: >), "最新在上")
        XCTAssertEqual(hits.first?.line, 0)
        XCTAssertEqual(SearchEngine.search("bootstrap", scope: .all, root: root).filter { $0.kind == .journal }.count,
                       SearchEngine.perKindLimit, "⌘K 仍是每類 30 筆")
    }

    func testNotesScopeMergesFileNameAndBodyHitsAndOrdersNameFirst() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFixtures.write("crossing equations in cft", at: "Notes/A/body only.md", in: root)
        try TestFixtures.write("nothing", at: "Notes/A/CFT name only.md", in: root)
        try TestFixtures.write("mentions CFT twice", at: "Notes/B/CFT both.md", in: root)
        try TestFixtures.write("\\documentclass{article}\ncft", at: "Notes/Proj/main.tex", in: root)
        try TestFixtures.write("cft in a project note", at: "Notes/Proj/notes.md", in: root)
        try TestFixtures.write("- [ ] cft", at: "Journal/2026/03/2026-03-01.md", in: root)
        let hits = SearchEngine.search("cft", scope: .notes, root: root)
        let notes = hits.filter { $0.kind == .note }
        XCTAssertEqual(notes.map(\.title).sorted(), ["CFT both", "CFT name only", "body only"].sorted())
        XCTAssertEqual(notes.prefix(2).map(\.field), [.fileName, .fileName], "檔名命中排前")
        XCTAssertEqual(notes.last?.field, .body)
        let both = try XCTUnwrap(notes.first { $0.title == "CFT both" })
        XCTAssertEqual(both.fields, [.fileName, .body], "同篇兩者都中合併成一筆、兩個標籤")
        // LaTeX 專案裡的檔排在筆記後面；日記不算
        let latex = hits.filter { $0.kind == .latex }
        XCTAssertEqual(latex.map(\.title).sorted(), ["Proj › main.tex", "Proj › notes.md"])
        XCTAssertEqual(hits.map(\.kind), Array(repeating: .note, count: 3) + [.latex, .latex])
        XCTAssertFalse(hits.contains { $0.kind == .journal }, "筆記範圍不含日記")
    }

    func testPapersAndNotesScope() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFixtures.write("ising cft", at: "Notes/x.md", in: root)
        try TestFixtures.write("- [ ] ising", at: "Journal/2026/03/2026-03-01.md", in: root)
        let papers = [SearchEngine.PaperEntry(key: "P1", title: "3d Ising", authors: "Kos", year: "2014",
                                              venue: "", abstract: "", tags: [])]
        let hits = SearchEngine.search("ising", scope: .papersAndNotes, root: root, papers: papers)
        XCTAssertEqual(hits.map(\.kind), [.paper, .note], "先論文、再筆記")
        XCTAssertEqual(hits.first?.field, .title)
    }
}
