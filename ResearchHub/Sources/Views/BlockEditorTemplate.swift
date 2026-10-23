import Foundation
import HubCore

/// Block 編輯器的網頁端（Tiptap）：HTML＋JS 在 Resources/EditorWeb/editor.html，
/// 由 BlockEditorHost 載進 WKWebView。以前整份塞在 Swift 的 raw string 裡（2100 行），
/// 現在是獨立檔案，帶 version.json 當 JS ↔ Swift 的版本契約（docs/ARCHITECTURE.md 第 2 節）。
///
/// 本地化：HTML 裡用 `{{L:原文}}` 佔位，載入時換成 `L("原文")`；
/// 用 computed property 是因為語言切換重載編輯器時要重新求值。
extension BlockEditorView {
    static var template: String {
        guard let base = WebResources.baseURL,
              let raw = try? String(contentsOf: base.appendingPathComponent("editor.html"), encoding: .utf8)
        else { return "" }
        return localize(raw)
    }

    /// `{{L:原文}}` → 本地化字串（沒有佔位符就原樣回傳）
    static func localize(_ html: String) -> String {
        guard html.contains("{{L:") else { return html }
        var out = ""
        var rest = Substring(html)
        while let open = rest.range(of: "{{L:") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else { out += rest[open.lowerBound...]; return out }
            let key = String(after[..<close.lowerBound])
            out += L(String.LocalizationValue(stringLiteral: key))
            rest = after[close.upperBound...]
        }
        out += rest
        return out
    }

    /// version.json 不相容時的說明（相容回 nil）
    static var bundleProblem: String? {
        let data = WebResources.baseURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent("version.json")) }
        return EditorWebVersion.problem(with: data)
    }
}
