import SwiftUI
import WebKit
import Combine

/// Notion 式 block 編輯器（日記用）：WKWebView + Tiptap。
/// markdown 仍是唯一真實來源——載入時 markdown → blocks，編輯時 blocks → markdown 回傳 binding。
/// 支援：/ 選單、markdown 快捷輸入、$...$ / $$...$$ KaTeX 數學節點（點擊編輯）、Cmd+V 貼圖。
struct BlockEditorView {
    @Binding var text: String
    var baseDir: URL?
    /// 文件身分（換日記/換檔案時用來重置宿主狀態）
    var documentID: URL?

    /// 共用 webView 永遠掛在「最新的」容器上；舊容器被 SwiftUI 回收時不會帶走它。
    private func attachWebView(to container: WebViewContainer) {
        let webView = BlockEditorHost.shared.webView
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        #if os(macOS)
        container.needsLayout = true
        #else
        container.setNeedsLayout()
        #endif
    }

    private func sync() {
        let host = BlockEditorHost.shared
        host.textBinding = $text
        host.baseDir = baseDir
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
    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        container.onActivate = { [weak container] in
            guard let container else { return }
            attachWebView(to: container); sync()
        }
        return container   // 還沒進視窗；viewDidMoveToWindow 時才決定要不要拿
    }

    func updateNSView(_ container: WebViewContainer, context: Context) {
        container.onActivate = { [weak container] in
            guard let container else { return }
            attachWebView(to: container); sync()
        }
        if container.shouldOwnWebView { container.onActivate?() }
    }

    /// 欄寬規則見 AdaptiveSizing.swift：給多少就用多少，不用內容的寬度撐大欄位
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WebViewContainer,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }
}

/// 容器自己負責把 webView 撐滿（比 autoresizing 從零尺寸起算可靠）。
final class WebViewContainer: NSView {
    /// 把共用 webView 搬進來並同步這個畫面的文件（由 BlockEditorView 設定）
    var onActivate: (() -> Void)?

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    /// 這個容器現在該不該擁有共用 webView：
    /// 已經在這裡 → 是；webView 不在任何視窗、或在同一個視窗的別的容器 → 是（最新的贏，跟以前一樣）；
    /// 在別的視窗 → 只有那個視窗看不到（背景分頁、關掉了）或這個視窗是目前的主視窗才拿。
    var shouldOwnWebView: Bool {
        guard let mine = window else { return false }
        let web = BlockEditorHost.shared.webView
        if web.superview === self { return true }
        guard let other = web.window, other !== mine else { return true }
        return mine.isKeyWindow || mine.isMainWindow
            || !other.isVisible || !other.occlusionState.contains(.visible)
    }

    override func viewDidMoveToWindow() {
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
        if BlockEditorHost.shared.webView.superview !== self { onActivate?() }
    }
}
#else
extension BlockEditorView: UIViewRepresentable {
    func makeUIView(context: Context) -> WebViewContainer {
        let container = WebViewContainer()
        attachWebView(to: container)
        sync()
        return container
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        attachWebView(to: container)
        sync()
    }

    /// 欄寬規則見 AdaptiveSizing.swift：給多少就用多少，不用內容的寬度撐大欄位
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WebViewContainer,
                      context: Context) -> CGSize? {
        proposal.adaptive
    }
}

/// 容器自己負責把 webView 撐滿（比 autoresizing 從零尺寸起算可靠）。
final class WebViewContainer: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}
#endif

/// 常駐的 block 編輯器宿主：WKWebView 只建立並載入一次（app 啟動即預載），
/// 之後切到日記分頁是即時顯示，只推送新的 markdown 內容。
@MainActor
final class BlockEditorHost: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = BlockEditorHost()

    let webView: WKWebView
    var baseDir: URL?
    var textBinding: Binding<String>?
    var documentID: URL?

    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?

    private var lastTextFromJS: String?
    private var lastPushed: String?
    private var pendingText: String?
    private var assetCache: [String: String] = [:]
    private var retryCount = 0

    private override init() {
        #if os(macOS)
        webView = FirstMouseWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #else
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #endif
        super.init()
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "contentChanged")
        ucc.add(self, name: "ready")
        ucc.add(self, name: "pasteImage")
        ucc.add(self, name: "jsError")
        ucc.add(self, name: "command")
        ucc.add(self, name: "foldChanged")
        // 編輯器依賴（tiptap+KaTeX，本地 editor-bundle.js）用 user script 注入：
        // 同 origin 執行、錯誤訊息不會被 file:// 隔離政策遮罩。
        if let url = WebResources.baseURL?.appendingPathComponent("editor-bundle.js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            ucc.addUserScript(WKUserScript(
                source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.navigationDelegate = self
        #if os(macOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        #endif
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        webView.underPageBackgroundColor = .clear
        startLoad()
    }

    /// app 啟動時呼叫即可觸發預載
    func preload() {}

    private func startLoad() {
        loadError = nil
        isReady = false
        webView.loadHTMLString(BlockEditorView.template, baseURL: WebResources.baseURL)
        // CDN 載入失敗（網路慢/斷線）時自動重試，最多 3 次
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !self.isReady else { return }
            if self.retryCount < 3 {
                self.retryCount += 1
                self.startLoad()
            } else {
                self.loadError = "編輯器載入失敗——請檢查網路後按「重試」"
            }
        }
    }
    #if os(macOS)
    /// 切回 app 時把焦點還給編輯器：macOS 預設第一下點擊只用來啟動視窗，
    /// 使用者得多點一兩下才能打字。焦點已經在別的文字區（搜尋面板等）就不搶。
    @objc func appBecameActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.webView.window, win.isKeyWindow,
                  nothingFocused(in: win) else { return }
            if win.firstResponder !== self.webView {
                win.makeFirstResponder(self.webView)
            }
            self.webView.evaluateJavaScript(
                "window.__editor && window.__editor.commands.focus()")
        }
    }
    #endif


    func retry() {
        retryCount = 0
        startLoad()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let body = message.body as? String ?? ""
        Task { @MainActor in
            switch name {
            case "ready":
                self.isReady = true
                self.loadError = nil
                self.retryCount = 0
                self.webView.evaluateJavaScript(
                    "window.__markersEnabled = \(self.markersEnabled); "
                    + "window.__pomoMinutes = \(Self.pomoMinutes)")
                self.lastMarkersSent = (self.markersEnabled, Self.pomoMinutes)
                if let pending = self.pendingText {
                    self.pendingText = nil
                    self.push(pending)
                }
            case "contentChanged":
                self.lastTextFromJS = body
                if self.textBinding?.wrappedValue != body {
                    self.textBinding?.wrappedValue = body
                }
            case "pasteImage":
                self.handlePastedImage(base64: body)
            case "foldChanged":
                self.recordFold(json: body)
            case "command":
                // 命令列送出的命令（如 /list）→ 由當前畫面決定怎麼呈現
                NotificationCenter.default.post(
                    name: .rhEditorCommand, object: nil, userInfo: ["command": body])
            case "jsError":
                NSLog("BlockEditor JS error: %@", body)
                if !self.isReady {
                    self.loadError = "編輯器發生錯誤：\(body.prefix(120))"
                }
            default:
                break
            }
        }
    }

    // MARK: - 待辦摺疊狀態

    /// 每份日記收起來的待辦（key＝那一項的文字）。不寫進 markdown，
    /// 所以 Obsidian 看到的還是普通清單；存在這台裝置的偏好設定。
    private static let foldStoreKey = "blockEditor.foldedTasks"

    private func foldedKeys(for doc: URL?) -> [String] {
        guard let doc else { return [] }
        let all = UserDefaults.standard.dictionary(forKey: Self.foldStoreKey) as? [String: [String]]
        return all?[doc.standardizedFileURL.path] ?? []
    }

    private func recordFold(json: String) {
        guard let doc = documentID,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["key"] as? String,
              let folded = obj["folded"] as? Bool else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.foldStoreKey) as? [String: [String]] ?? [:]
        let path = doc.standardizedFileURL.path
        var keys = Set(all[path] ?? [])
        if folded { keys.insert(key) } else { keys.remove(key) }
        all[path] = keys.isEmpty ? nil : Array(keys).sorted()
        UserDefaults.standard.set(all, forKey: Self.foldStoreKey)
    }

    /// 換文件時清空狀態，避免跨文件的內容比對誤判（todo 偶爾不顯示的元兇）
    func resetForNewDocument() {
        lastTextFromJS = nil
        lastPushed = nil
        pendingText = nil
    }

    /// @/! 待辦標記補全開關（只有日記啟用）。ready 之後重新套用，重載也不會丟。
    private var markersEnabled = false

    private var lastMarkersSent: (Bool, Int)?

    func setMarkersEnabled(_ enabled: Bool) {
        markersEnabled = enabled
        // sync() 在每次 SwiftUI 更新都會呼叫；值沒變就別再跨行程送 JS
        let sig = (enabled, Self.pomoMinutes)
        if let last = lastMarkersSent, last == sig { return }
        if isReady {
            lastMarkersSent = sig
            webView.evaluateJavaScript(
                "window.__markersEnabled = \(enabled); "
                + "window.__pomoMinutes = \(Self.pomoMinutes)")
        }
    }

    /// 一顆蕃茄的分鐘數（跟蕃茄鐘設定連動），給 @est 進度條換算格數。
    private static var pomoMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: PomodoroModel.SettingsKey.workMinutes)
        return v > 0 ? v : 25
    }

    func pushIfNeeded(_ text: String) {
        guard text != lastTextFromJS, text != lastPushed else { return }
        push(text)
    }

    private func push(_ text: String) {
        guard isReady else {
            pendingText = text
            return
        }
        lastPushed = text
        pushAssets(for: text)
        guard let json = encode(text) else { return }
        // 先告訴編輯器這份日記哪些待辦是收起來的，再載入內容
        if let keys = try? JSONEncoder().encode(foldedKeys(for: documentID)),
           let keysJSON = String(data: keys, encoding: .utf8) {
            webView.evaluateJavaScript("window.setFoldedKeys(\(keysJSON))")
        }
        webView.evaluateJavaScript("window.setMarkdown(\(json)[0])")
    }

    private func encode(_ string: String) -> String? {
        guard let data = try? JSONEncoder().encode([string]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Assets（本地圖片 → data URI 映射表）

    private static let imagePattern = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(([^)\s]+)\)"#)

    private func pushAssets(for text: String) {
        guard let baseDir else { return }
        let ns = text as NSString
        var map: [String: String] = [:]
        Self.imagePattern.enumerateMatches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let m = match else { return }
            let path = ns.substring(with: m.range(at: 1))
            guard !path.hasPrefix("http"), !path.hasPrefix("data:") else { return }
            if let uri = dataURI(for: path, baseDir: baseDir) {
                map[path] = uri
            }
        }
        guard !map.isEmpty,
              let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.mergeAssets(\(json))")
    }

    private func dataURI(for path: String, baseDir: URL) -> String? {
        if let cached = assetCache[path] { return cached }
        let url = baseDir.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        default: mime = "image/png"
        }
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        assetCache[path] = uri
        return uri
    }

    // MARK: - 貼圖

    private func handlePastedImage(base64: String) {
        guard let baseDir else { return }
        // body 可能是 dataURL（data:image/png;base64,xxx）或純 base64
        let raw = base64.contains(",")
            ? String(base64.split(separator: ",", maxSplits: 1)[1])
            : base64
        guard let data = Data(base64Encoded: raw) else { return }

        let dir = baseDir.appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "img-\(f.string(from: .now)).png"
        let path = "assets/\(name)"
        do {
            try data.write(to: dir.appendingPathComponent(name))
        } catch {
            return
        }

        let uri = "data:image/png;base64,\(raw)"
        assetCache[path] = uri
        guard let pathJSON = encode(path), let uriJSON = encode(uri) else { return }
        webView.evaluateJavaScript(
            "window.insertPastedImage(\(pathJSON)[0], \(uriJSON)[0])")
    }
}

extension BlockEditorView {
    // MARK: - HTML template

