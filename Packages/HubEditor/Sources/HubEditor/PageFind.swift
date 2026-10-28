#if os(macOS)
import SwiftUI
import HubCore
import AppKit
import WebKit
import PDFKit

/// ⌘F 的尋找列：在哪裡找由頁面決定（EditorHandle.findTarget），這裡只管呈現。
/// （以前自己從 NSApp.keyWindow 的 firstResponder 往上找、找不到就挑畫面上面積最大的那塊——
///   用幾何猜焦點是橋接 bug 的根源，見 docs/ARCHITECTURE.md 第 3 節。）
/// 尋找列貼在內容右上角（子視窗，跟著視窗移動）。
@MainActor
public final class PageFinder {
    public init() {}

    private var panel: FindBarPanel?

    /// 在 target（原始碼 NSTextView、網頁、PDF）裡找。尋找列已開著就只把焦點放回去。
    public func show(in target: NSView) {
        if refocusIfVisible() { return }
        present(for: target)
    }

    /// 尋找列開著（例如它自己的輸入框是 key）時再按 ⌘F：回到它。
    @discardableResult
    public func refocusIfVisible() -> Bool {
        guard let panel, panel.isVisible else { return false }
        panel.makeKeyAndOrderFront(nil)
        panel.focusField()
        return true
    }

    /// 用頁面自己的引擎（例如日記的時間軸：跨所有日記找，上下鍵在天與天之間跳），
    /// 尋找列貼在 target 的右上角。
    public func show(in target: NSView, engine: FindEngine) {
        if refocusIfVisible() { return }
        present(for: target, engine: engine)
    }

    /// 這個 view 適合的找法：原始碼 NSTextView、網頁、PDF；其他回 nil
    public static func engine(for view: NSView) -> FindEngine? {
        if let tv = view as? NSTextView { return TextFindEngine(textView: tv) }
        if let web = view as? WKWebView { return WebFindEngine(webView: web) }
        if let pdf = view as? PDFView { return PDFFindEngine(pdfView: pdf) }
        return nil
    }

    private func present(for target: NSView) {
        guard let engine = Self.engine(for: target) else { return }
        present(for: target, engine: engine)
    }

    private func present(for target: NSView, engine: FindEngine) {
        panel?.close()
        let panel = FindBarPanel(target: target, engine: engine) { [weak self] in self?.panel = nil }
        self.panel = panel
        panel.show()
    }
}

// MARK: - 找的方式

/// 尋找列右側「…」選單裡的一個開關（例如日記時間軸的「最舊在上」）
public struct FindOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let isOn: Bool
    public let toggle: @MainActor @Sendable () -> Void

    public init(id: String, title: String, isOn: Bool, toggle: @escaping @MainActor @Sendable () -> Void) {
        self.id = id; self.title = title; self.isOn = isOn; self.toggle = toggle
    }
}

@MainActor
public protocol FindEngine: AnyObject {
    /// 找 query；forward=false 往前找。回傳（第幾個, 共幾個），找不到回 (0, 0)
    func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int)
    func clear()
    /// 引擎自己的開關（切了會從頭重找）；預設沒有
    var options: [FindOption] { get }
    /// 能不能取代（只有原始碼編輯器可以；日記網頁、PDF 不行）
    var supportsReplace: Bool { get }
    /// 目前選到的那個符合處換成 replacement；回傳有沒有換
    func replaceCurrent(_ query: String, with replacement: String) -> Bool
    /// 全部換掉（一步復原）；回傳換了幾個
    func replaceAll(_ query: String, with replacement: String) -> Int
}

extension FindEngine {
    public var options: [FindOption] { [] }
    public var supportsReplace: Bool { false }
    public func replaceCurrent(_ query: String, with replacement: String) -> Bool { false }
    public func replaceAll(_ query: String, with replacement: String) -> Int { 0 }
}

