// 守 EditorWeb bundle（editor.html＋version.json）的契約：佔位符全部換掉、版本在支援區間內。
import XCTest
@testable import ResearchHub
@testable import HubEditor
@testable import HubCore

final class EditorWebBundleTests: XCTestCase {
    func testBundledTemplateLoadsAndIsFullyLocalized() {
        let html = BlockEditorView.template
        XCTAssertFalse(html.isEmpty, "editor.html 要在 app bundle 裡（EditorWeb/ 或攤平到 Resources 根）")
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertFalse(html.contains("{{L:"), "佔位符要全部換成本地化字串")
        XCTAssertFalse(html.contains("\\#("), "不能殘留 Swift 插值")
        XCTAssertTrue(html.contains("messageHandlers.ready"), "JS 準備好要回報 ready")
        XCTAssertTrue(html.contains("<script src=\"editor-bundle.js\">") || html.contains("editor-bundle.js"))
    }

    func testLocalizePlaceholders() {
        XCTAssertEqual(BlockEditorView.localize("a{{L:刪除}}b{{L:完成}}"), "a\(L("刪除"))b\(L("完成"))")
        XCTAssertEqual(BlockEditorView.localize("plain"), "plain")
        XCTAssertEqual(BlockEditorView.localize("{{L:沒關起來"), "{{L:沒關起來", "壞掉的佔位符原樣保留")
    }

    func testBundledVersionIsSupported() {
        XCTAssertNil(BlockEditorView.bundleProblem)
    }

    func testVersionContract() {
        XCTAssertEqual(EditorWebVersion.parse(Data(#"{"editor": 1}"#.utf8)), 1)
        XCTAssertNil(EditorWebVersion.parse(Data("{}".utf8)))
        XCTAssertNil(EditorWebVersion.problem(with: Data(#"{"editor": 1}"#.utf8), supported: 1...2))
        XCTAssertNotNil(EditorWebVersion.problem(with: Data(#"{"editor": 3}"#.utf8), supported: 1...2))
        XCTAssertNotNil(EditorWebVersion.problem(with: nil))
        XCTAssertNotNil(EditorWebVersion.problem(with: Data("nope".utf8)))
    }
}
