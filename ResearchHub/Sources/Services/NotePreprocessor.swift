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

        // 0.5 文字模式清單環境：\begin{enumerate}/\begin{itemize}（可巢狀、\item 可多行）
        //     → markdown 清單。一定要在數學處理「之前」做：KaTeX 不支援這些文字環境，
        //     不先轉換整塊會被預覽端當數學送去 KaTeX，渲染成錯誤。
        text = convertListEnvironments(text)

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
        // 3. \ref{key} → 可點擊的 n
        text = replace(text, pattern: #"\\ref\{([^}]*)\}"#) { groups in
            let key = groups[1].trimmingCharacters(in: .whitespaces)
            guard let n = eqMap[key] else { return "?" }
            return "[\(n)](#eq-\(anchorID(key)))"
        }

        // 3.5 文件抬頭：\title / \subtitle / \author / \date → 置中樣式區塊。
        //（前後一定要留空行，否則 marked 會把 <div> 當成 HTML 區塊，把後面的內容
        //  整段當原始 HTML 吞掉、不再解析 markdown／連結。）
        text = replaceBalancedCommand(text, "\\title") { inner in
            "\n\n<div class=\"rh-head\" style=\"text-align:center;font-size:1.9em;font-weight:700;margin:.3em 0 .1em;\">\(inner)</div>\n\n"
        }
        text = replaceBalancedCommand(text, "\\subtitle") { inner in
            "\n\n<div class=\"rh-head\" style=\"text-align:center;font-size:1.25em;font-weight:500;opacity:.8;margin:0 0 .4em;\">\(inner)</div>\n\n"
        }
        text = replaceBalancedCommand(text, "\\author") { inner in
            "\n\n<div class=\"rh-head\" style=\"text-align:center;opacity:.85;margin:.1em 0;\">\(inner)</div>\n\n"
        }
        text = replaceBalancedCommand(text, "\\date") { inner in
            "\n\n<div class=\"rh-head\" style=\"text-align:center;font-size:.9em;opacity:.7;margin:0 0 .6em;\">\(inner)</div>\n\n"
        }

        // 3.6 章節：\section / \subsection / \subsubsection → 自動編號標題 + 錨點，並收集目錄。
        //（用同一個 pass 才能依出現順序正確編號）
        var secNums = [0, 0, 0]
        var toc: [(level: Int, number: String, title: String, id: String)] = []
        text = replace(text, pattern: #"\\(sub)?(sub)?section\{([^}]*)\}"#) { g in
            let level = (g[1].isEmpty ? 0 : 1) + (g[2].isEmpty ? 0 : 1) + 1
            switch level {
            case 1: secNums[0] += 1; secNums[1] = 0; secNums[2] = 0
            case 2: secNums[1] += 1; secNums[2] = 0
            default: secNums[2] += 1
            }
            let number: String
            switch level {
            case 1: number = "\(secNums[0])"
            case 2: number = "\(secNums[0]).\(secNums[1])"
            default: number = "\(secNums[0]).\(secNums[1]).\(secNums[2])"
            }
            let title = g[3]
            let id = "sec-" + number.replacingOccurrences(of: ".", with: "-")
            toc.append((level, number, title, id))
            let hashes = String(repeating: "#", count: level)
            return "<span id=\"\(id)\"></span>\n\n\(hashes) \(number) \(title)"
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
