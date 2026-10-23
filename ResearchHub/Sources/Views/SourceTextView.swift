#if os(macOS)
import SwiftUI
import HubCore
import AppKit

// （ScrollSync 移到 Services/WebResources.swift，iOS 版共用）

/// 跳到某一行的一次性請求（編譯錯誤清單點過來）。
struct LineJumpRequest: Equatable {
    let id = UUID()
    let line: Int
    /// 有的話：在那一行（或附近幾行）找這個字並選起來（PDF 雙擊的字）
    var word: String? = nil
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
    /// 建好 NSTextView 時回報（頁面的 EditorHandle 靠它決定 ⌘F 找哪裡）
    var onTextViewReady: ((NSTextView) -> Void)? = nil

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
        // 一開始就用 TextKit 1：編輯器處處用 layoutManager（上色可視區、跳行、反白閃爍），
        // 預設的 TextKit 2 會在第一次碰 layoutManager 時才「中途」切換——不如一開始就定下來。
        let textView = PastingTextView(usingTextLayoutManager: false)
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
        onTextViewReady?(textView)
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // ⌘F 用 app 自己的尋找列（PageFind.swift）；不用內建的：在 SwiftUI 版面裡會跟編輯器斷開
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // 「智慧型剪下貼上」：貼上時自動在前後補空格、刪除時多吃掉空格——對原始碼就是改壞內容
        // （2026-10-22 使用者回報：同一個 LaTeX 檔裡複製貼上，內容不對）
        textView.smartInsertDeleteEnabled = false
        // 原始碼編輯器用不到的系統文字功能一律關掉：書寫工具（改寫文章）、行內預測文字、數學補全。
        // 反白時少跳東西出來，也少碰系統的 TextInputUI 游標介面。
        if #available(macOS 15.0, *) { textView.writingToolsBehavior = .none }
        if #available(macOS 14.0, *) { textView.inlinePredictionType = .no }
        if #available(macOS 15.0, *) { textView.mathExpressionCompletionType = .no }
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
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
            context.coordinator.jump(toLine: lineJump.line, word: lineJump.word)
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
        func jump(toLine line: Int, word: String? = nil) {
            guard let tv = textView, let sv = tv.enclosingScrollView,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let ns = tv.string as NSString
            // 每一行的範圍（行號從 1 算）
            var lines: [NSRange] = []
            var index = 0
            while index < ns.length {
                let r = ns.lineRange(for: NSRange(location: index, length: 0))
                lines.append(r)
                index = r.location + r.length
            }
            guard line >= 1, line <= max(lines.count, 1) else { return }
            let range = lines.isEmpty ? NSRange(location: 0, length: 0) : lines[line - 1]
            let trimmed = NSRange(
                location: range.location,
                length: max(0, range.length - (ns.substring(with: range).hasSuffix("\n") ? 1 : 0)))
            // SyncTeX 的行號常落在段落的頭或尾，字不一定在那一行：由近到遠看前後幾行
            var target = trimmed
            if let word, word.count >= 2, !lines.isEmpty {
                let order = [0] + (1...4).flatMap { [$0, -$0] }
                for offset in order {
                    let i = line - 1 + offset
                    guard lines.indices.contains(i) else { continue }
                    let found = ns.range(of: word, options: [], range: lines[i])
                    if found.location != NSNotFound { target = found; break }
                }
            }
            tv.setSelectedRange(target)
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

        /// 數學環境整塊（內容上數學色，之後指令/參數再覆蓋）。
        /// 只列數學環境：以前是「除了清單、圖表…以外都算」，結果 \begin{document} 也中了，
        /// 整份內文都變成數學色（2026-10-15 使用者：「顏色太多」）。
        private static let envBlockPattern = try! NSRegularExpression(
            pattern: #"\\begin\{((?:equation|align|alignat|gather|multline|flalign|eqnarray|displaymath|math)\*?)\}[\s\S]*?\\end\{\1\}"#)

        /// % 註解。LaTeX 專案：沒被 \ 跳脫的 % 到行尾；Markdown 筆記只算整行註解（內文常有「50%」）
        private static let latexCommentPattern = try! NSRegularExpression(
            pattern: #"(?<!\\)%[^\n]*"#)
        private static let lineCommentPattern = try! NSRegularExpression(
            pattern: #"^[ \t]*%[^\n]*"#, options: [.anchorsMatchLines])

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

        // MARK: - Colors（vim default 為底，深淺色模式各一組）

        /// 配色以 vim 內建 default 為底，黃、青調低彩度（2026-10-15 使用者從預覽挑的）；
        /// 內文一律是一般文字色（深色模式＝白）。light: 是淺色模式用的較深版本。
        private enum Palette {
            static let command = dynamic(dark: 0xD7D787, light: 0x7A7A1E)    // 卡其
            static let argument = dynamic(dark: 0x87D7D7, light: 0x1F7A7A)   // 淡青
            static let mathBody = dynamic(dark: 0xE59A85, light: 0xB5533F)   // 鮭魚粉（跟卡其拉開色相）
            static let delimiter = mathBody
            static let comment = dynamic(dark: 0x80A0FF, light: 0x3355CC)    // 藍
            static let task = NSColor.systemOrange
            static let wikiLink = NSColor.systemTeal

            private static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
                NSColor(name: nil) { appearance in
                    let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                                   green: CGFloat((v >> 8) & 0xFF) / 255,
                                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
                }
            }
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
            applyHangingIndents(storage: storage, text: ns, font: baseFont)

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

            // 註解最後上，蓋過裡面的指令／數學色
            let commentPattern = parent.projectRoot != nil ? Self.latexCommentPattern : Self.lineCommentPattern
            apply(commentPattern, in: storage, range: full, clipTo: window) {
                [.foregroundColor: Palette.comment]
            }

            storage.endEditing()
            recomputeAnchors()   // 文字/版面變了 → 更新捲動同步的標題位置
        }

        /// 自動換行的續行對齊這一行開頭的縮排（懸掛縮排）。
        /// 沒有這個的話，縮排過的長段落只有第一個視覺行往右，後面換行的部分都從第 0 欄開始，
        /// 整塊 Tab 看起來像沒作用（2026-10-01 使用者回報）。
        /// tab 寬固定 4 格（跟清單縮排單位一致），續行縮排＝行首空白的寬度。
        /// 跑全文但只在值不同時才設——設了就會讓那段重排，全文重設會讓畫面亂跳（見 2026-08-07）。
        private func applyHangingIndents(storage: NSTextStorage, text ns: NSString, font: NSFont) {
            let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
            let tabWidth = charWidth * 4
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                                   options: [.byParagraphs, .substringNotRequired]) { _, para, enclosing, _ in
                var indent: CGFloat = 0
                var i = para.location
                while i < NSMaxRange(para) {
                    let c = ns.character(at: i)
                    if c == 0x20 { indent += charWidth }
                    else if c == 0x09 { indent = (floor(indent / tabWidth) + 1) * tabWidth }
                    else { break }
                    i += 1
                }
                // 整行都是空白：不懸掛（不然游標會停在奇怪的位置）
                if i == NSMaxRange(para) { indent = 0 }
                let range = enclosing.length > 0 ? enclosing : para
                guard range.length > 0 else { return }
                let current = storage.attribute(.paragraphStyle, at: range.location,
                                                effectiveRange: nil) as? NSParagraphStyle
                if let current, current.headIndent == indent,
                   current.defaultTabInterval == tabWidth, current.tabStops.isEmpty { return }
                let style = NSMutableParagraphStyle()
                style.tabStops = []
                style.defaultTabInterval = tabWidth
                style.headIndent = indent
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
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
