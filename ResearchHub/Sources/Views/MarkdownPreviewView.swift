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
    var baseDir: URL?
    /// 供 \cite 解析用的 Zotero 文獻（載入後變動時會觸發重新渲染）。
    var citationItems: [ZoteroItem] = []
    /// 點擊 [[筆記]] 引用時開啟對應筆記。
    var onOpenNote: ((URL) -> Void)?
    /// 雙擊預覽的某個段落 → 回報該段落在錨點座標系的位置，讓左欄源碼跳到對應處。
    var onJumpToSource: ((ScrollSync) -> Void)?
    /// 版面："flow" = 連續（預設）、"a4" = A4 分頁（註腳放當頁底部）。
    var layout: String = "flow"

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "jumpToSource")
        let webView = WKWebView(frame: .zero, configuration: config)
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
        coordinator.pendingLayout = layout
        coordinator.onJumpToSource = onJumpToSource
        webView.loadHTMLString(Self.template, baseURL: WebResources.baseURL)
        return webView
    }

    private func refresh(coordinator: Coordinator) {
        coordinator.baseDir = baseDir
        coordinator.onOpenNote = onOpenNote
        coordinator.onJumpToSource = onJumpToSource
        coordinator.apply(layout: layout)
        coordinator.update(text: text, items: citationItems)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var pendingText: String?
        var baseDir: URL?
        var citationItems: [ZoteroItem] = []
        var onOpenNote: ((URL) -> Void)?
        var onJumpToSource: ((ScrollSync) -> Void)?
        var pendingLayout: String?
        private var isLoaded = false
        private var lastText: String?
        private var lastCiteSig = -1
        private var lastLayout: String?
        /// 圖片 base64 快取（path → data URI），避免每次按鍵重讀檔案
        private var imageCache: [String: String] = [:]

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let layout = pendingLayout {
                pendingLayout = nil
                apply(layout: layout)
            }
            if let pending = pendingText {
                pendingText = nil
                push(pending)
            }
        }

        /// 切換版面（flow / a4）。值來自我們自己的 AppStorage，安全可直接插入 JS。
        func apply(layout: String) {
            guard isLoaded else { pendingLayout = layout; return }
            guard layout != lastLayout else { return }
            lastLayout = layout
            webView?.evaluateJavaScript("window.setLayout('\(layout)')")
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

        private var pushWork: DispatchWorkItem?

        func update(text: String, items: [ZoteroItem]) {
            citationItems = items
            // 文字或文獻數量任一改變就重繪（文獻載入後 \cite 才解析得出來）。
            guard text != lastText || items.count != lastCiteSig else { return }
            let firstRender = lastText == nil
            lastText = text
            lastCiteSig = items.count
            guard isLoaded else {
                pendingText = text
                return
            }
            pushWork?.cancel()
            if firstRender {
                push(text)   // 開檔首繪不延遲
                return
            }
            // 打字中的重繪延後到停手：長筆記每個按鍵都全文跑 marked+KaTeX 很重，
            // 重繪瞬間的版面抖動也是預覽上下亂跳的來源之一。
            let w = DispatchWorkItem { [weak self] in self?.push(text) }
            pushWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }

        /// 預覽端雙擊段落 → 收到錨點座標，轉交給左欄源碼跳轉。
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "jumpToSource",
                  let body = message.body as? [String: Any],
                  let anchor = body["anchor"] as? Int,
                  let local = body["local"] as? Double,
                  let global = body["global"] as? Double,
                  let count = body["count"] as? Int else { return }
            onJumpToSource?(ScrollSync(
                anchor: anchor, local: CGFloat(local), global: CGFloat(global), count: count,
                word: body["word"] as? String ?? "",
                occ: body["occ"] as? Int ?? 0,
                fn: body["fn"] as? Int ?? 0))
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
      /* 巢狀編號清單：仿 LaTeX enumerate 的層級記號 1. → a. → i. */
      ol ol { list-style-type: lower-alpha; }
      ol ol ol { list-style-type: lower-roman; }
      input[type=checkbox] { margin-right: 6px; }
      img { max-width: 100%; border-radius: 6px; }
      li.task { list-style: none; margin-left: -1.2em; }
      hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); }
      .err { color: #c33; font-family: ui-monospace, monospace; font-size: 0.85em; }
      .rh-deadlink { color: #c33; border-bottom: 1px dashed #c33; cursor: help; }
      .rh-tail-head { font-weight: 600; margin: 1em 0 0.4em; }
      .rh-caption { font-size: 0.88em; opacity: 0.75; margin: 0.2em 0 0.6em; }
      .rh-abs-head { text-align: center; font-weight: 600; margin: 0.8em 0 0.2em; }
      .rh-abstract { margin: 0 1.5em 1em; opacity: 0.92; }
      table { border-collapse: collapse; margin: 0.5em auto; }
      th, td { border: 1px solid rgba(127,127,127,0.35); padding: 3px 10px; }
      th { background: rgba(127,127,127,0.12); }
      .rh-fn-head { font-size: 0.85em; opacity: 0.8; }
      /* A4 分頁模式：固定 794×1123（96dpi 的 210×297mm），註腳放當頁底部 */
      #measure { position: absolute; left: -10000px; top: 0; width: 680px; visibility: hidden; }
      /* 頁面外觀跟隨系統主題：半透明卡片 + 細框，只換排版不換配色 */
      #content.a4 .page {
        width: 794px; min-height: 1123px; box-sizing: border-box;
        padding: 57px;
        margin: 0 auto 26px;
        background: rgba(127,127,127,0.07);
        border: 1px solid rgba(127,127,127,0.28);
        border-radius: 4px;
        box-shadow: 0 2px 10px rgba(0,0,0,0.18);
        display: flex; flex-direction: column;
      }
      .pg-foot { margin-top: auto; }
      .pg-foot:not(:empty) {
        border-top: 1px solid rgba(127,127,127,0.4);
        padding-top: 8px; margin-top: auto;
        font-size: 0.82em; line-height: 1.5;
      }
      .pg-fn { margin: 3px 0; }
      .pg-fn-n { opacity: 0.65; margin-right: 4px; }
    </style>
    </head>
    <body>
    <div id="content"></div>
    <div id="measure"></div>
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

      let layoutMode = "flow";
      let lastSrc = null;

      window.setLayout = function (m) {
        if (m === layoutMode) return;
        layoutMode = m;
        if (lastSrc !== null) { const s = lastSrc; lastSrc = null; window.update(s); }
      };

      // 給尾端註腳清單的每個項目標上 data-fn（雙擊可跳回源碼對應的 \\footnote）
      function tagFootnotes(root) {
        const head = root.querySelector(".rh-fn-head");
        if (!head) return null;
        const list = head.nextElementSibling;
        if (!list || list.tagName !== "OL") return null;
        Array.from(list.children).forEach((li, i) => { li.dataset.fn = i + 1; });
        return { head: head, list: list };
      }

      // A4 分頁：把渲染好的區塊依高度塞進 794×1123 的頁面，
      // 區塊裡有 [n] 註腳標記時，把對應註腳搬到「當頁」底部。
      function paginate(meas, content) {
        const USABLE = 1123 - 2 * 57;
        // 比頁寬還寬的公式：等比縮小塞進頁面（消掉水平捲軸，
        // 否則捲軸會吃掉高度、把公式上下裁掉）。縮到 0.5 為止，再寬就讓它捲。
        for (const kd of meas.querySelectorAll(".katex-display")) {
          kd.style.zoom = "";
          if (kd.scrollWidth > kd.clientWidth + 1) {
            kd.style.zoom = Math.max(0.5, kd.clientWidth / kd.scrollWidth);
          }
        }
        const fn = tagFootnotes(meas);
        let fnItems = [], fnHeights = [];
        if (fn) {
          fnItems = Array.from(fn.list.children).map(li => {
            const d = document.createElement("div");
            d.className = "pg-fn";
            d.dataset.fn = li.dataset.fn;
            d.innerHTML = '<span class="pg-fn-n">' + li.dataset.fn + '.</span> ' + li.innerHTML;
            return d;
          });
          const hr = fn.head.previousElementSibling;
          fn.list.remove();
          fn.head.remove();
          if (hr && hr.tagName === "HR") hr.remove();
          for (const d of fnItems) {
            d.style.fontSize = "0.82em";
            meas.appendChild(d);
            fnHeights.push(d.getBoundingClientRect().height + 3);
            d.remove();
            d.style.fontSize = "";
          }
        }

        let body = null, foot = null, bodyH = 0, footH = 0;
        function newPage() {
          const page = document.createElement("div");
          page.className = "page";
          body = document.createElement("div");
          body.className = "pg-body";
          foot = document.createElement("div");
          foot.className = "pg-foot";
          page.append(body, foot);
          content.appendChild(page);
          bodyH = 0; footH = 0;
        }
        newPage();
        for (const b of Array.from(meas.children)) {
          const cs = getComputedStyle(b);
          const h = b.getBoundingClientRect().height
            + parseFloat(cs.marginTop) + parseFloat(cs.marginBottom);
          const marks = Array.from(b.querySelectorAll("sup.rh-fn"))
            .map(s => parseInt((s.textContent.match(/\\d+/) || ["0"])[0]))
            .filter(n => n >= 1 && n <= fnItems.length);
          let addFoot = 0;
          for (const n of marks) addFoot += fnHeights[n - 1];
          if (footH === 0 && marks.length) addFoot += 22;
          if (bodyH > 0 && bodyH + h + footH + addFoot > USABLE) {
            newPage();
            addFoot = 0;
            for (const n of marks) addFoot += fnHeights[n - 1];
            if (marks.length) addFoot += 22;
          }
          body.appendChild(b);
          bodyH += h;
          for (const n of marks) foot.appendChild(fnItems[n - 1]);
          footH += addFoot;
        }
      }

      // 窄視窗時整頁等比縮小（zoom 會影響版面與座標，左右對位不受影響）
      function applyScale() {
        const content = document.getElementById("content");
        if (!content.classList.contains("a4")) { content.style.zoom = ""; return; }
        const w = document.documentElement.clientWidth - 44;
        content.style.zoom = Math.max(0.3, Math.min(1, w / 794));
      }
      window.addEventListener("resize", applyScale);

      // 公式捲軸只留給「真的超寬」的：帶 \\tag 編號的 KaTeX 內部寬度常比容器
      // 多零點幾像素，overflow-x:auto 就會冒出整條捲軸。量一下，
      // 沒有實質溢出的改成 visible（x/y 要一起改，單留 hidden 會被瀏覽器算回 auto）。
      function tameEquationScrollbars() {
        for (const kd of document.querySelectorAll("#content .katex-display")) {
          const wide = kd.scrollWidth > kd.clientWidth + 3;
          kd.style.overflowX = wide ? "auto" : "visible";
          kd.style.overflowY = wide ? "hidden" : "visible";
        }
      }

      // KaTeX 字型是首次渲染才開始載入：載入前量測的高度不準（也會造成字符重疊），
      // 每批字型載完就把 A4 重新分頁（字型已齊時不會再觸發，不會迴圈）。
      if (document.fonts) {
        document.fonts.addEventListener("loadingdone", () => {
          if (layoutMode === "a4" && lastSrc !== null) {
            const s = lastSrc; lastSrc = null; window.update(s);
          } else {
            tameEquationScrollbars();   // 字型到齊後寬度會變，重新量
          }
        });
      }
      window.addEventListener("resize", tameEquationScrollbars);

      window.update = function (text) {
        lastSrc = text;
        mathBlocks = [];
        const safe = protect(text);
        let html = marked.parse(safe, { gfm: true, breaks: true });
        html = html.replace(/@@MATH(\\d+)@@/g, (_, i) => renderMath(mathBlocks[+i]));
        const content = document.getElementById("content");
        // 重繪防跳：記住捲動位置並鎖住高度——圖片/字型還沒定型時文件會暫時變矮，
        // 捲動位置被瀏覽器夾到底端就是「上下亂跳」的來源；等圖片就位再解除。
        const savedY = window.scrollY;
        content.style.minHeight = content.getBoundingClientRect().height + "px";
        if (layoutMode === "a4") {
          content.className = "a4";
          content.innerHTML = "";
          const meas = document.getElementById("measure");
          meas.innerHTML = html;
          paginate(meas, content);
          meas.innerHTML = "";
        } else {
          content.className = "";
          content.innerHTML = html;
          tagFootnotes(content);
        }
        applyScale();
        tameEquationScrollbars();
        window.scrollTo(0, savedY);
        const imgs = Array.from(content.querySelectorAll("img"));
        Promise.allSettled(imgs.map(im => im.decode ? im.decode() : Promise.resolve()))
          .then(() => {
            content.style.minHeight = "";
            if (window.scrollY < savedY - 4) window.scrollTo(0, savedY);
          });
      };

      // 雙擊某個段落 → 回報它在「標題 + 顯示型公式」錨點座標系的位置：
      // 位於第 k 個錨點之後、段內比例 local；錨點數對不上時源碼端退回整份比例 global。
      // 公式也是錨點 → 公式多的段落不會因為原始碼很長、渲染後很短而整段偏掉。
      const anchorSelector =
        "#content h1, #content h2, #content h3, #content h4, #content h5, #content h6, #content .rh-head, #content .katex-display";

      // 錨點清單：排除「生成尾端」（參考文獻/註腳，源碼沒有對應行）與 A4 頁底註腳，
      // 否則左右錨點數對不上、整份對位會歪掉。
      function anchorList() {
        const tail = document.getElementById("rh-tail-start");
        return Array.from(document.querySelectorAll(anchorSelector)).filter(el => {
          if (el.closest(".pg-foot")) return false;
          if (tail && (tail.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING))
            return false;
          return true;
        });
      }

      // 選到的字在 range 起點之前出現過幾次（＝這次是第 occ 次，0-based）
      function occurrenceBefore(word, containerRange, sel) {
        const pre = containerRange.cloneRange();
        const sr = sel.getRangeAt(0);
        pre.setEnd(sr.startContainer, sr.startOffset);
        const preText = pre.toString();
        let occ = 0, idx = preText.indexOf(word);
        while (idx !== -1) { occ += 1; idx = preText.indexOf(word, idx + 1); }
        return occ;
      }

      function selectedWord(sel) {
        if (!sel || sel.isCollapsed || sel.rangeCount === 0) return "";
        const w = sel.toString().trim();
        return (w && w.length <= 80 && w.indexOf("\\n") < 0) ? w : "";
      }

      document.addEventListener("dblclick", function (e) {
        const bridge = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.jumpToSource;
        if (!bridge) return;
        const sel = window.getSelection();

        // 註腳項目（A4 頁底 .pg-fn 或文末清單 li[data-fn]）→ 直接對到第 n 個 \\footnote
        const fnEl = e.target.closest("[data-fn]");
        if (fnEl) {
          let word = selectedWord(sel), occ = 0;
          if (word) {
            try {
              const r = document.createRange();
              r.selectNodeContents(fnEl);
              occ = occurrenceBefore(word, r, sel);
            } catch (_) { occ = 0; }
          }
          bridge.postMessage({ anchor: -1, local: 0, global: 0, count: 0,
                               word: word, occ: occ, fn: parseInt(fnEl.dataset.fn) || 0 });
          return;
        }

        const block = e.target.closest(".katex-display, .pg-body > *, #content > *");
        if (!block || block.classList.contains("page")) return;
        const top = block.getBoundingClientRect().top + window.scrollY;
        const maxScroll = Math.max(1, document.body.scrollHeight - window.innerHeight);
        const anchorEls = anchorList();
        const ys = anchorEls.map(el => el.getBoundingClientRect().top + window.scrollY);
        let k = -1;
        for (const y of ys) { if (y <= top + 0.5) k += 1; else break; }
        let local;
        if (ys.length === 0) {
          local = 0;
        } else if (k < 0) {
          local = top / Math.max(1, ys[0]);
        } else if (k >= ys.length - 1) {
          local = (top - ys[k]) / Math.max(1, maxScroll - ys[k]);
        } else {
          local = (top - ys[k]) / Math.max(1, ys[k + 1] - ys[k]);
        }
        // 雙擊已讓瀏覽器選了字：連同「該字在錨點段落內是第幾次出現」一起回報，
        // 左欄就能在對應的源碼區段選到同一個字（找不到時退回位置跳轉）。
        let word = selectedWord(sel), occ = 0;
        if (word) {
          try {
            const content = document.getElementById("content");
            const seg = document.createRange();
            if (k >= 0) seg.setStartBefore(anchorEls[k]);
            else seg.setStart(content, 0);
            if (k + 1 < anchorEls.length) seg.setEndBefore(anchorEls[k + 1]);
            else seg.setEnd(content, content.childNodes.length);
            occ = occurrenceBefore(word, seg, sel);
          } catch (_) { word = ""; occ = 0; }
        }
        bridge.postMessage({
          anchor: k,
          local: Math.max(0, Math.min(1, local)),
          global: Math.max(0, Math.min(1, top / maxScroll)),
          count: ys.length,
          word: word,
          occ: occ,
          fn: 0
        });
      });
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
