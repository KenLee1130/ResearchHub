#if os(macOS)
import SwiftUI
import AppKit
import WebKit
import PDFKit

/// ⌘F：只在「目前這一頁／這個檔案」裡找（全 app 搜尋在 ⌘K）。
///
/// 決定找哪裡：
///   1. 游標在原始碼編輯器、網頁（日記、筆記預覽）或 PDF 裡 → 就找它
///   2. （同一個尋找列：輸入框、第幾個／共幾個、上一個／下一個、Esc 關閉）
///   3. 都不是 → 目前視窗裡看得到、面積最大的那塊網頁／PDF（例如論文頁的 PDF）
///   4. 什麼都沒有（首頁）→ 開全 app 搜尋
/// 尋找列貼在內容右上角（子視窗，跟著視窗移動）。
@MainActor
final class PageFinder {
    static let shared = PageFinder()

    /// 可以被找的網頁／PDF（建立時登記；弱參照，找的時候才看在不在畫面上）
    private let targets = NSHashTable<NSView>.weakObjects()
    private var panel: FindBarPanel?

    func register(_ view: NSView) { targets.add(view) }

    func showFind() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.orderedWindows.first(where: { $0.isVisible && !($0 is NSPanel) })
        else { return openGlobalSearch() }

        // 尋找列自己的輸入框有焦點時再按 ⌘F：就是要回到它
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.focusField()
            return
        }
        if let responder = window.firstResponder as? NSView {
            if let tv = responder as? NSTextView, isDocumentEditor(tv) {
                return present(for: tv)
            }
            if let target = enclosingTarget(of: responder) {
                return present(for: target)
            }
        }
        // 游標不在可找的東西裡：挑這個視窗裡看得到、最大的那一塊（原始碼編輯器也算）
        var candidates: [NSView] = targets.allObjects.filter { isShowing($0, in: window) }
        if let root = window.contentView {
            candidates += documentEditors(in: root).filter { isShowing($0, in: window) }
        }
        guard let best = candidates.max(by: { area($0) < area($1) }) else {
            return openGlobalSearch()
        }
        present(for: best)
    }

    private func openGlobalSearch() {
        NotificationCenter.default.post(name: RootView.searchNotification, object: nil)
    }

    /// 文件編輯器（筆記／LaTeX 原始碼），不是輸入框背後的 field editor
    private func isDocumentEditor(_ tv: NSTextView) -> Bool {
        tv is PastingTextView && !tv.isFieldEditor
    }

    private func documentEditors(in view: NSView) -> [NSTextView] {
        if let tv = view as? NSTextView { return isDocumentEditor(tv) ? [tv] : [] }
        return view.subviews.flatMap(documentEditors)
    }

    private func enclosingTarget(of view: NSView) -> NSView? {
        var v: NSView? = view
        while let cur = v {
            if cur is WKWebView || cur is PDFView { return cur }
            v = cur.superview
        }
        return nil
    }

    private func isShowing(_ view: NSView, in window: NSWindow) -> Bool {
        view.window === window && !view.isHiddenOrHasHiddenAncestor && area(view) > 100
    }

    private func area(_ view: NSView) -> CGFloat {
        let r = view.visibleRect
        return r.width * r.height
    }

    private func present(for target: NSView) {
        panel?.close()
        let engine: FindEngine
        if let tv = target as? NSTextView {
            engine = TextFindEngine(textView: tv)
        } else if let web = target as? WKWebView {
            engine = WebFindEngine(webView: web)
        } else if let pdf = target as? PDFView {
            engine = PDFFindEngine(pdfView: pdf)
        } else {
            return openGlobalSearch()
        }
        let panel = FindBarPanel(target: target, engine: engine) { [weak self] in self?.panel = nil }
        self.panel = panel
        panel.show()
    }
}

// MARK: - 找的方式

@MainActor
protocol FindEngine: AnyObject {
    /// 找 query；forward=false 往前找。回傳（第幾個, 共幾個），找不到回 (0, 0)
    func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int)
    func clear()
    /// 能不能取代（只有原始碼編輯器可以；日記網頁、PDF 不行）
    var supportsReplace: Bool { get }
    /// 目前選到的那個符合處換成 replacement；回傳有沒有換
    func replaceCurrent(_ query: String, with replacement: String) -> Bool
    /// 全部換掉（一步復原）；回傳換了幾個
    func replaceAll(_ query: String, with replacement: String) -> Int
}

