#if os(macOS)
import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// 把筆記 markdown 渲染成 PDF：離屏 WKWebView（KaTeX + 本地圖片）→ createPDF → 儲存面板。
@MainActor
final class PDFExporter: NSObject, WKNavigationDelegate {
    static let shared = PDFExporter()

    private var webView: WKWebView?
    private var markdown = ""
    private var suggestedName = "Note"

    func export(noteURL: URL) {
        guard let content = FileSystemStore.safeRead(noteURL) else {
            fail("讀不到筆記檔（若在 iCloud 尚未下載，稍後再試一次）")
            return
        }
        suggestedName = noteURL.deletingPathExtension().lastPathComponent
        // 先處理 [[筆記]] / \cite / \footnote / \eqref / \label，再把本地圖片轉成 data URI。
        let pre = NotePreprocessor.process(
            content, zoteroItems: ZoteroStore.shared.items,
            noteLinks: NoteLinkIndex.shared.entries())
        markdown = Self.resolveLocalImages(
            in: pre, baseDir: noteURL.deletingLastPathComponent())

        // A4 寬度（96dpi ≈ 794pt），高度先給一頁，渲染後再延展
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1100))
        wv.appearance = NSAppearance(named: .aqua) // 強制淺色，PDF 白底
        wv.navigationDelegate = self
        webView = wv
        // 離屏 webview 用相對路徑載 katex/marked 會被擋（loadHTMLString 不給檔案
        // 子資源權限），marked 載不到 → 整份渲染成空白。改成把資源內嵌進 HTML。
        wv.loadHTMLString(Self.inlinedTemplate(), baseURL: WebResources.baseURL)
    }

    /// 匯出專用模板：katex/marked/css 直接內嵌，不依賴子資源載入。
    private static func inlinedTemplate() -> String {
        var html = MarkdownPreviewView.template
        guard let base = WebResources.baseURL else { return html }
        func res(_ name: String) -> String? {
            try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
        }
        if let css = res("katex.min.css") {
            html = html.replacingOccurrences(
                of: #"<link rel="stylesheet" href="katex.min.css">"#,
                with: "<style>\(css)</style>")
        }
        for js in ["katex.min.js", "marked.min.js"] {
            if let code = res(js) {
                html = html.replacingOccurrences(
                    of: #"<script src="\#(js)"></script>"#,
                    with: "<script>\(code)</script>")
            }
        }
        return html
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let data = try? JSONEncoder().encode([markdown]),
              let json = String(data: data, encoding: .utf8) else {
            fail("內容編碼失敗")
            return
        }
        webView.evaluateJavaScript("window.update(\(json)[0]); 0") { [weak self] _, error in
            if let error { Task { @MainActor in self?.fail("渲染失敗：\(error.localizedDescription)") } }
        }

        // 等 KaTeX/圖片渲染完，量高度 → 出 PDF
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.measureAndCreatePDF()
        }
    }

    private func fail(_ message: String) {
        webView = nil
        let alert = NSAlert()
        alert.messageText = "PDF 匯出失敗"
        alert.informativeText = message
        alert.runModal()
    }

    private func measureAndCreatePDF() {
        guard let webView else { return }
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let webView = self.webView else { return }
                let height = max((result as? CGFloat) ?? 1100, 200)
                webView.setFrameSize(NSSize(width: 794, height: height + 40))
                try? await Task.sleep(nanoseconds: 200_000_000)
                let config = WKPDFConfiguration()
                webView.createPDF(configuration: config) { result in
                    Task { @MainActor in
                        switch result {
                        case .success(let data):
                            self.webView = nil
                            self.savePDF(data)
                        case .failure(let error):
                            self.fail("產生 PDF 失敗：\(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    private func savePDF(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(suggestedName).pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - 本地圖片 → data URI（一次性，無快取）

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

    static func resolveLocalImages(in text: String, baseDir: URL) -> String {
        let ns = text as NSString
        var result = text
        let matches = imagePattern.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let alt = ns.substring(with: match.range(at: 1))
            let path = ns.substring(with: match.range(at: 2))
            guard !path.hasPrefix("http"), !path.hasPrefix("data:") else { continue }
            let url = baseDir.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime: String
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            default: mime = "image/png"
            }
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: "![\(alt)](\(uri))")
            }
        }
        return result
    }
}
#endif
