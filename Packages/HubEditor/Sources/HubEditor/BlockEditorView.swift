import SwiftUI
import HubCore
import WebKit
import Combine

/// Notion 式 block 編輯器（日記用）：WKWebView + Tiptap。
/// markdown 仍是唯一真實來源——載入時 markdown → blocks，編輯時 blocks → markdown 回傳 binding。
/// 支援：/ 選單、markdown 快捷輸入、$...$ / $$...$$ KaTeX 數學節點（點擊編輯）、Cmd+V 貼圖。
@MainActor
public struct BlockEditorView {
    /// 常駐的 webView 宿主（app 的 composition root 持有唯一一個）
    public let host: BlockEditorHost
    @Binding public var text: String
    public var baseDir: URL?
    /// 文件身分（換日記/換檔案時用來重置宿主狀態）
    public var documentID: URL?
    /// 編輯器命令列送出的命令（"list"、"go:…"）；沒給＝這個畫面不理命令列
    public var onCommand: ((String) -> Void)? = nil

    public init(host: BlockEditorHost, text: Binding<String>, baseDir: URL? = nil,
                documentID: URL? = nil, onCommand: ((String) -> Void)? = nil) {
        self.host = host; self._text = text; self.baseDir = baseDir
        self.documentID = documentID; self.onCommand = onCommand
    }

    /// 共用 webView 永遠掛在「最新的」容器上；舊容器被 SwiftUI 回收時不會帶走它。
    private func attachWebView(to container: WebViewContainer) {
        let webView = host.webView
        guard webView.superview !== container else { return }
        #if os(macOS)
        // 搬家會讓 webView 失去鍵盤焦點：網頁裡游標照樣在閃，打字卻沒反應、要再點一次
        let hadFocus = (webView.window?.firstResponder as? NSView)?.isDescendant(of: webView) ?? false
        #endif
        webView.removeFromSuperview()
        container.addSubview(webView)
        #if os(macOS)
        container.needsLayout = true
        container.restoreFocusIfIdle(force: hadFocus)
        #else
        container.setNeedsLayout()
        #endif
    }

    private func sync() {
        host.textBinding = $text
        host.baseDir = baseDir
        host.onCommand = onCommand
        if host.documentID != documentID {
            // 換了文件：清掉上一份的推送/回傳記錄，確保一定重新渲染
            host.documentID = documentID
            host.resetForNewDocument()
        }
        // @/! 標記補全只在日記啟用（筆記不需要）
        host.setMarkersEnabled(documentID?.path.contains("/Journal/") ?? false)
        host.pushIfNeeded(text)
    }
}

#if os(macOS)
extension BlockEditorView: NSViewRepresentable {
    // 共用的 webView 同時只能在一個容器裡。開了多個主視窗分頁、兩邊都停在日記時，
    // 以前每次更新（打字就會）都把它搬到「最後更新的那個」容器 → 被背景分頁搶走，
    // 眼前這個變黑；背景分頁若是別天的日記還會把那天的內容推進編輯器。
    // 現在只有「看得到的那個」能拿：見 WebViewContainer.shouldOwnWebView。
    public func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.host = host
        container.onActivate = { [weak container] in
            guard let container else { return }
            attachWebView(to: container); sync()
        }
        return container   // 還沒進視窗；viewDidMoveToWindow 時才決定要不要拿
    }

    public func updateNSView(_ container: WebViewContainer, context: Context) {
        container.onActivate = { [weak container] in
            guard let container else { return }
            attachWebView(to: container); sync()
        }
        if container.shouldOwnWebView { container.onActivate?() }
    }

    /// 欄寬規則見 AdaptiveSizing.swift：給多少就用多少，不用內容的寬度撐大欄位
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: WebViewContainer,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }
}

/// 容器自己負責把 webView 撐滿（比 autoresizing 從零尺寸起算可靠）。
public final class WebViewContainer: NSView {
    /// 把共用 webView 搬進來並同步這個畫面的文件（由 BlockEditorView 設定）
    public var onActivate: (() -> Void)?
    public weak var host: BlockEditorHost?

    public override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    /// 這個容器現在該不該擁有共用 webView：
    /// 已經在這裡 → 是；webView 不在任何視窗、或在同一個視窗的別的容器 → 是（最新的贏，跟以前一樣）；
    /// 在別的視窗 → 只有那個視窗看不到（背景分頁、關掉了）或這個視窗是目前的主視窗才拿。
    public var shouldOwnWebView: Bool {
        guard let mine = window else { return false }
        guard let web = host?.webView else { return false }
        if web.superview === self { return true }
        guard let other = web.window, other !== mine else { return true }
        return mine.isKeyWindow || mine.isMainWindow
            || !other.isVisible || !other.occlusionState.contains(.visible)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        // 切到這個分頁／視窗時把 webView 拿回來
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowActivated),
            name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowActivated),
            name: NSWindow.didBecomeMainNotification, object: window)
        if shouldOwnWebView { onActivate?() }
    }

    @objc private func windowActivated(_ note: Notification) {
        if host?.webView.superview !== self { onActivate?() }
        restoreFocusIfIdle(force: false)
    }

    /// webView 在這個容器、視窗是目前的視窗、而且視窗裡沒有別的東西拿著焦點（或剛搬家前它就有焦點）
    /// → 把鍵盤焦點交給它。搜尋面板等別的文字區拿著焦點時不搶。
    public func restoreFocusIfIdle(force: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window, win.isKeyWindow else { return }
            guard let web = self.host?.webView, web.superview === self else { return }
            if (win.firstResponder as? NSView)?.isDescendant(of: web) == true { return }
            guard force || nothingFocused(in: win) else { return }
            win.makeFirstResponder(web)
        }
    }
}
#else
extension BlockEditorView: UIViewRepresentable {
    public func makeUIView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.host = host
        attachWebView(to: container)
        sync()
        return container
    }

    public func updateUIView(_ container: WebViewContainer, context: Context) {
        attachWebView(to: container)
        sync()
    }

    /// 欄寬規則見 AdaptiveSizing.swift：給多少就用多少，不用內容的寬度撐大欄位
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: WebViewContainer,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }
}

/// 容器自己負責把 webView 撐滿（比 autoresizing 從零尺寸起算可靠）。
public final class WebViewContainer: UIView {
    weak var host: BlockEditorHost?
    public override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}
#endif
