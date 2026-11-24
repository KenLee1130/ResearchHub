import Foundation
import HubCore

/// 日記裡的待辦樹：縮排比上面那個待辦深的待辦是它的子項（`  - [ ] 1. …`）。
/// 排時段的四條規則（使用者定的）：
/// 1. 母項排了時段 → 整組（母項＋底下所有行）搬到檔首的規劃段
/// 2. 只有部分子項排了時段 → 子項原地加時段，整組不動
/// 3. 所有直屬子項都排了時段 → 整組搬到規劃段（排序看最早的子項）
/// 4. 直屬子項全部勾完 → 母項自動勾；之後有子項取消 → 母項跟著取消
public nonisolated enum TodoTree {

    // MARK: - 文字行（日記原文）

    /// 行首空白寬度（tab 算 4）
    public static func indent(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    /// `- [ ]`／`- [x]`／`- [-]` 開頭（可縮排）
    static func isTodo(_ line: String) -> Bool {
        body(of: line) != nil
    }

    /// `- [ ] 文字`（可縮排）→ 文字
    static func body(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, t.hasPrefix("- ["), t.dropFirst(4).hasPrefix("] ") else { return nil }
        return String(t.dropFirst(6))
    }

    /// 「10:00–12:00 …」開頭（同 `hasTimeRange`）
    public static func hasTimeRange(_ cleanText: String) -> Bool {
        cleanText.trimmingCharacters(in: .whitespaces)
            .range(of: #"^\d{1,2}:\d{2}\s*[–\-~]\s*\d{1,2}:\d{2}\s+"#, options: .regularExpression) != nil
    }

    static func isChecked(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("- [x]")
    }

    /// 這一行待辦已經排了時段（「10:00–11:00 …」開頭）
    static func isTimed(_ line: String) -> Bool {
        guard let body = body(of: line) else { return false }
        return hasTimeRange(TodoMeta.parse(body).cleanText)
    }

    /// 第 i 行往上找：第一個縮排比它淺的非空行；那行是待辦就是母項，不是（段落、`---`）就沒有母項。
    static func parent(of i: Int, in lines: [String]) -> Int? {
        let own = indent(lines[i])
        guard own > 0 else { return nil }
        var k = i - 1
        while k >= 0 {
            if !isBlank(lines[k]), indent(lines[k]) < own { return isTodo(lines[k]) ? k : nil }
            k -= 1
        }
        return nil
    }

    /// 第 i 行連同底下縮排更深的所有行（中間的空行算進去、尾端的不算）的最後一行
    static func subtreeEnd(of i: Int, in lines: [String]) -> Int {
        let own = indent(lines[i])
        var end = i
        var k = i + 1
        while k < lines.count {
            if !isBlank(lines[k]) {
                guard indent(lines[k]) > own else { break }
                end = k
            }
            k += 1
        }
        return end
    }

    /// 直屬子待辦的行號
    static func children(of i: Int, in lines: [String]) -> [Int] {
        let end = subtreeEnd(of: i, in: lines)
        guard end > i else { return [] }
        return (i + 1...end).filter { isTodo(lines[$0]) && parent(of: $0, in: lines) == i }
    }

    /// 拿掉 start...end 這幾行；接縫兩邊都是空行就少留一個
    static func removing(_ range: ClosedRange<Int>, from lines: [String]) -> [String] {
        var out = lines
        out.removeSubrange(range)
        let s = range.lowerBound
        if s > 0, s < out.count, isBlank(out[s - 1]), isBlank(out[s]) { out.remove(at: s) }
        while s == 0, let first = out.first, isBlank(first), out.count > 1 { out.removeFirst() }
        return out
    }

    // MARK: - 規則 4：子項全勾 → 母項勾

    /// 第 `changed` 行的勾選剛改過：往上對齊每一層母項。
    /// 直屬子項全勾而母項沒勾 → 勾；母項勾著但子項不再全勾 → 取消（只在這次改動讓它不再全勾時，
    /// 也就是被改的那一層一路往上）。
    public static func syncingParentChecks(_ lines: [String], changed: Int) -> [String] {
        var out = lines
        var current = changed
        while let p = parent(of: current, in: out) {
            let kids = children(of: p, in: out)
            guard !kids.isEmpty, !out[p].trimmingCharacters(in: .whitespaces).hasPrefix("- [-]") else { break }
            let allDone = kids.allSatisfy { isChecked(out[$0]) }
            let parentDone = isChecked(out[p])
            if allDone == parentDone { break }
            out[p] = settingChecked(out[p], allDone)
            current = p
        }
        return out
    }

    static func settingChecked(_ line: String, _ checked: Bool) -> String {
        let lead = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = line.dropFirst(lead.count)
        guard rest.hasPrefix("- [") , rest.count >= 5 else { return line }
        return lead + (checked ? "- [x]" : "- [ ]") + rest.dropFirst(5)
    }

    // MARK: - 解析後的待辦（時間軸清單用）

    /// 這個待辦的直屬子項（照日記順序；`TodoLine.indent` 決定層級）
    public static func children(of todo: TodoLine, in all: [TodoLine]) -> [TodoLine] {
        guard let i = all.firstIndex(where: { $0.lineIndex == todo.lineIndex }) else { return [] }
        var result: [TodoLine] = []
        var childIndent: Int?
        for t in all[(i + 1)...] {
            guard t.indent > todo.indent else { break }
            if childIndent == nil { childIndent = t.indent }
            if t.indent <= childIndent! { childIndent = t.indent; result.append(t) }
        }
        return result
    }

    /// 往上的母項鏈（近的在前）
    public static func ancestors(of todo: TodoLine, in all: [TodoLine]) -> [TodoLine] {
        guard let i = all.firstIndex(where: { $0.lineIndex == todo.lineIndex }) else { return [] }
        var result: [TodoLine] = []
        var level = todo.indent
        for t in all[..<i].reversed() where t.indent < level {
            result.append(t)
            level = t.indent
            if level == 0 { break }
        }
        return result
    }

    /// 排時段的長度：自己的 @est；沒有就子項 @est 加總；都沒有 1 小時
    public static func estimatedMinutes(of todo: TodoLine, in all: [TodoLine]) -> Int {
        if let est = todo.meta.estMinutes { return est }
        let sum = children(of: todo, in: all).compactMap(\.meta.estMinutes).reduce(0, +)
        return sum > 0 ? sum : 60
    }

    /// 時間軸「還沒排時段」清單：還沒做完、還沒排的待辦，帶層級。
    /// 母項排了（或整組靠子項排滿了）的那一組整個不列；子項各自可拖。
    public static func unscheduled(_ all: [TodoLine]) -> [(todo: TodoLine, depth: Int, childCount: Int)] {
        all.compactMap { t in
            guard !t.done, !hasTimeRange(t.meta.cleanText) else { return nil }
            let ups = ancestors(of: t, in: all)
            guard !ups.contains(where: { $0.done || hasTimeRange($0.meta.cleanText) }) else { return nil }
            let kids = children(of: t, in: all)
            if !kids.isEmpty, kids.allSatisfy({ hasTimeRange($0.meta.cleanText) }) { return nil }
            return (t, ups.count, kids.count)
        }
    }
}
