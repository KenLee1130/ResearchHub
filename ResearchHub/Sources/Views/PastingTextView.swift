#if os(macOS)
import SwiftUI
import HubCore
import AppKit

/// 左欄源碼編輯器：NSTextView 包裝，Overleaf 式多色語法高亮，
/// 可接收右欄預覽雙擊段落後的跳轉請求（SourceJumpRequest）。
/// 配色：定界符（$、$$、\[、\(）橘、數學內容紫、指令藍、
/// 環境名與指令第一個 {…} 參數綠、標題粗體、checkbox 橘。
/// 支援 Cmd+V 貼上圖片的 NSTextView：圖片交給 onPasteImage 存檔，插入回傳的 markdown。
final class PastingTextView: NSTextView {
    var onPasteImage: ((NSImage) -> String?)?
    /// LaTeX 專案的根目錄。有值時補全會多出專案才有意義的指令，
    /// 以及 \input{ 列檔案、\ref{ 列整個專案的 label 等（見 LatexProjectIndex）。
    var completionRoot: URL?

    /// Shift+Return。LaTeX 專案拿來當「編譯」。
    /// 直接攔 keyDown：AppKit 的標準鍵綁定沒有把 Shift+Return 對到 insertLineBreak:，
    /// 它會跟一般 Return 一樣走 insertNewline:，所以改不了行為。
    var onShiftReturn: (() -> Void)?

    // MARK: - 拖曳選取自己來：拖曳中按的鍵不能掉
    //
    // NSTextView 內建的滑鼠追蹤迴圈一收到按鍵就結束追蹤；用三指拖移時「放開」是系統延後合成的，
    // 使用者常在那個空檔就按下 ⌘C／delete，結果那一下在交接處消失（2026-10-22 紀錄：
    // WindowServer 有送到 app，app 的事件入口卻沒收到；第二下才正常）。
    // 這裡只接手最單純的「單擊拖曳選取」：拖曳中收到的按鍵先存起來，選取完成後再送出去，
    // 所以 ⌘C 會複製到完整的選取、delete 會刪掉完整的選取。雙擊／三擊、Shift 等修飾鍵、
    // 點在既有選取上（可能要拖曳文字）、點到連結、輸入法組字中：維持交給系統。
    override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let sel = selectedRange()
        let onLink = index < (string as NSString).length
            && textStorage?.attribute(.link, at: index, effectiveRange: nil) != nil
        guard event.clickCount == 1, mods.isEmpty, let window, isSelectable, !hasMarkedText(),
              !(sel.length > 0 && NSLocationInRange(index, sel)), !onLink
        else {
            super.mouseDown(with: event)
            return
        }

