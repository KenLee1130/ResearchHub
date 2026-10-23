#if os(macOS)
import SwiftUI
import HubCore
import AppKit

/// PastingTextView：打字輔助（括號包住、⌘/ 註解、自動補右括號、環境縮排）、貼上與拖放圖片
extension PastingTextView {
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
    func emptyPairAroundCaret() -> NSRange? {
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
    func leadingWhitespace(ofLineAt loc: Int) -> String {
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
    func insertNewlineKeepingIndent() {
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
}
#endif
