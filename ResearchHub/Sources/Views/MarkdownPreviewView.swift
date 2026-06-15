import SwiftUI
import WebKit

/// 右欄即時預覽：WKWebView + marked（Markdown）+ KaTeX（LaTeX 數學與環境）。
/// 數學段落先以 placeholder 保護再交給 marked，避免 $、反斜線被當成 Markdown 處理。
struct MarkdownPreviewView: NSViewRepresentable {
    var text: String
    var scrollFraction: CGFloat
    var baseDir: URL?
    /// 供 \cite 解析用的 Zotero 文獻（載入後變動時會觸發重新渲染）。
    var citationItems: [ZoteroItem] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView
        context.coordinator.citationItems = citationItems
        context.coordinator.pendingText = text
        webView.loadHTMLString(Self.template, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.baseDir = baseDir
        context.coordinator.update(text: text, items: citationItems)
        context.coordinator.scroll(to: scrollFraction)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingText: String?
        var baseDir: URL?
        var citationItems: [ZoteroItem] = []
        private var isLoaded = false
        private var lastText: String?
        private var lastCiteSig = -1
        private var lastFraction: CGFloat = -1
        /// 圖片 base64 快取（path → data URI），避免每次按鍵重讀檔案
        private var imageCache: [String: String] = [:]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending = pendingText {
                pendingText = nil
                push(pending)
            }
        }

        func update(text: String, items: [ZoteroItem]) {
            citationItems = items
            // 文字或文獻數量任一改變就重繪（文獻載入後 \cite 才解析得出來）。
            guard text != lastText || items.count != lastCiteSig else { return }
            lastText = text
            lastCiteSig = items.count
            if isLoaded {
                push(text)
            } else {
                pendingText = text
            }
        }

        func scroll(to fraction: CGFloat) {
            guard isLoaded, abs(fraction - lastFraction) > 0.001 else { return }
            lastFraction = fraction
            webView?.evaluateJavaScript("window.scrollToFraction(\(fraction))")
        }

        private func push(_ text: String) {
            // 先處理 \cite / \footnote / \eqref / \label，再把本地圖片轉成 data URI。
            let pre = NotePreprocessor.process(text, zoteroItems: citationItems)
            let resolved = resolveLocalImages(in: pre)
            guard
                let data = try? JSONEncoder().encode([resolved]),
                let json = String(data: data, encoding: .utf8)
            else { return }
            // 以單元素陣列編碼再在 JS 端取 [0]，避免字串跳脫問題
            webView?.evaluateJavaScript("window.update(\(json)[0])")
        }

        // MARK: - Local images → data URI

        private static let imagePattern = try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

        private func resolveLocalImages(in text: String) -> String {
            guard let baseDir else { return text }
            let ns = text as NSString
            var result = text
            let matches = Self.imagePattern.matches(
                in: text, range: NSRange(location: 0, length: ns.length))

            for match in matches.reversed() {
                let alt = ns.substring(with: match.range(at: 1))
                let path = ns.substring(with: match.range(at: 2))
                guard !path.hasPrefix("http"), !path.hasPrefix("data:") else { continue }
                guard let dataURI = dataURI(for: path, baseDir: baseDir) else { continue }
                let replacement = "![\(alt)](\(dataURI))"
                if let range = Range(match.range, in: result) {
                    result.replaceSubrange(range, with: replacement)
                }
            }
            return result
        }

        private func dataURI(for path: String, baseDir: URL) -> String? {
            if let cached = imageCache[path] { return cached }
            let url = baseDir.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let mime: String
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "svg": mime = "image/svg+xml"
            default: mime = "image/png"
            }
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            imageCache[path] = uri
            return uri
        }
    }

    // MARK: - HTML template

    static let template = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/katex.min.css">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.16.9/katex.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
    <style>
      html, body { background: transparent; margin: 0; }
      body {
        font: 15px/1.7 -apple-system, "PingFang TC", sans-serif;
        color: CanvasText;
        padding: 18px 22px;
        word-wrap: break-word;
      }
      h1 { font-size: 1.5em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
      code { font-family: ui-monospace, monospace; font-size: 0.9em;
             background: rgba(127,127,127,0.15); padding: 1px 5px; border-radius: 4px; }
      pre code { display: block; padding: 10px 12px; overflow-x: auto; }
      blockquote { margin: 0; padding-left: 12px;
                   border-left: 3px solid rgba(127,127,127,0.4); opacity: 0.85; }
      .katex-display { overflow-x: auto; overflow-y: hidden; padding: 4px 0; }
      input[type=checkbox] { margin-right: 6px; }
      img { max-width: 100%; border-radius: 6px; }
      li.task { list-style: none; margin-left: -1.2em; }
      hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); }
      .err { color: #c33; font-family: ui-monospace, monospace; font-size: 0.85em; }
    </style>
    </head>
    <body>
    <div id="content"></div>
    <script>
      let mathBlocks = [];

      const mathPatterns = [
        /\\$\\$[\\s\\S]+?\\$\\$/g,
        /\\\\begin\\{([a-zA-Z*]+)\\}[\\s\\S]*?\\\\end\\{\\1\\}/g,
        /\\\\\\[[\\s\\S]+?\\\\\\]/g,
        /\\\\\\([\\s\\S]+?\\\\\\)/g,
        /\\$[^$\\n]+?\\$/g
      ];

      function protect(src) {
        let out = src;
        for (const re of mathPatterns) {
          out = out.replace(re, m => {
            mathBlocks.push(m);
            return "@@MATH" + (mathBlocks.length - 1) + "@@";
          });
        }
        return out;
      }

      function renderMath(m) {
        let display = false, body = m;
        if (m.startsWith("$$"))           { display = true;  body = m.slice(2, -2); }
        else if (m.startsWith("\\\\["))    { display = true;  body = m.slice(2, -2); }
        else if (m.startsWith("\\\\begin")){ display = true;  body = m; }
        else if (m.startsWith("\\\\("))    { display = false; body = m.slice(2, -2); }
        else if (m.startsWith("$"))       { display = false; body = m.slice(1, -1); }
        try {
          return katex.renderToString(body, { displayMode: display, throwOnError: false });
        } catch (e) {
          return '<span class="err">' + m.replace(/</g, "&lt;") + "</span>";
        }
      }

      window.update = function (text) {
        mathBlocks = [];
        const safe = protect(text);
        let html = marked.parse(safe, { gfm: true, breaks: true });
        html = html.replace(/@@MATH(\\d+)@@/g, (_, i) => renderMath(mathBlocks[+i]));
        document.getElementById("content").innerHTML = html;
      };

      window.scrollToFraction = function (f) {
        const max = document.body.scrollHeight - window.innerHeight;
        window.scrollTo(0, Math.max(0, max * f));
      };
    </script>
    </body>
    </html>
    """
}