extension FindEngine {
    var supportsReplace: Bool { false }
    func replaceCurrent(_ query: String, with replacement: String) -> Bool { false }
    func replaceAll(_ query: String, with replacement: String) -> Int { 0 }
}

/// 原始碼編輯器：全部符合處淡黃底（暫時屬性，不動檔案內容／上色），目前這一個選起來並捲過去。
/// 每次都從目前的文字重新找——中途編輯、重新載入都不會亂掉。
/// （以前用 macOS 內建尋找列：放在 SwiftUI 版面裡，版面一變就跟編輯器斷開、按鈕失效甚至消失）
@MainActor
final class TextFindEngine: FindEngine {
    private weak var textView: NSTextView?
    private var highlighted: [NSRange] = []

    init(textView: NSTextView) { self.textView = textView }

    func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
        guard let tv = textView, !query.isEmpty else {
            clear()
            return (0, 0)
        }
        let ranges = matches(of: query, in: tv)
        highlight(ranges, in: tv)
        guard !ranges.isEmpty else { return (0, 0) }

        // 從目前選取的位置往下／往上找下一個（重新輸入時包含目前位置）
        let sel = tv.selectedRange()
        let i: Int
        if forward {
            let from = restart ? sel.location : NSMaxRange(sel)
            i = ranges.firstIndex { $0.location >= from } ?? 0
        } else {
            i = ranges.lastIndex { $0.location < sel.location } ?? ranges.count - 1
        }
        let r = ranges[i]
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        tv.showFindIndicator(for: r)
        return (i + 1, ranges.count)
    }

    private func matches(of query: String, in tv: NSTextView) -> [NSRange] {
        let ns = tv.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: query, options: [.caseInsensitive], range: search)
            if r.location == NSNotFound { break }
            ranges.append(r)
            let next = NSMaxRange(r)
            search = NSRange(location: next, length: ns.length - next)
        }
        return ranges
    }

    var supportsReplace: Bool { true }

    // 直接改 textStorage（夾在 shouldChangeText／didChangeText 之間：會進 undo、會存檔），
    // 不用 insertText——那裡有「選取後打括號＝包住」之類的自訂行為，取代成 ( 會變成包住。
    func replaceCurrent(_ query: String, with replacement: String) -> Bool {
        guard let tv = textView, tv.isEditable, !query.isEmpty else { return false }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        guard sel.length > 0, NSMaxRange(sel) <= ns.length,
              ns.substring(with: sel).compare(query, options: .caseInsensitive) == .orderedSame,
              tv.shouldChangeText(in: sel, replacementString: replacement) else { return false }
        clear()
        tv.textStorage?.replaceCharacters(in: sel, with: replacement)
        tv.didChangeText()
        // 游標放在換好的字後面，下一次「找下一個」從這裡往下
        tv.setSelectedRange(NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        return true
    }

    func replaceAll(_ query: String, with replacement: String) -> Int {
        guard let tv = textView, tv.isEditable, !query.isEmpty else { return 0 }
        let ranges = matches(of: query, in: tv)
        guard !ranges.isEmpty,
              tv.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                  replacementStrings: Array(repeating: replacement, count: ranges.count))
        else { return 0 }
        clear()
        tv.textStorage?.beginEditing()
        for r in ranges.reversed() {   // 由後往前換，前面的位置才不會跑掉
            tv.textStorage?.replaceCharacters(in: r, with: replacement)
        }
        tv.textStorage?.endEditing()
        tv.didChangeText()
        return ranges.count
    }

    private func highlight(_ ranges: [NSRange], in tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let length = (tv.string as NSString).length
        for r in highlighted where NSMaxRange(r) <= length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        for r in ranges {
            lm.addTemporaryAttribute(.backgroundColor,
                                     value: NSColor.systemYellow.withAlphaComponent(0.35),
                                     forCharacterRange: r)
        }
        highlighted = ranges
    }

    func clear() {
        guard let tv = textView, let lm = tv.layoutManager else { return }
        let length = (tv.string as NSString).length
        for r in highlighted where NSMaxRange(r) <= length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        highlighted = []
    }
}

