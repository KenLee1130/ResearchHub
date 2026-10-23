// 守 LatexBibliography 的純邏輯（\cite 補全寫進 .bib、沒人引用自動移除；commit a753548 的 .bib 從主檔資料夾找）。
import XCTest
@testable import ResearchHub
@testable import HubCore

final class LatexBibliographyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestFixtures.makeTempDir() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let zoteroExport = """
    @article{kos2014solving,
    \ttitle = {Solving the 3d Ising Model with the Conformal Bootstrap II},
    \tauthor = {Kos, Filip and Poland, David and Simmons-Duffin, David},
    \tjournal = {JHEP},
    \tyear = {2014},
    \tabstract = {We extend the previous work ...
    over several lines},
    \tfile = {/Users/ken/Zotero/storage/ABC/kos.pdf},
    }
    """

    func testParseExtractsKeyAndDropsNoisyFields() throws {
        let (key, entry) = try XCTUnwrap(LatexBibliography.parse(zoteroExport))
        XCTAssertEqual(key, "kos2014solving")
        XCTAssertTrue(entry.contains("title = {Solving"))
        XCTAssertTrue(entry.contains("year = {2014}"))
        XCTAssertFalse(entry.contains("abstract"), entry)
        XCTAssertFalse(entry.contains("over several lines"), "跨行的 abstract 要整段拿掉")
        XCTAssertFalse(entry.contains("file ="))
        XCTAssertNil(LatexBibliography.parse("not bibtex"))
    }

    func testCitedKeysCoverCiteVariants() {
        let source = """
        \\cite{a,b} and \\citep[p. 3]{c} and \\textcite{d}
        % \\cite{commented}
        \\nocite{*}
        """
        XCTAssertEqual(LatexBibliography.citedKeys(in: source), ["a", "b", "c", "d", "commented", "*"])
    }

    func testExtractRemovesEntryWithNestedBracesAndTrailingBlankLines() throws {
        var bib = """
        @article{one,
        \ttitle = {A {Nested} Title},
        }

        @book{two,
        \ttitle = {Second},
        }
        """
        let entry = try XCTUnwrap(LatexBibliography.extract(key: "one", from: &bib))
        XCTAssertTrue(entry.hasPrefix("@article{one,"))
        XCTAssertTrue(entry.hasSuffix("}"))
        XCTAssertTrue(bib.hasPrefix("@book{two,"), bib)
        XCTAssertFalse(LatexBibliography.contains(key: "one", in: bib))
        XCTAssertTrue(LatexBibliography.contains(key: "two", in: bib))
        XCTAssertNil(LatexBibliography.extract(key: "missing", from: &bib))
    }

    func testFallbackEntryBuildsAsciiKeyFromAuthorYearTitle() {
        let item = ZoteroItem(key: "I4UT4SMS", data: .init(
            itemType: "journalArticle", title: "Solving the 3d Ising CFT",
            creators: [.init(firstName: "Filip", lastName: "Kos"), .init(firstName: "David", lastName: "Poland")],
            date: "2014-06-01", DOI: "10.1007/x", publicationTitle: "JHEP"))
        let (key, entry) = LatexBibliography.fallbackEntry(for: item)
        XCTAssertEqual(key, "Kos2014Solving")
        XCTAssertTrue(entry.hasPrefix("@article{Kos2014Solving,"))
        XCTAssertTrue(entry.contains("author = {Kos, Filip and Poland, David}"))
        XCTAssertTrue(entry.contains("doi = {10.1007/x}"))
    }

    func testCiteAppendsExportedEntryOnceAndTracksKey() throws {
        try TestFixtures.write("\\documentclass{article}\n\\begin{document}\\end{document}\n", at: "main.tex", in: root)
        let item = ZoteroItem(key: "K", data: .init(itemType: "journalArticle", title: "T"))
        let first = LatexBibliography.cite(item, in: root, exportedBibtex: zoteroExport)
        let second = LatexBibliography.cite(item, in: root, exportedBibtex: zoteroExport)
        XCTAssertEqual(first, "kos2014solving")
        XCTAssertEqual(second, first)
        let bib = try String(contentsOf: root.appendingPathComponent("references.bib"), encoding: .utf8)
        XCTAssertEqual(bib.components(separatedBy: "@article{kos2014solving,").count - 1, 1, "同一筆只寫一次")
        XCTAssertNotNil(LatexProject.settings(of: root).autoBibKeys?["kos2014solving"])
    }

    func testTargetBibFollowsBibliographyCommandRelativeToMainFile() throws {
        // 主檔在子資料夾、\bibliography{refs} → 先找主檔旁邊的 refs.bib（commit a753548）
        try TestFixtures.write("\\documentclass{article}\n\\bibliography{refs}\n", at: "First Draft/paper.tex", in: root)
        LatexProject.save(.init(main: "First Draft/paper.tex"), to: root)
        XCTAssertEqual(LatexBibliography.targetBib(in: root).lastPathComponent, "refs.bib")
        XCTAssertEqual(LatexBibliography.targetBib(in: root).deletingLastPathComponent().lastPathComponent, "First Draft")
        // 主檔旁沒有、根目錄有 → 用根目錄那份
        try TestFixtures.write("", at: "refs.bib", in: root)
        XCTAssertEqual(LatexBibliography.targetBib(in: root).deletingLastPathComponent().lastPathComponent,
                       root.lastPathComponent)
    }
}
