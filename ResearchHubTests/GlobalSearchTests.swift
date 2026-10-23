// 守 GlobalSearch.match 的比對規則：不分大小寫、空白分開的多個關鍵字要全部出現（AND）。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class GlobalSearchTests: XCTestCase {
    func testMatchIsCaseInsensitive() throws {
        XCTAssertNotNil(GlobalSearch.match(["cft"], in: "I read CFT today"))
        XCTAssertNotNil(GlobalSearch.match(["bootstrap"], in: "Conformal BOOTSTRAP notes"))
    }

    func testAllTermsMustAppear() throws {
        let text = "CFT bootstrap: crossing equations"
        XCTAssertNotNil(GlobalSearch.match(["cft", "crossing"], in: text))
        XCTAssertNil(GlobalSearch.match(["cft", "modular"], in: text))
        XCTAssertNil(GlobalSearch.match(["nothing"], in: text))
    }

    func testEmptyTermsNeverMatch() throws {
        XCTAssertNil(GlobalSearch.match([], in: "anything"))
    }

    func testSnippetSurroundsFirstTermAndCollapsesNewlines() throws {
        let text = String(repeating: "x", count: 100) + "\nhello\nworld " + String(repeating: "y", count: 100)
        let snippet = try XCTUnwrap(GlobalSearch.match(["hello", "world"], in: text))
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
        XCTAssertTrue(snippet.hasSuffix("…"), snippet)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertTrue(snippet.contains("hello world"), snippet)
    }

    func testSnippetHasNoEllipsisAtTextBoundaries() throws {
        let snippet = try XCTUnwrap(GlobalSearch.match(["short"], in: "short note"))
        XCTAssertEqual(snippet, "short note")
    }

    func testSnippetKeepsOriginalCasing() throws {
        let snippet = try XCTUnwrap(GlobalSearch.match(["cft"], in: "Read CFT."))
        XCTAssertEqual(snippet, "Read CFT.")
    }

    func testSearchAppliesSameRulesAcrossKinds() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try TestFixtures.write("- [ ] 讀 CFT Bootstrap 論文\n", at: "Journal/2026/10/2026-10-20.md", in: root)
        try TestFixtures.write("today nothing\n", at: "Journal/2026/10/2026-10-21.md", in: root)
        try TestFixtures.write("crossing equations", at: "Notes/Physics/CFT bootstrap.md", in: root)
        try TestFixtures.write("unrelated", at: "Notes/Misc/cooking.md", in: root)
        let papers = [GlobalSearch.PaperEntry(key: "P1", title: "Solving the 3d Ising CFT", authors: "Kos",
                                              year: "2014", venue: "JHEP", abstract: "bootstrap", tags: []),
                      GlobalSearch.PaperEntry(key: "P2", title: "Other", authors: "", year: "",
                                              venue: "", abstract: "", tags: [])]
        let hits = GlobalSearch.search("cft BOOTSTRAP", root: root, papers: papers,
                                       todos: ["buy cft bootstrap book", "buy milk"])
        XCTAssertEqual(hits.filter { $0.kind == .journal }.count, 1)
        XCTAssertEqual(hits.filter { $0.kind == .note }.map(\.title), ["CFT bootstrap"])
        XCTAssertEqual(hits.filter { $0.kind == .paper }.map(\.title), ["Solving the 3d Ising CFT"])
        XCTAssertEqual(hits.filter { $0.kind == .todo }.map(\.title), ["buy cft bootstrap book"])
        XCTAssertTrue(GlobalSearch.search("   ", root: root, papers: papers, todos: ["x"]).isEmpty)
    }
}
