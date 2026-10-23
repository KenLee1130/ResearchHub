#if os(macOS)
import SwiftUI
import HubStore
import HubCore
import AppKit

/// PastingTextView：自動補全（Overleaf 式浮動清單）
extension PastingTextView {
    // MARK: - 自動補全（Overleaf 式浮動清單：不強制插入；方向鍵選、Tab 接受、Esc 關閉）

    /// \begin{} 內可選的環境名稱。
    static let envList: [String] = [
        "equation", "equation*", "align", "align*", "aligned", "gather", "gather*",
        "cases", "split", "multline", "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix",
        "enumerate", "itemize",
        "figure", "table", "tabular", "center", "quote", "quotation", "abstract",
    ]


    /// 目前游標所在的補全情境，以及要被取代的「已輸入部分」範圍。
    private func currentContext() -> (kind: CompletionItem.Kind, range: NSRange)? {
        let sel = selectedRange()
        guard sel.length == 0 else { return nil }
        let ns = string as NSString
        let caret = sel.location
        guard caret != NSNotFound, caret <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))

        if let r = before.range(of: #"\\begin\{[^}]*$"#, options: .regularExpression) {
            let len = (String(before[r].dropFirst(7)) as NSString).length     // 去掉 "\begin{"
            return (.env, NSRange(location: caret - len, length: len))
        }
        // \cite{、\citep{、\parencite[p.~3]{… 之內 → 搜尋 Zotero 文獻
        if let r = before.range(of: #"\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{[^}]*$"#,
                                options: .regularExpression) {
            let m = String(before[r])
            if let bi = m.lastIndex(of: "{") {
                var typed = String(m[m.index(after: bi)...])
                // \cite{a, b… 這種逗號清單：只搜最後一個
                if let comma = typed.lastIndex(of: ",") {
                    typed = String(typed[typed.index(after: comma)...])
                    typed = String(typed.drop(while: { $0 == " " }))
                }
                let len = (typed as NSString).length
                return (.cite, NSRange(location: caret - len, length: len))
            }
        }
        // [[ 之內 → 提示要連到的其他筆記
        if let r = before.range(of: #"\[\[([^\]\n|]*)$"#, options: .regularExpression) {
            let len = (String(before[r].dropFirst(2)) as NSString).length     // 去掉 "[["
            return (.noteLink, NSRange(location: caret - len, length: len))
        }
        // \eqref{ 或 \ref{ 內 → 提示本檔已定義的 \label
        if let r = before.range(of: #"\\(?:eq)?ref\{[^}]*$"#, options: .regularExpression) {
            let m = String(before[r])
            if let bi = m.lastIndex(of: "{") {
                let len = (String(m[m.index(after: bi)...]) as NSString).length
                return (.eqref, NSRange(location: caret - len, length: len))
            }
        }
        if let arg = argumentContext(before, caret: caret) { return arg }
        if let r = before.range(of: #"\\[a-zA-Z]*$"#, options: .regularExpression) {
            let len = (String(before[r]) as NSString).length                  // 含反斜線
            return (.command, NSRange(location: caret - len, length: len))
        }
        return nil
    }

    /// 指令參數裡的補全：\input{ 列 .tex、\includegraphics{ 列圖片、\usepackage{ 列套件…
    /// 只在 LaTeX 專案裡才有（Markdown 筆記沒有這些檔案的概念）。
    private func argumentContext(_ before: String, caret: Int) -> (kind: CompletionItem.Kind, range: NSRange)? {
        guard completionRoot != nil else { return nil }
        let rules: [(pattern: String, kind: CompletionItem.Kind)] = [
            (#"\\(?:input|include|includeonly|subfile)\{([^}]*)$"#, .texFile),
            (#"\\includegraphics(?:\[[^\]]*\])?\{([^}]*)$"#, .image),
            (#"\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{([^}]*)$"#, .package),
            (#"\\documentclass(?:\[[^\]]*\])?\{([^}]*)$"#, .docClass),
            (#"\\(?:bibliography|addbibresource)\{([^}]*)$"#, .bibFile),
        ]
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern),
                  let m = re.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
            else { continue }
            var typed = (before as NSString).substring(with: m.range(at: 1))
            // \usepackage{amsmath, ams… 這種逗號清單：只補最後一個
            if rule.kind == .package || rule.kind == .texFile,
               let comma = typed.lastIndex(of: ",") {
                typed = String(typed[typed.index(after: comma)...])
                typed = String(typed.drop(while: { $0 == " " }))
            }
            let len = (typed as NSString).length
            return (rule.kind, NSRange(location: caret - len, length: len))
        }
        return nil
    }

    private func completionItems(_ kind: CompletionItem.Kind, partial: String) -> [CompletionItem] {
        switch kind {
        case .command:
            let p = partial.lowercased()
            let inProject = completionRoot != nil
            var commands = LatexCommandCatalog.all.filter { !$0.projectOnly || inProject }
            if let root = completionRoot {
                // 專案自己定義的指令排最前面：打了一半的通常就是它
                commands = LatexProjectIndex.snapshot(for: root).macros + commands
            }
            var seen = Set<String>()
            return commands
                .filter { $0.insert.lowercased().hasPrefix(p) && seen.insert($0.insert).inserted }
                .prefix(80)
                .map { CompletionItem(display: $0.insert, insert: $0.insert, kind: .command,
                                      detail: $0.detail) }
        case .texFile, .image, .package, .docClass, .bibFile:
            return argumentItems(kind, partial: partial)
        case .env:
            let p = partial.lowercased()
            return Self.envList
                .filter { p.isEmpty || $0.lowercased().hasPrefix(p) }
                .map { CompletionItem(display: $0, insert: $0, kind: .env) }
        case .cite:
            return citeItems(prefix: partial)
        case .eqref:
            return labelItems(prefix: partial)
        case .noteLink:
            return noteLinkItems(prefix: partial)
        }
    }

    /// 指令參數的候選（檔案、套件、文件類別）。
    private func argumentItems(_ kind: CompletionItem.Kind, partial: String) -> [CompletionItem] {
        let q = partial.lowercased()
        let candidates: [String]
        var detail = ""
        switch kind {
        case .package:
            candidates = LatexCommandCatalog.packages
            detail = "套件"
        case .docClass:
            candidates = LatexCommandCatalog.documentClasses
            detail = "文件類別"
        default:
            guard let root = completionRoot else { return [] }
            let snap = LatexProjectIndex.snapshot(for: root)
            switch kind {
            case .texFile: candidates = snap.texFiles; detail = ".tex"
            case .image: candidates = snap.images; detail = "圖片"
            case .bibFile:
                // \bibliography{} 不含副檔名；\addbibresource{} 要含——兩種都給
                candidates = snap.bibFiles.flatMap { [String($0.dropLast(4)), $0] }
                detail = "參考文獻"
            default: candidates = []
            }
        }
        return candidates
            .filter { q.isEmpty || $0.lowercased().contains(q) }
            .prefix(60)
            .map { CompletionItem(display: $0, insert: $0, kind: kind, detail: detail) }
    }

    /// [[ 自動補全：列出所有其他筆記（依名稱／路徑過濾）。
    private func noteLinkItems(prefix: String) -> [CompletionItem] {
        let q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let all = NoteLinkIndex.shared.entries()
        // 名稱若不唯一就插入含資料夾的路徑，避免引用對象有歧義。
        var nameCount: [String: Int] = [:]
        for e in all { nameCount[e.name.lowercased(), default: 0] += 1 }
        var result: [CompletionItem] = []
        for e in all {
            guard q.isEmpty
                || e.name.lowercased().contains(q)
                || e.displayPath.lowercased().contains(q) else { continue }
            let insert = (nameCount[e.name.lowercased()] ?? 0) > 1 ? e.displayPath : e.name
            let display = e.name == e.displayPath ? e.name : "\(e.name)  —  \(e.displayPath)"
            result.append(CompletionItem(display: display, insert: insert, kind: .noteLink))
            if result.count >= 50 { break }
        }
        return result
    }

    /// 掃描整份筆記裡已定義的 \label{...}，供 \eqref/\ref 補全。
    private func labelItems(prefix: String) -> [CompletionItem] {
        let q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let ns = string as NSString
        var seen = Set<String>()
        var result: [CompletionItem] = []
        if let root = completionRoot {
            for key in LatexProjectIndex.snapshot(for: root).labels
            where q.isEmpty || key.lowercased().contains(q) {
                if seen.insert(key).inserted {
                    result.append(CompletionItem(display: key, insert: key, kind: .eqref))
                }
            }
        }
        let re = try? NSRegularExpression(pattern: #"\\label\{([^}]*)\}"#)
        re?.enumerateMatches(in: string, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !seen.contains(key) else { return }
            guard q.isEmpty || key.lowercased().contains(q) else { return }
            seen.insert(key)
            result.append(CompletionItem(display: key, insert: key, kind: .eqref))
        }
        return result
    }

    /// \cite{ 之後打的字就是搜尋：空白分隔的每個關鍵字都要出現在
    /// 作者／標題／年份／期刊裡（順序不拘，例如「pal 2018 modular」）。
    private func citeItems(prefix: String) -> [CompletionItem] {
        let tokens = prefix.lowercased().split(whereSeparator: { $0 == " " || $0 == "\u{3000}" })
        var result: [CompletionItem] = []
        for item in ZoteroStore.shared.items where !item.isStandalonePDF {
            let hay = "\(item.authors) \(item.title) \(item.year) \(item.data.publicationTitle ?? "") \(item.key)"
                .lowercased()
            guard tokens.allSatisfy({ hay.contains($0) }) else { continue }
            let creators = item.data.creators ?? []
            let first = creators.first?.display ?? "（無作者）"
            let authors = creators.count > 1 ? "\(first) et al." : first
            let yr = item.year.isEmpty ? "" : " (\(item.year))"
            result.append(CompletionItem(
                display: "\(authors)\(yr) — \(item.title)", insert: item.key, kind: .cite))
            if result.count >= 50 { break }
        }
        return result
    }

    /// 重新計算情境並更新浮動清單（由選取/輸入變動時呼叫）。
    func updateCompletion() {
        // 輸入法組字中不要重新計算清單（組字暫存會干擾判斷），但開著的要關掉——
        // 以前這裡直接 return，清單會一路卡在畫面上。關清單不影響選字視窗。
        if hasMarkedText() { completionPopup.hide(); return }
        if suppressCompletionOnce { suppressCompletionOnce = false; completionPopup.hide(); return }
        guard let win = window, let ctx = currentContext() else { completionPopup.hide(); return }
        let partial = (string as NSString).substring(with: ctx.range)
        let items = completionItems(ctx.kind, partial: partial)
        var hint: String?
        if ctx.kind == .cite {
            // 清單是 Zotero 的快取：背景跟 Zotero 對一下，有新文獻就重列
            Task { @MainActor [weak self] in
                if await ZoteroStore.shared.refreshIfStale() { self?.updateCompletion() }
            }
        }
        if ctx.kind == .cite, !ZoteroStore.shared.items.isEmpty {
            // 文獻清單一定帶搜尋說明；搜不到也留著（不然看起來像壞掉）
            hint = items.isEmpty
                ? L("找不到符合「\(partial)」的文獻——換個關鍵字（作者、標題、年份）")
                : (partial.isEmpty
                   ? L("直接打字搜尋：作者、標題、年份，空白分隔多個關鍵字")
                   : L("符合 \(items.count) 筆 · ↑↓ 選擇 · Tab 插入"))
        }
        guard !items.isEmpty || hint != nil else { completionPopup.hide(); return }
        completionRange = ctx.range
        let caretRect = firstRect(
            forCharacterRange: NSRange(location: selectedRange().location, length: 0),
            actualRange: nil)
        completionPopup.show(items: items, hint: hint, below: caretRect, parent: win)
    }

    /// 接受一個補全項目。
    func acceptCompletion(_ item: CompletionItem) {
        completionPopup.hide()
        switch item.kind {
        case .command:
            insertText(item.insert, replacementRange: completionRange)
            // 游標放進第一個「空的」{}：\textcolor{red}{} 要停在文字那格，不是顏色名稱前面
            let emptyArg = item.insert.range(of: "{}")?.lowerBound
            if let bi = emptyArg ?? item.insert.firstIndex(of: "{") {
                let after = item.insert.distance(from: item.insert.index(after: bi), to: item.insert.endIndex)
                let loc = selectedRange().location
                setSelectedRange(NSRange(location: max(0, loc - after), length: 0))
                // \begin{}：游標進到 {} 後直接列環境（清單平常只在打字時更新）
                if item.insert == "\\begin{}" { updateCompletion() }
            } else {
                suppressCompletionOnce = true   // 無參數指令，別馬上又跳同一份
            }
        case .cite where completionRoot != nil:
            acceptProjectCite(item)
        case .cite, .eqref, .texFile, .image, .package, .docClass, .bibFile:
            insertText(item.insert, replacementRange: completionRange)
            let loc = selectedRange().location
            let ns = string as NSString
            if loc < ns.length, ns.substring(with: NSRange(location: loc, length: 1)) == "}" {
                setSelectedRange(NSRange(location: loc + 1, length: 0))   // 跳過 } 避免又跳清單
            }
        case .noteLink:
            insertText(item.insert, replacementRange: completionRange)
            let loc = selectedRange().location
            let ns = string as NSString
            // 補上結尾 ]]（若使用者尚未自行輸入），游標移到 ]] 之後。
            let tail = String(ns.substring(from: loc).prefix(2))
            if tail == "]]" {
                setSelectedRange(NSRange(location: min(loc + 2, ns.length), length: 0))
            } else if tail.hasPrefix("]") {
                insertText("]", replacementRange: NSRange(location: loc, length: 0))
            } else {
                insertText("]]", replacementRange: NSRange(location: loc, length: 0))
            }
            suppressCompletionOnce = true
        case .env:
            acceptEnvironment(item.insert)
        }
    }

    /// LaTeX 專案裡選了 Zotero 的文獻：先把它的 BibTeX 寫進專案的 .bib，
    /// 再把 .bib 裡的 key 填進 \cite{}（Markdown 筆記仍用 Zotero key，預覽靠它查文獻）。
    private func acceptProjectCite(_ item: CompletionItem) {
        guard let root = completionRoot,
              let zotero = ZoteroStore.shared.items.first(where: { $0.key == item.insert })
        else {
            insertText(item.insert, replacementRange: completionRange)
            return
        }
        let range = completionRange
        let typed = (string as NSString).substring(with: range)
        Task { @MainActor [weak self] in
            let exported = await ZoteroStore.shared.bibtex(for: zotero)
            let key = LatexBibliography.cite(zotero, in: root, exportedBibtex: exported)
            guard let self else { return }
            // 等 Zotero 回應的這一瞬間使用者又打字了 → 不要硬塞到錯的位置
            let ns = self.string as NSString
            guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == typed else { return }
            // 後面還沒有 } 就一起補上（少了它整份文件會編不過）
            let end = NSMaxRange(range)
            let closed = end < ns.length && ns.substring(with: NSRange(location: end, length: 1)) == "}"
            self.suppressCompletionOnce = true
            self.insertText(closed ? key : key + "}", replacementRange: range)
            if closed {
                let loc = self.selectedRange().location
                self.setSelectedRange(NSRange(location: loc + 1, length: 0))   // 跳到 } 後面
            }
        }
    }

    /// 選了環境名稱：補成 \begin{name} … \end{name}，游標放中間那行。
    private func acceptEnvironment(_ name: String) {
        let ns = string as NSString
        let start = completionRange.location - 7   // "\begin{" 長度
        guard start >= 0 else { insertText(name, replacementRange: completionRange); return }
        var end = completionRange.location + completionRange.length
        if end < ns.length, ns.substring(with: NSRange(location: end, length: 1)) == "}" { end += 1 }
        let region = NSRange(location: start, length: end - start)
        // 內容多一層、\end 對齊 \begin 那一行的縮排
        let indent = leadingWhitespace(ofLineAt: start)
        let head = "\\begin{\(name)}\n" + indent + "\t"
        let replacement = head + "\n" + indent + "\\end{\(name)}"
        guard shouldChangeText(in: region, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: region, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: start + (head as NSString).length, length: 0))
        suppressCompletionOnce = true
    }

    /// 浮動清單可見時攔截方向鍵/Tab/Esc；不可見時 Esc 用來手動叫出清單。
    override func doCommand(by selector: Selector) {
        if completionPopup.isVisible {
            switch selector {
            case #selector(moveUp(_:)): completionPopup.move(by: -1); return
            case #selector(moveDown(_:)): completionPopup.move(by: 1); return
            case #selector(insertTab(_:)): completionPopup.acceptSelected(); return
            case #selector(cancelOperation(_:)): completionPopup.hide(); return
            default: break
            }
        } else if selector == #selector(cancelOperation(_:)) {
            updateCompletion()   // Esc：手動叫出我們的清單（而非系統補全）
            return
        }
        // 選取跨多行時 Tab / Shift-Tab＝整塊縮排／取消縮排（像一般程式編輯器）
        if selector == #selector(insertTab(_:)), shiftSelectedLines(by: 1) { return }
        if selector == #selector(insertBacktab(_:)), shiftSelectedLines(by: -1) { return }
        // Tab / Shift-Tab：游標在清單項上時升降層級（編號會跟著兩層重編）
        if selector == #selector(insertTab(_:)), changeListLevel(by: 1) { return }
        if selector == #selector(insertBacktab(_:)), changeListLevel(by: -1) { return }
        // 其他行的 Shift-Tab：游標所在那一行退一層縮排
        if selector == #selector(insertBacktab(_:)), shiftSelectedLines(by: -1, singleLine: true) { return }
        super.doCommand(by: selector)
    }
}
#endif