/// 原始碼編輯器：全部符合處淡黃底（暫時屬性，不動檔案內容／上色），目前這一個選起來並捲過去。
/// 每次都從目前的文字重新找——中途編輯、重新載入都不會亂掉。
/// （以前用 macOS 內建尋找列：放在 SwiftUI 版面裡，版面一變就跟編輯器斷開、按鈕失效甚至消失）
@MainActor
public final class TextFindEngine: FindEngine {
    private weak var textView: NSTextView?
    private var highlighted: [NSRange] = []

    public init(textView: NSTextView) { self.textView = textView }

    public func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
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

    public var supportsReplace: Bool { true }

    // 直接改 textStorage（夾在 shouldChangeText／didChangeText 之間：會進 undo、會存檔），
    // 不用 insertText——那裡有「選取後打括號＝包住」之類的自訂行為，取代成 ( 會變成包住。
    public func replaceCurrent(_ query: String, with replacement: String) -> Bool {
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

    public func replaceAll(_ query: String, with replacement: String) -> Int {
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

    public func clear() {
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
public final class WebFindEngine: FindEngine {
    private weak var webView: WKWebView?
    private var index = 0

    public init(webView: WKWebView) { self.webView = webView }

    public func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
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

    public func clear() {}
}

/// PDF：全部符合處標黃，目前這一個選起來並捲過去
@MainActor
public final class PDFFindEngine: FindEngine {
    private weak var pdfView: PDFView?
    private var hits: [PDFSelection] = []
    private var lastQuery = ""
    private var index = -1

    public init(pdfView: PDFView) { self.pdfView = pdfView }

    public func find(_ query: String, forward: Bool, restart: Bool) async -> (index: Int, total: Int) {
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

    public func clear() {
        pdfView?.highlightedSelections = nil
        hits = []
    }
}

// MARK: - 尋找列

/// 貼在內容右上角的小尋找列（子視窗：跟著主視窗移動、不會被內容蓋住）
@MainActor
public final class FindBarPanel: NSPanel {
    private let engine: FindEngine
    private let onClose: () -> Void
    private weak var target: NSView?

    public init(target: NSView, engine: FindEngine, onClose: @escaping () -> Void) {
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
    public override var canBecomeKey: Bool { true }

    public func focusField() { model?.focusToken += 1 }

    public func show() {
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

    public override func close() {
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

    public override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
@Observable
public final class FindBarModel {
    public var query = "" { didSet { if query != oldValue { run(forward: true, restart: true) } } }
    public var status = ""
    public var onClose: (() -> Void)?
    /// 每加一就把焦點放到輸入框
    public var focusToken = 0
    public var replacement = ""
    public var showReplace = false { didSet { onResize?() } }
    /// 取代列展開／收起時讓面板跟著長高變矮
    public var onResize: (() -> Void)?
    public var supportsReplace: Bool { engine.supportsReplace }
    public var options: [FindOption] { engine.options }
    private let engine: FindEngine

    /// 切引擎的開關，然後從頭重找
    public func toggle(_ option: FindOption) {
        option.toggle()
        run(forward: true, restart: true)
    }
    private var task: Task<Void, Never>?

    public init(engine: FindEngine) { self.engine = engine }

    /// 「取代」：目前選到的是符合處就換掉，然後跳到下一個（還沒選到就先找到第一個）
    public func replaceOne() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        _ = engine.replaceCurrent(q, with: replacement)
        run(forward: true, restart: false)
    }

    public func replaceAll() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let n = engine.replaceAll(q, with: replacement)
        status = n == 0 ? "找不到" : "已取代 \(n) 個"
    }

    public func run(forward: Bool, restart: Bool) {
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

public struct FindBarView: View {
    @Bindable public var model: FindBarModel
    @FocusState private var focused: Bool

    public var body: some View {
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
            if !model.options.isEmpty {
                Menu {
                    ForEach(model.options) { option in
                        Button {
                            model.toggle(option)
                        } label: {
                            if option.isOn { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("選項")
            }
            Button { model.onClose?() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .help("關閉（Esc）")
        }
    }
}
#endif
