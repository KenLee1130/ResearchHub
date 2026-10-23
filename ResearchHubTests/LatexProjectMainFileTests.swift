// 守 commit a753548：LaTeX 專案主檔在子資料夾時無法編譯（Overleaf 專案整包放進來的情形）。
import XCTest
@testable import ResearchHub

final class LatexProjectMainFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let doc = "\\documentclass{article}\n\\begin{document}\nhi\n\\end{document}\n"

    // MARK: mainSubdirectory

    func testMainSubdirectoryIsEmptyWhenMainIsAtRoot() {
        let main = root.appendingPathComponent("main.tex")
        XCTAssertEqual(LatexProject.mainSubdirectory(of: main, in: root), "")
    }

    func testMainSubdirectoryForNestedMain() {
        let main = root.appendingPathComponent("First Draft/PRLShort_truePRL.tex")
        XCTAssertEqual(LatexProject.mainSubdirectory(of: main, in: root), "First Draft")
        let deeper = root.appendingPathComponent("a/b/c.tex")
        XCTAssertEqual(LatexProject.mainSubdirectory(of: deeper, in: root), "a/b")
    }

    func testMainSubdirectoryOutsideProjectIsEmpty() {
        let other = root.deletingLastPathComponent().appendingPathComponent("elsewhere/x.tex")
        XCTAssertEqual(LatexProject.mainSubdirectory(of: other, in: root), "")
    }

    // MARK: mainFile

    func testSavedMainInSubfolderIsHonored() throws {
        let nested = try TestFixtures.write(doc, at: "First Draft/paper.tex", in: root)
        LatexProject.save(LatexProject.Settings(main: "First Draft/paper.tex"), to: root)
        let found = LatexProject.mainFile(in: root)
        XCTAssertEqual(found?.resolvingSymlinksInPath().path, nested.resolvingSymlinksInPath().path)
        XCTAssertTrue(LatexProject.isProject(root))
    }

    func testMainTexIsPreferredAmongRootCandidates() throws {
        try TestFixtures.write(doc, at: "appendix.tex", in: root)
        let main = try TestFixtures.write(doc, at: "main.tex", in: root)
        XCTAssertEqual(LatexProject.mainFile(in: root)?.lastPathComponent, main.lastPathComponent)
    }

    func testNestedTexAloneDoesNotMakeAProject() throws {
        // 沒設定主檔時只看最上層：子資料夾裡的 .tex 不算
        try TestFixtures.write(doc, at: "First Draft/paper.tex", in: root)
        XCTAssertNil(LatexProject.mainFile(in: root))
        XCTAssertFalse(LatexProject.isProject(root))
    }

    // MARK: engine 與 latexmkrc

    func testLatexmkrcWithoutOutputModeIsIgnored() throws {
        // Overleaf 的 latexmkrc 常常只設時區：交給它 latexmk 會跑 DVI 模式而中止
        let main = try TestFixtures.write(doc, at: "First Draft/paper.tex", in: root)
        try TestFixtures.write("$ENV{'TZ'}='Asia/Taipei';\n", at: "First Draft/latexmkrc", in: root)
        XCTAssertEqual(LatexProject.engine(for: root, main: main), "pdflatex")
    }

    func testLatexmkrcInMainSubdirectoryWithOutputModeIsHonored() throws {
        let main = try TestFixtures.write(doc, at: "First Draft/paper.tex", in: root)
        try TestFixtures.write("$pdf_mode = 5;\n", at: "First Draft/latexmkrc", in: root)
        XCTAssertEqual(LatexProject.engine(for: root, main: main), "auto")
    }

    func testEngineFallsBackToXelatexForCJKPackages() throws {
        let main = try TestFixtures.write(
            "\\documentclass{article}\n\\usepackage{xeCJK}\n\\begin{document}\n\\end{document}\n",
            at: "main.tex", in: root)
        XCTAssertEqual(LatexProject.engine(for: root, main: main), "xelatex")
    }

    // MARK: 補全索引（相對專案根目錄）

    func testIndexListsNestedFilesRelativeToProjectRoot() throws {
        try TestFixtures.write(doc + "\\label{eq:main}\n", at: "First Draft/paper.tex", in: root)
        try TestFixtures.write("\\newcommand{\\vb}[1]{\\mathbf{#1}}\n", at: "First Draft/macros.tex", in: root)
        try TestFixtures.write("@article{k, title={t}}", at: "First Draft/refs.bib", in: root)
        let figures = root.appendingPathComponent("First Draft/figures", isDirectory: true)
        try FileManager.default.createDirectory(at: figures, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: figures.appendingPathComponent("plot.png"))
        let snap = LatexProjectIndex.scan(root)
        XCTAssertEqual(snap.texFiles, ["First Draft/macros", "First Draft/paper"])
        XCTAssertEqual(snap.bibFiles, ["First Draft/refs.bib"])
        XCTAssertEqual(snap.images, ["First Draft/figures/plot.png"])
        XCTAssertEqual(snap.labels, ["eq:main"])
        XCTAssertEqual(snap.macros.map(\.insert), ["\\vb{}"])
    }

    // MARK: 錯誤位置換算回專案路徑

    func testProjectRelativePrependsMainSubdirectory() {
        let build = root.appendingPathComponent("build")
        XCTAssertEqual(LatexCompiler.projectRelative("./sections/intro.tex", subdir: "First Draft", buildRoot: build),
                       "First Draft/sections/intro.tex")
        XCTAssertEqual(LatexCompiler.projectRelative("paper.tex", subdir: "First Draft", buildRoot: build),
                       "First Draft/paper.tex")
        XCTAssertEqual(LatexCompiler.projectRelative("../common.tex", subdir: "First Draft", buildRoot: build),
                       "common.tex")
    }

    func testProjectRelativeWithoutSubdirectoryOnlyStripsDotSlash() {
        let build = root.appendingPathComponent("build")
        XCTAssertEqual(LatexCompiler.projectRelative("./main.tex", subdir: "", buildRoot: build), "main.tex")
        XCTAssertEqual(LatexCompiler.projectRelative("main.tex", subdir: "", buildRoot: build), "main.tex")
    }

    func testProjectRelativeMapsBuildAbsolutePathsAndKeepsSystemPaths() {
        let build = root.appendingPathComponent("build")
        XCTAssertEqual(LatexCompiler.projectRelative(build.path + "/First Draft/paper.tex",
                                                     subdir: "First Draft", buildRoot: build),
                       "First Draft/paper.tex")
        let sty = "/usr/local/texlive/2026/texmf-dist/tex/latex/base/article.cls"
        XCTAssertEqual(LatexCompiler.projectRelative(sty, subdir: "First Draft", buildRoot: build), sty)
    }

    func testFullWidthPunctuationDetection() {
        XCTAssertTrue(LatexCompiler.isFullWidthPunctuation(in: "Unicode character ， (U+FF0C)"))
        XCTAssertTrue(LatexCompiler.isFullWidthPunctuation(in: "Unicode character 。 (U+3002)"))
        XCTAssertFalse(LatexCompiler.isFullWidthPunctuation(in: "Unicode character 中 (U+4E2D)"))
        XCTAssertFalse(LatexCompiler.isFullWidthPunctuation(in: "Missing $ inserted"))
    }
}
