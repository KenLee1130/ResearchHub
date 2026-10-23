#if os(macOS)
import SwiftUI
import HubCore
import PDFKit
import CoreImage
import Combine
import UniformTypeIdentifiers

/// PDF 檢視控制：暗色模式（反色 + 色相旋轉，顏色大致保留）與螢光筆。
@MainActor
public final class PDFViewerController: ObservableObject {
    public init() {}
    public weak var pdfView: PDFView?
    /// 掃描書：畫面顯示原檔（沒有文字），文字位置改從 OCR 版讀（同一份掃描、頁面幾何一樣）。
    /// 使用者希望看到的永遠是原檔——OCR 有錯也不會出現在眼前。
    public var textDocument: PDFDocument? { didSet { resetTextCache() } }

    /// 用來找字的那一頁：有 OCR 版就用它，沒有就用畫面上的文件
    public func textPage(_ index: Int) -> PDFPage? {
        let doc = textDocument ?? pdfView?.document
        guard let doc, index >= 0, index < doc.pageCount else { return nil }
        return doc.page(at: index)
    }

    /// 點了頁面上的某一點（掃描原檔沒辦法反白，對照改用點的）
    public var onClick: ((Int, CGPoint) -> Void)?
    @Published public var isDark = false
    /// 本地檔案路徑（有才能把註記寫回）
    public var fileURL: URL?

    public func toggleDark() {
        isDark.toggle()
        applyAppearance()
    }

    public func applyAppearance() {
        guard let view = pdfView else { return }
        view.wantsLayer = true
        if isDark {
            // 仿 Zotero：反轉 + 色相還原後，把純黑底抬成深石板色、略降對比
            guard let invert = CIFilter(name: "CIColorInvert"),
                  let hue = CIFilter(name: "CIHueAdjust"),
                  let tone = CIFilter(name: "CIColorMatrix") else { return }
            hue.setValue(Double.pi, forKey: kCIInputAngleKey)
            tone.setValue(CIVector(x: 0.82, y: 0, z: 0, w: 0), forKey: "inputRVector")
            tone.setValue(CIVector(x: 0, y: 0.82, z: 0, w: 0), forKey: "inputGVector")
            tone.setValue(CIVector(x: 0, y: 0, z: 0.82, w: 0), forKey: "inputBVector")
            tone.setValue(CIVector(x: 0.11, y: 0.13, z: 0.17, w: 0), forKey: "inputBiasVector")
            view.layer?.filters = [invert, hue, tone]
            view.backgroundColor = NSColor(
                calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
            view.pageShadowsEnabled = false
        } else {
            view.layer?.filters = nil
            view.backgroundColor = .windowBackgroundColor
            view.pageShadowsEnabled = true
        }
    }

    /// 螢光筆 toggle：選取處已有標記 → 移除；沒有 → 加上。存回 PDF 檔。
    public func highlightSelection() {
        guard let view = pdfView, let selection = view.currentSelection else { return }
        let lines = selection.selectionsByLine()

        // 1. 先檢查選取範圍是否壓到既有標記 → 是就移除（= 取消螢光筆）
        var removedAny = false
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                for annotation in page.annotations
                where annotation.type == "Highlight"
                    && annotation.bounds.intersects(bounds) {
                    page.removeAnnotation(annotation)
                    removedAny = true
                }
            }
        }
        if removedAny {
            view.clearSelection()
            save()
            return
        }