/// 網頁（日記編輯器、筆記預覽）：WKWebView 內建的 find 會選取並捲到符合處；
/// 總數用 JS 數畫面文字裡出現幾次（WebKit 沒有給數量）。
@MainActor
final class WebFindEngine: FindEngine {
    private weak var webView: WKWebView?
    private var index = 0

    init(webView: WKWebView) { self.webView = webView }

    func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
        guard let webView, !query.isEmpty else { return (0, 0) }
        let total = await count(query, in: webView)
        guard total > 0 else { return (0, 0) }
        if restart {
            // 從頭找：先把選取清掉，find 才會從文件開頭開始
            _ = try? await webView.evaluateJavaScript("window.getSelection().removeAllRanges(); 0")
            index = 0
        }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        let result = try? await webView.find(query, configuration: config)
        guard result?.matchFound == true else { return (0, total) }
        index = forward ? (index % total) + 1 : (index <= 1 ? total : index - 1)
        return (index, total)
    }

    private func count(_ query: String, in webView: WKWebView) async -> Int {
        guard let data = try? JSONEncoder().encode([query]),
              let json = String(data: data, encoding: .utf8) else { return 0 }
        let js = """
        (function(q){ q = q.toLowerCase(); const t = (document.body.innerText || "").toLowerCase();
          if (!q) return 0; let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n; })(\(json)[0])
        """
        return (try? await webView.evaluateJavaScript(js) as? Int) ?? 0
    }

    func clear() {}
}

/// PDF：全部符合處標黃，目前這一個選起來並捲過去
@MainActor
final class PDFFindEngine: FindEngine {
    private weak var pdfView: PDFView?
    private var hits: [PDFSelection] = []
    private var lastQuery = ""
    private var index = -1

    init(pdfView: PDFView) { self.pdfView = pdfView }

    func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
        guard let pdfView, let doc = pdfView.document, !query.isEmpty else {
            clear()
            return (0, 0)
        }
        if restart || query != lastQuery {
            lastQuery = query
            hits = doc.findString(query, withOptions: [.caseInsensitive])
            hits.forEach { $0.color = .systemYellow }
            pdfView.highlightedSelections = hits
            // 從目前看到的那一頁開始，不要每次都跳回第一頁
            let currentPage = pdfView.currentPage.map { doc.index(for: $0) } ?? 0
            let start = hits.firstIndex {
                ($0.pages.first.map { doc.index(for: $0) } ?? 0) >= currentPage
            } ?? 0
            index = forward ? start - 1 : start
        }
        guard !hits.isEmpty else { return (0, 0) }
        index = forward ? (index + 1) % hits.count : (index - 1 + hits.count) % hits.count
        let sel = hits[index]
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
        return (index + 1, hits.count)
    }

    func clear() {
        pdfView?.highlightedSelections = nil
        hits = []
    }
}

// MARK: - 尋找列

/// 貼在內容右上角的小尋找列（子視窗：跟著主視窗移動、不會被內容蓋住）
@MainActor
final class FindBarPanel: NSPanel {
    private let engine: FindEngine
    private let onClose: () -> Void
    private weak var target: NSView?

    init(target: NSView, engine: FindEngine, onClose: @escaping () -> Void) {
        self.target = target
        self.engine = engine
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let model = FindBarModel(engine: engine)
        model.onClose = { [weak self] in self?.close() }
        self.model = model
        let host = NSHostingView(rootView: FindBarView(model: model))
        contentView = host
        setContentSize(host.fittingSize)
        // 展開取代列：上緣固定、往下長
        model.onResize = { [weak self, weak host] in
            DispatchQueue.main.async {
                guard let self, let host else { return }
                let top = self.frame.maxY
                let size = host.fittingSize
                self.setFrame(NSRect(x: self.frame.minX, y: top - size.height,
                                     width: size.width, height: size.height), display: true)
            }
        }
    }

    private var model: FindBarModel?

    // 無邊框面板預設不能接鍵盤
    override var canBecomeKey: Bool { true }

    func focusField() { model?.focusToken += 1 }

