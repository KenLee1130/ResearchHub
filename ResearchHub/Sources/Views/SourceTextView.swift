#if os(macOS)
import SwiftUI
import AppKit

/// 記住最後取得焦點的 markdown 編輯器，讓「插入引用」能把 \cite{...} 插到游標處
/// （即使焦點已移到引用挑選視窗，selectedRange 仍保留）。
final class ActiveEditorRegistry {
    static let shared = ActiveEditorRegistry()
    weak var textView: NSTextView?

    /// 把文字插到目前作用中的編輯器游標處（取代選取範圍）。
    func insert(_ string: String) {
        guard let tv = textView else { return }
        tv.insertText(string, replacementRange: tv.selectedRange())
    }
}

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
            if let bi = item.insert.firstIndex(of: "{") {
                let after = item.insert.distance(from: item.insert.index(after: bi), to: item.insert.endIndex)
                let loc = selectedRange().location
                setSelectedRange(NSRange(location: max(0, loc - after), length: 0))
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
            let key = await LatexBibliography.cite(zotero, in: root)
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
        let head = "\\begin{\(name)}\n\t"
        let replacement = head + "\n\\end{\(name)}"
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
        // Tab / Shift-Tab：游標在清單項上時升降層級（編號會跟著兩層重編）
        if selector == #selector(insertTab(_:)), changeListLevel(by: 1) { return }
        if selector == #selector(insertBacktab(_:)), changeListLevel(by: -1) { return }
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
        super.insertText(string, replacementRange: replacementRange)
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
            super.insertNewline(sender)
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

// （ScrollSync 移到 Services/WebResources.swift，iOS 版共用）

/// 跳到某一行的一次性請求（編譯錯誤清單點過來）。
struct LineJumpRequest: Equatable {
    let id = UUID()
    let line: Int
}

/// 右欄預覽雙擊段落 → 左欄源碼跳轉的一次性請求（id 變了才執行，避免重複觸發）。
struct SourceJumpRequest: Equatable {
    let id = UUID()
    let sync: ScrollSync
}

struct SourceTextView: NSViewRepresentable {
    /// 只是為了讓主題切換時 SwiftUI 會重跑 updateNSView（底色在那裡套用）
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.ambient.rawValue

    @Binding var text: String
    var fontSize: CGFloat = 14
    var jump: SourceJumpRequest?
    var lineJump: LineJumpRequest?
    var onPasteImage: ((NSImage) -> String?)?
    /// Shift+Return 要做的事（LaTeX 專案＝編譯）。沒給就是原本的插入軟換行。
    var onShiftReturn: (() -> Void)?
    /// LaTeX 專案根目錄（補全會多出專案才有的指令與檔案）；Markdown 筆記是 nil
    var projectRoot: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 編輯器底色。這是全 app 唯一自己畫底色的 view：
    /// 系統預設的 textBackgroundColor 在深色模式是 #1E1E1E，跟墨黑主題的面板亮度太接近，
    /// 兩塊會糊在一起，所以墨黑主題改用最深的那一層（#08080A），周圍的面板自然浮起來。
    /// 內文顏色。純白（labelColor）壓在近黑底上會有光暈，墨黑主題降一點亮度。
    static var bodyTextColor: NSColor {
        AppTheme.current == .ink ? NSColor(InkPalette.textPrimary) : .labelColor
    }

    static func applyTheme(to textView: NSTextView, scrollView: NSScrollView) {
        let ink = AppTheme.current == .ink
        let background: NSColor = ink ? NSColor(InkPalette.editor) : .textBackgroundColor
        textView.drawsBackground = true
        textView.backgroundColor = background
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        // 游標在近黑底上要亮一點才看得到
        textView.insertionPointColor = ink ? NSColor(InkPalette.textPrimary) : .textColor
    }

    /// 欄寬規則見 AdaptiveSizing.swift：給多少就用多少，不用內容的寬度撐大欄位
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PastingTextView()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textView.onPasteImage = onPasteImage
        textView.onShiftReturn = onShiftReturn
        textView.completionRoot = projectRoot
        // 接受從 Finder/瀏覽器拖進來的圖片檔與圖片資料（保留原本已註冊的型別）。
        textView.registerForDraggedTypes(
            Array(Set(textView.registeredDraggedTypes + [.fileURL, .png, .tiff])))
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // 關掉系統補全；改用自己的浮動清單（CompletionPopup，由 updateCompletion 驅動）。
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.string = text
        Self.applyTheme(to: textView, scrollView: scrollView)

        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()
        // 切回 app 時自動把焦點還給編輯器（不必先點一下才能打字）
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        // 捲到還沒上色的區域時補色（visibleOnly 模式只上可視區）
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.viewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? PastingTextView else { return }
        tv.onPasteImage = onPasteImage
        tv.onShiftReturn = onShiftReturn
        tv.completionRoot = projectRoot
        Self.applyTheme(to: tv, scrollView: nsView)
        var needsHighlight = false
        // hasMarkedText = 輸入法（注音/拼音等）正在組字：此時 tv.string 含組字暫存、
        // binding 還是舊值，若在這裡回寫會把組字狀態整個抹掉（中文打到一半跳掉）。
        if tv.string != text && !context.coordinator.isEditing && !tv.hasMarkedText() {
            tv.string = text
            // 內容被整份換掉（換檔案、iCloud 同步進來、外部附加文字）：
            // 舊的 undo 動作記的是舊內容的位置，留著的話 ⌘Z 會把上一個檔案的編輯
            // 套到新內容上，甚至超出範圍當掉——一律清空。
            context.coordinator.editorUndo.removeAllActions()
            needsHighlight = true
        }
        if context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastFontSize = fontSize
            needsHighlight = true
        }
        if needsHighlight {
            context.coordinator.applyHighlighting()
        }
        if let jump, jump.id != context.coordinator.lastJumpID {
            context.coordinator.lastJumpID = jump.id
            context.coordinator.jump(to: jump.sync)
        }
        if let lineJump, lineJump.id != context.coordinator.lastLineJumpID {
            context.coordinator.lastLineJumpID = lineJump.id
            context.coordinator.jump(toLine: lineJump.line)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextView
        weak var textView: NSTextView?

        /// 這個編輯器自己的 undo 堆疊。
        ///
        /// NSTextView 預設把可復原動作登記在「整個視窗共用」的 undo 堆疊，而且不保留自己。
        /// 編輯器被換掉（換檔案類型、切版面、關專案）之後，堆疊裡還留著指向舊編輯器的動作，
        /// 一按 ⌘Z 就去呼叫已釋放的物件 → 閃退（2026-09-25 EXC_BAD_ACCESS in popAndInvoke）。
        /// 自己擁有一份，壽命就跟著編輯器走；編輯器不在了，⌘Z 也碰不到它的動作。
        let editorUndo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }
        var isEditing = false
        var lastFontSize: CGFloat
        var lastJumpID: UUID?
        var lastLineJumpID: UUID?
        /// 各「標題」行的字元起點（供跳轉對位；隨文字變動由 applyHighlighting 重算）。
        private var anchorCharIndices: [Int] = []
        /// 各 \footnote{...} 的內容範圍（跳轉對位用，順序 = 預覽端的註腳編號）。
        private var footnoteRanges: [NSRange] = []
        /// 反白閃爍的世代計數（新的跳轉會取消上一次的移除排程）。
        private var flashGeneration = 0

        init(_ parent: SourceTextView) {
            self.parent = parent
            self.lastFontSize = parent.fontSize
        }

        private var highlightWork: DispatchWorkItem?

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
            scheduleHighlight()
        }

        /// 打字中的重新上色延後到停手（0.25s），而且只套可視區
        /// （visibleOnly；全文套用會在長筆記造成捲動位置跳動）。
        private func scheduleHighlight() {
            highlightWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                self?.applyHighlighting(visibleOnly: true)
            }
            highlightWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }

        /// 選取/輸入變動時更新浮動補全清單（涵蓋打字時游標移動）。
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let pv = textView as? PastingTextView else { return }
            DispatchQueue.main.async { [weak pv] in pv?.updateCompletion() }
        }

        /// 跳到第 line 行（1 起算）：選取整行、捲到中間、閃一下。
        func jump(toLine line: Int) {
            guard let tv = textView, let sv = tv.enclosingScrollView,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let ns = tv.string as NSString
            var index = 0, current = 1
            var range = NSRange(location: 0, length: 0)
            while index < ns.length {
                let r = ns.lineRange(for: NSRange(location: index, length: 0))
                if current == line { range = r; break }
                index = r.location + r.length
                current += 1
            }
            guard range.length > 0 || current == line else { return }
            let trimmed = NSRange(
                location: range.location,
                length: max(0, range.length - (ns.substring(with: range).hasSuffix("\n") ? 1 : 0)))
            tv.setSelectedRange(trimmed)
            tv.window?.makeFirstResponder(tv)
            flash(trimmed)
            let gr = lm.glyphRange(forCharacterRange: trimmed, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
            let inset = tv.textContainerInset.height
            let maxOffset = max(0, tv.bounds.height - sv.contentView.bounds.height)
            let centered = rect.midY + inset - sv.contentView.bounds.height / 2
            scroll(sv, to: max(0, min(maxOffset, centered)))
        }

        /// 右欄預覽雙擊 → 優先在對應的源碼區段（錨點段或第 n 個 \footnote{...}）
        /// 選到同一個字（選取 + 聚焦 + 置中），並反白對應的區域；
        /// 找不到字（如雙擊到公式）時退回位置跳轉 + 反白整段。
        func jump(to sync: ScrollSync) {
            guard let tv = textView, let sv = tv.enclosingScrollView,
                  let lm = tv.layoutManager else { return }
            let inset = tv.textContainerInset.height
            let ns = tv.string as NSString
            let chars = anchorCharIndices.filter { $0 < ns.length }
            let maxOffset = max(0, tv.bounds.height - sv.contentView.bounds.height)

            // 對應的源碼區段：註腳 → 第 n 個 \footnote{...} 的內容；否則錨點段
            var segment: NSRange?
            if sync.fn > 0 {
                if sync.fn <= footnoteRanges.count {
                    segment = footnoteRanges[sync.fn - 1]
                }
            } else if !chars.isEmpty, chars.count == sync.count {
                let start = sync.anchor >= 0 && sync.anchor < chars.count
                    ? chars[sync.anchor] : 0
                let end = sync.anchor + 1 < chars.count ? chars[sync.anchor + 1] : ns.length
                segment = NSRange(location: start, length: max(0, end - start))
            } else if chars.isEmpty, sync.count == 0 {
                segment = NSRange(location: 0, length: ns.length)   // 短筆記：全篇當一段
            }

            // 1) 選字模式：在區段裡找第 occ 次出現的字 → 選取 + 聚焦 + 置中 + 反白所在段落
            if !sync.word.isEmpty, let seg = segment, seg.length > 0 {
                let segEnd = seg.location + seg.length
                var found = NSRange(location: NSNotFound, length: 0)
                var remaining = sync.occ
                var loc = seg.location
                while loc < segEnd {
                    let r = ns.range(
                        of: sync.word, options: [],
                        range: NSRange(location: loc, length: segEnd - loc))
                    if r.location == NSNotFound { break }
                    found = r   // occ 超過段內出現次數時就用最後一個
                    if remaining == 0 { break }
                    remaining -= 1
                    loc = r.location + 1
                }
                if found.location != NSNotFound, let tc = tv.textContainer {
                    tv.setSelectedRange(found)
                    tv.window?.makeFirstResponder(tv)
                    flash(sync.fn > 0 ? seg : blockRange(around: found, in: ns, limit: seg))
                    let gr = lm.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
                    let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
                    let centered = rect.midY + inset - sv.contentView.bounds.height / 2
                    scroll(sv, to: max(0, min(maxOffset, centered)))
                    return
                }
            }

            // 2) 註腳但沒選到字：跳到該 \footnote 置中並反白
            if sync.fn > 0, let seg = segment {
                flash(seg)
                let gi = lm.glyphIndexForCharacter(at: min(seg.location, max(0, ns.length - 1)))
                let r = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                let centered = r.midY + inset - sv.contentView.bounds.height / 2
                scroll(sv, to: max(0, min(maxOffset, centered)))
                return
            }

            // 3) 位置模式：各錨點行目前的 Y（用當前版面算，所以縮放/改寬度也對）
            var ys: [CGFloat] = []
            for ci in chars {
                let gi = lm.glyphIndexForCharacter(at: ci)
                let r = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                ys.append(r.minY + inset)
            }
            var target: CGFloat
            if !ys.isEmpty, ys.count == sync.count {
                if sync.anchor < 0 {
                    target = sync.local * ys[0]
                } else if sync.anchor >= ys.count - 1 {
                    target = ys[ys.count - 1]
                        + sync.local * max(0, maxOffset - ys[ys.count - 1])
                } else {
                    target = ys[sync.anchor]
                        + sync.local * (ys[sync.anchor + 1] - ys[sync.anchor])
                }
                if let seg = segment { flash(seg) }   // 反白對應的錨點段
            } else {
                target = sync.global * maxOffset      // 錨點對不上：只捲動，不反白
            }
            scroll(sv, to: max(0, min(maxOffset, target)))
        }

        /// found 所在的「段落」：往前後找空行（\n\n）邊界，不超出 limit。
        private func blockRange(around r: NSRange, in ns: NSString, limit: NSRange) -> NSRange {
            var start = limit.location
            var end = limit.location + limit.length
            let beforeLen = max(0, r.location - start)
            let before = ns.range(
                of: "\n\n", options: .backwards,
                range: NSRange(location: start, length: beforeLen))
            if before.location != NSNotFound { start = before.location + 2 }
            let afterStart = min(r.location + r.length, end)
            let after = ns.range(
                of: "\n\n",
                range: NSRange(location: afterStart, length: max(0, end - afterStart)))
            if after.location != NSNotFound { end = after.location }
            return NSRange(location: start, length: max(0, end - start))
        }

        /// 短暫反白一段源碼（暫時屬性，不動 textStorage、不進 undo），約 1.4 秒後淡出。
        private func flash(_ range: NSRange) {
            guard let tv = textView, let lm = tv.layoutManager, range.length > 0 else { return }
            let ns = tv.string as NSString
            let safe = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
            guard safe.length > 0 else { return }
            flashGeneration += 1
            let gen = flashGeneration
            lm.addTemporaryAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.22),
                forCharacterRange: safe)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                guard let self, self.flashGeneration == gen,
                      let tv = self.textView, let lm = tv.layoutManager else { return }
                let len = (tv.string as NSString).length
                lm.removeTemporaryAttribute(
                    .backgroundColor, forCharacterRange: NSRange(location: 0, length: len))
            }
        }

        private func scroll(_ sv: NSScrollView, to y: CGFloat) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            } completionHandler: {
                sv.reflectScrolledClipView(sv.contentView)
            }
        }

        /// 掃描捲動同步的錨點：各「標題」(\title/\subtitle/\author/\date/\section… 與 markdown #)
        /// 的行起點，外加每個「顯示型數學區塊」($$…$$ / \[…\] / \begin{env}…\end{env}) 的起點。
        /// 公式多的長段落（例如一段裡夾好幾條方程式）也因此有細錨點，左右才對得準。
        /// \footnote{…} 內的內容排除（預覽端把它搬到文末，位置對不上）。
        private func recomputeAnchors() {
            guard let tv = textView else {
                anchorCharIndices = []; footnoteRanges = []; return
            }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            footnoteRanges = Self.balancedArgRanges("\\footnote", in: ns)
            let fnRanges = footnoteRanges
            func insideFootnote(_ loc: Int) -> Bool {
                fnRanges.contains { NSLocationInRange(loc, $0) }
            }
            var idx: [Int] = []
            Self.anchorLineRegex.enumerateMatches(in: tv.string, range: full) { m, _, _ in
                if let m, !insideFootnote(m.range.location) { idx.append(m.range.location) }
            }
            Self.mathBlockRegex.enumerateMatches(in: tv.string, range: full) { m, _, _ in
                if let m, !insideFootnote(m.range.location) { idx.append(m.range.location) }
            }
            anchorCharIndices = idx.sorted()
        }

        /// \command{...} 的「內容」範圍清單（大括號計數配對，巢狀也正確）。
        private static func balancedArgRanges(_ command: String, in ns: NSString) -> [NSRange] {
            var ranges: [NSRange] = []
            let needle = command + "{"
            let n = ns.length
            let open = UInt16(UnicodeScalar("{").value)
            let close = UInt16(UnicodeScalar("}").value)
            var i = 0
            while i < n {
                let f = ns.range(of: needle, range: NSRange(location: i, length: n - i))
                if f.location == NSNotFound { break }
                var depth = 1
                var j = f.location + f.length
                while j < n, depth > 0 {
                    let c = ns.character(at: j)
                    if c == open { depth += 1 } else if c == close { depth -= 1 }
                    j += 1
                }
                guard depth == 0 else { break }
                let start = f.location + f.length
                ranges.append(NSRange(location: start, length: j - 1 - start))
                i = j
            }
            return ranges
        }

        // MARK: - Patterns

        /// 數學區域。enumerate 時用同樣的順序判斷定界符長度。
        private static let mathPatterns: [(regex: NSRegularExpression, delim: Int)] = {
            let sources: [(String, Int)] = [
                (#"\$\$[\s\S]+?\$\$"#, 2),
                (#"\\\[[\s\S]+?\\\]"#, 2),
                (#"\\\([\s\S]+?\\\)"#, 2),
                (#"\$[^$\n]+?\$"#, 1)
            ]
            return sources.compactMap { (src, d) in
                guard let re = try? NSRegularExpression(pattern: src) else { return nil }
                return (re, d)
            }
        }()

        /// begin/end 環境整塊（內容上紫色，之後指令/參數再覆蓋）。
        /// enumerate/itemize 是文字清單環境（預覽端轉成 markdown 清單），不算數學。
        private static let envBlockPattern = try! NSRegularExpression(
            pattern: #"\\begin\{(?!enumerate\}|itemize\}|figure\}|table\}|tabular\}|center\}|quote\}|quotation\}|abstract\})([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}"#)

        private static let commandPattern = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+"#)

        /// 指令後的第一個 {…} 參數（含 \begin{env}、\label{...}、\text{...} 等），group 1 = 參數內容。
        private static let argPattern = try! NSRegularExpression(
            pattern: #"\\[a-zA-Z]+(?:\[[^\]\n]*\])?\{([^{}\n]*)\}"#)

        private static let headerPattern = try! NSRegularExpression(
            pattern: #"^#{1,6}[^\n]*$"#, options: [.anchorsMatchLines])
        private static let boldPattern = try! NSRegularExpression(pattern: #"\*\*[^*\n]+\*\*"#)
        /// [[筆記]] 互相引用標記
        private static let wikiLinkPattern = try! NSRegularExpression(pattern: #"\[\[[^\]\n]+\]\]"#)
        private static let taskPattern = try! NSRegularExpression(
            pattern: #"^\s*- \[[ xX]\]"#, options: [.anchorsMatchLines])
        /// 捲動同步的「標題」錨點：markdown # 或 \title/\subtitle/\author/\date/\section…
        private static let anchorLineRegex = try! NSRegularExpression(
            pattern: #"^[ \t]*(?:#{1,6}\s|\\(?:title|subtitle|author|date|subsubsection|subsection|section|subparagraph|paragraph)\*?\{)"#,
            options: [.anchorsMatchLines])
        /// 顯示型數學區塊（每塊對到預覽裡一個 .katex-display），當作捲動同步的細錨點。
        /// enumerate/itemize 在預覽端渲染成清單而非 .katex-display，要排除，否則左右錨點數對不上。
        private static let mathBlockRegex = try! NSRegularExpression(
            pattern: #"\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\begin\{(?!enumerate\}|itemize\}|figure\}|table\}|tabular\}|center\}|quote\}|quotation\}|abstract\})([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}"#)

        // MARK: - Colors (Overleaf-ish, adapts to dark mode)

        private enum Palette {
            static let delimiter = NSColor.systemOrange
            static let mathBody = NSColor.systemPurple
            static let command = NSColor.systemBlue
            static let argument = NSColor.systemGreen
            static let task = NSColor.systemOrange
            static let wikiLink = NSColor.systemTeal
        }

        // MARK: - Highlighting

        /// 上次上色套用的視窗（判斷捲動後要不要補色）。
        private var lastHighlightWindow = NSRange(location: 0, length: 0)

        /// 目前可視範圍對應的字元區間；margin 為上下加的 overscan（以視窗高為單位）。
        private func visibleCharRange(_ tv: NSTextView, margin: CGFloat) -> NSRange? {
            guard let lm = tv.layoutManager, let tc = tv.textContainer,
                  let sv = tv.enclosingScrollView else { return nil }
            var rect = sv.documentVisibleRect
            rect.origin.y -= tv.textContainerInset.height + rect.height * margin
            rect.size.height += rect.height * margin * 2
            let glyphs = lm.glyphRange(forBoundingRect: rect, in: tc)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard chars.length > 0 || chars.location == 0 else { return nil }
            return (tv.string as NSString).lineRange(for: chars)
        }

        /// 語法上色。visibleOnly = true 時 regex 仍掃全文（跨行的 $$/環境配對才正確），
        /// 但屬性只套在可視區 ± 一個視窗高：長筆記整份 setAttributes 會讓 layout
        /// 全域失效、文件高度暫時用估計值，捲動位置被夾走——在文件底部打字時
        /// 就是上下亂跳的根因。侷限套用範圍後，可視區以上的版面完全不動。
        func applyHighlighting(visibleOnly: Bool = false) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let size = parent.fontSize
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            let window = visibleOnly
                ? (visibleCharRange(tv, margin: 1) ?? full)
                : full
            guard window.length > 0 || full.length == 0 else { return }
            lastHighlightWindow = window
            let baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)

            func clipped(_ r: NSRange) -> NSRange? {
                let c = NSIntersectionRange(r, window)
                return c.length > 0 ? c : nil
            }

            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: SourceTextView.bodyTextColor
            ], range: window)

            // Markdown 結構
            apply(Self.headerPattern, in: storage, range: full, clipTo: window) {
                [.font: boldFont]
            }
            apply(Self.boldPattern, in: storage, range: full, clipTo: window) {
                [.font: boldFont]
            }
            apply(Self.taskPattern, in: storage, range: full, clipTo: window) {
                [.foregroundColor: Palette.task]
            }
            apply(Self.wikiLinkPattern, in: storage, range: full, clipTo: window) {
                [.foregroundColor: Palette.wikiLink]
            }

            // 長文字指令（\footnote/\title/\section…）的內容先整段上參數綠；大括號用計數配對，
            // 所以巢狀（如 \frac{}{}）也不會壞。放在數學之前，數學區段稍後會被蓋回數學色。
            for name in Self.proseArgCommands {
                highlightBalancedArg("\\" + name, in: storage,
                                     color: Palette.argument, clipTo: window)
            }

            // 數學區域：內容紫 + 定界符橘
            for (regex, delim) in Self.mathPatterns {
                regex.enumerateMatches(in: tv.string, range: full) { match, _, _ in
                    guard let r = match?.range, r.length >= delim * 2 else { return }
                    if let c = clipped(r) {
                        storage.addAttribute(.foregroundColor, value: Palette.mathBody, range: c)
                    }
                    if let c = clipped(NSRange(location: r.location, length: delim)) {
                        storage.addAttribute(.foregroundColor, value: Palette.delimiter, range: c)
                    }
                    if let c = clipped(
                        NSRange(location: r.location + r.length - delim, length: delim)) {
                        storage.addAttribute(.foregroundColor, value: Palette.delimiter, range: c)
                    }
                }
            }

            // begin/end 環境整塊內容上紫
            apply(Self.envBlockPattern, in: storage, range: full, clipTo: window) {
                [.foregroundColor: Palette.mathBody]
            }

            // 指令藍（含數學內的指令）
            apply(Self.commandPattern, in: storage, range: full, clipTo: window) {
                [.foregroundColor: Palette.command]
            }

            // 指令第一個 {…} 參數內容綠（\begin{align}、\text{aff}、\label{...}）
            Self.argPattern.enumerateMatches(in: tv.string, range: full) { match, _, _ in
                guard let m = match, m.numberOfRanges > 1 else { return }
                // 長文字指令上面已用計數配對處理；這裡略過，免得蓋掉裡面的數學色。
                let name = String(ns.substring(with: m.range).dropFirst().prefix { $0.isLetter })
                if Self.proseArgCommands.contains(name) { return }
                if let c = clipped(m.range(at: 1)) {
                    storage.addAttribute(.foregroundColor, value: Palette.argument, range: c)
                }
            }

            storage.endEditing()
            recomputeAnchors()   // 文字/版面變了 → 更新捲動同步的標題位置
        }

        // 捲動後補色：可視區露出「上次視窗」以外的區域才重上（debounce 0.12s）。
        private var scrollWork: DispatchWorkItem?

        /// app 回到前景：焦點「完全沒落在任何東西上」時，才還給編輯器。
        /// 以前的條件是「不是 NSTextView 就搶」，但右欄預覽是 WKWebView：
        /// 從別的 app 切回來在預覽裡選字，焦點會被搶回左欄，⌘C 就複製不到。
        @objc func appBecameActive() {
            DispatchQueue.main.async { [weak self] in
                guard let tv = self?.textView, let win = tv.window, win.isKeyWindow,
                      nothingFocused(in: win) else { return }
                win.makeFirstResponder(tv)
            }
        }

        @objc func viewDidScroll(_ note: Notification) {
            scrollWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.rehighlightIfNeeded() }
            scrollWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        }

        private func rehighlightIfNeeded() {
            guard let tv = textView,
                  let visible = visibleCharRange(tv, margin: 0) else { return }
            if NSIntersectionRange(visible, lastHighlightWindow).length == visible.length {
                return   // 可視區還在上次上色的範圍內
            }
            applyHighlighting(visibleOnly: true)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// 長文字指令（內容可能含巢狀大括號或數學）的清單。
        private static let proseArgCommands: Set<String> =
            ["footnote", "title", "subtitle", "author", "date",
             "section", "subsection", "subsubsection",
             "paragraph", "subparagraph", "caption",
             "textbf", "textit", "emph", "texttt", "underline", "textsc"]

        /// 把 \command{...} 的內容上色，大括號用計數配對，巢狀（\frac{}{} 等）也不會壞。
        /// 只在 clipTo 範圍內實際套屬性（掃描仍走全文以保持配對正確）。
        private func highlightBalancedArg(
            _ command: String, in storage: NSTextStorage, color: NSColor, clipTo: NSRange
        ) {
            let ns = storage.string as NSString
            let needle = command + "{"
            let n = ns.length
            let open = UInt16(UnicodeScalar("{").value)
            let close = UInt16(UnicodeScalar("}").value)
            var i = 0
            while i < n {
                let found = ns.range(of: needle, range: NSRange(location: i, length: n - i))
                if found.location == NSNotFound { break }
                var depth = 1
                var j = found.location + found.length
                let contentStart = j
                while j < n, depth > 0 {
                    let c = ns.character(at: j)
                    if c == open { depth += 1 } else if c == close { depth -= 1 }
                    j += 1
                }
                if depth == 0 {
                    let len = (j - 1) - contentStart
                    let c = NSIntersectionRange(
                        NSRange(location: contentStart, length: max(0, len)), clipTo)
                    if c.length > 0 {
                        storage.addAttribute(.foregroundColor, value: color, range: c)
                    }
                    i = j
                } else { break }
            }
        }

        private func apply(
            _ regex: NSRegularExpression,
            in storage: NSTextStorage,
            range: NSRange,
            clipTo: NSRange,
            attributes: () -> [NSAttributedString.Key: Any]
        ) {
            let attrs = attributes()
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                guard let r = match?.range else { return }
                let c = NSIntersectionRange(r, clipTo)
                if c.length > 0 {
                    storage.addAttributes(attrs, range: c)
                }
            }
        }
    }
}

/// 視窗裡是否沒有任何元件取得焦點（焦點停在視窗本身或其內容容器）。
/// 預覽網頁、搜尋欄、表單等只要已經拿到焦點，就不該被「自動還焦點」搶走。
@MainActor
func nothingFocused(in win: NSWindow) -> Bool {
    guard let r = win.firstResponder else { return true }
    return r === win || r === win.contentView
}
#endif
