import Foundation

/// 在 marked + KaTeX 渲染「之前」，先把筆記裡的學術寫作指令處理成可渲染的 markdown：
///   • 方程式編號  \label{key}  → \tag{n}（留在 display math 內，KaTeX 會畫出 (n)）
///   • 交叉引用    \eqref{key} → (n)、\ref{key} → n
///   • 註腳        \footnote{文字} → 上標標記 + 文末註腳清單
///   • 文獻引用    \cite{key[,key2]} → [n]（連到 Zotero）+ 文末「參考文獻」清單（資料來自 Zotero）
///
/// 全部在 Swift 端做，渲染模板（MarkdownPreviewView.template）不需改動，
/// 因此預覽與「輸出 PDF」都會自動套用。
enum NotePreprocessor {

    static func process(
        _ markdown: String,
        zoteroItems: [ZoteroItem],
        noteLinks: [NoteLink] = []
    ) -> String {
        var text = markdown

        // 0. 筆記互相引用：[[筆記]] 或 [[資料夾/筆記|顯示文字]]
        //    → 解析得到 → 可點擊連結（researchhub://note，由預覽攔截開啟）
        //    → 解析不到 → 紅色虛線標記（提醒筆記名稱可能打錯或尚未建立）
        //    放在最前面處理，這樣連結文字之後仍會正常被 marked 解析。
        text = replace(text, pattern: #"\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#) { g in
            let target = g[1].trimmingCharacters(in: .whitespaces)
            let display = g[2].trimmingCharacters(in: .whitespaces).isEmpty
                ? target
                : g[2].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return g[0] }
            if let link = NoteLinkIndex.resolve(target, in: noteLinks) {
                let allowed = CharacterSet.urlQueryAllowed
                    .subtracting(CharacterSet(charactersIn: "&=+?#"))
                let encoded = link.relativePath
                    .addingPercentEncoding(withAllowedCharacters: allowed)
                    ?? link.relativePath
                return "[\(display)](researchhub://note?path=\(encoded))"
            } else {
                let safe = display
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<span class=\"rh-deadlink\" title=\"找不到筆記：\(target)\">\(safe)</span>"
            }
        }