    func show() {
        guard let target, let parent = target.window else { return }
        var inWindow = target.convert(target.visibleRect, to: nil)
        // 內容可能延伸到工具列底下（日記）：尋找列一律放在工具列下方，不要蓋住工具列的按鈕
        let layout = parent.contentLayoutRect
        if inWindow.maxY > layout.maxY { inWindow.size.height -= inWindow.maxY - layout.maxY }
        let onScreen = parent.convertToScreen(inWindow)
        let size = frame.size
        setFrameOrigin(NSPoint(x: onScreen.maxX - size.width - 16,
                               y: onScreen.maxY - size.height - 12))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        // 面板變成 key 之後才能把焦點交給輸入框（onAppear 時還不是 key，設了沒用 → 打字打不進去）
        DispatchQueue.main.async { [weak self] in self?.model?.focusToken += 1 }
    }

    override func close() {
        engine.clear()
        parent?.removeChildWindow(self)
        // 找完把焦點還給原本的內容（例如日記編輯器，可以直接接著打字）
        if let target, let win = target.window {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(target)
        }
        super.close()
        onClose()
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
@Observable
final class FindBarModel {
    var query = "" { didSet { if query != oldValue { run(forward: true, restart: true) } } }
    var status = ""
    var onClose: (() -> Void)?
    /// 每加一就把焦點放到輸入框
    var focusToken = 0
    var replacement = ""
    var showReplace = false { didSet { onResize?() } }
    /// 取代列展開／收起時讓面板跟著長高變矮
    var onResize: (() -> Void)?
    var supportsReplace: Bool { engine.supportsReplace }
    private let engine: FindEngine
    private var task: Task<Void, Never>?

    init(engine: FindEngine) { self.engine = engine }

    /// 「取代」：目前選到的是符合處就換掉，然後跳到下一個（還沒選到就先找到第一個）
    func replaceOne() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        _ = engine.replaceCurrent(q, with: replacement)
        run(forward: true, restart: false)
    }

    func replaceAll() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let n = engine.replaceAll(q, with: replacement)
        status = n == 0 ? "找不到" : "已取代 \(n) 個"
    }

    func run(forward: Bool, restart: Bool) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            engine.clear()
            status = ""
            return
        }
        task = Task {
            // 打字中稍等一下再找，不要每個字都捲來捲去
            if restart { try? await Task.sleep(nanoseconds: 180_000_000) }
            guard !Task.isCancelled else { return }
            let r = await engine.find(q, forward: forward, restart: restart)
            guard !Task.isCancelled else { return }
            status = r.total == 0 ? "找不到" : "\(r.index)/\(r.total)"
        }
    }
}

struct FindBarView: View {
    @Bindable var model: FindBarModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            findRow
            if model.showReplace { replaceRow }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .onExitCommand { model.onClose?() }
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                .frame(width: 16)
            TextField("取代成", text: $model.replacement)
                .textFieldStyle(.plain)
                .onSubmit { model.replaceOne() }
            Button("取代") { model.replaceOne() }
                .buttonStyle(.bordered).controlSize(.small)
                .help("換掉目前這一個，跳到下一個")
            Button("全部取代") { model.replaceAll() }
                .buttonStyle(.bordered).controlSize(.small)
                .help("全部換掉（⌘Z 一次還原）")
        }
    }

    private var findRow: some View {
        HStack(spacing: 6) {
            if model.supportsReplace {
                Button { model.showReplace.toggle() } label: {
                    Image(systemName: model.showReplace ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16)
                }
                .help(model.showReplace ? "收起取代" : "取代…")
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            TextField("在此頁尋找", text: $model.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.run(forward: true, restart: false) }
                // ⇧Return 往前找
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.run(forward: false, restart: false)
                    return .handled
                }
            Text(model.status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.status == "找不到" ? .red : .secondary)
                .lineLimit(1)
                .fixedSize()
            Button { model.run(forward: false, restart: false) } label: {
                Image(systemName: "chevron.up")
            }
            .help("上一個（⇧Return）")
            Button { model.run(forward: true, restart: false) } label: {
                Image(systemName: "chevron.down")
            }
            .help("下一個（Return）")
            Button { model.onClose?() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .help("關閉（Esc）")
        }
    }
}
#endif
