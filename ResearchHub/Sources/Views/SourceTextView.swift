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

/// 左欄源碼編輯器：NSTextView 包裝，Overleaf 式多色語法高亮，回報捲動位置。
/// 配色：定界符（$、$$、\[、\(）橘、數學內容紫、指令藍、
/// 環境名與指令第一個 {…} 參數綠、標題粗體、checkbox 橘。
/// 支援 Cmd+V 貼上圖片的 NSTextView：圖片交給 onPasteImage 存檔，插入回傳的 markdown。
final class PastingTextView: NSTextView {
    var onPasteImage: ((NSImage) -> String?)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { ActiveEditorRegistry.shared.textView = self }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        completionPopup.hide()   // 點到別處時關掉浮動清單
        return super.resignFirstResponder()
    }

    // MARK: - 自動補全（Overleaf 式浮動清單：不強制插入；方向鍵選、Tab 接受、Esc 關閉）

    /// 打 \ 之後可選的指令。
    static let commandList: [String] = [
        "\\title{}", "\\subtitle{}", "\\author{}", "\\date{}",
        "\\section{}", "\\subsection{}", "\\subsubsection{}", "\\tableofcontents",
        "\\cite{}", "\\footnote{}", "\\label{}", "\\eqref{}", "\\ref{}",
        "\\begin{}", "\\end{}",
        "\\frac{}{}", "\\sqrt{}", "\\text{}", "\\mathbb{}", "\\mathcal{}", "\\mathbf{}",
        "\\hat{}", "\\bar{}", "\\tilde{}", "\\vec{}", "\\overline{}", "\\underline{}",
        "\\sum", "\\prod", "\\int", "\\oint", "\\lim", "\\partial", "\\nabla", "\\infty",
        "\\langle", "\\rangle", "\\otimes", "\\oplus", "\\times", "\\cdot", "\\approx",
        "\\equiv", "\\sim", "\\propto", "\\leq", "\\geq", "\\neq", "\\rightarrow", "\\to",
        "\\Rightarrow", "\\mapsto", "\\forall", "\\exists", "\\in", "\\subset", "\\cup", "\\cap",
        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\epsilon", "\\varepsilon", "\\zeta",
        "\\eta", "\\theta", "\\kappa", "\\lambda", "\\mu", "\\nu", "\\xi", "\\pi", "\\rho",
        "\\sigma", "\\tau", "\\phi", "\\varphi", "\\chi", "\\psi", "\\omega",
        "\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi", "\\Pi", "\\Sigma",
        "\\Phi", "\\Psi", "\\Omega",
        "\\left(", "\\right)", "\\left[", "\\right]", "\\left\\{", "\\right\\}",
    ]

    /// \begin{} 內可選的環境名稱。
    static let envList: [String] = [
        "equation", "equation*", "align", "align*", "aligned", "gather", "gather*",
        "cases", "split", "multline", "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix",
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
        if let r = before.range(of: #"\\cite\{[^}]*$"#, options: .regularExpression) {
            let len = (String(before[r].dropFirst(6)) as NSString).length     // 去掉 "\cite{"
            return (.cite, NSRange(location: caret - len, length: len))
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
        if let r = before.range(of: #"\\[a-zA-Z]*$"#, options: .regularExpression) {
            let len = (String(before[r]) as NSString).length                  // 含反斜線
            return (.command, NSRange(location: caret - len, length: len))
        }
        // 待辦標記：行首或空白後的 @/!（「![」圖片語法不會觸發）
        if let r = before.range(of: #"(?:^|\s)([@!][a-zA-Z]*)$"#, options: .regularExpression) {
            let token = String(before[r]).trimmingCharacters(in: .whitespaces)
            let len = (token as NSString).length
            return (.marker, NSRange(location: caret - len, length: len))
        }
        return nil
    }

    private func completionItems(_ kind: CompletionItem.Kind, partial: String) -> [CompletionItem] {
        switch kind {
        case .command:
            let p = partial.lowercased()
            return Self.commandList
                .filter { $0.lowercased().hasPrefix(p) }
                .map { CompletionItem(display: $0, insert: $0, kind: .command) }
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
        case .marker:
            return Self.markerList
                .filter { partial.isEmpty || $0.lowercased().hasPrefix(partial.lowercased()) }
                .map { CompletionItem(display: $0, insert: $0, kind: .marker) }
        }
    }

    /// 待辦標記（@due/@line/!high/!low）。
    static let markerList = ["@due()", "@line()", "!high", "!low"]

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

    private func citeItems(prefix: String) -> [CompletionItem] {
        let q = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [CompletionItem] = []
        for item in ZoteroStore.shared.items {
            let hay = "\(item.authors) \(item.title) \(item.year) \(item.key)".lowercased()
            guard q.isEmpty || hay.contains(q) else { continue }
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
        // 輸入法組字中不要動補全清單，避免干擾候選字視窗。
        if hasMarkedText() { return }
        if suppressCompletionOnce { suppressCompletionOnce = false; completionPopup.hide(); return }
        guard let win = window, let ctx = currentContext() else { completionPopup.hide(); return }
        let partial = (string as NSString).substring(with: ctx.range)
        let items = completionItems(ctx.kind, partial: partial)
        guard !items.isEmpty else { completionPopup.hide(); return }
        completionRange = ctx.range
        let caretRect = firstRect(
            forCharacterRange: NSRange(location: selectedRange().location, length: 0),
            actualRange: nil)
        completionPopup.show(items: items, below: caretRect, parent: win)
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
        case .cite, .eqref:
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
        case .marker:
            insertText(item.insert, replacementRange: completionRange)
            if item.insert.hasSuffix("()") {
                // 游標退回括號內
                let loc = selectedRange().location
                setSelectedRange(NSRange(location: max(0, loc - 1), length: 0))
            } else {
                suppressCompletionOnce = true
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
        super.doCommand(by: selector)
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
        if match.range(at: 4).location != NSNotFound,
           let n = Int(lineNS.substring(with: match.range(at: 4))) {
            let indent = lineNS.substring(with: match.range(at: 1))
            let sep = lineNS.substring(with: match.range(at: 5))
            newPrefix = "\(indent)\(n + 1)\(sep) "
        }

        insertText("\n" + newPrefix, replacementRange: sel)
    }
}

// （ScrollSync 移到 Services/WebResources.swift，iOS 版共用）

struct SourceTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 14
    var onScroll: ((ScrollSync) -> Void)?
    var onPasteImage: ((NSImage) -> String?)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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

        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = nsView.documentView as? PastingTextView else { return }
        tv.onPasteImage = onPasteImage
        var needsHighlight = false
        // hasMarkedText = 輸入法（注音/拼音等）正在組字：此時 tv.string 含組字暫存、
        // binding 還是舊值，若在這裡回寫會把組字狀態整個抹掉（中文打到一半跳掉）。
        if tv.string != text && !context.coordinator.isEditing && !tv.hasMarkedText() {
            tv.string = text
            needsHighlight = true
        }
        if context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastFontSize = fontSize
            needsHighlight = true
        }
        if needsHighlight {
            context.coordinator.applyHighlighting()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceTextView
        weak var textView: NSTextView?
        var isEditing = false
        var lastFontSize: CGFloat
        /// 各「標題」行的字元起點（供捲動同步；隨文字變動由 applyHighlighting 重算）。
        private var anchorCharIndices: [Int] = []

        init(_ parent: SourceTextView) {
            self.parent = parent
            self.lastFontSize = parent.fontSize
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            isEditing = true
            parent.text = tv.string
            applyHighlighting()
            isEditing = false
        }

        /// 選取/輸入變動時更新浮動補全清單（涵蓋打字時游標移動）。
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let pv = textView as? PastingTextView else { return }
            DispatchQueue.main.async { [weak pv] in pv?.updateCompletion() }
        }

        @objc func scrolled() {
            guard let tv = textView, let sv = tv.enclosingScrollView,
                  let lm = tv.layoutManager else { return }
            let topY = sv.contentView.bounds.origin.y
            let contentH = tv.bounds.height
            let maxOffset = max(1, contentH - sv.contentView.bounds.height)
            let global = max(0, min(1, topY / maxOffset))
            let inset = tv.textContainerInset.height
            let ns = tv.string as NSString

            // 各標題行目前的 Y（用當前版面算，所以縮放/改寬度也對）
            var ys: [CGFloat] = []
            for ci in anchorCharIndices where ci < ns.length {
                let gi = lm.glyphIndexForCharacter(at: ci)
                let r = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                ys.append(r.minY + inset)
            }
            // 視窗頂端上方最近的標題
            var k = -1
            for (i, y) in ys.enumerated() {
                if y <= topY + 0.5 { k = i } else { break }
            }
            let segStart = k >= 0 ? ys[k] : 0
            let segEnd = (k + 1 < ys.count) ? ys[k + 1] : maxOffset
            let local = max(0, min(1, (topY - segStart) / max(1, segEnd - segStart)))
            parent.onScroll?(ScrollSync(anchor: k, local: local, global: global, count: ys.count))
        }

        /// 掃描捲動同步的錨點：各「標題」(\title/\subtitle/\author/\date/\section… 與 markdown #)
        /// 的行起點，外加每個「顯示型數學區塊」($$…$$ / \[…\] / \begin{env}…\end{env}) 的起點。
        /// 公式多的長段落（例如一段裡夾好幾條方程式）也因此有細錨點，左右才對得準。
        private func recomputeAnchors() {
            guard let tv = textView else { anchorCharIndices = []; return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            var idx: [Int] = []
            Self.anchorLineRegex.enumerateMatches(in: tv.string, range: full) { m, _, _ in
                if let m { idx.append(m.range.location) }
            }
            Self.mathBlockRegex.enumerateMatches(in: tv.string, range: full) { m, _, _ in
                if let m { idx.append(m.range.location) }
            }
            anchorCharIndices = idx.sorted()
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
        private static let envBlockPattern = try! NSRegularExpression(
            pattern: #"\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}"#)

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
            pattern: #"^[ \t]*(?:#{1,6}\s|\\(?:title|subtitle|author|date|subsubsection|subsection|section)\{)"#,
            options: [.anchorsMatchLines])
        /// 顯示型數學區塊（每塊對到預覽裡一個 .katex-display），當作捲動同步的細錨點。
        private static let mathBlockRegex = try! NSRegularExpression(
            pattern: #"\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\begin\{([a-zA-Z*]+)\}[\s\S]*?\\end\{\1\}"#)

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

        func applyHighlighting() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let size = parent.fontSize
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)

            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ], range: full)

            // Markdown 結構
            apply(Self.headerPattern, in: storage, range: full) {
                [.font: boldFont]
            }
            apply(Self.boldPattern, in: storage, range: full) {
                [.font: boldFont]
            }
            apply(Self.taskPattern, in: storage, range: full) {
                [.foregroundColor: Palette.task]
            }
            apply(Self.wikiLinkPattern, in: storage, range: full) {
                [.foregroundColor: Palette.wikiLink]
            }

            // 長文字指令（\footnote/\title/\section…）的內容先整段上參數綠；大括號用計數配對，
            // 所以巢狀（如 \frac{}{}）也不會壞。放在數學之前，數學區段稍後會被蓋回數學色。
            for name in Self.proseArgCommands {
                highlightBalancedArg("\\" + name, in: storage, color: Palette.argument)
            }

            // 數學區域：內容紫 + 定界符橘
            for (regex, delim) in Self.mathPatterns {
                regex.enumerateMatches(in: tv.string, range: full) { match, _, _ in
                    guard let r = match?.range, r.length >= delim * 2 else { return }
                    storage.addAttribute(.foregroundColor, value: Palette.mathBody, range: r)
                    storage.addAttribute(
                        .foregroundColor, value: Palette.delimiter,
                        range: NSRange(location: r.location, length: delim))
                    storage.addAttribute(
                        .foregroundColor, value: Palette.delimiter,
                        range: NSRange(location: r.location + r.length - delim, length: delim))
                }
            }

            // begin/end 環境整塊內容上紫
            apply(Self.envBlockPattern, in: storage, range: full) {
                [.foregroundColor: Palette.mathBody]
            }

            // 指令藍（含數學內的指令）
            apply(Self.commandPattern, in: storage, range: full) {
                [.foregroundColor: Palette.command]
            }

            // 指令第一個 {…} 參數內容綠（\begin{align}、\text{aff}、\label{...}）
            Self.argPattern.enumerateMatches(in: tv.string, range: full) { match, _, _ in
                guard let m = match, m.numberOfRanges > 1 else { return }
                // 長文字指令上面已用計數配對處理；這裡略過，免得蓋掉裡面的數學色。
                let name = String(ns.substring(with: m.range).dropFirst().prefix { $0.isLetter })
                if Self.proseArgCommands.contains(name) { return }
                let argRange = m.range(at: 1)
                if argRange.length > 0 {
                    storage.addAttribute(.foregroundColor, value: Palette.argument, range: argRange)
                }
            }

            storage.endEditing()
            recomputeAnchors()   // 文字/版面變了 → 更新捲動同步的標題位置
        }

        /// 長文字指令（內容可能含巢狀大括號或數學）的清單。
        private static let proseArgCommands: Set<String> =
            ["footnote", "title", "subtitle", "author", "date",
             "section", "subsection", "subsubsection"]

        /// 把 \command{...} 的內容上色，大括號用計數配對，巢狀（\frac{}{} 等）也不會壞。
        private func highlightBalancedArg(
            _ command: String, in storage: NSTextStorage, color: NSColor
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
                    if len > 0 {
                        storage.addAttribute(.foregroundColor, value: color,
                                             range: NSRange(location: contentStart, length: len))
                    }
                    i = j
                } else { break }
            }
        }

        private func apply(
            _ regex: NSRegularExpression,
            in storage: NSTextStorage,
            range: NSRange,
            attributes: () -> [NSAttributedString.Key: Any]
        ) {
            let attrs = attributes()
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                if let r = match?.range {
                    storage.addAttributes(attrs, range: r)
                }
            }
        }
    }
}
#endif
