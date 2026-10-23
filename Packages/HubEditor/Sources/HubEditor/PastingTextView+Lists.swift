#if os(macOS)
import SwiftUI
import HubCore
import AppKit

/// PastingTextView：清單（Enter 接續、編號重編、Tab 升降層級）
extension PastingTextView {
    // MARK: - Enter 自動接續列表

    /// 匹配行首的列表前綴：bullet（- * +）、todo（- [ ]）、編號（1. / 1)）
    private static let listPrefixRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(?:([-*+])\s+\[[ xX]\]\s+|([-*+])\s+|(\d+)([.)])\s+)"#)

    public override func insertNewline(_ sender: Any?) {
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

    public override func deleteBackward(_ sender: Any?) {
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

    public override func deleteForward(_ sender: Any?) {
        let crossed = deletionCrossesLine(backward: false)
        super.deleteForward(sender)
        if crossed { renumberAfterDeletion() }
    }

    public override func cut(_ sender: Any?) {
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
    public func shiftSelectedLines(by delta: Int, singleLine: Bool = false) -> Bool {
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
    public func changeListLevel(by delta: Int) -> Bool {
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
