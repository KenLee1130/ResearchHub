// 守 NotePreprocessor（筆記渲染前處理）：[[筆記]] 連結解析、\cite 編號與參考文獻、\footnote。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class NotePreprocessorTests: XCTestCase {
    private let links = [
        NoteLink(url: URL(fileURLWithPath: "/n/Physics/CFT bootstrap.md"), relativePath: "Physics/CFT bootstrap.md"),
        NoteLink(url: URL(fileURLWithPath: "/n/Misc/Todo.md"), relativePath: "Misc/Todo.md"),
    ]

    func testResolverMatchesPathThenName() {
        XCTAssertEqual(NoteLinkResolver.resolve("physics/cft bootstrap", in: links)?.relativePath, "Physics/CFT bootstrap.md")
        XCTAssertEqual(NoteLinkResolver.resolve("CFT Bootstrap", in: links)?.relativePath, "Physics/CFT bootstrap.md")
        XCTAssertEqual(NoteLinkResolver.resolve("Misc/Todo.md", in: links)?.name, "Todo")
        XCTAssertNil(NoteLinkResolver.resolve("nope", in: links))
        XCTAssertNil(NoteLinkResolver.resolve("  ", in: links))
    }

    func testWikiLinksBecomeInternalURLsOrDeadLinkMarkers() {
        let out = NotePreprocessor.process("see [[CFT bootstrap|這篇]] and [[missing]]", zoteroItems: [], noteLinks: links)
        XCTAssertTrue(out.contains("[這篇](researchhub://note?path=Physics/CFT%20bootstrap.md)"), out)
        XCTAssertTrue(out.contains("class=\"rh-deadlink\""), out)
        XCTAssertTrue(out.contains("找不到筆記：missing"), out)
    }

    func testCiteNumbersInOrderOfFirstAppearanceAndAppendsReferences() {
        let a = ZoteroItem(key: "A", data: .init(itemType: "journalArticle", title: "Alpha paper",
                                                 creators: [.init(lastName: "Kos")], date: "2014", publicationTitle: "JHEP"))
        let b = ZoteroItem(key: "B", data: .init(itemType: "journalArticle", title: "Beta paper"))
        let out = NotePreprocessor.process("x \\cite{B} y \\cite{A,B} z", zoteroItems: [a, b])
        XCTAssertTrue(out.contains("參考文獻"), out)
        XCTAssertLessThan(try XCTUnwrap(out.range(of: "Beta paper")?.lowerBound),
                          try XCTUnwrap(out.range(of: "Alpha paper")?.lowerBound), "先出現的先編號")
        XCTAssertFalse(out.contains("\\cite{"))
    }

    func testFootnotesBecomeSuperscriptsWithNestedBraces() {
        let out = NotePreprocessor.process("a\\footnote{see $\\frac{1}{2}$} b", zoteroItems: [])
        XCTAssertTrue(out.contains("<sup class=\"rh-fn\">[1]</sup>"), out)
        XCTAssertTrue(out.contains("\\frac{1}{2}"), "註腳內容連同巢狀大括號要完整搬到文末")
        XCTAssertFalse(out.contains("\\footnote"))
    }
}