        // 2. 否則新增標記
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                let annotation = PDFAnnotation(
                    bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.6)
                page.addAnnotation(annotation)
            }
        }
        view.clearSelection()
        save()
    }

    private func save() {
        guard let url = fileURL else { return }
        clearSync()   // 對照用的暫時標記不能寫進 Zotero 的 PDF
        pdfView?.document?.write(to: url)
    }

    // MARK: 對照模式：反白一邊、另一邊標出同一段

    /// 選取改變時通知（並排對照用來在另一邊標出對應段落）
    public var onSelectionChange: (() -> Void)?
    private static let syncMark = "researchhub-sync"
    private var syncAnnotations: [(PDFPage, PDFAnnotation)] = []

    /// 目前選取在第幾頁（0 起算）、選取範圍的方框
    public func selectionAnchor() -> (page: Int, rect: CGRect)? {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection,
              let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let page = sel.pages.first else { return nil }
        return (doc.index(for: page), sel.bounds(for: page))
    }

    /// 在這一頁的 rect 範圍內，把文字一行一行淡淡標色，並捲到看得到的地方
    public func showSync(page index: Int, rect: CGRect) {
        guard let page = textPage(index) else { return }
        let lines = page.selection(for: rect.insetBy(dx: -1, dy: -1))?.selectionsByLine() ?? []
        var rects = lines.map { $0.bounds(for: page) }.filter { $0.width > 1 && $0.height > 1 }
        if rects.isEmpty { rects = [rect] }   // 抓不到文字（例如字是畫成圖形的）就整塊標
        highlight(page: index, lineRects: rects)
    }

    /// 只標這幾段文字（句子等級的對照）
    public func showSync(page index: Int, ranges: [NSRange]) {
        guard let page = textPage(index) else { return }
        let rects = ranges.flatMap { range in
            (page.selection(for: range)?.selectionsByLine() ?? []).map { $0.bounds(for: page) }
        }.filter { $0.width > 1 && $0.height > 1 }
        guard !rects.isEmpty else { return }
        highlight(page: index, lineRects: rects)
    }

    private func highlight(page index: Int, lineRects rects: [CGRect]) {
        clearSync()
        guard let view = pdfView, let doc = view.document,
              index >= 0, index < doc.pageCount, let page = doc.page(at: index) else { return }
        let color = NSColor.systemBlue.withAlphaComponent(0.22)
        let rect = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        for r in rects {
            let a = PDFAnnotation(bounds: r.insetBy(dx: -1, dy: -0.5), forType: .highlight, withProperties: nil)
            a.color = color
            a.userName = Self.syncMark
            page.addAnnotation(a)
            syncAnnotations.append((page, a))
        }
        let onScreen = view.convert(rect, from: page)
        if !view.bounds.insetBy(dx: 0, dy: 20).intersects(onScreen) {
            view.go(to: CGRect(x: rect.minX, y: rect.maxY - 1, width: 1, height: 1), on: page)
        }
    }

    /// 由 app 自己清掉選取（不是使用者取消反白）。選取改變的通知是非同步送來的，
    /// 所以記個時間：這之後短時間內收到的「選取變空」是 app 造成的。
    private var appClearedSelectionAt: Date?
    public var selectionWasClearedByApp: Bool {
        appClearedSelectionAt.map { Date().timeIntervalSince($0) < 0.6 } ?? false
    }

    public func clearSelection() {
        guard pdfView?.currentSelection != nil else { return }
        appClearedSelectionAt = Date()
        pdfView?.clearSelection()
    }

    public func clearSync() {
        for (page, a) in syncAnnotations { page.removeAnnotation(a) }
        syncAnnotations = []
    }

    // MARK: 句子定位（句子等級的對照）

    /// 每頁每個字的位置（page.string 的索引、方框、字）。
    /// ⚠️ 不能用 page.characterBounds(at:)：它的索引跟 page.string 對不起來（實測 x 差了 60pt），
    /// 要用 page.selection(for: NSRange) 取方框才準。一頁幾千個字，算一次就快取。
    private var charCache: [Int: [(i: Int, b: CGRect, s: String)]] = [:]
    private var boxCache: [String: (chars: [Character], idx: [Int])] = [:]
    /// 換了文件（例如新的譯文）就要丟掉
    public func resetTextCache() { charCache = [:]; boxCache = [:] }

    private func pageChars(_ index: Int) -> [(i: Int, b: CGRect, s: String)] {
        if let hit = charCache[index] { return hit }
        guard let page = textPage(index) else { return [] }
        let text = (page.string ?? "") as NSString
        var out: [(i: Int, b: CGRect, s: String)] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: .byComposedCharacterSequences) { sub, r, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let sel = page.selection(for: r) else { return }
            let b = sel.bounds(for: page)
            if b.width > 0 { out.append((r.location, b, sub)) }
        }
        charCache[index] = out
        return out
    }

    /// 段落方框裡的字，照畫面位置重排（一行一行、由左到右），只留字母數字。
    /// 譯文 PDF 抽出的文字是左右兩欄一行一行交錯的，照 page.string 的順序找不到跨行的句子。
    private func boxText(_ index: Int, _ box: CGRect) -> (chars: [Character], idx: [Int]) {
        let key = "\(index)|\(box.minX),\(box.minY),\(box.maxX),\(box.maxY)"
        if let hit = boxCache[key] { return hit }
        let area = box.insetBy(dx: -3, dy: -3)
        let items = pageChars(index)
            .filter { area.contains(CGPoint(x: $0.b.midX, y: $0.b.midY)) }
            .sorted { $0.b.midY > $1.b.midY }
        var lines: [[(i: Int, b: CGRect, s: String)]] = []
        for it in items {
            if let first = lines.last?.first,
               abs(first.b.midY - it.b.midY) < max(2, 0.45 * max(first.b.height, it.b.height)) {
                lines[lines.count - 1].append(it)
            } else {
                lines.append([it])
            }
        }
        var chars: [Character] = [], idx: [Int] = []
        for line in lines {
            for it in line.sorted(by: { $0.b.minX < $1.b.minX }) {
                for c in Self.loose(it.s) { chars.append(c); idx.append(it.i) }
            }
        }
        boxCache[key] = (chars, idx)
        return (chars, idx)
    }

    public nonisolated static func loose(_ s: String) -> [Character] {
        var t = s.lowercased()
        for (a, b) in [("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(Character.init)
    }

    /// 這句話在段落方框裡的位置（page.string 的字元索引）。
    /// 以空白切成片段依序比對（公式、引用編號在對照資料裡是空白，PDF 裡卻有字），
    /// 片段之間允許夾少量多出來的字。實測 Das 2018：原文 96%、譯文 98% 的句子找得到。
    public func locate(_ sentence: String, page index: Int, within box: CGRect) -> [Int]? {
        let pieces = sentence.split(whereSeparator: { $0.isWhitespace })
            .map { Self.loose(String($0)) }.filter { !$0.isEmpty }
        guard let first = pieces.first, pieces.reduce(0, { $0 + $1.count }) >= 2 else { return nil }
        let bt = boxText(index, box)
        let c = bt.chars
        func matches(_ pat: [Character], at k: Int) -> Bool {
            k >= 0 && k + pat.count <= c.count && Array(c[k..<(k + pat.count)]) == pat
        }
        let gap = 24
        for i in 0..<max(0, c.count - first.count + 1) where matches(first, at: i) {
            var pos = i + first.count, skipped = 0, ok = true
            for piece in pieces.dropFirst() {
                if pos < c.count, let q = (pos...min(c.count - 1, pos + gap)).first(where: { matches(piece, at: $0) }) {
                    pos = q + piece.count
                } else if pieces.count > 4 && skipped < 2 {
                    skipped += 1
                } else {
                    ok = false
                    break
                }
            }
            if ok, pos > i { return Array(bt.idx[i..<pos]) }
        }
        return nil
    }

    /// 這些字有沒有包住這一點（掃描原檔用點的對照）
    public func charsContain(_ indices: [Int], page index: Int, point: CGPoint) -> Bool {
        let wanted = Set(indices)
        return pageChars(index).contains { wanted.contains($0.i) && $0.b.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// 這些字有沒有落在目前的選取裡
    public func selectionTouches(_ indices: [Int], page index: Int) -> Bool {
        guard let view = pdfView, let doc = view.document, let sel = view.currentSelection,
              let page = sel.pages.first, doc.index(for: page) == index else { return false }
        let lines = sel.selectionsByLine().map { $0.bounds(for: page).insetBy(dx: -0.5, dy: -0.5) }
        let wanted = Set(indices)
        return pageChars(index).contains { ch in
            wanted.contains(ch.i) && lines.contains { $0.contains(CGPoint(x: ch.b.midX, y: ch.b.midY)) }
        }
    }

    /// 把字元索引併成連續範圍（中間隔幾個空白、標點也算連續）再標色
    public func showSync(page index: Int, indices: [Int]) {
        let sorted = Array(Set(indices)).sorted()
        guard var start = sorted.first else { return }
        var ranges: [NSRange] = [], last = start
        for i in sorted.dropFirst() {
            if i - last > 3 {
                ranges.append(NSRange(location: start, length: last - start + 1))
                start = i
            }
            last = i
        }
        ranges.append(NSRange(location: start, length: last - start + 1))
        showSync(page: index, ranges: ranges)
    }

    /// 沒有 align.json 時的退路：從選取的那幾行往上下延伸，行距正常就算同一段，
    /// 遇到大空白（段落間距）或換欄就停。
    public func paragraphRect(page index: Int, around rect: CGRect) -> CGRect? {
        guard let page = textPage(index),
              let all = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() else { return nil }
        // 同一欄的行（水平方向跟選取重疊夠多），由上而下
        let column = all.map { $0.bounds(for: page) }
            .filter { b in
                let overlap = min(b.maxX, rect.maxX) - max(b.minX, rect.minX)
                return b.height > 1 && overlap > 0.3 * min(b.width, max(rect.width, 20))
            }
            .sorted { $0.maxY > $1.maxY }
        guard let hit = column.firstIndex(where: { $0.intersects(rect.insetBy(dx: 0, dy: -1)) }) else { return nil }
        let lineHeight = column[hit].height
        var top = hit, bottom = hit
        while top > 0, column[top - 1].minY - column[top].maxY < lineHeight * 0.9 { top -= 1 }
        while bottom < column.count - 1, column[bottom].minY - column[bottom + 1].maxY < lineHeight * 0.9 { bottom += 1 }
        return column[top...bottom].reduce(column[top]) { $0.union($1) }
    }

    // MARK: 翻頁同步、引文跳轉、選取文字

    /// 翻頁時通知（並排對照用來同步另一邊）
    public var onPageChange: ((Int) -> Void)?

    public var currentPageIndex: Int? {
        guard let view = pdfView, let page = view.currentPage, let doc = view.document else { return nil }
        return doc.index(for: page)
    }

    public func go(toPage index: Int) {
        guard let view = pdfView, let doc = view.document,
              index >= 0, index < doc.pageCount, let page = doc.page(at: index),
              view.currentPage != page else { return }
        view.go(to: page)
    }

    /// 選取的文字與它在第幾頁（1 起算），給「引用到提問」用
    public func selectionInfo() -> (text: String, page: Int)? {
        guard let view = pdfView, let sel = view.currentSelection,
              let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let page = sel.pages.first, let doc = view.document else { return nil }
        return (text, doc.index(for: page) + 1)
    }

    /// 點了回答裡的引文：跳到那頁，並把那段原文選起來（找不到就只跳頁）。
    /// PDF 的文字常有斷行與連字號，整句找不到時改用前幾個字找。
    public func reveal(quote: String, page: Int) {
        guard let view = pdfView, let shown = view.document else { return }
        // 掃描原檔沒有文字：在 OCR 版裡找，找到後在原檔同一位置標出來
        let doc = textDocument ?? shown
        let words = quote.replacingOccurrences(of: "…", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let attempts = [words.joined(separator: " "),
                        words.prefix(8).joined(separator: " "),
                        words.prefix(4).joined(separator: " ")].filter { $0.count >= 4 }
        for text in attempts {
            let hits = doc.findString(text, withOptions: [.caseInsensitive])
            guard !hits.isEmpty else { continue }
            let best = hits.min { a, b in
                let pa = a.pages.first.map { doc.index(for: $0) } ?? 0
                let pb = b.pages.first.map { doc.index(for: $0) } ?? 0
                return abs(pa - (page - 1)) < abs(pb - (page - 1))
            }
            if let best {
                if textDocument != nil, let p = best.pages.first {
                    showSync(page: doc.index(for: p), rect: best.bounds(for: p))
                } else {
                    view.setCurrentSelection(best, animate: true)
                    view.go(to: best)
                }
                return
            }
        }
        go(toPage: page - 1)
    }
}
#endif