    /// 用 computed property：內含 L() 本地化字串，語言切換重載編輯器時要重新求值。
    static var template: String { #"""
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <!-- 手機必要：沒有 viewport 會以 980px 桌面寬渲染；鎖縮放避免 iOS 聚焦輸入時自動放大 -->
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
    <link rel="stylesheet" href="katex.min.css">
    <style>
      html, body { background: transparent; margin: 0; }
      body {
        font: 15px/1.7 -apple-system, "PingFang TC", sans-serif;
        color: CanvasText;
        padding: 16px 22px 40vh;
      }
      /* 滑鼠環境才有 gutter（＋ 和 ⋮⋮）：左邊距要放得下兩顆按鈕，
         否則最外層區塊的把手會掛出視窗外、很難點到。手機維持窄邊距。 */
      @media (hover: hover) and (pointer: fine) {
        body { padding-left: 46px; }
      }
      .tiptap:focus { outline: none; }
      .tiptap > * + * { margin-top: 0.4em; }
      .tiptap p { margin: 0; }
      h1 { font-size: 1.6em; margin: 0.5em 0 0.2em; }
      h2 { font-size: 1.3em; margin: 0.5em 0 0.2em; }
      h3 { font-size: 1.1em; margin: 0.4em 0 0.2em; }
      p.is-empty:first-child::before {
        content: attr(data-placeholder);
        color: rgba(127,127,127,0.6);
        float: left; height: 0; pointer-events: none;
      }
      ul, ol { padding-left: 1.4em; margin: 0; }
      ul[data-type="taskList"] { list-style: none; padding-left: 0.15em; }
      ul[data-type="taskList"] li { display: flex; gap: 8px; align-items: flex-start; }
      ul[data-type="taskList"] li > label { flex: 0 0 auto; margin-top: 4px; }
      ul[data-type="taskList"] li > div { flex: 1 1 auto; min-width: 0; }
      /* 打勾只淡化「這一項自己」，不連帶子項目（母子勾選各自獨立） */
      ul[data-type="taskList"] li[data-checked="true"] > div > :not(ul):not(ol) { opacity: 0.55; text-decoration: line-through; }
      /* ---- 待辦摺疊：有子項目的待辦，勾選框後面多一個 ▸ ---- */
      .task-fold-toggle {
        display: inline-block; width: 1em; margin-right: 3px; text-align: center;
        cursor: pointer; user-select: none; color: rgba(127,127,127,0.85);
        transform: rotate(90deg); transition: transform 0.12s ease;
      }
      .task-fold-toggle:hover { color: CanvasText; }
      .task-fold-toggle.folded { transform: rotate(0deg); }
      /* 用摺疊時加上的 class 選，不能用 li[data-type=taskItem]——tiptap 的節點畫面不會加那個屬性 */
      li.task-folded > div > ul,
      li.task-folded > div > ol { display: none; }
      code {
        font-family: ui-monospace, monospace; font-size: 0.9em;
        background: rgba(127,127,127,0.15); padding: 1px 5px; border-radius: 4px;
      }
      pre {
        background: rgba(127,127,127,0.13); padding: 10px 12px;
        border-radius: 8px; overflow-x: auto;
      }
      pre code { background: none; padding: 0; }
      blockquote {
        border-left: 3px solid rgba(127,127,127,0.4);
        margin: 0; padding-left: 12px; opacity: 0.85;
      }
      hr { border: none; border-top: 1px solid rgba(127,127,127,0.3); margin: 12px 0; }
      img { max-width: 100%; border-radius: 6px; }
      .math-inline {
        cursor: pointer; padding: 0 2px; border-radius: 4px;
      }
      .math-inline:hover { background: rgba(127,127,127,0.15); }
      .math-block {
        cursor: pointer; display: block; text-align: center;
        padding: 8px 4px; border-radius: 8px; margin: 4px 0;
      }
      .math-block:hover { background: rgba(127,127,127,0.1); }
      .math-empty { color: rgba(127,127,127,0.6); font-style: italic; }
      #slash-menu, #math-editor {
        position: absolute; z-index: 50; display: none;
        background: Canvas; color: CanvasText;
        border: 1px solid rgba(127,127,127,0.35); border-radius: 10px;
        box-shadow: 0 8px 24px rgba(0,0,0,0.25); padding: 4px;
      }
      #slash-menu { min-width: 190px; max-height: 280px; overflow-y: auto; }
      #math-editor { padding: 10px; width: 340px; }
      #math-editor textarea {
        width: 100%; box-sizing: border-box; min-height: 60px; resize: vertical;
        font-family: ui-monospace, monospace; font-size: 13px;
        background: rgba(127,127,127,0.1); color: CanvasText;
        border: 1px solid rgba(127,127,127,0.3); border-radius: 6px; padding: 6px;
        outline: none;
      }
      #math-preview { padding: 8px 4px; text-align: center; min-height: 24px; overflow-x: auto; }
      #math-editor .row { display: flex; gap: 8px; justify-content: flex-end; margin-top: 6px; }
      #math-editor button {
        font: 13px -apple-system, sans-serif; padding: 3px 12px; border-radius: 6px;
        border: 1px solid rgba(127,127,127,0.35); background: transparent; color: CanvasText;
        cursor: pointer;
      }
      #math-editor button.primary { background: rgba(127,127,127,0.2); }
      .slash-item {
        padding: 6px 10px; border-radius: 6px; font-size: 14px;
        cursor: pointer; display: flex; align-items: center; gap: 8px;
      }
      .slash-item.active { background: rgba(127,127,127,0.18); }
      .slash-hint { margin-left: auto; opacity: 0.45; font-size: 11px; font-family: ui-monospace; }
      .toggle-list { position: relative; padding-left: 22px; }
      .toggle-arrow {
        position: absolute; left: 0; top: 1px;
        width: 18px; height: 22px; border: none; background: none;
        cursor: pointer; color: rgba(127,127,127,0.7); font-size: 12px;
        transition: transform 0.15s; padding: 0;
      }
      .toggle-list.open > .toggle-arrow { transform: rotate(90deg); }
      .toggle-summary-node { font-weight: 500; }
      .toggle-list:not(.open) > .toggle-body > *:not(.toggle-summary-node) { display: none; }
      /* 區塊左側 gutter：＋（插入區塊）與 ⋮⋮（點=選單、拖=移動） */
      .block-gutter {
        position: fixed; z-index: 40; display: flex; align-items: center;
        padding: 2px;   /* 透明外圈加大滑鼠容錯範圍 */
      }
      .block-gutter.hide { display: none; }
      .gutter-btn {
        width: 18px; height: 24px;
        display: flex; align-items: center; justify-content: center;
        border-radius: 5px; color: rgba(127,127,127,0.7);
      }
      .gutter-btn:hover { background: rgba(127,127,127,0.15); color: rgba(127,127,127,1); }
      .plus-btn { cursor: pointer; font-size: 15px; }
      .plus-btn::after { content: "+"; }
      .drag-handle { cursor: grab; font-size: 13px; letter-spacing: -2px; }
      .drag-handle::after { content: "⋮⋮"; }
      .drag-handle:active { cursor: grabbing; }
      #block-menu {
        position: fixed; z-index: 60; display: none;
        background: Canvas; color: CanvasText; min-width: 170px;
        border: 1px solid rgba(127,127,127,0.35); border-radius: 10px;
        box-shadow: 0 8px 24px rgba(0,0,0,0.25); padding: 4px;
        max-height: 320px; overflow-y: auto;
      }
      .slash-item.danger { color: rgb(224, 83, 61); }
      .menu-sep { height: 1px; background: rgba(127,127,127,0.25); margin: 4px 6px; }
      /* 命令輸入行：CLI 式外框，整列、自動長高 */
      .command-input {
        font-family: ui-monospace, monospace;
        font-size: 0.92em;
        background: rgba(127,127,127,0.12);
        border: 1px solid rgba(127,127,127,0.4);
        border-radius: 8px;
        padding: 7px 12px 7px 30px;
        margin: 3px 0;
        position: relative;
      }
      .command-input::before {
        content: "❯";
        position: absolute; left: 12px; opacity: 0.5;
        font-weight: 600;
      }
      /* 標記徽章：一律排在行尾（widget），彼此與最後一個字保持固定間隔 */
      .marker-badge {
        display: inline-block; font-size: 0.76em; line-height: 1.5;
        padding: 0 7px; border-radius: 999px; margin: 0 0 0 8px;
        background: rgba(127,127,127,0.16); cursor: default;
        white-space: nowrap; vertical-align: baseline;
      }
      .badge-due { background: rgba(255,159,10,0.16); color: #cc7d00; }
      .badge-overdue { background: rgba(255,69,58,0.18); color: #e0342a; }
      @media (prefers-color-scheme: dark) {
        .badge-due { color: #ffb340; }
        .badge-overdue { color: #ff6961; }
      }
      .badge-from { opacity: 0.7; }
      .badge-every { background: rgba(191,90,242,0.16); color: #bf5af2; }
      .badge-line { background: rgba(10,132,255,0.16); color: #4da2ff; }
      .badge-pomo button {
        border: none; background: transparent; cursor: pointer;
        font: inherit; padding: 0 3px; opacity: 0.7;
      }
      .badge-pomo button:hover { opacity: 1; }
      .pomo-track { display: inline-flex; gap: 2px; margin: 0 3px; vertical-align: -1px; }
      .pomo-cell {
        width: 9px; height: 7px; border-radius: 2px;
        background: rgba(216,90,48,0.28);
      }
      .pomo-cell.filled { background: #d85a30; }
      .pomo-count { font-size: 0.9em; opacity: 0.8; margin-right: 2px; }
      .marker-hidden { display: none; }
      /* 底部浮動提示（例如：含 @due 的待辦請從 /list 刪除） */
      #rh-hint {
        position: fixed; left: 50%; bottom: 24px;
        transform: translateX(-50%) translateY(8px);
        background: rgba(30,30,32,0.92); color: #fff; font-size: 12px;
        padding: 6px 14px; border-radius: 8px;
        opacity: 0; pointer-events: none;
        transition: opacity .18s, transform .18s; z-index: 99;
      }
      #rh-hint.show { opacity: 1; transform: translateX(-50%) translateY(0); }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <div id="slash-menu"></div>
    <script>
      // 載入錯誤回報（module import 失敗也會觸發）
      window.onerror = function (msg, src, line) {
        try { window.webkit.messageHandlers.jsError.postMessage(msg + " @" + line); } catch (e) {}
      };
      window.addEventListener("unhandledrejection", function (e) {
        try { window.webkit.messageHandlers.jsError.postMessage(String(e.reason)); } catch (err) {}
      });
    </script>
    <div id="math-editor">
      <textarea id="math-input" placeholder="\#(L("LaTeX，例如")) \frac{S_{im}S_{jm}}{S_{0m}}"></textarea>
      <div id="math-preview"></div>
      <div class="row">
        <button id="math-delete">\#(L("刪除"))</button>
        <button id="math-done" class="primary">\#(L("完成")) ⏎</button>
      </div>
    </div>
    <script>
      // 依賴由 Swift 端以 WKUserScript 注入本地 editor-bundle.js（IIFE，global RHEditor），離線可用。
      // 整段包進 IIFE：頂層 const Node/Image 會遮蔽 DOM 全域（bundle 內部要用 window.Node
      // 判斷 TEXT_NODE），造成 markdown 解析炸掉、內容顯示不出來。
      (() => {
      const { Editor, Extension, Node, mergeAttributes, InputRule,
              TextSelection, NodeSelection, Fragment, Plugin, PluginKey,
              Decoration, DecorationSet,
              StarterKit, TaskList, TaskItem, Image, Placeholder,
              Markdown, katex } = RHEditor;

      // ---- Assets（相對路徑 → data URI）----
      let assetMap = {};
      window.mergeAssets = function (map) {
        Object.assign(assetMap, map);
        if (window.__editor) refreshImages();
      };

      function renderKatex(el, latex, displayMode) {
        if (!latex || !latex.trim()) {
          el.innerHTML = '<span class="math-empty">\#(L("點擊編輯公式"))</span>';
          return;
        }
        try {
          katex.render(latex, el, { displayMode, throwOnError: false });
        } catch (e) {
          el.textContent = latex;
        }
      }

      // ---- 數學節點 ----
      function makeMathNode(name, isBlock) {
        return Node.create({
          name,
          group: isBlock ? "block" : "inline",
          inline: !isBlock,
          atom: true,
          selectable: true,
          addAttributes() {
            return { latex: { default: "" } };
          },
          parseHTML() {
            return [{ tag: `span[data-${name}]` }];
          },
          renderHTML({ node, HTMLAttributes }) {
            return ["span", mergeAttributes(HTMLAttributes, { [`data-${name}`]: "" }),
                    node.attrs.latex];
          },
          addInputRules() {
            const type = this.type;
            const find = isBlock
              ? /\$\$([^$]+)\$\$$/
              : /\$([^$\s][^$]*?)\$$/;
            // 自訂 handler：明確刪除整個 match（含 $ 定界符）再插入節點
            return [new InputRule({
              find,
              handler: ({ range, match, chain }) => {
                chain()
                  .deleteRange(range)
                  .insertContent({ type: type.name, attrs: { latex: match[1].trim() } })
                  .run();
              }
            })];
          },
          addNodeView() {
            return ({ node, getPos, editor }) => {
              const dom = document.createElement("span");
              dom.className = isBlock ? "math-block" : "math-inline";
              renderKatex(dom, node.attrs.latex, isBlock);
              dom.addEventListener("mousedown", e => {
                e.preventDefault();
                openMathEditor(editor, getPos, isBlock);
              });
              return {
                dom,
                update(updated) {
                  if (updated.type.name !== name) return false;
                  renderKatex(dom, updated.attrs.latex, isBlock);
                  return true;
                }
              };
            };
          },
          addStorage() {
            return {
              markdown: {
                serialize(state, node) {
                  if (isBlock) {
                    state.write("$$" + node.attrs.latex + "$$");
                    state.closeBlock(node);
                  } else {
                    state.write("$" + node.attrs.latex + "$");
                  }
                },
                parse: {}
              }
            };
          }
        });
      }
      const MathInline = makeMathNode("mathInline", false);
      const MathBlock = makeMathNode("mathBlock", true);

      // ---- 圖片：src 為相對路徑，顯示時查 assetMap ----
      const LocalImage = Image.extend({
        addNodeView() {
          return ({ node }) => {
            const img = document.createElement("img");
            img.src = assetMap[node.attrs.src] || node.attrs.src;
            return {
              dom: img,
              update(updated) {
                if (updated.type.name !== "image") return false;
                img.src = assetMap[updated.attrs.src] || updated.attrs.src;
                return true;
              }
            };
          };
        }
      });

      function refreshImages() {
        document.querySelectorAll(".tiptap img").forEach(img => {
          const src = img.getAttribute("src");
          if (assetMap[src]) img.src = assetMap[src];
        });
      }

      // ---- Toggle list（摺疊區塊）----
      // 結構：toggleList = toggleSummary（行內標題，正常編輯）+ block+（內容）
      // markdown 表示法：> [!toggle] 標題（內容為 blockquote 後續段落）
      const ToggleSummary = Node.create({
        name: "toggleSummary",
        content: "inline*",
        defining: true,
        selectable: false,
        parseHTML() {
          return [{ tag: "div[data-toggle-summary]" }];
        },
        renderHTML({ HTMLAttributes }) {
          return ["div", mergeAttributes(HTMLAttributes,
            { "data-toggle-summary": "", class: "toggle-summary-node" }), 0];
        },
        addKeyboardShortcuts() {
          return {
            // 標題列按 Enter → 跳到內容第一個 block
            Enter: ({ editor }) => {
              const { $from } = editor.state.selection;
              for (let d = $from.depth; d > 0; d--) {
                if ($from.node(d).type.name === "toggleSummary") {
                  editor.commands.setTextSelection($from.after(d) + 1);
                  return true;
                }
              }
              return false;
            },
            // 標題最前面按 Backspace → 解開整個 toggle（標題變一般段落、內容放出來），
            // 否則 defining + selectable:false 的外殼永遠刪不掉。
            Backspace: ({ editor }) => {
              const { state } = editor;
              const { $from, empty } = state.selection;
              if (!empty || $from.parentOffset !== 0) return false;
              let sumDepth = -1;
              for (let d = $from.depth; d > 0; d--) {
                if ($from.node(d).type.name === "toggleSummary") { sumDepth = d; break; }
              }
              if (sumDepth < 1) return false;
              const listDepth = sumDepth - 1;
              if ($from.node(listDepth).type.name !== "toggleList") return false;
              const listNode = $from.node(listDepth);
              const from = $from.before(listDepth), to = $from.after(listDepth);
              const summary = listNode.firstChild;
              const para = state.schema.nodes.paragraph.create(
                null, summary ? summary.content : null);
              const frag = Fragment.from([para])
                .append(listNode.content.cut(summary.nodeSize));
              let tr = state.tr.replaceWith(from, to, frag);
              tr = tr.setSelection(TextSelection.create(tr.doc, from + 1));
              editor.view.dispatch(tr);
              return true;
            }
          };
        },
        addStorage() {
          return {
            markdown: {
              serialize(state, node) { state.renderInline(node); },
              parse: {}
            }
          };
        }
      });

      const ToggleList = Node.create({
        name: "toggleList",
        group: "block",
        content: "toggleSummary block+",
        defining: true,
        addAttributes() {
          return { open: { default: true } };
        },
        parseHTML() {
          return [{ tag: "div[data-toggle]" }];
        },
        renderHTML({ HTMLAttributes }) {
          return ["div", mergeAttributes(HTMLAttributes, { "data-toggle": "" }), 0];
        },
        addNodeView() {
          return ({ node, getPos, editor }) => {
            const dom = document.createElement("div");
            dom.className = "toggle-list" + (node.attrs.open ? " open" : "");
            const arrow = document.createElement("button");
            arrow.className = "toggle-arrow";
            arrow.textContent = "▸";
            arrow.contentEditable = "false";
            arrow.addEventListener("mousedown", e => {
              e.preventDefault();
              e.stopPropagation();
              const pos = getPos();
              const current = editor.state.doc.nodeAt(pos);
              if (!current) return;
              editor.view.dispatch(editor.state.tr.setNodeMarkup(
                pos, undefined, { open: !current.attrs.open }));
            });
            const body = document.createElement("div");
            body.className = "toggle-body";
            dom.appendChild(arrow);
            dom.appendChild(body);
            return {
              dom,
              contentDOM: body,
              update(updated) {
                if (updated.type.name !== "toggleList") return false;
                dom.className = "toggle-list" + (updated.attrs.open ? " open" : "");
                return true;
              }
            };
          };
        },
        addStorage() {
          return {
            markdown: {
              serialize(state, node) {
                state.wrapBlock("> ", null, node, () => {
                  node.forEach((child, _, i) => {
                    if (i === 0) {
                      state.write("[!toggle] ");
                      state.renderInline(child);
                      state.closeBlock(child);
                    } else {
                      state.render(child, node, i);
                    }
                  });
                });
              },
              parse: {}
            }
          };
        }
      });

      // 載入時把「> [!toggle] …」blockquote 轉回 toggleList 節點（支援巢狀，重複跑到穩定）
      function togglify() {
        for (let pass = 0; pass < 5; pass++) {
          const { state } = editor;
          const replacements = [];
          state.doc.descendants((node, pos) => {
            if (node.type.name !== "blockquote") return true;
            const first = node.firstChild;
            if (!first || first.type.name !== "paragraph") return true;
            const text = first.textContent;
            if (!text.startsWith("[!toggle]")) return true;
            const summaryStr = text.slice(9).trim();
            const summaryNode = state.schema.nodes.toggleSummary.create(
              null, summaryStr ? state.schema.text(summaryStr) : null);
            let rest = node.content.cut(first.nodeSize);
            if (rest.childCount === 0) {
              rest = Fragment.from(state.schema.nodes.paragraph.create());
            }
            replacements.push({
              from: pos, to: pos + node.nodeSize,
              node: state.schema.nodes.toggleList.create(
                { open: true }, Fragment.from([summaryNode]).append(rest))
            });
            return false;
          });
          if (!replacements.length) break;
          let tr = state.tr;
          for (const r of replacements.reverse()) {
            tr = tr.replaceWith(r.from, r.to, r.node);
          }
          editor.view.dispatch(tr);
        }
      }

      // ---- 空清單項目按 Backspace → 一路 lift 到最外層 ----
      const ExitListOnBackspace = Extension.create({
        name: "exitListOnBackspace",
        priority: 1000,
        addKeyboardShortcuts() {
          return {
            Backspace: ({ editor }) => {
              const { state } = editor;
              const { $from, empty } = state.selection;
              if (!empty || $from.parentOffset !== 0) return false;
              if ($from.parent.type.name !== "paragraph") return false;
              if ($from.parent.content.size !== 0) return false;

              const listAncestor = ($f) => {
                for (let d = $f.depth; d > 0; d--) {
                  const name = $f.node(d).type.name;
                  if (name === "taskItem" || name === "listItem") return name;
                }
                return null;
              };

              // 情況 A：空段落在清單「內」→ 一路 lift 到最外層
              if (listAncestor($from)) {
                let guard = 0;
                while (guard++ < 10) {
                  const inside = listAncestor(editor.state.selection.$from);
                  if (!inside) break;
                  if (!editor.commands.liftListItem(inside)) break;
                }
                return true;
              }

              // 情況 B：空段落的前一個 sibling 是清單 → 刪掉空段落、游標回到清單最後
              const paraPos = $from.before();
              const $para = state.doc.resolve(paraPos);
              const prev = $para.nodeBefore;
              if (prev && ["bulletList", "orderedList", "taskList"].includes(prev.type.name)) {
                let tr = state.tr.delete(paraPos, paraPos + $from.parent.nodeSize);
                tr = tr.setSelection(TextSelection.near(tr.doc.resolve(paraPos), -1));
                editor.view.dispatch(tr.scrollIntoView());
                return true;
              }
              return false;
            }
          };
        }
      });

      // ---- 待辦裡的 Backspace（toggle 內容不會被整個拆掉）----
      // 以前在 toggle 內容的空行按 Backspace，ExitListOnBackspace 會把「包著這一行的項目」
      // ——也就是 toggle 本身——一路拉出清單，整個 toggle 不見。規則改成：
      //   • 內容行（項目的第 2 個以後的段落）：空行只刪這一行；有字就接到上一行，不離開 toggle
      //   • 待辦標題開頭：有子項目＝先拿掉 toggle（子待辦移到後面同一層）；
      //     沒有＝整項原地變回一般文字（子待辦留在母項目裡）
      const ITEM_TYPES = ["taskItem", "listItem"];

      function lastTextblockEnd(node, start) {
        let end = null;
        node.descendants((n, p) => { if (n.isTextblock) end = start + 1 + p + 1 + n.content.size; });
        return end;
      }

      function toggleAwareBackspace(ed) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (ed.view.composing) return false;   // 注音選字中的 Backspace 是刪注音
        if (!empty || $from.parentOffset !== 0 || !$from.parent.isTextblock) return false;
        const d = $from.depth;
        if (d < 2) return false;
        const item = $from.node(d - 1);
        if (!ITEM_TYPES.includes(item.type.name)) return false;
        const idx = $from.index(d - 1);
        const block = $from.parent;
        const blockStart = $from.before();

        // 內容行
        if (idx > 0) {
          const prev = item.child(idx - 1);
          const prevStart = blockStart - prev.nodeSize;
          let tr = state.tr;
          if (block.content.size === 0) {
            tr.delete(blockStart, blockStart + block.nodeSize);
            tr.setSelection(TextSelection.near(tr.doc.resolve(blockStart), -1));
          } else if (prev.isTextblock) {
            return false;   // 預設 joinBackward：接到上一段，還在同一個項目裡
          } else {
            const end = lastTextblockEnd(prev, prevStart);
            if (end === null) return true;
            tr.delete(blockStart, blockStart + block.nodeSize);
            tr.insert(end, block.content);
            tr.setSelection(TextSelection.create(tr.doc, end));
          }
          ed.view.dispatch(tr.scrollIntoView());
          return true;
        }

        // 標題行
        const itemPos = $from.before(d - 1);
        const listDepth = d - 2;
        const list = $from.node(listDepth);
        if (hasChildList(item)) {
          // 拿掉 toggle：子清單的項目搬到這一項後面（同一層）。只處理同型清單，其他情況不動手。
          const childItems = [];
          let ok = true;
          item.forEach(child => {
            if (child.type === list.type) child.forEach(ci => childItems.push(ci));
            else if (["taskList", "bulletList", "orderedList"].includes(child.type.name)) ok = false;
          });
          if (!ok || !childItems.length) return true;
          const kept = [];
          item.forEach(child => { if (child.type !== list.type) kept.push(child); });
          const newItem = item.type.create(item.attrs, kept);
          const tr = state.tr.replaceWith(itemPos, itemPos + item.nodeSize, [newItem, ...childItems]);
          tr.setSelection(TextSelection.create(tr.doc, itemPos + 2));
          ed.view.dispatch(tr.scrollIntoView());
          return true;
        }
        // 沒有子項目 → 整項（標題＋內容行）原地變回一般文字：
        // 子項目就留在母項目裡；最外層就變成清單之間的段落。
        // （預設的 lift 只拉出標題那段，內容行會被拆成一個新的待辦，很怪）
        {
          const at = $from.index(listDepth);
          const before = [], after = [];
          list.forEach((ci, _, i) => { if (i < at) before.push(ci); else if (i > at) after.push(ci); });
          const parts = [];
          if (before.length) parts.push(list.type.create(list.attrs, before));
          item.forEach(c => parts.push(c));
          if (after.length) parts.push(list.type.create(list.attrs, after));
          const listPos = $from.before(listDepth);
          const tr = state.tr.replaceWith(listPos, listPos + list.nodeSize, parts);
          const caret = listPos + (before.length ? parts[0].nodeSize : 0) + 1;
          tr.setSelection(TextSelection.create(tr.doc, caret));
          ed.view.dispatch(tr.scrollIntoView());
          return true;
        }
      }

      const ToggleAwareBackspace = Extension.create({
        name: "toggleAwareBackspace",
        priority: 1100,   // 比 ExitListOnBackspace（1000）先
        addKeyboardShortcuts() {
          return { Backspace: () => toggleAwareBackspace(this.editor) };
        }
      });

      // ---- Slash 選單項目 ----
      // label 由 Swift 端本地化注入；match 保留中英關鍵字，兩種語言都搜得到。
      const slashItems = [
        { label: "\#(L("文字"))", hint: "", match: "text paragraph 文字",
          run: ed => ed.chain().focus().setParagraph().run() },
        { label: "\#(L("標題 1"))", hint: "#", match: "h1 heading1 標題",
          run: ed => ed.chain().focus().setHeading({ level: 1 }).run() },
        { label: "\#(L("標題 2"))", hint: "##", match: "h2 heading2 標題",
          run: ed => ed.chain().focus().setHeading({ level: 2 }).run() },
        { label: "\#(L("標題 3"))", hint: "###", match: "h3 heading3 標題",
          run: ed => ed.chain().focus().setHeading({ level: 3 }).run() },
        { label: "\#(L("項目清單"))", hint: "-", match: "bullet list ul 項目 清單",
          run: ed => ed.chain().focus().toggleBulletList().run() },
        { label: "\#(L("編號清單"))", hint: "1.", match: "ordered number ol 編號",
          run: ed => ed.chain().focus().toggleOrderedList().run() },
        { label: "\#(L("待辦清單"))", hint: "[ ]", match: "todo task checkbox 待辦",
          run: ed => ed.chain().focus().toggleTaskList().run() },
        { label: "\#(L("命令列"))", hint: "/todo /h1 /go /list …", match: "cmd command line 命令 指令",
          run: ed => ed.chain().focus().setNode("commandInput").run() },
        { label: "\#(L("行內公式"))", hint: "$", match: "math inline latex eq equation 行內 公式 數學",
          run: ed => {
            ed.chain().focus().insertContent({ type: "mathInline", attrs: { latex: "" } }).run();
          } },
        { label: "\#(L("數學公式（區塊）"))", hint: "$$", match: "math block latex eq equation 數學 公式 區塊",
          run: ed => {
            ed.chain().focus().insertContent({ type: "mathBlock", attrs: { latex: "" } }).run();
          } },
        { label: "\#(L("摺疊清單"))", hint: "▸", match: "toggle details collapse fold 摺疊 折疊 收合",
          run: ed => {
            // 在待辦的標題行選它＝要可摺疊的待辦（不是在待辦裡塞一個摺疊區塊，版面會壞）
            if (makeTaskFoldable(ed)) return;
            ed.chain().focus().insertContent({
              type: "toggleList",
              attrs: { open: true },
              content: [{ type: "toggleSummary" }, { type: "paragraph" }]
            }).run();
          } },
        { label: "\#(L("引用"))", hint: ">", match: "quote blockquote 引用",
          run: ed => ed.chain().focus().toggleBlockquote().run() },
        { label: "\#(L("程式碼"))", hint: "```", match: "code 程式 代碼",
          run: ed => ed.chain().focus().toggleCodeBlock().run() },
        { label: "\#(L("分隔線"))", hint: "---", match: "divider hr rule 分隔",
          run: ed => ed.chain().focus().setHorizontalRule().run() }
      ];

      let applying = false;
      let sendTimer = null;

      // ---- 命令輸入行（/command 或 /cmd → 整行變成 CLI 式輸入框）----
      const CommandInput = Node.create({
        name: "commandInput",
        group: "block",
        content: "inline*",
        defining: true,
        addStorage() {
          return {
            markdown: {
              // 萬一命令行沒執行就存檔：當一般段落序列化，不會弄壞檔案
              serialize(state, node) { state.renderInline(node); state.closeBlock(node); },
              parse: {}
            }
          };
        },
        parseHTML() { return [{ tag: 'div[data-type="command-input"]' }]; },
        renderHTML({ HTMLAttributes }) {
          return ["div", mergeAttributes(HTMLAttributes,
            { "data-type": "command-input", class: "command-input" }), 0];
        },
        addInputRules() {
          return [new InputRule({
            find: /^\/(?:command|cmd)\s$/i,
            handler: ({ range, chain }) => {
              chain.deleteRange(range).setNode("commandInput").run();
            }
          })];
        }
      });

      // 命令執行：Enter 在命令行（或 /todo 開頭的段落）觸發
      function runCommandLine(ed) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (!empty || !$from.parent.isTextblock) return false;
        const isCmd = $from.parent.type.name === "commandInput";
        const start = $from.start(), end = $from.end();
        const text = state.doc.textBetween(start, end, "\n").trim();

        // /todo /toggle 標題（順序可以反過來）：可摺疊的待辦——待辦底下先開好一個空的子待辦，
        // 摺疊箭頭馬上出現、游標停在子項目上。必須排在 /todo 前面，
        // 否則 /todo 會先吃掉整行、把「/toggle 標題」當成待辦的文字。
        let fm = text.match(/^\/(?:todo\s+\/toggle|toggle\s+\/todo)(?:\s+(.*))?$/i);
        if (fm) {
          const title = (fm[1] || "").trim();
          const nodeFrom = $from.before(), nodeTo = nodeFrom + $from.parent.nodeSize;
          const emptyTask = { type: "taskItem", attrs: { checked: false },
                              content: [{ type: "paragraph" }] };
          // 游標位置：taskList(1) taskItem(1) paragraph(1) 標題 /paragraph(1) taskList(1) taskItem(1) paragraph(1)
          const childPos = nodeFrom + 7 + title.length;
          ed.chain()
            .insertContentAt({ from: nodeFrom, to: nodeTo }, {
              type: "taskList",
              content: [{
                type: "taskItem", attrs: { checked: false },
                content: [
                  { type: "paragraph", content: title ? [{ type: "text", text: title }] : [] },
                  { type: "taskList", content: [emptyTask] }
                ]
              }]
            })
            .setTextSelection(title ? childPos : nodeFrom + 3)   // 沒標題就先停在母項目
            .run();
          return true;
        }

        // todo：整行變成待辦項目（標記是純文字，@due/@every 由播種引擎接手）
        // 命令一律要以 / 開頭；cmd 裡打純文字（如 list）不觸發任何行為。
        let m = text.match(/^\/todo\s+(.+)$/i);
        if (m) {
          const content = m[1].trim();
          let chain = ed.chain()
            .setNode("paragraph")
            .insertContentAt({ from: start, to: end },
                             [{ type: "text", text: content }])
            .setTextSelection(start + content.length);
          // 命令列是獨立的一行：一律「包進」待辦清單（相鄰的清單會自動接起來）。
          // 不能用 toggleTaskList——命令列在母項目底下時它已經身在待辦清單裡，
          // toggle 會反過來把清單解除，第二個子項目就變成普通文字。
          chain = isCmd ? chain.wrapInList("taskList") : chain.toggleTaskList();
          chain.run();
          return true;
        }
        // list：開任務總覽（原生視窗），命令行清空還原
        if (/^\/(list|tasks)$/i.test(text)) {
          try { window.webkit.messageHandlers.command.postMessage("list"); } catch (e) {}
          let chain = ed.chain();
          if (end > start) chain = chain.deleteRange({ from: start, to: end });
          chain.setNode("paragraph").run();
          return true;
        }
        // 空的 todo 命令（自動接續後沒打內容就按 Enter）→ 取消，還原成一般段落
        if (isCmd && /^\/todo\s*$/i.test(text)) {
          let chain = ed.chain();
          if (end > start) chain = chain.deleteRange({ from: start, to: end });
          chain.setNode("paragraph").run();
          return true;
        }
        // 內容指令：就地把這一行變成對應區塊（和底部命令列同一套）
        let hm = text.match(/^\/h([123])\s+(.+)$/i);
        if (hm) {
          ed.chain()
            .setNode("paragraph")
            .insertContentAt({ from: start, to: end },
                             [{ type: "text", text: hm[2].trim() }])
            .setNode("heading", { level: +hm[1] })
            .run();
          return true;
        }
        let bm = text.match(/^\/(bullet|num)\s+(.+)$/i);
        if (bm) {
          let chain = ed.chain()
            .setNode("paragraph")
            .insertContentAt({ from: start, to: end },
                             [{ type: "text", text: bm[2].trim() }]);
          chain = bm[1].toLowerCase() === "num"
            ? chain.toggleOrderedList() : chain.toggleBulletList();
          chain.run();
          return true;
        }
        let tm = text.match(/^\/toggle\s+(.+)$/i);
        if (tm) {
          const title = tm[1].trim();
          const nodeFrom = $from.before(), nodeTo = nodeFrom + $from.parent.nodeSize;
          ed.chain().insertContentAt({ from: nodeFrom, to: nodeTo }, {
            type: "toggleList",
            attrs: { open: true },
            content: [
              { type: "toggleSummary",
                content: title ? [{ type: "text", text: title }] : [] },
              { type: "paragraph" }
            ]
          }).run();
          return true;
        }
        // /go：跳到那一天（交給 Swift 端；先把這一行清掉，免得留在原本那天的檔案裡）
        let gm = text.match(/^\/(?:go|goto|day)\b\s*(.*)$/i);
        if (gm) {
          let chain = ed.chain();
          if (end > start) chain = chain.deleteRange({ from: start, to: end });
          chain.setNode("paragraph").run();
          try {
            window.webkit.messageHandlers.command.postMessage("go:" + gm[1].trim());
          } catch (e) {}
          return true;
        }
        if (isCmd) return true;   // 未知命令：吞掉 Enter，留在輸入行讓使用者改
        return false;
      }

      // 待辦行按 Enter → 新行自動變成命令輸入行「/todo 」：
      // 打 @標記 全程保持原文，Enter 提交才變成待辦 + 徽章（省去事後點回去編輯）。
      //   • 行尾（容忍游標後只剩隱藏的 @標記/空白）→ 插在下面
      //   • 行首 → 插在上面（往上開新行也給 cmd）
      // 這樣標記永遠不會被劈到別行（先前蕃茄鐘被拖下來的成因）。
      function todoEnterToCommand(ed) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (!empty || $from.parent.type.name !== "paragraph") return false;
        if ($from.parent.content.size === 0) return false;   // 空項目 → 預設行為（結束清單）
        const atStart = $from.parentOffset === 0;
        if (!atStart) {
          const rest = $from.parent.textContent.slice($from.parentOffset);
          const markersOnly =
            /^(?:\s*(?:@(?:due|from|on|est|every|remind|line|pomo)\([^)]*\)|!(?:high|low)\b))*\s*$/i;
          if (!markersOnly.test(rest)) return false;         // 游標在正文中間 → 一般換行
        }
        let itemDepth = -1;
        for (let d = $from.depth; d > 0; d--) {
          if ($from.node(d).type.name === "taskItem") { itemDepth = d; break; }
        }
        if (itemDepth < 1) return false;
        const listDepth = itemDepth - 1;
        const list = $from.node(listDepth);
        if (list.type.name !== "taskList") return false;
        const idx = $from.index(listDepth);
        let tr = state.tr;
        let insertPos;
        if (atStart) {
          if (idx === 0) {
            insertPos = $from.before(listDepth);             // 第一項：插在清單前面
          } else {
            const itemBefore = $from.before(itemDepth);      // 中間項：把清單劈成兩段
            tr = tr.split(itemBefore, 1);
            insertPos = itemBefore + 1;
          }
        } else if (idx === list.childCount - 1) {
          insertPos = $from.after(listDepth);                // 最後一項：插在清單後面
        } else {
          const itemAfter = $from.after(itemDepth);          // 中間項：把清單劈成兩段
          tr = tr.split(itemAfter, 1);
          insertPos = itemAfter + 1;
        }
        const node = state.schema.nodes.commandInput.create(null, state.schema.text("/todo "));
        tr = tr.insert(insertPos, node);
        tr = tr.setSelection(TextSelection.create(tr.doc, insertPos + 1 + node.content.size));
        ed.view.dispatch(tr.scrollIntoView());
        return true;
      }

      // ---- 標記保護：標記只能從 /list 改（蕃茄 −/＋ 除外），編輯器裡刪不掉 ----
      const MARKER_RE = /@(?:due|from|on|est|every|remind|line|pomo)\([^)]*\)|!(?:high|low)\b/gi;

      function markerRanges(text) {
        const out = [];
        MARKER_RE.lastIndex = 0;
        let m;
        while ((m = MARKER_RE.exec(text))) out.push([m.index, m.index + m[0].length]);
        return out;
      }

      // 底部浮動提示（自動淡出）
      function showHint(msg) {
        let el = document.getElementById("rh-hint");
        if (!el) {
          el = document.createElement("div");
          el.id = "rh-hint";
          document.body.appendChild(el);
        }
        el.textContent = msg;
        el.classList.add("show");
        clearTimeout(showHint._t);
        showHint._t = setTimeout(() => el.classList.remove("show"), 1800);
      }

      function selectionHasDue(state) {
        const sel = state.selection;
        if (sel.empty) return false;
        return /@due\(/i.test(state.doc.textBetween(sel.from, sel.to, "\n"));
      }

      // Backspace/Delete：游標貼著標記（或在其隱藏文字裡）→ 跳過整顆標記、不刪除；
      // 範圍選取蓋到 @due → 擋下（含 @due 的待辦請從 /list 刪，明天還是會播種回來）。
      function guardMarkerDelete(ed, forward) {
        const { state } = ed;
        if (selectionHasDue(state)) {
          showHint("\#(L("含 @due 的待辦請從 /list 刪除"))");
          return true;
        }
        const { $from, empty } = state.selection;
        if (!empty) return false;
        if (!$from.parent.isTextblock || $from.parent.type.name === "commandInput") return false;
        const text = $from.parent.textContent;
        const off = $from.parentOffset;
        for (const [ms, me] of markerRanges(text)) {
          const inside = off > ms && off < me;
          if (!forward && (off === me || inside)) {
            ed.commands.setTextSelection($from.start() + ms);
            return true;
          }
          if (forward && (off === ms || inside)) {
            ed.commands.setTextSelection($from.start() + me);
            return true;
          }
        }
        return false;
      }

      // 方向鍵跳過隱藏的標記文字，游標不會「卡」在看不見的字裡
      function skipMarkerArrow(ed, dir) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (!empty || !$from.parent.isTextblock) return false;
        if ($from.parent.type.name === "commandInput") return false;
        const text = $from.parent.textContent;
        const off = $from.parentOffset;
        for (const [ms, me] of markerRanges(text)) {
          if (dir < 0 && off === me) {
            ed.commands.setTextSelection($from.start() + ms);
            return true;
          }
          if (dir > 0 && off === ms) {
            ed.commands.setTextSelection($from.start() + me);
            return true;
          }
          if (off > ms && off < me) {
            ed.commands.setTextSelection($from.start() + (dir < 0 ? ms : me));
            return true;
          }
        }
        return false;
      }

      // 命令行的 Backspace：有字照常刪；「已經空了」再按一下才變回一般段落。
      // 永遠不往上併回待辦行（否則 Enter → Backspace → Enter 會死循環）。
      function cmdBackspaceToParagraph(ed) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (!empty || $from.parent.type.name !== "commandInput") return false;
        if ($from.parent.textContent === "") {
          ed.commands.setNode("paragraph");
          return true;
        }
        if ($from.parentOffset === 0) return true;   // 行首（還有字）：不往上併行
        return false;
      }

      // 待辦行 Shift+Enter → 在該項目底下開縮排子項目（一般 bullet，不帶 checkbox）。
      // 子項目只屬於當天，不會被播種複製；徽章仍固定在父行行尾。
      function todoShiftEnterSubItem(ed) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (!empty) return false;
        let itemDepth = -1;
        for (let d = $from.depth; d > 0; d--) {
          if ($from.node(d).type.name === "taskItem") { itemDepth = d; break; }
        }
        if (itemDepth < 1) return false;
        const types = state.schema.nodes;
        const item = $from.node(itemDepth);
        const endOfItem = $from.end(itemDepth);
        let tr = state.tr, caret;
        if (item.lastChild && item.lastChild.type.name === "bulletList") {
          tr = tr.insert(endOfItem - 1, types.listItem.createAndFill());
          caret = endOfItem + 1;
        } else {
          tr = tr.insert(endOfItem, types.bulletList.createAndFill());
          caret = endOfItem + 3;
        }
        tr = tr.setSelection(TextSelection.create(tr.doc, caret));
        ed.view.dispatch(tr.scrollIntoView());
        return true;
      }

      const CommandLine = Extension.create({
        name: "commandLine",
        // 要贏過 TaskItem 的 Enter（splitListItem 會先接手），否則
        // todoEnterToCommand 在待辦行永遠輪不到。
        priority: 1000,
        addKeyboardShortcuts() {
          return {
            Enter: () => runCommandLine(this.editor) || todoEnterToCommand(this.editor),
            "Shift-Enter": () => todoShiftEnterSubItem(this.editor),
            Backspace: () => cmdBackspaceToParagraph(this.editor)
              || guardMarkerDelete(this.editor, false),
            Delete: () => guardMarkerDelete(this.editor, true),
            "Mod-x": () => {
              if (selectionHasDue(this.editor.state)) {
                showHint("\#(L("含 @due 的待辦請從 /list 刪除"))");
                return true;
              }
              return false;
            },
            ArrowLeft: () => skipMarkerArrow(this.editor, -1),
            ArrowRight: () => skipMarkerArrow(this.editor, 1),
            Escape: () => {
              const { $from } = this.editor.state.selection;
              if ($from.parent.type.name !== "commandInput") return false;
              return this.editor.commands.setNode("paragraph");
            }
          };
        }
      });

      // ---- 標記徽章：@due/@est/@remind… 一律渲染成元件（游標在該行也不退回原文）----
      // 原文仍是唯一真實來源；要改標記請走 /list 任務總覽或源碼模式。
      function pomoMinutes() { return Math.max(1, window.__pomoMinutes || 25); }

      function parseDateArg(s) {
        s = s.trim();
        let m = s.match(/^(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})$/);
        if (m) return new Date(+m[1], +m[2] - 1, +m[3]);
        m = s.match(/^(\d{1,2})[\/-](\d{1,2})$/);
        if (m) return new Date(new Date().getFullYear(), +m[1] - 1, +m[2]);
        return null;
      }
      // 要「數字＋單位」才算：@est() 或 @est(3) 是還沒打完，不渲染成徽章、保留原文
      function parseEstMinutes(s) {
        s = s.trim().toLowerCase();
        let m = s.match(/^(\d+(?:\.\d+)?)\s*(?:h|hr|hrs)$/);
        if (m) return Math.round(parseFloat(m[1]) * 60);
        m = s.match(/^(\d+(?:\.\d+)?)\s*(?:m|min|mins)$/);
        if (m) return Math.round(parseFloat(m[1]));
        return null;
      }
      function startOfDay(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()); }

      function badgeDom(cls, text) {
        const s = document.createElement("span");
        s.className = "marker-badge " + cls;
        s.textContent = text;
        // 點徽章不做事（不再把游標移進原文）；避免點擊把游標放進隱藏的標記文字裡
        s.onmousedown = e => e.preventDefault();
        return s;
      }

      // 加減鈕改 @pomo(n)（純文字標記，只是任務自己的進度，不動蕃茄鐘統計）
      function adjustPomo(blockBase, delta) {
        const ed = window.__editor;
        const node = ed.state.doc.resolve(blockBase).parent;
        const text = node.textContent;
        let m = text.match(/@pomo\((\d*)\)/i);
        if (m) {
          const v = Math.max(0, (parseInt(m[1]) || 0) + delta);
          const from = blockBase + m.index, to = from + m[0].length;
          ed.chain().insertContentAt({ from, to },
            [{ type: "text", text: "@pomo(" + v + ")" }]).run();
        } else if (delta > 0) {
          const e = text.match(/@est\([^)]*\)/i);
          const at = e ? blockBase + e.index + e[0].length : blockBase + text.length;
          ed.chain().insertContentAt({ from: at, to: at },
            [{ type: "text", text: " @pomo(1)" }]).run();
        }
      }

      // 🍅 + 分段進度條 + k/n + −/＋
      function pomoBadgeDom(estMin, done, blockBase) {
        const wrap = document.createElement("span");
        wrap.className = "marker-badge badge-pomo";
        wrap.onmousedown = e => e.preventDefault();
        function btn(t, delta) {
          const b = document.createElement("button");
          b.textContent = t;
          b.onmousedown = e => {
            e.preventDefault(); e.stopPropagation();
            adjustPomo(blockBase, delta);
          };
          return b;
        }
        const icon = document.createElement("span");
        icon.textContent = "🍅";
        icon.style.marginRight = "2px";
        const total = estMin != null
          ? Math.max(1, Math.ceil(estMin / pomoMinutes()))
          : Math.max(done, 1);
        const track = document.createElement("span");
        track.className = "pomo-track";
        const shown = Math.min(total, 10);   // 太多顆時格子最多 10，數字仍準確
        for (let i = 0; i < shown; i++) {
          const cell = document.createElement("span");
          cell.className = "pomo-cell" + (i < Math.round(done / total * shown) ? " filled" : "");
          track.appendChild(cell);
        }
        const count = document.createElement("span");
        count.className = "pomo-count";
        count.textContent = done + "/" + total;
        wrap.append(icon, btn("−", -1), track, count, btn("+", +1));
        return wrap;
      }

      // rangeFrom/rangeTo 省略＝整份文件；有給就只處理該範圍內的 textblock
      // （打字時只重建受影響的那幾塊，不必掃全篇——文件愈長差愈多）。
      function buildBadgeDecos(state, rangeFrom, rangeTo) {
        const decos = [];
        const todayD = startOfDay(new Date());
        const all = rangeFrom === undefined;
        const walk = (node, pos) => {
          if (!node.isTextblock) return true;
          if (node.type.name === "commandInput") return false;
          const text = node.textContent;
          if (!text || (text.indexOf("@") < 0 && text.indexOf("!") < 0)) return false;
          const base = pos + 1;
          const re = /@(due|from|on|est|every|remind|line|pomo)\(([^)]*)\)|!(high|low)\b/gi;
          const matches = [];
          let m;
          while ((m = re.exec(text))) matches.push(m);
          if (!matches.length) return false;

          let estMin = null, pomoDone = 0, hasEstOrPomo = false, pomoHandled = false;
          for (const mm of matches) {
            const kind = (mm[1] || mm[3]).toLowerCase();
            if (kind === "est") {
              const v = parseEstMinutes(mm[2] || "");
              if (v != null) { estMin = v; hasEstOrPomo = true; }
            }
            if (kind === "pomo") { pomoDone = parseInt(mm[2]) || 0; hasEstOrPomo = true; }
          }

          const doms = [];
          const selFrom = state.selection.from;
          for (const mm of matches) {
            const kind = (mm[1] || mm[3]).toLowerCase();
            const arg = (mm[2] || "").trim();
            const from = base + mm.index, to = from + mm[0].length;
            // 游標在這顆標記裡（例如 @est 補全後停在括號內正要打數字）→
            // 先顯示原文讓使用者編輯，游標離開後才渲染成徽章。
            if (state.selection.empty && selFrom > from && selFrom < to) continue;
            // 預估時長還沒打完（沒數字或沒單位）→ 照原文顯示
            if (kind === "est" && parseEstMinutes(arg) == null) continue;
            let dom = null;
            if (kind === "due") {
              const d = parseDateArg(arg);
              if (d) {
                const days = Math.round((startOfDay(d) - todayD) / 86400000);
                if (days > 0) {
                  dom = badgeDom("badge-due",
                    "⏳ " + "\#(L("還有 {n} 天"))".replace("{n}", days));
                } else if (days === 0) {
                  dom = badgeDom("badge-due", "⏳ \#(L("今天到期"))");
                } else {
                  dom = badgeDom("badge-overdue",
                    "⚠️ " + "\#(L("過期 {n} 天"))".replace("{n}", -days));
                }
              }
            } else if (kind === "from") {
              const d = parseDateArg(arg);
              if (d && startOfDay(d) > todayD) {
                dom = badgeDom("badge-from",
                  "▸ " + "\#(L("{d} 開始"))".replace("{d}", (d.getMonth() + 1) + "/" + d.getDate()));
              }
              // 已開始的 from：整段隱藏即可
            } else if (kind === "est" || kind === "pomo") {
              if (!pomoHandled) {
                dom = pomoBadgeDom(estMin, pomoDone, base);
                pomoHandled = true;   // est+pomo 合成一顆徽章，第二個標記只隱藏
              }
            } else if (kind === "on") {
              dom = badgeDom("badge-every", "📅 " + arg);
            } else if (kind === "remind") {
              dom = badgeDom("badge-remind", "🔔 " + arg);
            } else if (kind === "every") {
              dom = badgeDom("badge-every", "↻ " + arg);
            } else if (kind === "line") {
              dom = badgeDom("badge-line", arg);
            } else if (kind === "high") {
              dom = badgeDom("badge-overdue", "❗");
            } else if (kind === "low") {
              dom = badgeDom("badge-from", "↓");
            }
            // PM 沒有 Decoration.replace：用 inline 隱藏原文；徽章統一放行尾
            decos.push(Decoration.inline(from, to, { class: "marker-hidden" }));
            if (dom) doms.push(dom);
          }
          // 徽章一律掛在行尾（依標記出現順序），打字時自動往後退
          const endPos = pos + node.nodeSize - 1;
          doms.forEach((d, i) => {
            // key 讓 ProseMirror 能重用既有 DOM，不必每次重畫徽章；
            // base 放進 key：前面文字變動時位置會變，closure 抓的 blockBase
            // 不能留舊的（＋/− 會改到錯的地方）。
            decos.push(Decoration.widget(endPos, d, {
              side: 1 + i, key: "badge:" + base + ":" + i + ":" + d.className
            }));
          });
          return false;
        };
        if (all) {
          state.doc.descendants(walk);
        } else {
          state.doc.nodesBetween(rangeFrom, rangeTo, walk);
        }
        return decos;
      }

      function buildBadges(state) {
        return DecorationSet.create(state.doc, buildBadgeDecos(state));
      }

      // 游標所在 textblock 的範圍（游標在標記裡時要顯示原文，所以選取變動也要重算）
      function textblockRange(doc, pos) {
        const p = Math.max(0, Math.min(pos, doc.content.size));
        const $p = doc.resolve(p);
        for (let d = $p.depth; d >= 0; d--) {
          if ($p.node(d).isTextblock) return { from: $p.before(d), to: $p.after(d) };
        }
        return null;
      }

      window.__buildBadges = buildBadges;   // debug 用
      const MarkerBadges = Extension.create({
        name: "markerBadges",
        addProseMirrorPlugins() {
          const key = new PluginKey("markerBadges");
          return [new Plugin({
            key,
            state: {
              init: (_, state) => buildBadges(state),
              apply(tr, old, oldState, newState) {
                const selChanged = !oldState.selection.eq(newState.selection);
                if (!tr.docChanged && !selChanged) return old;
                let set = tr.docChanged ? old.map(tr.mapping, tr.doc) : old;
                // 受影響的範圍：這次改動的區段 ＋ 游標離開與進入的那兩塊
                let from = Infinity, to = -Infinity;
                if (tr.docChanged) {
                  tr.mapping.maps.forEach(map => {
                    map.forEach((os, oe, ns, ne) => {
                      from = Math.min(from, ns); to = Math.max(to, ne);
                    });
                  });
                }
                for (const p of [tr.mapping.map(oldState.selection.from),
                                 newState.selection.from]) {
                  const r = textblockRange(newState.doc, p);
                  if (r) { from = Math.min(from, r.from); to = Math.max(to, r.to); }
                }
                if (from > to) return set;
                const a = textblockRange(newState.doc, from);
                const b = textblockRange(newState.doc, to);
                from = a ? Math.min(from, a.from) : from;
                to = b ? Math.max(to, b.to) : to;
                from = Math.max(0, from);
                to = Math.min(newState.doc.content.size, to);
                set = set.remove(set.find(from, to));
                return set.add(newState.doc, buildBadgeDecos(newState, from, to));
              }
            },
            props: { decorations(state) { return key.getState(state); } }
          })];
        }
      });

      // ---- TaskFold BEGIN ----
      // 待辦摺疊：底下有子項目的待辦，勾選框後面出現 ▸，點了收起／展開子項目。
      // 子項目就是標準的巢狀待辦（縮排的 - [ ]），Obsidian／GitHub 都看得懂；
      // 摺疊狀態不寫進 markdown，而是用「這一項的文字」當 key 交給 Swift 存在偏好設定
      // （依日記檔案分開記），載入時再用 setFoldedKeys 送回來。
      let foldedKeys = new Set();
      const taskFoldKey = new PluginKey("taskFold");

      function taskText(node) {
        const first = node.firstChild;
        return first ? first.textContent.trim() : "";
      }

      function hasChildList(node) {
        let found = false;
        node.forEach(child => {
          const t = child.type.name;
          if (t === "taskList" || t === "bulletList" || t === "orderedList") found = true;
        });
        return found;
      }

      function toggleFold(key) {
        if (!key) return;
        const folded = !foldedKeys.has(key);
        if (folded) foldedKeys.add(key); else foldedKeys.delete(key);
        try {
          window.webkit.messageHandlers.foldChanged.postMessage(JSON.stringify({ key, folded }));
        } catch (e) {}
        const view = window.__editor.view;
        view.dispatch(view.state.tr.setMeta(taskFoldKey, true));
      }

      function buildFoldDecos(doc) {
        const decos = [];
        doc.descendants((node, pos) => {
          if (node.type.name !== "taskItem" || !hasChildList(node)) return true;
          const key = taskText(node);
          const folded = key !== "" && foldedKeys.has(key);
          decos.push(Decoration.node(pos, pos + node.nodeSize, {
            class: folded ? "task-has-children task-folded" : "task-has-children"
          }));
          // pos+1＝進到 taskItem 裡，+1＝進到第一段文字的最前面（勾選框之後、文字之前）
          decos.push(Decoration.widget(pos + 2, () => {
            const btn = document.createElement("span");
            btn.className = "task-fold-toggle" + (folded ? " folded" : "");
            btn.contentEditable = "false";
            btn.textContent = "▸";
            btn.title = folded ? "展開子項目" : "收起子項目";
            btn.addEventListener("mousedown", e => {
              e.preventDefault(); e.stopPropagation();
              toggleFold(key);
            });
            return btn;
          }, { side: -1, ignoreSelection: true, key: "fold:" + key + (folded ? ":f" : ":o") }));
          return true;
        });
        return DecorationSet.create(doc, decos);
      }

      const TaskFold = Extension.create({
        name: "taskFold",
        addProseMirrorPlugins() {
          return [new Plugin({
            key: taskFoldKey,
            state: {
              init: (_, state) => buildFoldDecos(state.doc),
              apply(tr, old) {
                // 日記很短，文件一變或摺疊狀態一變就整份重算
                if (tr.docChanged || tr.getMeta(taskFoldKey)) return buildFoldDecos(tr.doc);
                return old;
              }
            },
            props: { decorations(state) { return taskFoldKey.getState(state); } }
          })];
        }
      });

      // 相鄰的同類清單自動接成同一串。
      // 例：普通段落夾在兩串待辦中間，把它變回待辦之後會自成一串——畫面看起來連續，
      // 但它底下那一項變成下一串的第一項，按 Tab 沒有「上一項」可以縮進去。
      // 存成 markdown 時相鄰清單本來就是同一串，所以接起來不會改變存檔內容。
      const LIST_TYPES = new Set(["taskList", "bulletList", "orderedList"]);
      function joinableBoundaries(doc) {
        const out = [];
        const visit = (node, contentStart) => {
          let prev = null;
          node.forEach((child, offset) => {
            if (prev && LIST_TYPES.has(child.type.name) && prev.type === child.type) {
              out.push(contentStart + offset);
            }
            prev = child;
            if (!child.isLeaf) visit(child, contentStart + offset + 1);
          });
        };
        visit(doc, 0);
        return out;
      }
      const JoinAdjacentLists = Extension.create({
        name: "joinAdjacentLists",
        addProseMirrorPlugins() {
          return [new Plugin({
            appendTransaction(trs, oldState, newState) {
              if (!trs.some(tr => tr.docChanged)) return null;
              const boundaries = joinableBoundaries(newState.doc);
              if (!boundaries.length) return null;
              let tr = newState.tr;
              for (const pos of boundaries.reverse()) tr = tr.join(pos);   // 由後往前，位置才不會跑掉
              return tr;
            }
          })];
        }
      });

      // Shift+Tab 在「母項目底下、但不是某一項標題」的那一行（例如子項目打完開出來的 /todo 行）：
      // 只把這一行移到母項目後面（回到上一層），母項目不動。
      // 預設的 liftListItem 會把「包著這一行的那一項」整個拉出清單——也就是母項目，
      // 母項目的勾選框就這樣不見、變成普通段落。
      function liftLineOutOfItem(ed) {
        const { state } = ed;
        const { $from, empty } = state.selection;
        if (!empty || !$from.parent.isTextblock) return false;
        const itemDepth = $from.depth - 1;
        if (itemDepth < 2) return false;
        if ($from.node(itemDepth).type.name !== "taskItem") return false;
        if ($from.index(itemDepth) === 0) return false;   // 這一項自己的標題行 → 預設行為
        const listDepth = itemDepth - 1;
        const list = $from.node(listDepth);
        const block = $from.parent;
        const caret = $from.parentOffset;
        const blockStart = $from.before();
        let tr = state.tr.delete(blockStart, blockStart + block.nodeSize);
        let insertPos;
        if ($from.index(listDepth) === list.childCount - 1) {
          insertPos = tr.mapping.map($from.after(listDepth));         // 母項目是最後一項：放在清單後面
        } else {
          const itemEnd = tr.mapping.map($from.after(itemDepth));      // 中間項：在母項目後面把清單劈開
          tr = tr.split(itemEnd, 1);
          insertPos = itemEnd + 1;
        }
        tr = tr.insert(insertPos, block);
        tr = tr.setSelection(TextSelection.create(tr.doc, insertPos + 1 + caret));
        ed.view.dispatch(tr.scrollIntoView());
        return true;
      }
      const LiftLineOutOfItem = Extension.create({
        name: "liftLineOutOfItem",
        priority: 1000,   // 要比 TaskItem 自己的 Shift-Tab 先處理
        addKeyboardShortcuts() {
          return { "Shift-Tab": () => liftLineOutOfItem(this.editor) };
        }
      });

      /// Swift 載入日記時呼叫：這份日記哪些項目是收起來的
      window.setFoldedKeys = function (keys) {
        foldedKeys = new Set(keys || []);
        if (window.__editor) {
          const view = window.__editor.view;
          view.dispatch(view.state.tr.setMeta(taskFoldKey, true));
        }
      };
      // ---- TaskFold END ----

      // ---- TaskToggleShortcut BEGIN ----
      // 已經寫好的待辦，在標題開頭或「空格」後打 /toggle → 就地變成可摺疊的待辦：
      // 拿掉 /toggle，底下開一個空的子待辦、游標移過去（跟 /todo /toggle 建出來的一樣）。
      // 已經有子項目的待辦本來就可以摺疊，只拿掉 /toggle。
      // 游標在待辦的標題行（第一段）→ 變成可摺疊的待辦：底下開一個空的子待辦、游標移過去。
      // 已經有子項目就本來可以摺疊，不動。不在待辦標題行回傳 false。
      function makeTaskFoldable(ed) {
        const { state } = ed;
        const { $from } = state.selection;
        const d = $from.depth;
        if (d < 1 || $from.parent.type.name !== "paragraph") return false;
        const item = $from.node(d - 1);
        if (item.type.name !== "taskItem" || $from.index(d - 1) !== 0) return false;
        if (hasChildList(item)) return true;
        const { taskList, taskItem, paragraph } = state.schema.nodes;
        const afterTitle = $from.before(d - 1) + 1 + item.firstChild.nodeSize;
        const tr = state.tr.insert(afterTitle, taskList.create(null,
          taskItem.create({ checked: false }, paragraph.create())));
        // taskList(1) taskItem(1) paragraph(1) → 子待辦的文字開頭
        tr.setSelection(TextSelection.create(tr.doc, afterTitle + 3));
        ed.view.dispatch(tr.scrollIntoView());
        return true;
      }

      const TaskToggleShortcut = Extension.create({
        name: "taskToggleShortcut",
        addInputRules() {
          return [new InputRule({
            find: /(?:^|\s)\/toggle$/i,   // 標題開頭或空格後面都可以
            handler: ({ state, range }) => {
              const $from = state.doc.resolve(range.from);
              const d = $from.depth;
              // 只在待辦項目的第一段（標題那行）裡生效
              if (d < 1 || $from.parent.type.name !== "paragraph") return null;
              const item = $from.node(d - 1);
              if (item.type.name !== "taskItem" || $from.index(d - 1) !== 0) return null;
              const tr = state.tr;
              const itemPos = $from.before(d - 1);
              tr.delete(range.from, range.to);
              const itemNode = tr.doc.nodeAt(itemPos);
              if (hasChildList(itemNode)) {
                tr.setSelection(TextSelection.create(tr.doc, range.from));
                return;
              }
              const { taskList, taskItem, paragraph } = state.schema.nodes;
              const afterTitle = itemPos + 1 + itemNode.firstChild.nodeSize;
              tr.insert(afterTitle, taskList.create(null,
                taskItem.create({ checked: false }, paragraph.create())));
              // taskList(1) taskItem(1) paragraph(1) → 子待辦的文字開頭
              tr.setSelection(TextSelection.create(tr.doc, afterTitle + 3));
            }
          })];
        }
      });
      // ---- TaskToggleShortcut END ----

      // ---- ArrowShortcuts BEGIN ----
      // 像 Notion：打 -> 自動變成 →（打完馬上按 ⌫ 會還原，tiptap 內建 undoInputRule）。
      // 順序有意義：同一個字觸發時由上往下比，長的要先比（<=> 要先於 =>）。
      // <-> 的情況：打到 <- 時已經先變成 ←，再打 > 時看到的是 ←>。
      const ArrowShortcuts = Extension.create({
        name: "arrowShortcuts",
        addInputRules() {
          const rule = (find, to) => new InputRule({
            find,
            handler: ({ state, range }) => { state.tr.insertText(to, range.from, range.to); }
          });
          return [
            rule(/<=>$/, "⇔"),
            rule(/←>$/, "↔"),
            rule(/=>$/, "⇒"),
            rule(/->$/, "→"),
            rule(/<-$/, "←"),
          ];
        }
      });
      // ---- ArrowShortcuts END ----

      const editor = new Editor({
        element: document.getElementById("editor"),
        extensions: [
          StarterKit,
          CommandLine,
          CommandInput,
          MarkerBadges,
          ToggleAwareBackspace,
          ExitListOnBackspace,
          TaskList,
          TaskItem.configure({ nested: true }),
          TaskFold,
          TaskToggleShortcut,
          JoinAdjacentLists,
          LiftLineOutOfItem,
          ArrowShortcuts,
          LocalImage,
          MathInline,
          MathBlock,
          ToggleSummary,
          ToggleList,
          Placeholder.configure({ placeholder: "\#(L("輸入文字，或打「/」插入區塊"))" }),
          Markdown.configure({ html: false, breaks: false, transformPastedText: true })
        ],
        onUpdate() { scheduleSend(); refreshSlash(true); },
        onSelectionUpdate() { refreshSlash(false); }
      });
      window.__editor = editor;

      // ---- 區塊 gutter：hover 在 block 左側出現「＋」與「⋮⋮」----
      // ＋：在該區塊下方插入新區塊並打開 slash 選單。
      // ⋮⋮：點一下開區塊選單（轉換類型/複製/刪除）；拖拉用 ProseMirror 原生
      // 拖放重排（dragstart 選取整個 block 並設定 view.dragging，落點交給 PM）。
      const gutter = document.createElement("div");
      gutter.className = "block-gutter hide";
      const plusBtn = document.createElement("div");
      plusBtn.className = "gutter-btn plus-btn";
      plusBtn.title = "\#(L("在下方插入區塊"))";
      const dragHandle = document.createElement("div");
      dragHandle.className = "gutter-btn drag-handle";
      dragHandle.title = "\#(L("點擊開啟選單；拖拉移動"))";
      dragHandle.draggable = true;
      gutter.appendChild(plusBtn);
      gutter.appendChild(dragHandle);
      document.body.appendChild(gutter);
      let handleBlockPos = null;
      let gutterHideTimer = null;

      function hideHandle() {
        clearTimeout(gutterHideTimer);
        gutter.classList.add("hide");
        handleBlockPos = null;
      }
      // 延遲隱藏：滑鼠從內文往 gutter 移動的路上不會讓按鈕消失
      function scheduleHideHandle() {
        clearTimeout(gutterHideTimer);
        gutterHideTimer = setTimeout(hideHandle, 300);
      }

      document.addEventListener("mousemove", e => {
        if (gutter.contains(e.target)) { clearTimeout(gutterHideTimer); return; }
        if (blockMenu.style.display === "block") return;   // 選單開著時 gutter 定住
        const view = editor.view;
        const editorRect = view.dom.getBoundingClientRect();
        if (e.clientX < editorRect.left - 60 || e.clientX > editorRect.right ||
            e.clientY < editorRect.top || e.clientY > editorRect.bottom) {
          scheduleHideHandle();
          return;
        }
        const posInfo = view.posAtCoords({
          left: Math.max(e.clientX, editorRect.left + 1), top: e.clientY });
        if (!posInfo) { scheduleHideHandle(); return; }

        let blockPos = null;
        if (posInfo.inside >= 0) {
          const $i = view.state.doc.resolve(posInfo.inside);
          blockPos = $i.depth === 0 ? posInfo.inside : $i.before(1);
        } else {
          const $p = view.state.doc.resolve(posInfo.pos);
          if ($p.depth >= 1) blockPos = $p.before(1);
        }
        if (blockPos == null) { scheduleHideHandle(); return; }

        // 相鄰的 todo/清單項在 markdown 裡是同一個頂層清單節點，但對使用者
        // 來說每一項都該是獨立區塊：改用「滑鼠的 y 座標落在哪個項目的 DOM 範圍」
        // 來選（不能用 posAtCoords 的解析結果——滑鼠在左側 gutter 區時它會落在
        // 清單邊界上，找不到項目就退回整串清單，把手會跳到第一項）。
        const blockNode = view.state.doc.nodeAt(blockPos);
        if (blockNode &&
            ["taskList", "bulletList", "orderedList"].includes(blockNode.type.name)) {
          let p = blockPos + 1;
          let chosen = null;
          for (let i = 0; i < blockNode.childCount; i++) {
            const itemDom = view.nodeDOM(p);
            if (itemDom instanceof HTMLElement) {
              const r = itemDom.getBoundingClientRect();
              if (chosen == null || e.clientY >= r.top) chosen = p;
              if (e.clientY <= r.bottom) break;
            }
            p += blockNode.child(i).nodeSize;
          }
          if (chosen != null) blockPos = chosen;
        }

        const dom = view.nodeDOM(blockPos);
        if (!dom || !(dom instanceof HTMLElement)) { scheduleHideHandle(); return; }
        clearTimeout(gutterHideTimer);
        const rect = dom.getBoundingClientRect();
        handleBlockPos = blockPos;
        gutter.style.left = (rect.left - 44) + "px";
        gutter.style.top = (rect.top - 1) + "px";
        gutter.classList.remove("hide");
      });

      dragHandle.addEventListener("dragstart", e => {
        if (handleBlockPos == null) return;
        const view = editor.view;
        const sel = NodeSelection.create(view.state.doc, handleBlockPos);
        view.dispatch(view.state.tr.setSelection(sel));
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", "block");
        let slice = sel.content();
        // 拖的是清單項目時包回一層外層清單（開放邊界）：掉進別的清單
        // 會合併成一項、掉在段落之間會自己長成新清單。
        if (["taskItem", "listItem"].includes(sel.node.type.name)) {
          const $item = view.state.doc.resolve(handleBlockPos);
          const wrapped = $item.parent.type.create($item.parent.attrs, sel.node);
          const SliceCtor = slice.constructor;   // bundle 沒匯出 Slice，從實例拿
          slice = new SliceCtor(Fragment.from(wrapped), 1, 1);
        }
        view.dragging = { slice, move: true };
      });

      // ＋：在 hover 的區塊正下方插入新區塊（清單項就插同型項目），
      // 並自動打上「/」讓 slash 選單跳出來選類型。
      plusBtn.addEventListener("mousedown", e => e.preventDefault());
      plusBtn.addEventListener("click", () => {
        if (handleBlockPos == null) return;
        const node = editor.state.doc.nodeAt(handleBlockPos);
        if (!node) return;
        const at = handleBlockPos + node.nodeSize;
        const isItem = ["taskItem", "listItem"].includes(node.type.name);
        const content = isItem
          ? { type: node.type.name,
              attrs: node.type.name === "taskItem" ? { checked: false } : undefined,
              content: [{ type: "paragraph" }] }
          : { type: "paragraph" };
        editor.chain()
          .insertContentAt(at, content)
          .setTextSelection(at + (isItem ? 2 : 1))
          .focus()
          .insertContent("/")   // onUpdate → refreshSlash(true) 會打開 slash 選單
          .run();
        hideHandle();
      });

      // ---- ⋮⋮ 點一下 → 區塊選單：轉換類型 / 複製 / 刪除 ----
      const blockMenu = document.createElement("div");
      blockMenu.id = "block-menu";
      document.body.appendChild(blockMenu);
      let blockMenuPos = null;

      function closeBlockMenu() {
        blockMenu.style.display = "none";
        blockMenuPos = null;
      }

      // 轉換前先脫離清單包裹，轉出來的結果才是獨立的頂層區塊
      function liftOutOfLists() {
        let guard = 0;
        while (guard++ < 8) {
          const { $from } = editor.state.selection;
          let itemName = null;
          for (let d = $from.depth; d > 0; d--) {
            const n = $from.node(d).type.name;
            if (n === "taskItem" || n === "listItem") { itemName = n; break; }
          }
          if (!itemName) break;
          if (!editor.commands.liftListItem(itemName)) break;
        }
      }

      const blockMenuItems = [
        { label: "\#(L("文字"))", hint: "", run: ed => ed.chain().setParagraph().run() },
        { label: "\#(L("標題 1"))", hint: "#", run: ed => ed.chain().setHeading({ level: 1 }).run() },
        { label: "\#(L("標題 2"))", hint: "##", run: ed => ed.chain().setHeading({ level: 2 }).run() },
        { label: "\#(L("標題 3"))", hint: "###", run: ed => ed.chain().setHeading({ level: 3 }).run() },
        { label: "\#(L("待辦清單"))", hint: "[ ]", run: ed => ed.chain().toggleTaskList().run() },
        { label: "\#(L("項目清單"))", hint: "•", run: ed => ed.chain().toggleBulletList().run() },
        { label: "\#(L("編號清單"))", hint: "1.", run: ed => ed.chain().toggleOrderedList().run() },
        { label: "\#(L("引用"))", hint: ">", run: ed => ed.chain().toggleBlockquote().run() },
        { label: "\#(L("程式碼"))", hint: "```", run: ed => ed.chain().toggleCodeBlock().run() },
        { sep: true },
        { label: "\#(L("複製區塊"))", hint: "", act: "duplicate" },
        { label: "\#(L("刪除區塊"))", hint: "", act: "delete", danger: true }
      ];

      function applyBlockMenuItem(item) {
        const pos = blockMenuPos;
        closeBlockMenu();
        if (pos == null) return;
        const node = editor.state.doc.nodeAt(pos);
        if (!node) return;
        if (item.act === "delete") {
          editor.chain().deleteRange({ from: pos, to: pos + node.nodeSize }).focus().run();
          hideHandle();
          return;
        }
        if (item.act === "duplicate") {
          editor.chain().insertContentAt(pos + node.nodeSize, node.toJSON()).focus().run();
          hideHandle();
          return;
        }
        editor.chain().setTextSelection(pos + 1).focus().run();
        liftOutOfLists();
        item.run(editor);
        hideHandle();
      }

      function openBlockMenu() {
        if (handleBlockPos == null) return;
        blockMenuPos = handleBlockPos;
        blockMenu.innerHTML = "";
        blockMenuItems.forEach(item => {
          if (item.sep) {
            const s = document.createElement("div");
            s.className = "menu-sep";
            blockMenu.appendChild(s);
            return;
          }
          const div = document.createElement("div");
          div.className = "slash-item" + (item.danger ? " danger" : "");
          div.innerHTML = "<span>" + item.label + "</span>" +
            (item.hint ? "<span class='slash-hint'>" + item.hint + "</span>" : "");
          div.onmousedown = e => { e.preventDefault(); applyBlockMenuItem(item); };
          blockMenu.appendChild(div);
        });
        const r = dragHandle.getBoundingClientRect();
        blockMenu.style.left = r.left + "px";
        blockMenu.style.top = (r.bottom + 4) + "px";
        blockMenu.style.display = "block";
        // 底下放不下就往上開
        const mh = blockMenu.offsetHeight;
        if (r.bottom + 4 + mh > window.innerHeight - 8) {
          blockMenu.style.top = Math.max(8, r.top - mh - 4) + "px";
        }
      }

      dragHandle.addEventListener("click", () => openBlockMenu());
      document.addEventListener("mousedown", e => {
        if (blockMenu.style.display === "block" &&
            !blockMenu.contains(e.target) && !gutter.contains(e.target)) {
          closeBlockMenu();
        }
      });
      document.addEventListener("keydown", e => {
        if (e.key === "Escape" && blockMenu.style.display === "block") closeBlockMenu();
      });

      document.addEventListener("dragend", () => hideHandle());
      document.addEventListener("scroll", () => { hideHandle(); closeBlockMenu(); }, true);

      // ---- 雙擊內容下方的空白處 → 在文末新增空白 block ----
      document.body.addEventListener("dblclick", e => {
        if (editor.view.dom.contains(e.target)) return;
        const doc = editor.state.doc;
        const last = doc.lastChild;
        if (last && last.type.name === "paragraph" && last.content.size === 0) {
          editor.chain().focus("end").run();
        } else {
          editor.chain()
            .insertContentAt(doc.content.size, { type: "paragraph" })
            .focus("end")
            .run();
        }
      });

      function scheduleSend() {
        if (applying) return;
        clearTimeout(sendTimer);
        sendTimer = setTimeout(() => {
          const md = editor.storage.markdown.getMarkdown();
          window.webkit.messageHandlers.contentChanged.postMessage(md);
        }, 250);
      }

      // 載入 markdown 後，把純文字中的 $...$ / $$...$$ 轉成數學節點
      function mathify() {
        const { state } = editor;
        const replacements = [];

        state.doc.descendants((node, pos) => {
          // 整段只有 $$...$$ → mathBlock
          if (node.type.name === "paragraph" && node.childCount === 1 &&
              node.firstChild.isText) {
            const m = node.textContent.match(/^\$\$([\s\S]+)\$\$$/);
            if (m) {
              replacements.push({
                from: pos, to: pos + node.nodeSize,
                node: state.schema.nodes.mathBlock.create({ latex: m[1].trim() })
              });
              return false;
            }
          }
          // 行內 $...$ → mathInline
          if (node.isText && node.text.includes("$")) {
            const re = /\$([^$\n]+?)\$/g;
            let m;
            while ((m = re.exec(node.text)) !== null) {
              replacements.push({
                from: pos + m.index, to: pos + m.index + m[0].length,
                node: state.schema.nodes.mathInline.create({ latex: m[1].trim() })
              });
            }
          }
          return true;
        });

        if (!replacements.length) return;
        let tr = state.tr;
        for (const r of replacements.reverse()) {
          tr = tr.replaceWith(r.from, r.to, r.node);
        }
        editor.view.dispatch(tr);
      }

      window.setMarkdown = function (md) {
        applying = true;
        editor.commands.setContent(md, false);
        togglify();
        mathify();
        refreshImages();
        applying = false;
      };

      window.insertPastedImage = function (path, uri) {
        assetMap[path] = uri;
        editor.chain().focus()
          .insertContent({ type: "image", attrs: { src: path } }).run();
      };

      // ---- 貼上圖片攔截（有文字時讓文字優先）----
      document.addEventListener("paste", e => {
        const cd = e.clipboardData;
        if (!cd) return;
        if (cd.types.includes("text/plain")) return;
        for (const item of cd.items) {
          if (item.type.startsWith("image/")) {
            const file = item.getAsFile();
            if (!file) continue;
            e.preventDefault();
            const reader = new FileReader();
            reader.onload = () =>
              window.webkit.messageHandlers.pasteImage.postMessage(reader.result);
            reader.readAsDataURL(file);
            return;
          }
        }
      }, true);

      // ---- 數學編輯彈窗 ----
      const mathEditor = document.getElementById("math-editor");
      const mathInput = document.getElementById("math-input");
      const mathPreview = document.getElementById("math-preview");
      let mathTarget = null; // { getPos, isBlock }

      function openMathEditor(ed, getPos, isBlock) {
        const pos = getPos();
        const node = ed.state.doc.nodeAt(pos);
        if (!node) return;
        mathTarget = { getPos, isBlock };
        mathInput.value = node.attrs.latex;
        renderKatex(mathPreview, node.attrs.latex, true);
        const c = ed.view.coordsAtPos(pos);
        mathEditor.style.left = Math.min(c.left + window.scrollX, window.innerWidth - 360) + "px";
        mathEditor.style.top = (c.bottom + window.scrollY + 6) + "px";
        mathEditor.style.display = "block";
        mathInput.focus();
      }

      function closeMathEditor() {
        mathEditor.style.display = "none";
        mathTarget = null;
        editor.commands.focus();
      }

      function commitMath() {
        if (!mathTarget) return;
        const pos = mathTarget.getPos();
        const node = editor.state.doc.nodeAt(pos);
        if (!node) return closeMathEditor();
        const latex = mathInput.value.trim();
        let tr = editor.state.tr;
        if (latex) {
          tr = tr.setNodeMarkup(pos, undefined, { latex });
        } else {
          tr = tr.delete(pos, pos + node.nodeSize);
        }
        editor.view.dispatch(tr);
        closeMathEditor();
      }

      function deleteMathNode() {
        if (!mathTarget) return;
        const pos = mathTarget.getPos();
        const node = editor.state.doc.nodeAt(pos);
        if (node) {
          editor.view.dispatch(editor.state.tr.delete(pos, pos + node.nodeSize));
        }
        closeMathEditor();
      }

      mathInput.addEventListener("input", () =>
        renderKatex(mathPreview, mathInput.value, true));
      mathInput.addEventListener("keydown", e => {
        if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); commitMath(); }
        else if (e.key === "Escape") { e.preventDefault(); closeMathEditor(); }
        e.stopPropagation();
      });
      document.getElementById("math-done").onclick = commitMath;
      document.getElementById("math-delete").onclick = deleteMathNode;

      // ---- Slash 選單 + @/! 標記補全 ----
      const menu = document.getElementById("slash-menu");
      let filtered = [];
      let activeIndex = 0;
      let slashRange = null;

      // 待辦標記：insert 為插入文字，back 為插入後游標回退格數
      const commandItems = [
        { label: "/todo", hint: "\#(L("新增待辦（可帶 @ 標記）"))", insert: "/todo ", match: "todo 待辦 新增" },
        { label: "/todo /toggle", hint: "\#(L("可摺疊的待辦（底下放子項目）"))", insert: "/todo /toggle ", match: "todo toggle fold 待辦 摺疊 折疊 子項目" },
        { label: "/h1", hint: "\#(L("標題 1"))", insert: "/h1 ", match: "h1 heading 標題" },
        { label: "/h2", hint: "\#(L("標題 2"))", insert: "/h2 ", match: "h2 heading 標題" },
        { label: "/h3", hint: "\#(L("標題 3"))", insert: "/h3 ", match: "h3 heading 標題" },
        { label: "/toggle", hint: "\#(L("摺疊清單"))", insert: "/toggle ", match: "toggle fold 摺疊 折疊" },
        { label: "/bullet", hint: "\#(L("項目清單"))", insert: "/bullet ", match: "bullet list ul 項目" },
        { label: "/num", hint: "\#(L("編號清單"))", insert: "/num ", match: "num ordered ol 編號" },
        { label: "/go", hint: "\#(L("跳到某天（7/10・+3・明天）"))", insert: "/go ", match: "go goto day 跳 日期" },
        { label: "/list", hint: "\#(L("任務總覽：查詢／改／刪"))", insert: "/list", match: "list tasks 任務 總覽 查詢" }
      ];

      const markerItems = [
        { label: "@due(7/15)", hint: "\#(L("到期日"))", insert: "@due()", back: 1, match: "@due deadline 到期" },
        { label: "@from(7/5)", hint: "\#(L("開始日"))", insert: "@from()", back: 1, match: "@from start defer 開始 延後" },
        { label: "@on(7/10,7/14)", hint: "\#(L("指定日期（不連續）"))", insert: "@on()", back: 1, match: "@on dates 指定 不連續" },
        { label: "@est(3h)", hint: "\#(L("預估時長"))", insert: "@est()", back: 1, match: "@est estimate time 預估 時長" },
        { label: "@every(mon,thu)", hint: "\#(L("循環"))", insert: "@every()", back: 1, match: "@every repeat weekly 循環 每週" },
        { label: "@remind(7/20 09:00)", hint: "\#(L("提醒"))", insert: "@remind()", back: 1, match: "@remind notify 提醒 通知" },
        { label: "@line(A)", hint: "\#(L("主線歸屬"))", insert: "@line()", back: 1, match: "@line track 主線" },
        { label: "@pomo(2)", hint: "\#(L("已投入蕃茄數"))", insert: "@pomo()", back: 1, match: "@pomo 蕃茄 進度" },
        { label: "!high", hint: "\#(L("高優先"))", insert: "!high ", back: 0, match: "!high priority 高" },
        { label: "!low", hint: "\#(L("低優先"))", insert: "!low ", back: 0, match: "!low priority 低" }
      ];

      // allowOpen：只有文件真的變動（打字）才允許「打開」選單；
      // 純游標移動/點擊只能更新或關閉已開的選單，避免點到 @xxx 字尾亂彈。
      function refreshSlash(allowOpen) {
        const { state } = editor;
        const { $from, empty } = state.selection;
        if (!empty || !$from.parent.isTextblock) return hideMenu();
        const start = $from.start();
        const textBefore = state.doc.textBetween(start, $from.pos, "\n");

        const inCmd = $from.parent.type.name === "commandInput";
        const m = !inCmd && textBefore.match(/^\/([^\s]*)$/);
        if (m) {
          const query = m[1].toLowerCase();
          filtered = slashItems.filter(i =>
            i.match.includes(query) || i.label.toLowerCase().includes(query));
          if (!filtered.length) return hideMenu();
          slashRange = { from: start, to: $from.pos };
        } else if (inCmd && /^\/?[a-zA-Z0-9]*$/.test(textBefore)) {
          const q = textBefore.replace(/^\//, "").toLowerCase();
          filtered = commandItems.filter(i =>
            i.match.includes(q) || i.insert.replace("/", "").startsWith(q));
          // 已打完整命令字 → 收起選單，讓 Enter 直接執行
          filtered = filtered.filter(i => i.insert.trim() !== textBefore.trim());
          if (!filtered.length) return hideMenu();
          slashRange = { from: start, to: $from.pos };
        } else {
          // 行內任意位置的 @/! 開頭字組（前面是行首或空白；「![」不會觸發）
          // 只在日記啟用（由 Swift 端依文件路徑設定）
          if (!window.__markersEnabled) return hideMenu();
          const mk = textBefore.match(/(?:^|\s)(@[a-zA-Z]*|![a-zA-Z]+)$/);
          if (!mk) return hideMenu();
          const q = mk[1].toLowerCase();
          filtered = markerItems.filter(i =>
            i.insert.toLowerCase().startsWith(q) || i.match.includes(q));
          if (!filtered.length) return hideMenu();
          slashRange = { from: $from.pos - mk[1].length, to: $from.pos };
        }

        if (menu.style.display !== "block" && !allowOpen) return hideMenu();
        activeIndex = Math.min(activeIndex, filtered.length - 1);
        renderMenu();
        const c = editor.view.coordsAtPos($from.pos);
        menu.style.left = (c.left + window.scrollX) + "px";
        menu.style.top = (c.bottom + window.scrollY + 4) + "px";
        menu.style.display = "block";
        // 夾在視窗內，靠右打字時選單不被切掉
        const mw = menu.offsetWidth;
        const maxLeft = window.scrollX + document.documentElement.clientWidth - mw - 8;
        if (c.left + window.scrollX > maxLeft) {
          menu.style.left = Math.max(window.scrollX + 8, maxLeft) + "px";
        }
      }

      function renderMenu() {
        menu.innerHTML = "";
        filtered.forEach((item, i) => {
          const div = document.createElement("div");
          div.className = "slash-item" + (i === activeIndex ? " active" : "");
          div.innerHTML = "<span>" + item.label + "</span>" +
            (item.hint ? "<span class='slash-hint'>" + item.hint + "</span>" : "");
          div.onmouseenter = () => { activeIndex = i; renderMenu(); };
          div.onmousedown = e => { e.preventDefault(); applyItem(item); };
          menu.appendChild(div);
        });
      }

      function hideMenu() {
        menu.style.display = "none";
        slashRange = null;
        activeIndex = 0;
      }

      function applyItem(item) {
        if (slashRange) {
          editor.chain().focus().deleteRange(slashRange).run();
        }
        if (item.run) {
          item.run(editor);
        } else {
          // 標記項目：插入文字，必要時把游標退回括號內
          editor.chain().focus().insertContent(item.insert).run();
          if (item.back) {
            editor.commands.setTextSelection(editor.state.selection.from - item.back);
          }
        }
        hideMenu();
      }

      function scrollActiveIntoView() {
        const el = menu.children[activeIndex];
        if (el) el.scrollIntoView({ block: "nearest" });
      }
      document.addEventListener("keydown", e => {
        if (menu.style.display !== "block") return;
        if (e.key === "ArrowDown") {
          e.preventDefault(); e.stopPropagation();
          activeIndex = (activeIndex + 1) % filtered.length;
          renderMenu(); scrollActiveIntoView();
        } else if (e.key === "ArrowUp") {
          e.preventDefault(); e.stopPropagation();
          activeIndex = (activeIndex - 1 + filtered.length) % filtered.length;
          renderMenu(); scrollActiveIntoView();
        } else if (e.key === "Enter" || e.key === "Tab") {
          // 命令行裡 Enter 一律「執行」（像終端機）：選字用 Tab／點選
          if (e.key === "Enter"
              && editor.state.selection.$from.parent.type.name === "commandInput") {
            hideMenu();
            return;   // 不攔截 → 交給 CommandLine 的 Enter 執行命令
          }
          // Tab 與 Enter（一般情境）都接受，和筆記源碼編輯器的 Tab 習慣一致
          e.preventDefault(); e.stopPropagation();
          applyItem(filtered[activeIndex]);
        } else if (e.key === "Escape") {
          e.preventDefault(); e.stopPropagation();
          hideMenu();
        }
      }, true);

      window.addEventListener("blur", () => { hideMenu(); });

      window.webkit.messageHandlers.ready.postMessage("");
      })();
    </script>
    </body>
    </html>
    """#
    }
}

extension Notification.Name {
    /// 編輯器命令列送出的命令（userInfo["command"]，如 "list"）。
    static let rhEditorCommand = Notification.Name("ResearchHub.editorCommand")
}