        if window.firstResponder !== self { window.makeFirstResponder(self) }
        let anchor = index
        setSelectedRange(NSRange(location: anchor, length: 0))
        var dragged = false
        var pendingKeys: [NSEvent] = []
        func range(to i: Int) -> NSRange { NSRange(location: min(anchor, i), length: abs(i - anchor)) }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                           timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
            guard let ev else { stop.pointee = true; return }
            switch ev.type {
            case .leftMouseDragged:
                dragged = true
                autoscroll(with: ev)
                let i = characterIndexForInsertion(at: convert(ev.locationInWindow, from: nil))
                setSelectedRange(range(to: i), affinity: i < anchor ? .upstream : .downstream,
                                 stillSelecting: true)
            case .leftMouseUp:
                let i = characterIndexForInsertion(at: convert(ev.locationInWindow, from: nil))
                setSelectedRange(dragged ? range(to: i) : NSRange(location: anchor, length: 0),
                                 affinity: i < anchor ? .upstream : .downstream, stillSelecting: false)
                stop.pointee = true
            case .keyDown:
                pendingKeys.append(ev)   // 拖曳中按的：等選取完成再送
            default:
                break
            }
        }
        for key in pendingKeys { NSApp.sendEvent(key) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let onShiftReturn,
           event.keyCode == 36,                       // Return
           flags.contains(.shift),
           flags.isDisjoint(with: [.command, .option, .control]),
           !hasMarkedText() {                         // 輸入法組字中不攔
            onShiftReturn()
            return
        }
        super.keyDown(with: event)
    }

    /// 從別的 app 切回來時，第一下點擊就直接放游標、可以馬上打字
    /// （預設行為是第一下只啟動視窗、被吃掉）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { ActiveEditorRegistry.shared.textView = self }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        completionPopup.hide()   // 點到別處時關掉浮動清單
        return super.resignFirstResponder()
    }

    // 浮動清單是掛在視窗上的子視窗：擁有它的編輯器被移除（換版面、換檔案、彈出視窗）時，
    // 如果不主動關，它會一直掛在畫面上，而且再也沒有人會去關它。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            completionPopup.hide()
            if let old = window {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didResignKeyNotification, object: old)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // 切到別的視窗時編輯器本身沒有失去焦點（resignFirstResponder 不會被叫），也要關
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResignedKey(_ note: Notification) {
        completionPopup.hide()
    }

    // MARK: - 剪下／拷貝／貼上／全選：自己接手，不靠選單轉送
    //
    // 使用者回報筆記源碼區選字後 ⌘C 複製不到（2026-09-22），靜態查不出攔截點；
    // 改成文字區是焦點時直接處理這四個快捷鍵後就正常了。

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘/：切換 % 註解。用實體鍵位（44＝/）判斷：注音輸入法下字元不是「/」
        if mods == [.command], event.keyCode == 44 || event.charactersIgnoringModifiers == "/",
           completionRoot != nil, window?.firstResponder === self, !hasMarkedText() {
            // 按住稍久會送出重複按鍵：第二下又把註解拿掉，看起來像沒反應／閃一下
            if !event.isARepeat { toggleLineComments() }
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard mods == [.command], ["c", "x", "v", "a"].contains(key),
              window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        default: selectAll(nil)
        }
        return true
    }

    // MARK: - 自動補全（Overleaf 式浮動清單：不強制插入；方向鍵選、Tab 接受、Esc 關閉）

    /// \begin{} 內可選的環境名稱。
    static let envList: [String] = [
        "equation", "equation*", "align", "align*", "aligned", "gather", "gather*",
        "cases", "split", "multline", "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix",
        "enumerate", "itemize",
        "figure", "table", "tabular", "center", "quote", "quotation", "abstract",
    ]

    private lazy var completionPopup: CompletionPopup = {
        let p = CompletionPopup()
        p.onAccept = { [weak self] item in self?.acceptCompletion(item) }
        return p
    }()
    private var completionRange = NSRange(location: 0, length: 0)
    private var suppressCompletionOnce = false

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
    private func acceptCompletion(_ item: CompletionItem) {
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

    // MARK: - 選取文字後打括號 → 包住（不是取代）

    /// 打這些字元時，若有選取範圍就把選取的文字包起來。
    /// 值是（左, 右）；成對符號打左邊那個就會自動補右邊。
    private static let wrapPairs: [String: (String, String)] = [
        "(": ("(", ")"),
        "[": ("[", "]"),
        "{": ("{", "}"),
        "$": ("$", "$"),
        "（": ("（", "）"),
        "「": ("「", "」"),
        "\"": ("\"", "\""),
    ]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        // 輸入法組字中不攔（中文選字過程也會走 insertText）
        if let typed, let pair = Self.wrapPairs[typed], !hasMarkedText() {
            let target = replacementRange.location != NSNotFound
                ? replacementRange : selectedRange()
            if target.length > 0, target.location != NSNotFound {
                let ns = self.string as NSString
                let selected = ns.substring(with: target)
                let replacement = pair.0 + selected + pair.1
                if shouldChangeText(in: target, replacementString: replacement) {
                    textStorage?.replaceCharacters(in: target, with: replacement)
                    didChangeText()
                    // 選取維持在原本那段文字上（現在位於括號內），可以連續再包一層
                    setSelectedRange(NSRange(
                        location: target.location + (pair.0 as NSString).length,
                        length: (selected as NSString).length))
                }
                return
            }
        }
        if let typed, completionRoot != nil, !hasMarkedText(),
           autoPair(typed, replacementRange: replacementRange) { return }
        super.insertText(string, replacementRange: replacementRange)
        // 打完 \end{name}（自己打 } 或從補全選 \end{} 再填名稱都算）→ 對齊對應的 \begin
        if typed != nil, completionRoot != nil, !hasMarkedText() { alignEndWithBegin() }
    }

    // MARK: - ⌘/ 批量註解（LaTeX 專案）

    /// 選到的行（沒選就是游標那行）切換 % 註解，一步可復原。選取維持在這幾行上。
    func toggleLineComments() {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.location != NSNotFound else { return }
        // 選取剛好停在下一行行首（整行選取的常見情形）→ 那一行不算
        var end = NSMaxRange(sel)
        if sel.length > 0, end > sel.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let block = ns.lineRange(for: NSRange(location: sel.location, length: end - sel.location))
        let old = ns.substring(with: block)
        let new = Self.toggledComments(old)
        guard new != old, shouldChangeText(in: block, replacementString: new) else { return }
        textStorage?.replaceCharacters(in: block, with: new)
        didChangeText()
        // 一般打字是停手 0.25 秒才重新上色；整批改完要馬上上色，不然會先看到沒變色的 %，像卡住
        (delegate as? SourceTextView.Coordinator)?.applyHighlighting(visibleOnly: true)
        let newLength = (new as NSString).length
        if sel.length == 0 {
            // 游標留在同一行、跟著前面多出／少掉的字移動
            let caret = max(block.location, min(block.location + newLength, sel.location + newLength - block.length))
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            let trailing = new.hasSuffix("\n") ? 1 : 0
            setSelectedRange(NSRange(location: block.location, length: newLength - trailing))
        }
    }

    /// 一段完整的行：有一行沒註解 → 全部在最淺縮排處加「% 」；全都是註解 → 全部拿掉「%」（連同後面一個空白）。
    /// 空行不動。
    static func toggledComments(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        func isBlank(_ l: String) -> Bool { l.allSatisfy { $0 == " " || $0 == "\t" } }
        func indent(_ l: String) -> Int { l.prefix { $0 == " " || $0 == "\t" }.count }
        let content = lines.filter { !isBlank($0) }
        guard !content.isEmpty else { return text }
        let allCommented = content.allSatisfy { $0.dropFirst(indent($0)).hasPrefix("%") }
        let out: [String]
        if allCommented {
            out = lines.map { line in
                guard !isBlank(line) else { return line }
                var rest = line.dropFirst(indent(line)).dropFirst()   // 拿掉 %
                if rest.first == " " { rest = rest.dropFirst() }
                return String(line.prefix(indent(line))) + String(rest)
            }
        } else {
            let column = content.map(indent).min() ?? 0
            out = lines.map { line in
                isBlank(line) ? line : String(line.prefix(column)) + "% " + String(line.dropFirst(column))
            }
        }
        return out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    // MARK: - 自動補右括號（LaTeX 專案；Markdown 筆記不做，內文常打半個括號）
    //
    //   ( [ { $  → 補上 ) ] } $，游標停在中間
    //   \( \[ \{ → 補 \) \] \}；\$ 是字面上的錢字號，不補
    //   $|$ 裡再打 $ → $$|$$（行間公式）
    //   右邊緊接著就是要打的那個右括號 → 直接跳過去，不會變成兩個
    //   後面緊接著是字（例如在 word 前面打 (）→ 不補，免得多出一個要刪
    //   空的一對裡按刪除 → 兩個一起刪

    private static let closers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "$": "$"]

    private func character(at i: Int) -> Character? {
        let ns = string as NSString
        guard i >= 0, i < ns.length else { return nil }
        return Character(ns.substring(with: NSRange(location: i, length: 1)))
    }

    /// 處理掉了回傳 true（呼叫端就不再插入原本的字）
    private func autoPair(_ typed: String, replacementRange: NSRange) -> Bool {
        guard typed.count == 1, let c = typed.first else { return false }
        let target = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        guard target.length == 0, target.location != NSNotFound else { return false }
        let loc = target.location
        let prev = character(at: loc - 1), next = character(at: loc)
        let escaped = prev == "\\" && character(at: loc - 2) != "\\"   // \\ 是換行，不算跳脫

        // 右邊就是要打的右括號 → 跳過去
        if [")", "]", "}", "$"].contains(c), next == c, !escaped {
            // 例外：$|$ 裡再打 $ 是要 $$|$$
            if c == "$", prev == "$", character(at: loc - 2) != "$" {
                insert("$$", at: loc, caretOffset: 1)
                return true
            }
            setSelectedRange(NSRange(location: loc + 1, length: 0))
            return true
        }

        guard let closer = Self.closers[c] else { return false }
        // 這一行前面已經有奇數個 $（例如 $x 打到一半）→ 這個 $ 是收尾，不是開新的一對
        if c == "$", !escaped, unescapedDollarCount(beforeLineOf: loc) % 2 == 1 { return false }
        // 後面緊接著字母／數字 → 不補
        if let next, next.isLetter || next.isNumber || next == "\\" { return false }
        if escaped {
            if c == "$" { return false }                      // \$ 字面錢字號
            insert("\(c)\\\(closer)", at: loc, caretOffset: 1)   // \( → \(|\)
            return true
        }
        insert("\(c)\(closer)", at: loc, caretOffset: 1)
        return true
    }

    /// 同一行、loc 之前沒被 \ 跳脫的 $ 有幾個
    private func unescapedDollarCount(beforeLineOf loc: Int) -> Int {
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
        var count = 0, i = lineStart
        while i < loc {
            let ch = ns.character(at: i)
            if ch == 0x5C { i += 2; continue }   // \ 後面那個字不算
            if ch == 0x24 { count += 1 }         // $
            i += 1
        }
        return count
    }

    /// 在 loc 插入 text（一步可復原），游標放在 loc + caretOffset
    private func insert(_ text: String, at loc: Int, caretOffset: Int) {
        let range = NSRange(location: loc, length: 0)
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: loc + caretOffset, length: 0))
    }

    /// 游標在空的一對中間（(|)、\(|\)、$$|$$）→ 回傳要整個刪掉的範圍
    private func emptyPairAroundCaret() -> NSRange? {
        guard completionRoot != nil, !hasMarkedText() else { return nil }
        let sel = selectedRange()
        guard sel.length == 0, sel.location != NSNotFound else { return nil }
        let ns = string as NSString
        let loc = sel.location
        for (open, close) in [("\\(", "\\)"), ("\\[", "\\]"), ("\\{", "\\}"), ("$$", "$$"),
                              ("(", ")"), ("[", "]"), ("{", "}"), ("$", "$")] {
            let o = (open as NSString).length, c = (close as NSString).length
            guard loc - o >= 0, loc + c <= ns.length,
                  ns.substring(with: NSRange(location: loc - o, length: o)) == open,
                  ns.substring(with: NSRange(location: loc, length: c)) == close else { continue }
            return NSRange(location: loc - o, length: o + c)
        }
        return nil
    }

    // MARK: - LaTeX 環境縮排（Overleaf 式）

    /// `loc` 所在那一行開頭的空白（tab／空格）
    private func leadingWhitespace(ofLineAt loc: Int) -> String {
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: min(loc, ns.length), length: 0))
        return String(ns.substring(with: line).prefix { $0 == " " || $0 == "\t" })
    }

    private static let endLineRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)\\end\{([^}]+)\}[ \t]*$"#)

    /// 這一行只有完整的 `\end{name}` 時，縮排改成跟對應的 \begin{name} 一樣。
    /// 名稱還沒打完（找不到同名 \begin）就不動。
    private func alignEndWithBegin() {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret != NSNotFound, caret <= ns.length else { return }
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let lineStr = ns.substring(with: line).trimmingCharacters(in: .newlines)
        let lineNS = lineStr as NSString
        guard let m = Self.endLineRegex.firstMatch(
            in: lineStr, range: NSRange(location: 0, length: lineNS.length)) else { return }
        let current = lineNS.substring(with: m.range(at: 1))
        let name = lineNS.substring(with: m.range(at: 2))
        guard let target = indentOfMatchingBegin(name, before: line.location),
              target != current else { return }
        let region = NSRange(location: line.location, length: (current as NSString).length)
        guard shouldChangeText(in: region, replacementString: target) else { return }
        textStorage?.replaceCharacters(in: region, with: target)
        didChangeText()
        let delta = (target as NSString).length - (current as NSString).length
        setSelectedRange(NSRange(location: max(line.location, caret + delta), length: 0))
    }

    /// 從 `loc` 往前找還沒被關掉的 \begin{name}（同名巢狀會配對），回傳它那一行的縮排。
    /// 註解掉的（同一行 % 之後）不算。
    private func indentOfMatchingBegin(_ name: String, before loc: Int) -> String? {
        let ns = string as NSString
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let re = try? NSRegularExpression(pattern: #"\\(begin|end)\{"# + escaped + #"\}"#)
        else { return nil }
        let matches = re.matches(in: string, range: NSRange(location: 0, length: loc))
        var depth = 0
        for m in matches.reversed() {
            let lineStart = ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location
            let beforeOnLine = ns.substring(with: NSRange(location: lineStart,
                                                          length: m.range.location - lineStart))
            if beforeOnLine.contains("%") { continue }
            if ns.substring(with: m.range(at: 1)) == "end" {
                depth += 1
            } else if depth == 0 {
                return leadingWhitespace(ofLineAt: m.range.location)
            } else {
                depth -= 1
            }
        }
        return nil
    }

    /// LaTeX 專案的 Enter：延續這一行的縮排；剛打開一個環境（\begin{…}，document 除外）再多一層。
    private func insertNewlineKeepingIndent() {
        let ns = string as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: line.location,
                                                length: sel.location - line.location))
        var indent = String(before.prefix { $0 == " " || $0 == "\t" })
        let code = before.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        if code.range(of: #"\\begin\{(?!document\})[^}]+\}"#, options: .regularExpression) != nil,
           !code.contains("\\end{") {
            indent += "\t"
        }
        insertText("\n" + indent, replacementRange: sel)
    }

    private static let imageExtensions: Set<String> =
        ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp", "bmp"]

    /// 宣告可讀圖片類型，否則剪貼簿只有圖片時「貼上」選單會被停用，paste() 不會被呼叫。
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for t in [NSPasteboard.PasteboardType.tiff, .png, .fileURL] where !types.contains(t) {
            types.append(t)
        }
        return types
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // 1. Finder 複製的圖片檔（pasteboard 是 file URL）
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first,
           Self.imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url),
           let markdown = onPasteImage?(image) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }

        // 2. 原始圖片資料（截圖、從 Preview/瀏覽器複製）；有純文字時讓文字優先
        if pb.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pb),
           let markdown = onPasteImage?(image) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }

        super.paste(sender)
    }

    // MARK: - 拖放圖片（從 Finder/瀏覽器把圖片拖到編輯器上即插入）

    /// 輕量檢查：拖進來的是不是圖片（不載入整張圖，draggingUpdated 會一直呼叫）。
    private func hasDroppableImage(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: { Self.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            return true
        }
        let types = pb.types ?? []
        return types.contains(.png) || types.contains(.tiff)
    }

    /// 真正讀出拖進來的圖片（圖片檔可多張）。
    private func droppedImages(_ sender: NSDraggingInfo) -> [NSImage] {
        let pb = sender.draggingPasteboard
        var images: [NSImage] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                if let img = NSImage(contentsOf: url) { images.append(img) }
            }
        }
        if images.isEmpty, let img = NSImage(pasteboard: pb) { images.append(img) }
        return images
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDroppableImage(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasDroppableImage(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hasDroppableImage(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = droppedImages(sender)
        guard !images.isEmpty, onPasteImage != nil else {
            return super.performDragOperation(sender)   // 非圖片 → 交回原本行為（例如拖文字）
        }
        var markdown = ""
        for img in images {
            if let md = onPasteImage?(img) { markdown += md }
        }
        guard !markdown.isEmpty else { return false }

        // 插到滑鼠放開的位置（不是目前游標）
        let point = convert(sender.draggingLocation, from: nil)
        let idx = characterIndexForInsertion(at: point)
        let range = NSRange(location: idx, length: 0)
        if shouldChangeText(in: range, replacementString: markdown) {
            textStorage?.replaceCharacters(in: range, with: markdown)
            didChangeText()
            setSelectedRange(NSRange(location: idx + (markdown as NSString).length, length: 0))
        }
        return true
    }

    // MARK: - Enter 自動接續列表

    /// 匹配行首的列表前綴：bullet（- * +）、todo（- [ ]）、編號（1. / 1)）
    private static let listPrefixRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(?:([-*+])\s+\[[ xX]\]\s+|([-*+])\s+|(\d+)([.)])\s+)"#)

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.location != NSNotFound else {
            super.insertNewline(sender)
            return
        }

        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let lineNS = line as NSString

        guard let match = Self.listPrefixRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: lineNS.length)
        ) else {
            // LaTeX 專案：延續縮排（Markdown 筆記行首縮排會變程式碼區塊，不做）
            if completionRoot != nil, !hasMarkedText() {
                insertNewlineKeepingIndent()
            } else {
                super.insertNewline(sender)
            }
            return
        }

        let prefix = lineNS.substring(with: match.range)
        let rest = lineNS.substring(from: match.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 空項目按 Enter → 移除前綴、結束列表
        if rest.isEmpty {
            let prefixAbsolute = NSRange(location: lineRange.location, length: match.range.length)
            insertText("", replacementRange: prefixAbsolute)
            return
        }

        var newPrefix = prefix
        // todo 接續時一律未勾選
        newPrefix = newPrefix
            .replacingOccurrences(of: "[x]", with: "[ ]")
            .replacingOccurrences(of: "[X]", with: "[ ]")
        // 編號列表遞增
        var renumber: (indent: String, next: Int)?
        if match.range(at: 4).location != NSNotFound,
           let n = Int(lineNS.substring(with: match.range(at: 4))) {
            let indent = lineNS.substring(with: match.range(at: 1))
            let sep = lineNS.substring(with: match.range(at: 5))
            newPrefix = "\(indent)\(n + 1)\(sep) "
            renumber = (indent, n + 2)
        }

        insertText("\n" + newPrefix, replacementRange: sel)
        // 在清單中間插入新項後，後面同層的既有項目依序改號（2. 變 3.、3. 變 4.…）
        if let renumber {
            renumberFollowingItems(indent: renumber.indent, startingAt: renumber.next)
        }
    }

    // MARK: - 編號清單重編（插入 / 刪除 / 升降層級共用）

    /// 把一行解析成編號清單項：回傳（縮排, 數字在行內的範圍, 數字）。
    private func numberedItem(in line: String) -> (indent: String, numRange: NSRange, num: Int)? {
        let lineNS = line as NSString
        guard let m = Self.listPrefixRegex.firstMatch(
                in: line, range: NSRange(location: 0, length: lineNS.length)),
              m.range(at: 4).location != NSNotFound,
              let n = Int(lineNS.substring(with: m.range(at: 4))) else { return nil }
        return (lineNS.substring(with: m.range(at: 1)), m.range(at: 4), n)
    }

    /// 從游標所在行的下一行開始重編（插入新項後用）。
    private func renumberFollowingItems(indent: String, startingAt first: Int) {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret != NSNotFound, caret <= ns.length else { return }
        renumberItems(afterLine: ns.lineRange(for: NSRange(location: caret, length: 0)),
                      indent: indent, startingAt: first)
    }

    /// 從 baseLine 的下一行開始，把同縮排的編號項重編為 first、first+1…。
    /// 更深縮排的行（子清單/續行）跳過；空行或其他內容代表清單結束就停。
    private func renumberItems(afterLine baseLine: NSRange, indent: String, startingAt first: Int) {
        let ns = string as NSString
        var pos = baseLine.location + baseLine.length
        var next = first
        var edits: [(range: NSRange, num: String)] = []
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            let line = ns.substring(with: lr)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            if let it = numberedItem(in: line), it.indent == indent {
                if it.num != next {
                    edits.append((NSRange(location: lr.location + it.numRange.location,
                                          length: it.numRange.length), "\(next)"))
                }
                next += 1
            } else {
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                if leading.count <= indent.count { break }
            }
            pos = lr.location + lr.length
        }
        guard !edits.isEmpty else { return }
        guard shouldChangeText(
            inRanges: edits.map { NSValue(range: $0.range) },
            replacementStrings: edits.map { $0.num }) else { return }
        textStorage?.beginEditing()
        for e in edits.reversed() {   // 由後往前套用，前面的 range 才不會位移
            textStorage?.replaceCharacters(in: e.range, with: e.num)
        }
        textStorage?.endEditing()
        didChangeText()
    }

    /// 從 line 往上找「indent 這一層」最上面的編號項。
    /// 更深縮排的行（子清單/續行）跳過；空行或縮排更淺的其他內容＝清單邊界就停。
    private func topItemLine(from line: NSRange, indent: String) -> (line: NSRange, num: Int)? {
        let ns = string as NSString
        var scan = line
        var top: (line: NSRange, num: Int)?
        if let it = numberedItem(in: ns.substring(with: scan)), it.indent == indent {
            top = (scan, it.num)
        }
        while scan.location > 0 {
            let prev = ns.lineRange(for: NSRange(location: scan.location - 1, length: 0))
            let prevLine = ns.substring(with: prev)
            if let it = numberedItem(in: prevLine), it.indent == indent {
                top = (prev, it.num)
                scan = prev
            } else {
                if prevLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                let leading = prevLine.prefix { $0 == " " || $0 == "\t" }
                if leading.count <= indent.count { break }
                scan = prev
            }
        }
        return top
    }

    /// 重編 line 所在「indent 層」的整串編號：最上面一項的號碼保留，其餘依序遞增。
    private func renumberLevel(around line: NSRange, indent: String) {
        guard let top = topItemLine(from: line, indent: indent) else { return }
        renumberItems(afterLine: top.line, indent: indent, startingAt: top.num + 1)
    }

    /// 從 line 的下一行往下找到第一個「indent 層」編號項，把它改成 first，
    /// 其後同層項目接續重編（升降層級後，留下/新生的子清單從頭編）。
    private func resequenceLevelBelow(_ line: NSRange, indent: String, startingAt first: Int) {
        let ns = string as NSString
        var pos = line.location + line.length
        while pos < ns.length {
            let lr = ns.lineRange(for: NSRange(location: pos, length: 0))
            let l = ns.substring(with: lr)
            if l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            if let it = numberedItem(in: l), it.indent == indent {
                if it.num != first {
                    let r = NSRange(location: lr.location + it.numRange.location,
                                    length: it.numRange.length)
                    guard shouldChangeText(in: r, replacementString: "\(first)") else { return }
                    textStorage?.replaceCharacters(in: r, with: "\(first)")
                    didChangeText()
                }
                let ns2 = string as NSString
                renumberItems(afterLine: ns2.lineRange(for: NSRange(location: lr.location, length: 0)),
                              indent: indent, startingAt: first + 1)
                return
            }
            let leading = l.prefix { $0 == " " || $0 == "\t" }
            if leading.count <= indent.count { return }
            pos = lr.location + lr.length
        }
    }

    // MARK: - 刪除時自動重編

    /// 這次刪除是否跨行（併行/整行刪除才需要重編；行內改字不動編號）。
    private func deletionCrossesLine(backward: Bool) -> Bool {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.location != NSNotFound else { return false }
        if sel.length > 0 { return ns.substring(with: sel).contains("\n") }
        if backward {
            return sel.location > 0 && ns.character(at: sel.location - 1) == 0x0A
        }
        return sel.location < ns.length && ns.character(at: sel.location) == 0x0A
    }

    override func deleteBackward(_ sender: Any?) {
        if let pair = emptyPairAroundCaret(),
           shouldChangeText(in: pair, replacementString: "") {
            textStorage?.replaceCharacters(in: pair, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: pair.location, length: 0))
            return
        }
        let crossed = deletionCrossesLine(backward: true)
        super.deleteBackward(sender)
        if crossed { renumberAfterDeletion() }
    }

    override func deleteForward(_ sender: Any?) {
        let crossed = deletionCrossesLine(backward: false)
        super.deleteForward(sender)
        if crossed { renumberAfterDeletion() }
    }

    override func cut(_ sender: Any?) {
        let sel = selectedRange()
        let crossed = sel.length > 0
            && (string as NSString).substring(with: sel).contains("\n")
        super.cut(sender)
        if crossed { renumberAfterDeletion() }
    }

    private func renumberAfterDeletion() {
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret != NSNotFound, caret <= ns.length else { return }
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        guard let it = numberedItem(in: ns.substring(with: line)) else { return }
        renumberLevel(around: line, indent: it.indent)
    }

    // MARK: - 多行選取的 Tab / Shift-Tab

    /// 選取範圍跨兩行以上時，每一行行首加一個 tab（delta>0）或去掉一層縮排（一個 tab 或最多 4 格空白）。
    /// 空白行不加縮排。整塊一次替換＝一步復原；做完選取擴成完整的那幾行，可以連按。
    /// 選取沒有跨行時回傳 false，交給原本的 Tab 行為（清單升降層／插入 tab）。
    /// `singleLine`：選取沒跨行也照做（只動游標那一行，用於 Shift-Tab）。
    private func shiftSelectedLines(by delta: Int, singleLine: Bool = false) -> Bool {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.location != NSNotFound, NSMaxRange(sel) <= ns.length,
              singleLine || (sel.length > 0 && ns.substring(with: sel).contains("\n"))
        else { return false }
        // 選取結尾剛好在某行行首（整行選到換行為止）→ 那一行不算
        var end = NSMaxRange(sel)
        if end > sel.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let block = ns.lineRange(for: NSRange(location: sel.location, length: end - sel.location))

        let original = ns.substring(with: block)
        let lines = original.components(separatedBy: "\n")
        var changed = false
        let shifted = lines.enumerated().map { index, line -> String in
            // lineRange 含結尾換行，split 後最後一段是空字串，不是一行
            if index == lines.count - 1, line.isEmpty { return line }
            if delta > 0 {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                changed = true
                return "\t" + line
            }
            let remove = line.hasPrefix("\t")
                ? 1 : min(Self.listIndentUnit.count, line.prefix { $0 == " " }.count)
            if remove > 0 { changed = true }
            return String(line.dropFirst(remove))
        }
        guard changed else { return true }   // 全都已在最外層：吃掉按鍵即可
        let replacement = shifted.joined(separator: "\n")
        guard shouldChangeText(in: block, replacementString: replacement) else { return true }
        textStorage?.replaceCharacters(in: block, with: replacement)
        didChangeText()
        // 單行、沒有選取：游標跟著文字左移，不要變成整行選取
        if singleLine, sel.length == 0 {
            let removed = (original as NSString).length - (replacement as NSString).length
            let offset = max(block.location, sel.location - removed)
            setSelectedRange(NSRange(location: offset, length: 0))
            return true
        }
        // 選取保持在這幾行（不含最後的換行，再按一次 Tab 範圍不會往下多吃一行）
        var length = (replacement as NSString).length
        if replacement.hasSuffix("\n") { length -= 1 }
        setSelectedRange(NSRange(location: block.location, length: length))
        return true
    }

    // MARK: - Tab / Shift-Tab 升降清單層級

    private static let listIndentUnit = "    "   // 巢狀清單縮排 4 格（markdown 各層都吃）

    /// 游標所在的清單項升（+1）/降（-1）一層；編號項會重編「離開」與「加入」兩層。
    /// 非清單行回傳 false，維持原本 Tab 行為。
    private func changeListLevel(by delta: Int) -> Bool {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length == 0, sel.location != NSNotFound, sel.location <= ns.length
        else { return false }
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineStr = ns.substring(with: line)
        guard Self.listPrefixRegex.firstMatch(
            in: lineStr,
            range: NSRange(location: 0, length: (lineStr as NSString).length)) != nil
        else { return false }
        let oldIndent = String(lineStr.prefix { $0 == " " || $0 == "\t" })

        if delta > 0 {
            insertText(Self.listIndentUnit,
                       replacementRange: NSRange(location: line.location, length: 0))
        } else {
            let removeLen = oldIndent.hasPrefix("\t")
                ? 1 : min(Self.listIndentUnit.count, oldIndent.prefix { $0 == " " }.count)
            guard removeLen > 0 else { return true }   // 已在最外層：吃掉按鍵即可
            insertText("", replacementRange: NSRange(location: line.location, length: removeLen))
        }

        // 縮排變了，重新取行與縮排
        let ns2 = string as NSString
        let newLine = ns2.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let newLineStr = ns2.substring(with: newLine)
        let newIndent = String(newLineStr.prefix { $0 == " " || $0 == "\t" })

        if let it = numberedItem(in: newLineStr) {
            // 加入的那一層：上面有同層項就接續它重編；沒有就本行從 1 開始、後面接著編
            if let top = topItemLine(from: newLine, indent: newIndent),
               top.line.location != newLine.location {
                renumberItems(afterLine: top.line, indent: newIndent, startingAt: top.num + 1)
            } else {
                if it.num != 1 {
                    let r = NSRange(location: newLine.location + it.numRange.location,
                                    length: it.numRange.length)
                    if shouldChangeText(in: r, replacementString: "1") {
                        textStorage?.replaceCharacters(in: r, with: "1")
                        didChangeText()
                    }
                }
                let ns3 = string as NSString
                let lr = ns3.lineRange(for: NSRange(location: selectedRange().location, length: 0))
                renumberItems(afterLine: lr, indent: newIndent, startingAt: 2)
            }
        }

        // 離開的那一層：升層後外層剩下的項目補位；上面沒有同層項時，下面的從 1 重編
        let ns4 = string as NSString
        let lr = ns4.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        if delta > 0, let top = topItemLine(from: lr, indent: oldIndent) {
            renumberItems(afterLine: top.line, indent: oldIndent, startingAt: top.num + 1)
        } else {
            resequenceLevelBelow(lr, indent: oldIndent, startingAt: 1)
        }
        return true
    }
}
#endif
