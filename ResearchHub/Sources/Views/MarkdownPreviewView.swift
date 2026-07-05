import SwiftUI
import WebKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// 右欄即時預覽：WKWebView + marked（Markdown）+ KaTeX（LaTeX 數學與環境）。
/// 數學段落先以 placeholder 保護再交給 marked，避免 $、反斜線被當成 Markdown 處理。
struct MarkdownPreviewView {
    var text: String
    var scrollSync: ScrollSync = ScrollSync()
    var baseDir: URL?
    /// 供 \cite 解析用的 Zotero 文獻（載入後變動時會觸發重新渲染）。
    var citationItems: [ZoteroItem] = []
    /// 點擊 [[筆記]] 引用時開啟對應筆記。
    var onOpenNote: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        webView.underPageBackgroundColor = .clear
        coordinator.webView = webView
        coordinator.citationItems = citationItems
        coordinator.pendingText = text
        webView.loadHTMLString(Self.template, baseURL: WebResources.baseURL)
        return webView
    }

    private func refresh(coordinator: Coordinator) {
        coordinator.baseDir = baseDir
        coordinator.onOpenNote = onOpenNote
        coordinator.update(text: text, items: citationItems)
        coordinator.scroll(sync: scrollSync)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingText: String?
        var baseDir: URL?
        var citationItems: [ZoteroItem] = []
        var onOpenNote: ((URL) -> Void)?
        private var isLoaded = false
        private var lastText: String?
        private var lastCiteSig = -1
        private var lastSync: ScrollSync?
        /// 圖片 base64 快取（path → data URI），避免每次按鍵重讀檔案
        private var imageCache: [String: String] = [:]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let pending = pendingText {
                pendingText = nil
                push(pending)
            }
        }

        /// 攔截連結點擊：
        ///   • researchhub://note?path=… → 開啟對應筆記（[[筆記]] 引用）。
        ///   • 文件內錨點（\eqref/\ref/目錄）→ 放行，讓網頁自行捲動。
        ///   • 其餘外部連結（http/https/zotero/mailto…）→ 用系統預設程式開啟，不取代預覽。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "researchhub", url.host == "note" {
                if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let rel = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                   let fileURL = NoteLinkIndex.shared.url(forRelativePath: rel) {
                    onOpenNote?(fileURL)
                }
                decisionHandler(.cancel)
                return
            }
            // 文件內錨點：baseURL 指向本地資源後 scheme 是 file；
            // 舊情況（baseURL nil）則是 about/applewebdata 或沒有 scheme。
            if url.scheme == nil || url.scheme == "about" || url.scheme == "applewebdata"
                || url.scheme == "file" {
                decisionHandler(.allow)
                return
            }
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            decisionHandler(.cancel)
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

        func scroll(sync: ScrollSync) {
            guard isLoaded, sync != lastSync else { return }
            lastSync = sync
            webView?.evaluateJavaScript(
                "window.scrollSync(\(sync.anchor),\(sync.local),\(sync.global),\(sync.count))")
        }

        private func push(_ text: String) {
            // 先處理 [[筆記]] / \cite / \footnote / \eqref / \label，再把本地圖片轉成 data URI。
            let pre = NotePreprocessor.process(
                text, zoteroItems: citationItems, noteLinks: NoteLinkIndex.shared.entries())
            let resolved = resolveLocalImages(in: pre)
            guard
                let data = try? JSONEncoder().encode([resolved]),
                let json = String(data: data, encoding: .utf8)
            else { return }
            // 以單元素陣列編碼再在 JS 端取 [0]，避免字串跳脫問題。
            // 打字重繪後「不」重新套用捲動位置 → 右邊維持原處、不會跳。
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
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="katex.min.css">
    <script src="katex.min.js"></script>
    <script src="marked.min.js"></script>
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
      .rh-deadlink { color: #c33; border-bottom: 1px dashed #c33; cursor: help; }
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

      // 以「標題 + 顯示型公式」為錨點的捲動同步：左邊在第 k 個錨點之後、段內比例 local，
      // 右邊就對到對應錨點之間的同樣比例；錨點數對不上時退回整份比例 global。
      // 公式也是錨點 → 公式多的段落不會因為原始碼很長、渲染後很短而整段偏掉。
      window.scrollSync = function (k, local, global, srcCount) {
        const anchors = Array.from(document.querySelectorAll(
          "#content h1, #content h2, #content h3, #content h4, #content h5, #content h6, #content .rh-head, #content .katex-display"));
        if (anchors.length === 0 || anchors.length !== srcCount) {
          window.scrollToFraction(global);
          return;
        }
        const ys = anchors.map(el => el.getBoundingClientRect().top + window.scrollY);
        const maxScroll = Math.max(0, document.body.scrollHeight - window.innerHeight);
        let target;
        if (k < 0) {
          target = local * ys[0];
        } else if (k >= ys.length - 1) {
          target = ys[ys.length - 1] + local * Math.max(0, maxScroll - ys[ys.length - 1]);
        } else {
          target = ys[k] + local * (ys[k + 1] - ys[k]);
        }
        window.scrollTo(0, Math.max(0, Math.min(maxScroll, target)));
      };
    </script>
    </body>
    </html>
    """
}

#if os(macOS)
extension MarkdownPreviewView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { refresh(coordinator: context.coordinator) }
}
#else
extension MarkdownPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { refresh(coordinator: context.coordinator) }
}
#endif
