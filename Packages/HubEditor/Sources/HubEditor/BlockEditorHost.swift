import SwiftUI
import HubCore
import OSLog
import WebKit
import Combine

/// 常駐的 block 編輯器宿主：WKWebView 只建立並載入一次（app 啟動即預載），
/// 之後切到日記分頁是即時顯示，只推送新的 markdown 內容。
@MainActor
public final class BlockEditorHost: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    public let webView: WKWebView
    public var baseDir: URL?
    public var textBinding: Binding<String>?
    public var documentID: URL?
    /// 命令列送出的命令（"list"、"go:…"），由目前擁有 webView 的 BlockEditorView 設定
    public var onCommand: ((String) -> Void)?

    @Published public private(set) var isReady = false
    @Published public private(set) var loadError: String?

    private var lastTextFromJS: String?
    private var lastPushed: String?
    private var pendingText: String?
    private var assetCache: [String: String] = [:]
    private var retryCount = 0

    public override init() {
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
    public func preload() {}

    private func startLoad() {
        loadError = nil
        isReady = false
        // JS ↔ Swift 的版本契約：bundle 的 version.json 不在支援區間就明確報錯，不渲染成一片空白
        if let problem = BlockEditorView.bundleProblem {
            loadError = problem
            return
        }
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
    @objc public func appBecameActive() {
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


    public func retry() {
        retryCount = 0
        startLoad()
    }

    public nonisolated func userContentController(
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
                    + "window.__pomoMinutes = \(pomoMinutes)")
                self.lastMarkersSent = (self.markersEnabled, pomoMinutes)
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
                // 命令列送出的命令（如 "list"、"go:明天"）→ 由目前擁有 webView 的畫面決定怎麼呈現
                self.onCommand?(body)
            case "jsError":
                EditorLog.text.error("BlockEditor JS error: \(body, privacy: .public)")
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
    public func resetForNewDocument() {
        lastTextFromJS = nil
        lastPushed = nil
        pendingText = nil
    }

    /// @/! 待辦標記補全開關（只有日記啟用）。ready 之後重新套用，重載也不會丟。
    private var markersEnabled = false

    private var lastMarkersSent: (Bool, Int)?

    public func setMarkersEnabled(_ enabled: Bool) {
        markersEnabled = enabled
        // sync() 在每次 SwiftUI 更新都會呼叫；值沒變就別再跨行程送 JS
        let sig = (enabled, pomoMinutes)
        if let last = lastMarkersSent, last == sig { return }
        if isReady {
            lastMarkersSent = sig
            webView.evaluateJavaScript(
                "window.__markersEnabled = \(enabled); "
                + "window.__pomoMinutes = \(pomoMinutes)")
        }
    }

    /// 一顆蕃茄的分鐘數（跟蕃茄鐘設定連動），給 @est 進度條換算格數；由 app 注入（設定鍵在 app）。
    public var pomoMinutesProvider: () -> Int = { 25 }
    private var pomoMinutes: Int { pomoMinutesProvider() }

    public func pushIfNeeded(_ text: String) {
        guard text != lastTextFromJS, text != lastPushed else { return }
        push(text)
    }

    private func push(_ text: String) {
        guard isReady else {
            pendingText = text
            return
        }
        lastPushed = text
        // 推了新內容進去，網頁上次回報的那份就不再是網頁的現況；不清掉的話，
        // 同一天的編輯器重建時（先推空字串、再讀到檔案內容）會因「跟上次回報的一樣」被跳過，畫面留白。
        lastTextFromJS = nil
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