        // 0.2 全行 % 註解（LaTeX 慣例）：行首（含縮排）以 % 開頭的整行拿掉。
        //     \% 跳脫不受影響；數學區內的 % 交給 KaTeX 自己處理。
        text = replaceOutsideMath(text) { seg in
            replace(seg, pattern: #"(?m)^[ \t]*%[^\n]*\n?"#) { _ in "" }
        }

        // 0.3 波浪號：marked 的 GFM 會把「單個」~ 成對當刪除線，時段寫法
        //     「0910~1200 助教課\n1420~1620 專討」就被吃掉波浪號、中間整段劃掉。
        //     只保留 ~~雙波浪~~ 當刪除線；單個 ~ 轉義成字面波浪號。
        //     LaTeX 的 Eq.~\eqref{} / Fig.~\ref{} / ~\cite{} 轉成不斷行空格。
        //     數學區不動；`行內程式碼` 與 ``` 區塊也不動。
        text = replaceOutsideMath(text) { seg in
            var t = replace(seg, pattern: #"~(?=\\(?:eq)?ref\{|\\cite\{)"#) { _ in "\u{00A0}" }
            t = replace(t, pattern: #"(`+)[\s\S]*?\1|(?<![~\\])~(?!~)"#) { g in
                g[1].isEmpty ? "\\~" : g[0]
            }
            return t
        }

        // 0.5 文字模式清單環境：\begin{enumerate}/\begin{itemize}（可巢狀、\item 可多行）
        //     → markdown 清單。一定要在數學處理「之前」做：KaTeX 不支援這些文字環境，
        //     不先轉換整塊會被預覽端當數學送去 KaTeX，渲染成錯誤。
        text = convertListEnvironments(text)

        // 0.6 文字環境：quote/quotation → 引用塊、center → 置中、abstract → 摘要。
        //     （html 區塊前後要留空行，marked 才會繼續解析中間的 markdown。）
        for env in ["quote", "quotation"] {
            text = replaceEnvironment(text, env) { c in
                "\n\n<blockquote>\n\n\(c.trimmingCharacters(in: .whitespacesAndNewlines))\n\n</blockquote>\n\n"
            }
        }
        text = replaceEnvironment(text, "center") { c in
            "\n\n<div style=\"text-align:center\">\n\n\(c.trimmingCharacters(in: .whitespacesAndNewlines))\n\n</div>\n\n"
        }
        text = replaceEnvironment(text, "abstract") { c in
            "\n\n<div class=\"rh-abs-head\">摘要</div>\n<div class=\"rh-abstract\">\n\n"
                + c.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n</div>\n\n"
        }

        // 0.65 圖與表：\includegraphics → 圖片、figure/table 環境 →
        //      置中內容 + 「圖 n／表 n：caption」+ \label 錨點（\ref 可引用編號）。
        var figMap: [String: Int] = [:]
        var tabMap: [String: Int] = [:]
        text = replace(text, pattern: #"\\includegraphics(?:\[[^\]\n]*\])?\{([^}]*)\}"#) { g in
            "![](\(g[1].trimmingCharacters(in: .whitespaces)))"
        }
        var figCount = 0
        text = replaceEnvironment(text, "figure") { content in
            var body = replace(content, pattern: #"^\s*\[[^\]\n]*\]"#) { _ in "" }  // [h!] 等placement
            var caption = ""
            body = replaceBalancedCommand(body, "\\caption") { c in caption = c; return "" }
            var keys: [String] = []
            body = replace(body, pattern: #"\\label\{([^}]*)\}"#) { lg in
                keys.append(lg[1].trimmingCharacters(in: .whitespaces)); return ""
            }
            body = replace(body, pattern: #"\\centering(?![a-zA-Z])"#) { _ in "" }
            figCount += 1
            for k in keys { figMap[k] = figCount }
            let anchors = keys.map { "<span id=\"fig-\(anchorID($0))\"></span>" }.joined()
            let cap = caption.isEmpty ? "" :
                "\n\n<div class=\"rh-caption\">圖 \(figCount)：\(inlineFormatHTML(caption))</div>\n"
            return "\n\n<div style=\"text-align:center\">\n\n" + anchors
                + body.trimmingCharacters(in: .whitespacesAndNewlines) + cap + "\n\n</div>\n\n"
        }
        var tabCount = 0
        text = replaceEnvironment(text, "table") { content in
            var body = replace(content, pattern: #"^\s*\[[^\]\n]*\]"#) { _ in "" }
            var caption = ""
            body = replaceBalancedCommand(body, "\\caption") { c in caption = c; return "" }
            var keys: [String] = []
            body = replace(body, pattern: #"\\label\{([^}]*)\}"#) { lg in
                keys.append(lg[1].trimmingCharacters(in: .whitespaces)); return ""
            }
            body = replace(body, pattern: #"\\centering(?![a-zA-Z])"#) { _ in "" }
            body = replaceEnvironment(body, "tabular") { tb in
                tabularToMarkdown(tb) ?? ("\\begin{tabular}" + tb + "\\end{tabular}")
            }
            tabCount += 1
            for k in keys { tabMap[k] = tabCount }
            let anchors = keys.map { "<span id=\"tab-\(anchorID($0))\"></span>" }.joined()
            let cap = caption.isEmpty ? "" :
                "<div class=\"rh-caption\" style=\"text-align:center\">表 \(tabCount)：\(inlineFormatHTML(caption))</div>\n"
            return "\n\n" + anchors + cap
                + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        // 沒包在 table 環境裡的落單 tabular 也轉
        text = replaceEnvironment(text, "tabular") { tb in
            tabularToMarkdown(tb) ?? ("\\begin{tabular}" + tb + "\\end{tabular}")
        }

        // 1. 方程式編號（仿 LaTeX）：
        //    - \label 不顯示任何東西，只記錄該式的編號供 \eqref 使用。
        //    - 編號由「環境」決定：equation/align/gather… 會編號；星號版、$$、\[ 不編號。
        //    - KaTeX 對每個式子各自從 (1) 重編、且同一塊放多個 \tag 也只顯示一個，所以這裡把編號
        //      環境改成星號版（關掉 KaTeX 自動編號），再為整塊注入一個整篇連續的 \tag{n}，
        //      避免出現重複數字或每條都變 (1)。
        //    - 同時在式子前放 <span id="eq-…"> 作為 \eqref 點擊跳轉的目標。
        var eqMap: [String: Int] = [:]
        var eqCounter = 0
        let numberedEnvs: Set<String> =
            ["equation", "align", "gather", "multline", "flalign", "alignat", "eqnarray"]
        // 用 \1 反向參照配對 begin/end，才能正確抓到「外層」環境（例如 equation 包 align*）。
        let blockPattern = #"\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}|\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]"#
        text = replace(text, pattern: blockPattern) { g in
            let env = g[1]
            var keys: [String] = []
            var body = replace(g[0], pattern: #"\\label\{([^}]*)\}"#) { lg in
                keys.append(lg[1].trimmingCharacters(in: .whitespaces))
                return ""   // \label 不顯示
            }
            guard numberedEnvs.contains(env) else { return body }   // 未編號環境：label 拿掉即可
            eqCounter += 1
            for k in keys { eqMap[k] = eqCounter }
            let starred = env + "*"
            body = body
                .replacingOccurrences(of: "\\begin{\(env)}", with: "\\begin{\(starred)}")
                .replacingOccurrences(of: "\\end{\(env)}", with: "\\end{\(starred)}")
            if let r = body.range(of: "\\end{\(starred)}", options: .backwards) {
                body.replaceSubrange(r, with: "\\tag{\(eqCounter)}\n\\end{\(starred)}")
            }
            let anchors = keys.map { "<span id=\"eq-\(anchorID($0))\"></span>" }.joined()
            return anchors.isEmpty ? body : anchors + "\n\n" + body
        }

        // 2. \eqref{key} → 可點擊的 (n)（跳到該式）；找不到 → (?)
        text = replace(text, pattern: #"\\eqref\{([^}]*)\}"#) { groups in
            let key = groups[1].trimmingCharacters(in: .whitespaces)
            guard let n = eqMap[key] else { return "(?)" }
            return "[(\(n))](#eq-\(anchorID(key)))"
        }
        // 3. \ref{key} → 可點擊的 n（公式、圖、表都能引用）
        text = replace(text, pattern: #"\\ref\{([^}]*)\}"#) { groups in
            let key = groups[1].trimmingCharacters(in: .whitespaces)
            if let n = eqMap[key] { return "[\(n)](#eq-\(anchorID(key)))" }
            if let n = figMap[key] { return "[\(n)](#fig-\(anchorID(key)))" }
            if let n = tabMap[key] { return "[\(n)](#tab-\(anchorID(key)))" }
            return "?"
        }

        // 3.5 文件抬頭：\title / \subtitle / \author / \date → 置中樣式區塊。
        //（前後一定要留空行，否則 marked 會把 <div> 當成 HTML 區塊，把後面的內容
        //  整段當原始 HTML 吞掉、不再解析 markdown／連結。）
        text = replaceBalancedCommand(text, "\\title") { raw in
            let inner = unescapeTilde(raw)
            return "\n\n<div class=\"rh-head\" style=\"text-align:center;font-size:1.9em;font-weight:700;margin:.3em 0 .1em;\">\(inner)</div>\n\n"
        }
        text = replaceBalancedCommand(text, "\\subtitle") { raw in
            let inner = unescapeTilde(raw)
            return "\n\n<div class=\"rh-head\" style=\"text-align:center;font-size:1.25em;font-weight:500;opacity:.8;margin:0 0 .4em;\">\(inner)</div>\n\n"
        }
        text = replaceBalancedCommand(text, "\\author") { raw in
            let inner = unescapeTilde(raw)
            return "\n\n<div class=\"rh-head\" style=\"text-align:center;opacity:.85;margin:.1em 0;\">\(inner)</div>\n\n"
        }
        text = replaceBalancedCommand(text, "\\date") { raw in
            let inner = unescapeTilde(raw)
            return "\n\n<div class=\"rh-head\" style=\"text-align:center;font-size:.9em;opacity:.7;margin:0 0 .6em;\">\(inner)</div>\n\n"
        }

        // 3.6 章節：\section / \subsection / \subsubsection → 自動編號標題 + 錨點，並收集目錄。
        //（用同一個 pass 才能依出現順序正確編號）
        //  \appendix 之後第一層編號改 A、B、C…；\section*{} 星號版不編號、不進目錄。
        var secNums = [0, 0, 0]
        var inAppendix = false
        var toc: [(level: Int, number: String, title: String, id: String)] = []
        text = replace(
            text,
            pattern: #"\\appendix(?![a-zA-Z])|\\(sub)?(sub)?section(\*)?\{([^}]*)\}"#
        ) { g in
            if g[0].hasPrefix("\\appendix") {
                inAppendix = true
                secNums = [0, 0, 0]
                return ""
            }
            let level = (g[1].isEmpty ? 0 : 1) + (g[2].isEmpty ? 0 : 1) + 1
            let title = g[4]
            let hashes = String(repeating: "#", count: level)
            if !g[3].isEmpty {   // 星號版
                return "\(hashes) \(title)"
            }
            switch level {
            case 1: secNums[0] += 1; secNums[1] = 0; secNums[2] = 0
            case 2: secNums[1] += 1; secNums[2] = 0
            default: secNums[2] += 1
            }
            let l1 = inAppendix ? appendixLetter(secNums[0]) : "\(secNums[0])"
            let number: String
            switch level {
            case 1: number = l1
            case 2: number = "\(l1).\(secNums[1])"
            default: number = "\(l1).\(secNums[1]).\(secNums[2])"
            }
            let id = "sec-" + number.replacingOccurrences(of: ".", with: "-")
            toc.append((level, number, title, id))
            return "<span id=\"\(id)\"></span>\n\n\(hashes) \(number) \(title)"
        }

        // 3.65 段落級標題：\paragraph → h4、\subparagraph → h5（不編號）
        text = replace(text, pattern: #"\\(sub)?paragraph\*?\{([^}]*)\}"#) { g in
            "\n\n\(g[1].isEmpty ? "####" : "#####") \(g[2])\n\n"
        }

        // 3.7 \tableofcontents → 依章節自動生成目錄（連結可跳到該節）
        text = replace(text, pattern: #"\\tableofcontents"#) { _ in
            guard !toc.isEmpty else { return "" }
            var lines = ["", "**目錄**", ""]
            for e in toc {
                let indent = String(repeating: "  ", count: max(0, e.level - 1))
                lines.append("\(indent)- [\(e.number) \(e.title)](#\(e.id))")
            }
            lines.append("")
            return lines.joined(separator: "\n")
        }

        // 3.8 文字樣式與雜項（只動數學區以外；公式裡的 \textbf 等交給 KaTeX）：
        //     樣式 → markdown/HTML、\href/\url → 連結、
        //     排版留白指令拿掉、\newpage/\clearpage → 分隔線。
        text = replaceOutsideMath(text) { seg in
            var s = seg
            // 顏色：\textcolor{red}{字}、\textcolor[HTML]{FF8800}{字}、\colorbox{yellow}{字}
            s = replaceColorCommand(s, "\\textcolor") { color, inner in
                "<span style=\"color:\(color)\">\(inner)</span>"
            }
            s = replaceColorCommand(s, "\\colorbox") { color, inner in
                "<span style=\"background:\(color);padding:0 .15em;border-radius:3px\">\(inner)</span>"
            }
            s = replaceBalancedCommand(s, "\\textbf") { "**\($0)**" }
            s = replaceBalancedCommand(s, "\\textit") { "*\($0)*" }
            s = replaceBalancedCommand(s, "\\emph") { "*\($0)*" }
            s = replaceBalancedCommand(s, "\\underline") { "<u>\($0)</u>" }
            s = replaceBalancedCommand(s, "\\texttt") { "`\($0)`" }
            s = replaceBalancedCommand(s, "\\textsc") {
                "<span style=\"font-variant:small-caps\">\($0)</span>"
            }
            s = replaceBalancedCommand(s, "\\textsuperscript") { "<sup>\($0)</sup>" }
            s = replaceBalancedCommand(s, "\\textsubscript") { "<sub>\($0)</sub>" }
            s = replace(s, pattern: #"\\href\{([^}]*)\}\{([^}]*)\}"#) { g in
                "[\(g[2])](\(g[1]))"
            }
            s = replace(s, pattern: #"\\url\{([^}]*)\}"#) { g in "[\(g[1])](\(g[1]))" }
            s = replace(s, pattern: #"\\(?:vspace|hspace)\*?\{[^}]*\}"#) { _ in " " }
            s = replace(s, pattern:
                #"\\(?:maketitle|noindent|centering|raggedright|bigskip|medskip|smallskip|vfill|hfill)(?![a-zA-Z])"#
            ) { _ in "" }
            s = replace(s, pattern: #"\\(?:newpage|clearpage)(?![a-zA-Z])"#) { _ in
                "\n\n---\n\n"
            }
            return s
        }

        // 4. 註腳：\footnote{文字} → 上標 [n]，文字收集到文末
        var footnotes: [String] = []
        text = replaceBalancedCommand(text, "\\footnote") { inner in
            footnotes.append(inner.trimmingCharacters(in: .whitespacesAndNewlines))
            return "<sup class=\"rh-fn\">[\(footnotes.count)]</sup>"
        }

        // 5. 文獻：\cite{key} / \cite{k1,k2} → [n]（連到 Zotero）
        let itemsByKey = Dictionary(zoteroItems.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var citeOrder: [String] = []     // 依首次出現排序的唯一 key
        var citeNum: [String: Int] = [:]
        text = replace(text, pattern: #"\\cite\{([^}]*)\}"#) { groups in
            let keys = groups[1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !keys.isEmpty else { return "" }
            let markers = keys.map { key -> String in
                if citeNum[key] == nil {
                    citeOrder.append(key)
                    citeNum[key] = citeOrder.count
                }
                let n = citeNum[key]!
                // markdown 連結，連結文字是 [n]（用 \[ \] 顯示中括號），點了開 Zotero
                return "[\\[\(n)\\]](zotero://select/library/items/\(key))"
            }
            return markers.joined()
        }

        // 5.5 尾端生成區哨兵：預覽端用它排除「生成內容」的捲動錨點
        //（生成的標題/公式在源碼沒有對應行，混進錨點會讓左右對位整個歪掉）。
        //  標題刻意用 <div> 而不是 markdown 標題，才不會被當成 h1–h6 錨點。
        if !citeOrder.isEmpty || !footnotes.isEmpty {
            text += "\n\n<span id=\"rh-tail-start\"></span>"
        }

        // 6. 附上「參考文獻」清單
        if !citeOrder.isEmpty {
            var lines = ["", "", "---", "", "<div class=\"rh-tail-head\">參考文獻</div>", ""]
            for (i, key) in citeOrder.enumerated() {
                let n = i + 1
                if let item = itemsByKey[key] {
                    lines.append("\(n). \(reference(for: item))")
                } else {
                    lines.append("\(n). （在 Zotero 找不到：\(key)）")
                }
            }
            text += lines.joined(separator: "\n")
        }

        // 7. 附上註腳清單
        if !footnotes.isEmpty {
            var lines = ["", "", "---", "", "<div class=\"rh-tail-head rh-fn-head\">註腳</div>", ""]
            for (i, note) in footnotes.enumerated() {
                lines.append("\(i + 1). \(note)")
            }
            text += lines.joined(separator: "\n")
        }

        return text
    }

    // MARK: - 文字清單環境 → markdown

    /// KaTeX 只支援數學環境；enumerate/itemize 是文字模式清單，先轉成 markdown 清單。
    private static let textListEnvs = ["enumerate", "itemize"]

    /// 掃出環境內容裡的結構 token：\begin{...}、\end{...}、頂層 \item（可帶 [自訂標籤]）。
    private static let listTokenRegex = try! NSRegularExpression(
        pattern: #"\\begin\{[a-zA-Z*]+\}|\\end\{[a-zA-Z*]+\}|\\item(?![a-zA-Z])(?:\[[^\]\n]*\])?"#)

    private static func convertListEnvironments(_ text: String) -> String {
        let ns = text as NSString
        let n = ns.length
        var result = ""
        var i = 0
        while i < n {
            var found: (begin: NSRange, env: String)?
            for env in textListEnvs {
                let r = ns.range(of: "\\begin{\(env)}", range: NSRange(location: i, length: n - i))
                if r.location != NSNotFound,
                   found == nil || r.location < found!.begin.location {
                    found = (r, env)
                }
            }
            guard let f = found,
                  let (contentEnd, blockEnd) = matchingEnd(
                    for: f.env, in: ns, from: f.begin.location + f.begin.length)
            else {
                // 沒有清單環境（或沒有對應的 \end）→ 剩餘內容原樣保留
                result += ns.substring(from: i)
                break
            }
            result += ns.substring(with: NSRange(location: i, length: f.begin.location - i))
            let contentStart = f.begin.location + f.begin.length
            let content = ns.substring(
                with: NSRange(location: contentStart, length: contentEnd - contentStart))
            result += markdownList(from: content, ordered: f.env == "enumerate")
            i = blockEnd
        }
        return result
    }

    /// 從 from 開始找同名環境的對應 \end（同名巢狀會計數）。回傳（內容結尾, 區塊結尾）。
    private static func matchingEnd(for env: String, in ns: NSString, from: Int) -> (Int, Int)? {
        let beginTok = "\\begin{\(env)}"
        let endTok = "\\end{\(env)}"
        let n = ns.length
        var depth = 1
        var j = from
        while j < n {
            let e = ns.range(of: endTok, range: NSRange(location: j, length: n - j))
            guard e.location != NSNotFound else { return nil }
            let b = ns.range(of: beginTok, range: NSRange(location: j, length: n - j))
            if b.location != NSNotFound, b.location < e.location {
                depth += 1
                j = b.location + b.length
            } else {
                depth -= 1
                if depth == 0 { return (e.location, e.location + e.length) }
                j = e.location + e.length
            }
        }
        return nil
    }

    /// 把環境內容轉成 markdown 清單。\item 依「頂層」切分（巢狀環境內的不算），
    /// 每項先逐行去掉 LaTeX 排版縮排、遞迴轉換巢狀清單，續行縮 4 格掛回本項。
    /// 第一個 \item 之前的內容（如 \begin{enumerate}[(a)] 的選項）一併忽略。
    private static func markdownList(from content: String, ordered: Bool) -> String {
        let ns = content as NSString
        var boundaries: [(afterToken: Int, tokenStart: Int)] = []
        var depth = 0
        listTokenRegex.enumerateMatches(
            in: content, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let tok = ns.substring(with: m.range)
            if tok.hasPrefix("\\begin") {
                depth += 1
            } else if tok.hasPrefix("\\end") {
                depth -= 1
            } else if depth == 0 {
                boundaries.append((m.range.location + m.range.length, m.range.location))
            }
        }
        // 沒有半個 \item：使用者多半直接在環境裡寫了 markdown 式的「1. 2.」清單，
        // 把各層縮排正規化成 0/4/8 格（頂層縮 4 格以上會被 markdown 當 code block）。
        guard !boundaries.isEmpty else { return normalizeMarkdownListIndent(content) }

        var lines: [String] = []
        for (k, b) in boundaries.enumerated() {
            let end = k + 1 < boundaries.count ? boundaries[k + 1].tokenStart : ns.length
            let raw = ns.substring(
                with: NSRange(location: b.afterToken, length: end - b.afterToken))
            var itemLines = raw.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            while itemLines.first?.isEmpty == true { itemLines.removeFirst() }
            while itemLines.last?.isEmpty == true { itemLines.removeLast() }
            let converted = convertListEnvironments(itemLines.joined(separator: "\n"))
            let outLines = converted.components(separatedBy: "\n")
            let marker = ordered ? "\(k + 1). " : "- "
            lines.append(marker + (outLines.first ?? ""))
            for l in outLines.dropFirst() {
                lines.append(l.isEmpty ? "" : "    " + l)
            }
        }
        // 前後各留空行，marked 才會把它當獨立清單解析（就算原本卡在段落中間）
        return "\n\n" + lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - 通用工具（文字環境 / 數學區外替換 / 表格）

    /// 數學區（$$…$$、\begin{env}…\end{env}、\[…\]、\(…\)、$…$）。
    /// 文字類替換用它切段，只動數學區以外的內容。
    private static let mathRegionRegex = try! NSRegularExpression(pattern:
        #"\$\$[\s\S]+?\$\$|\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}|\\\[[\s\S]+?\\\]|\\\([\s\S]+?\\\)|\$[^$\n]+?\$"#)

    /// 只對「數學區以外」的片段套 transform，數學區原樣保留。
    private static func replaceOutsideMath(
        _ text: String, transform: (String) -> String
    ) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        mathRegionRegex.enumerateMatches(
            in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            result += transform(
                ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            result += ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += transform(ns.substring(from: last))
        return result
    }

    /// 把每個 \begin{env}…\end{env} 的「內容」交給 transform（同名巢狀正確配對）；
    /// 沒有對應 \end 的原樣保留。
    private static func replaceEnvironment(
        _ text: String, _ env: String, transform: (String) -> String
    ) -> String {
        let ns = text as NSString
        let n = ns.length
        let beginTok = "\\begin{\(env)}"
        var result = ""
        var i = 0
        while i < n {
            let r = ns.range(of: beginTok, range: NSRange(location: i, length: n - i))
            guard r.location != NSNotFound,
                  let (contentEnd, blockEnd) = matchingEnd(
                    for: env, in: ns, from: r.location + r.length)
            else {
                result += ns.substring(from: i)
                break
            }
            result += ns.substring(with: NSRange(location: i, length: r.location - i))
            let start = r.location + r.length
            result += transform(
                ns.substring(with: NSRange(location: start, length: contentEnd - start)))
            i = blockEnd
        }
        return result
    }

    /// 簡單 tabular → markdown 表格（\\ 分列、& 分欄、\hline/booktabs 線拿掉）。
    /// 有 \multicolumn/\multirow 或巢狀環境就放棄（回傳 nil，原樣保留）。
    private static func tabularToMarkdown(_ raw: String) -> String? {
        var body = raw
        // 去掉開頭的欄位規格 {…}（可含巢狀，如 p{2cm}）
        if let specEnd = leadingBraceGroupEnd(body) {
            body = String(body[specEnd...])
        }
        guard !body.contains("\\begin{"), !body.contains("\\multicolumn"),
              !body.contains("\\multirow") else { return nil }
        for tok in ["\\hline", "\\toprule", "\\midrule", "\\bottomrule"] {
            body = body.replacingOccurrences(of: tok, with: "")
        }
        // \& 先藏起來，切完欄再還原
        body = body.replacingOccurrences(of: "\\&", with: "\u{1}")
        let rows = body.components(separatedBy: "\\\\")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rows.isEmpty else { return nil }
        let cells = rows.map { row in
            row.components(separatedBy: "&").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{1}", with: "&")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
        }
        let cols = cells.map(\.count).max() ?? 1
        func line(_ row: [String]) -> String {
            "| " + (0..<cols).map { $0 < row.count ? row[$0] : "" }
                .joined(separator: " | ") + " |"
        }
        var out = ["", line(cells[0]),
                   "| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |"]
        for row in cells.dropFirst() { out.append(line(row)) }
        out.append("")
        return out.joined(separator: "\n")
    }

    /// 開頭（可有空白）第一個平衡的 {…} 群組結束位置之後的 index；沒有就 nil。
    private static func leadingBraceGroupEnd(_ s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        guard i < s.endIndex, s[i] == "{" else { return nil }
        var depth = 0
        while i < s.endIndex {
            if s[i] == "{" { depth += 1 }
            else if s[i] == "}" {
                depth -= 1
                if depth == 0 { return s.index(after: i) }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// 把 \command{色}{內容} 或 \command[HTML]{RRGGBB}{內容} 換掉（內容可含巢狀大括號）。
    /// 只在數學區外呼叫——公式裡的 \textcolor 由 KaTeX 自己處理。
    private static func replaceColorCommand(
        _ text: String, _ command: String, transform: (String, String) -> String
    ) -> String {
        let ns = text as NSString
        let n = ns.length
        var result = ""
        var i = 0
        while i < n {
            let found = ns.range(of: command, range: NSRange(location: i, length: n - i))
            if found.location == NSNotFound {
                result += ns.substring(from: i)
                break
            }
            result += ns.substring(with: NSRange(location: i, length: found.location - i))
            var j = found.location + found.length
            // 可選的 [HTML] / [RGB] 模式參數
            var model = ""
            if j < n, ns.substring(with: NSRange(location: j, length: 1)) == "[" {
                guard let close = braceEnd(ns, from: j, open: "[", close: "]") else {
                    result += ns.substring(from: found.location); break
                }
                model = ns.substring(with: NSRange(location: j + 1, length: close - j - 2))
                j = close
            }
            // 第一組 {色}
            guard let colorEnd = braceEnd(ns, from: j, open: "{", close: "}") else {
                result += ns.substring(from: found.location); break
            }
            let rawColor = ns.substring(with: NSRange(location: j + 1, length: colorEnd - j - 2))
            // 第二組 {內容}
            guard let innerEnd = braceEnd(ns, from: colorEnd, open: "{", close: "}") else {
                result += ns.substring(from: found.location); break
            }
            let inner = ns.substring(
                with: NSRange(location: colorEnd + 1, length: innerEnd - colorEnd - 2))
            result += transform(cssColor(rawColor, model: model), inner)
            i = innerEnd
        }
        return result
    }

    /// 從 from 位置（必須是 open 字元）找平衡的結尾，回傳「結尾字元的下一個 index」。
    private static func braceEnd(
        _ ns: NSString, from: Int, open: String, close: String
    ) -> Int? {
        guard from < ns.length, ns.substring(with: NSRange(location: from, length: 1)) == open
        else { return nil }
        var depth = 0
        var j = from
        while j < ns.length {
            let c = ns.substring(with: NSRange(location: j, length: 1))
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return nil
    }

    /// LaTeX 顏色 → CSS。xcolor 的基本色名對到相近的 CSS 值；
    /// black/white 改用 CanvasText/Canvas，否則深色模式下會看不見。
    /// 認不得的值只留安全字元（英數與 #），避免把 style 屬性寫壞。
    private static func cssColor(_ raw: String, model: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if model.uppercased() == "HTML" {
            let hex = name.filter { $0.isHexDigit }
            return hex.count == 6 ? "#\(hex)" : "CanvasText"
        }
        if model.uppercased() == "RGB" || model.lowercased() == "rgb" {
            let parts = name.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3 {
                // RGB 模式是 0–255，rgb 模式是 0–1
                let scale = model == "rgb" ? 255.0 : 1.0
                let v = parts.map { Int(max(0, min(255, $0 * scale))) }
                return "rgb(\(v[0]),\(v[1]),\(v[2]))"
            }
            return "CanvasText"
        }
        switch name.lowercased() {
        case "black": return "CanvasText"          // 跟隨主題，深色模式才看得見
        case "white": return "Canvas"
        case "red": return "#e03131"
        case "green": return "#2f9e44"             // xcolor 的 green 是純綠，太亮改用可讀版
        case "blue": return "#1971c2"
        case "cyan": return "#0c8599"
        case "magenta": return "#c2255c"
        case "yellow": return "#e8b100"
        case "orange": return "#e8590c"
        case "purple": return "#9c36b5"
        case "violet": return "#7048e8"
        case "brown": return "#a9713a"
        case "pink": return "#e64980"
        case "olive": return "#5c940d"
        case "teal": return "#0c8599"
        case "lime": return "#66a80f"
        case "gray", "grey": return "#868e96"
        case "darkgray", "darkgrey": return "#495057"
        case "lightgray", "lightgrey": return "#adb5bd"
        default:
            let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "#" }
            return safe.isEmpty ? "CanvasText" : safe
        }
    }

    /// caption 等會直接放進 HTML 的文字：樣式指令轉成 HTML 標籤
    /// （html 區塊內的 markdown 不會被解析，所以不能用 **…**）。
    private static func inlineFormatHTML(_ s: String) -> String {
        var t = unescapeTilde(s.trimmingCharacters(in: .whitespacesAndNewlines))
        t = replaceBalancedCommand(t, "\\textbf") { "<b>\($0)</b>" }
        t = replaceBalancedCommand(t, "\\textit") { "<i>\($0)</i>" }
        t = replaceBalancedCommand(t, "\\emph") { "<i>\($0)</i>" }
        t = replaceBalancedCommand(t, "\\texttt") { "<code>\($0)</code>" }
        return t
    }

    /// 步驟 0.3 把單個 ~ 轉義成 \~ 給 marked 看；但內容若會直接放進 HTML 區塊
    /// （\title、caption…），marked 不處理 HTML 裡的跳脫，反斜線就會露出來 → 還原。
    private static func unescapeTilde(_ s: String) -> String {
        s.replacingOccurrences(of: "\\~", with: "~")
    }

    /// 附錄章節編號：1 → A、2 → B…（超出 26 就退回數字）。
    private static func appendixLetter(_ n: Int) -> String {
        guard n >= 1, n <= 26, let sc = UnicodeScalar(64 + n) else { return "\(n)" }
        return String(Character(sc))
    }

    /// 清單環境裡沒有 \item 時的救援：內容當 markdown 清單，把「出現過的縮排寬度」
    /// 由淺到深映射成第 0/1/2… 層，重寫成每層 4 格；非清單行剝掉縮排讓它以
    /// lazy continuation 掛回上一項。內容完全沒有清單行就原樣還回去。
    private static let markdownListLineRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:\d+[.)]|[-*+])\s"#)

    private static func normalizeMarkdownListIndent(_ content: String) -> String {
        func width(_ line: String) -> Int {
            line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
        let lines = content.components(separatedBy: "\n")
        var isList: [Bool] = []
        var widths = Set<Int>()
        for l in lines {
            let m = markdownListLineRegex.firstMatch(
                in: l, range: NSRange(location: 0, length: (l as NSString).length))
            isList.append(m != nil)
            if m != nil { widths.insert(width(l)) }
        }
        guard !widths.isEmpty else { return content }
        let level = Dictionary(
            uniqueKeysWithValues: widths.sorted().enumerated().map { ($1, $0) })
        var out: [String] = []
        for (i, l) in lines.enumerated() {
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if isList[i] {
                out.append(String(repeating: "    ", count: level[width(l)] ?? 0) + trimmed)
            } else {
                out.append(trimmed)
            }
        }
        // 前後留空行，跟其他轉換結果一樣讓 marked 把它當獨立清單
        return "\n\n" + out.joined(separator: "\n") + "\n\n"
    }

    /// 把 key 轉成可當 HTML id / URL 片段的字串（非 ASCII 英數一律換成 -）。
    private static func anchorID(_ s: String) -> String {
        let alnum = CharacterSet.alphanumerics
        let mapped = s.unicodeScalars.map { sc -> Character in
            (sc.isASCII && alnum.contains(sc)) ? Character(sc) : "-"
        }
        let r = String(mapped)
        return r.isEmpty ? "x" : r
    }

    /// 把 Zotero 文獻排成一行 markdown：作者. *標題*. 期刊. 年份. DOI
    private static func reference(for item: ZoteroItem) -> String {
        var parts: [String] = []
        if !item.authors.isEmpty { parts.append(item.authors) }
        parts.append("*\(item.title)*")
        if let venue = item.data.publicationTitle, !venue.isEmpty { parts.append(venue) }
        if !item.year.isEmpty { parts.append(item.year) }
        var ref = parts.joined(separator: ". ")
        if let doi = item.data.DOI, !doi.isEmpty {
            ref += ". https://doi.org/\(doi)"
        }
        return ref
    }

    /// 替換 \command{...}，大括號用「計數配對」，所以內容可含巢狀大括號與數學
    /// （例如 \footnote{$\frac{a}{b}$}）。command 需含反斜線，例如 "\\footnote"。
    private static func replaceBalancedCommand(
        _ text: String, _ command: String, transform: (String) -> String
    ) -> String {
        let ns = text as NSString
        let needle = command + "{"
        let n = ns.length
        var result = ""
        var i = 0
        while i < n {
            let found = ns.range(of: needle, range: NSRange(location: i, length: n - i))
            if found.location == NSNotFound {
                result += ns.substring(from: i)
                break
            }
            result += ns.substring(with: NSRange(location: i, length: found.location - i))
            // 從 "{" 之後開始數括號，找到對應的 "}"
            var depth = 1
            var j = found.location + found.length
            var content = ""
            while j < n, depth > 0 {
                let ch = ns.substring(with: NSRange(location: j, length: 1))
                if ch == "{" { depth += 1; content += ch }
                else if ch == "}" { depth -= 1; if depth > 0 { content += ch } }
                else { content += ch }
                j += 1
            }
            if depth == 0 {
                result += transform(content)
                i = j
            } else {
                // 沒有對應的右括號 → 原樣保留，停止
                result += ns.substring(from: found.location)
                break
            }
        }
        return result
    }

    /// 依出現順序（左到右）替換符合 pattern 的片段；transform 收到各 capture group 字串。
    private static func replace(
        _ text: String, pattern: String, transform: ([String]) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let full = m.range
            result += ns.substring(with: NSRange(location: last, length: full.location - last))
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = full.location + full.length
        }
        result += ns.substring(from: last)
        return result
    }
}
