#if os(macOS)
import SwiftUI
import AppKit
import WebKit

/// 編輯器檢視模式（筆記與日記共用）。
enum EditorMode: String, CaseIterable, Identifiable {
    case blocks, split, source, preview
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .blocks: return "square.text.square"
        case .split: return "rectangle.split.2x1"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .preview: return "eye"
        }
    }

    var label: String {
        switch self {
        case .blocks: return "區塊"
        case .split: return "雙欄"
        case .source: return "源碼"
        case .preview: return "預覽"
        }
    }
}

/// 預覽版面切換（連續 / A4 分頁），放在筆記標題列；設定全域共用。
struct PreviewLayoutPicker: View {
    @AppStorage("settings.previewLayout") private var previewLayout = "flow"

    var body: some View {
        Picker("版面", selection: $previewLayout) {
            Text("連續").tag("flow")
            Text("A4").tag("a4")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
        .help("預覽版面：連續捲動或 A4 分頁（註腳在當頁底部）")
    }
}

/// 模式切換器（放在各自的 header 裡）。
struct EditorModePicker: View {
    @Binding var mode: EditorMode
    var available: [EditorMode] = [.split, .source, .preview]

    var body: some View {
        Picker("檢視模式", selection: $mode) {
            ForEach(available) { m in
                Image(systemName: m.icon)
                    .help(LocalizedStringKey(m.label))
                    .tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: CGFloat(available.count) * 44)
    }
}

/// 共用編輯器核心：源碼 + KaTeX 預覽、自動存檔、貼圖存到檔案旁的 assets/。
/// 檔案不存在時以空白內容開始，首次有內容才寫入磁碟。
/// 底部命令列交回給日記層級處理的動作；回傳 false = 參數無效（命令列顯示錯誤）。
enum JournalQuickAction {
    case go(String)   // /go 的參數原文（需要「目前顯示哪天」的脈絡，由 JournalView 解析）
    case list         // /list 開任務總覽
}

/// 貼上圖片時要插入什麼語法。
enum ImageInsertion: Equatable {
    case markdown                      // ![](assets/xxx.png)
    case latex(projectRoot: URL)       // \includegraphics{figures/xxx.png}
}

struct EditorCore: View {
    let fileURL: URL
    @Binding var mode: EditorMode
    /// 貼圖語法：markdown 筆記用 ![]()，LaTeX 專案用 \includegraphics
    var imageInsertion: ImageInsertion = .markdown
    /// 存檔完成（LaTeX 專案用來觸發重新編譯）
    var onSaved: (() -> Void)?
    /// 跳到某一行（編譯錯誤點過來）
    var lineJump: LineJumpRequest?
    /// 顯示底部快速命令列（日記用）。
    var quickCmdBar: Bool = false
    var onJournalCommand: ((JournalQuickAction) -> Bool)? = nil

    /// 外部（如規劃儀式）要求把文字附加到某檔案的編輯器尾端。
    /// 走通知而不是直接改檔案：檔案正被編輯器持有，直接寫檔會被 autosave 蓋掉。
    static let appendNotification = Notification.Name("EditorCore.append")

    static func requestAppend(to url: URL, text: String) {
        NotificationCenter.default.post(
            name: appendNotification, object: nil,
            userInfo: ["url": url, "text": text])
    }

    @EnvironmentObject private var store: FileSystemStore
    @AppStorage("settings.editorFontSize") private var editorFontSize = 14.0
    /// 預覽版面：flow = 連續、a4 = A4 分頁（註腳在當頁底部）。
    @AppStorage("settings.previewLayout") private var previewLayout = "flow"
    @ObservedObject private var zotero = ZoteroStore.shared
    @State private var text = ""
    @State private var initialText = ""
    @State private var fileExisted = false
    /// 右欄預覽雙擊段落 → 左欄源碼跳轉（兩欄捲動各自獨立，只有雙擊會觸發跳轉）。
    @State private var jumpRequest: SourceJumpRequest?
    @State private var saveTask: Task<Void, Never>?
    /// 監看這個檔案被另一台裝置（iCloud）或其他程式改動
    @State private var watcher: FileWatcher?
    /// 檔案在 iCloud 上但還沒下載到本機：這時絕不能存檔，否則會用空內容蓋掉雲端那份
    @State private var awaitingDownload = false

    private var fileDir: URL { fileURL.deletingLastPathComponent() }

    var body: some View {
        VStack(spacing: 0) {
            content
            if quickCmdBar {
                QuickCommandBar(text: $text, onJournal: onJournalCommand)
            }
        }
            // 編輯區墊一層厚材質，避免環境色彩場干擾閱讀
            .surface(.editor, ambient: .thickMaterial)
            .onAppear(perform: load)
            .onDisappear {
                saveNow()
                watcher?.stop()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                // 切回 app：另一台裝置可能改過 → 請 iCloud 抓最新版，沒有未存修改就重讀
                watcher?.requestLatest()
                reloadIfClean()
            }
            .overlay {
                if awaitingDownload {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在從 iCloud 下載…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .onChange(of: text) { scheduleAutosave() }
            .onReceive(NotificationCenter.default.publisher(for: Self.appendNotification)) { note in
                guard let url = note.userInfo?["url"] as? URL, url == fileURL,
                      let appended = note.userInfo?["text"] as? String else { return }
                if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                text += appended
            }
            // 載入 Zotero 文獻供 \cite 解析（已有快取就不重抓）。
            .task { if zotero.items.isEmpty { await zotero.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .blocks:
            ZStack {
                BlockEditorView(text: $text, baseDir: fileDir, documentID: fileURL)
                BlockEditorStatusOverlay()
            }
        case .split:
            HSplitView {
                SourceTextView(
                    text: $text,
                    fontSize: CGFloat(editorFontSize),
                    jump: jumpRequest,
                    lineJump: lineJump,
                    onPasteImage: saveImage
                )
                // minWidth 壓低:窄視窗時雙欄仍能縮進可用寬度,不會把側欄擠歪、
                // 造成選單位置與首頁/日記不一致。
                .frame(minWidth: 150)
                MarkdownPreviewView(
                    text: text, baseDir: fileDir,
                    citationItems: zotero.items, onOpenNote: { store.openNote($0) },
                    onJumpToSource: { jumpRequest = SourceJumpRequest(sync: $0) },
                    layout: previewLayout)
                    .frame(minWidth: 150)
            }
        case .source:
            SourceTextView(
                text: $text,
                fontSize: CGFloat(editorFontSize),
                lineJump: lineJump,
                onPasteImage: saveImage
            )
        case .preview:
            MarkdownPreviewView(
                text: text, baseDir: fileDir,
                citationItems: zotero.items, onOpenNote: { store.openNote($0) },
                layout: previewLayout)
        }
    }

    // MARK: - Load & save

    private func load() {
        watcher?.stop()
        let w = FileWatcher(url: fileURL) { reloadIfClean() }
        watcher = w
        if let content = FileSystemStore.safeRead(fileURL) {
            text = content
            initialText = content
            fileExisted = true
            awaitingDownload = false
            w.requestLatest()           // 本機這份可能不是最新的：背景跟 iCloud 要
        } else if (try? fileURL.checkResourceIsReachable()) == true {
            // 檔案在 iCloud 還沒下載：先顯示下載中，下載完 watcher 會通知 → reloadIfClean
            awaitingDownload = true
            w.requestLatest()
        } else {
            text = ""
            initialText = ""
            fileExisted = false
            awaitingDownload = false
        }
    }

    /// 檔案被外部改動（另一台裝置同步進來）時重讀。
    /// 本機有還沒存的修改就以本機為準（autosave 0.8 秒內就會寫出去）。
    private func reloadIfClean() {
        guard text == initialText, let w = watcher else { return }
        w.read { content in
            guard let content else { return }
            guard text == initialText else { return }     // 讀檔期間使用者又打字了
            awaitingDownload = false
            fileExisted = true
            if content != text {
                text = content
                initialText = content
            }
        }
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard !awaitingDownload else { return }   // 還沒拿到雲端那份，寫出去就是蓋掉它
        // 檔案原本不存在且內容仍是空的 → 不落地，避免製造空檔案
        guard fileExisted || !text.isEmpty else { return }
        guard text != initialText || !fileExisted else { return }
        let snapshot = text
        // 協調寫入：iCloud 會正確接手上傳，也不會通知回自己的 watcher
        watcher?.write(snapshot) { ok in
            guard ok else { return }             // 寫入失敗保持靜默，下次 autosave 再試
            initialText = snapshot
            fileExisted = true
            onSaved?()
        }
    }

    // MARK: - Paste image

    private func saveImage(_ image: NSImage) -> String? {
        switch imageInsertion {
        case .markdown:
            return saveImage(image, into: fileDir.appendingPathComponent("assets", isDirectory: true))
                .map { "![](assets/\($0))\n" }
        case .latex(let root):
            // LaTeX 的圖片路徑是相對主檔（＝專案根目錄），所以固定放 figures/
            return saveImage(image, into: root.appendingPathComponent("figures", isDirectory: true))
                .map { "\\includegraphics[width=0.8\\linewidth]{figures/\($0)}\n" }
        }
    }

    /// 存成 PNG，回傳檔名。
    private func saveImage(_ image: NSImage, into dir: URL) -> String? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "img-\(f.string(from: .now)).png"
        do {
            try png.write(to: dir.appendingPathComponent(name))
        } catch {
            return nil
        }
        return name
    }
}

// MARK: - 底部快速命令列（日記用）

/// 嚴格命令列：一定要打 / 指令才會做事，沒有對應指令會顯示錯誤。
/// 支援 /todo /sub /h1-h3 /toggle /bullet /num /move /go /list；
/// 打 / 出現提示選單（↑↓ 選、Tab 補全、Enter 執行、Esc 取消）。
struct QuickCommandBar: View {
    @Binding var text: String
    var onJournal: ((JournalQuickAction) -> Bool)?

    @AppStorage("journal.quickCmdOpen") private var open = true
    @State private var input = ""
    @FocusState private var focused: Bool
    @State private var stage: Stage = .command
    @State private var sel = 0
    @State private var errorMsg: String?
    /// /sub、/move 捷徑：選完區塊後直接跳到對應動作（略過動作選單）
    @State private var presetAction: BlockAction?
    /// ⌘J 的全域鍵盤監聽（焦點在 WKWebView 裡時 SwiftUI keyboardShortcut 會被吃掉，
    /// 用 local monitor 才攔得到）。
    @State private var keyMonitor: Any?

    enum Stage: Equatable {
        case command          // 輸入指令與參數
        case pickBlock        // /block：選區塊
        case pickAction(Int)  // 已選區塊 → 選動作（移動/子項目/改內容）
        case subContent(Int)  // 連續輸入子項目
        case moving(Int)      // 移動模式
        case editContent(Int) // 編輯區塊第一行原文
    }

    enum BlockAction: Equatable { case move, sub, edit, delete }

    private struct Cmd {
        let name: String
        let arg: String
        let desc: String
    }

    private static let commands: [Cmd] = [
        .init(name: "/todo", arg: "文字 @due(7/20) @est(2h)", desc: "新增待辦"),
        .init(name: "/block", arg: "→ 選區塊", desc: "選區塊後：移動／加子項目／改內容"),
        .init(name: "/h1", arg: "標題", desc: "加入標題 1"),
        .init(name: "/h2", arg: "標題", desc: "加入標題 2"),
        .init(name: "/h3", arg: "標題", desc: "加入標題 3"),
        .init(name: "/toggle", arg: "標題", desc: "加入摺疊清單"),
        .init(name: "/bullet", arg: "文字", desc: "加入項目清單"),
        .init(name: "/num", arg: "文字", desc: "加入編號清單"),
        .init(name: "/go", arg: "7/10・+3・明天", desc: "日記跳到那一天"),
        .init(name: "/list", arg: "", desc: "開任務總覽"),
    ]

    /// @ / ! 標記提示（insert 以 "(" 結尾的，補完後游標留在括號內側繼續打值）
    private static let markers: [(insert: String, display: String, desc: String)] = [
        ("@due(", "@due(7/10)", "到期日：每天出現直到到期"),
        ("@from(", "@from(7/5)", "開始日"),
        ("@on(", "@on(7/10,7/14)", "只在指定日期出現"),
        ("@every(", "@every(mon,thu)", "每週循環"),
        ("@est(", "@est(2h)", "預估時長"),
        ("@remind(", "@remind(7/20 09:00)", "提醒推播"),
        ("@line(", "@line(A)", "主線歸屬"),
        ("@pomo(", "@pomo(2)", "已投入蕃茄數"),
        ("!high", "!high", "高優先"),
        ("!low", "!low", "低優先"),
    ]

    // MARK: 文件區塊解析（頂層行 + 其縮排延續行 = 一塊；連續引用行也歸同塊）

    private struct Block: Identifiable {
        let index: Int
        let range: Range<Int>     // 行範圍
        let title: String
        var id: Int { index }
    }

    private func parseBlocks() -> [Block] {
        let ls = text.components(separatedBy: "\n")
        var res: [Block] = []
        var i = 0
        while i < ls.count {
            let trimmed = ls[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            let isQuote = ls[i].hasPrefix(">")
            var j = i + 1
            while j < ls.count {
                let l = ls[j]
                if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if l.hasPrefix(" ") || l.hasPrefix("\t") || (isQuote && l.hasPrefix(">")) {
                    j += 1
                    continue
                }
                break
            }
            var title = trimmed
            if trimmed.hasPrefix("- [") && trimmed.count > 5 {
                title = TodoMeta.parse(
                    String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)).cleanText
            } else if trimmed.hasPrefix("- ") {
                title = String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix("> [!toggle]") {
                title = "▸ " + trimmed.dropFirst(11).trimmingCharacters(in: .whitespaces)
            }
            res.append(Block(index: res.count, range: i..<j, title: String(title.prefix(48))))
            i = j
        }
        return res
    }

    // MARK: 提示選單

    private enum SuggestionID: Equatable {
        case cmd(Int)
        case block(Int)
        case action(BlockAction)
        case marker(Int)
    }

    private typealias Suggestion = (sid: SuggestionID, title: String, detail: String)

    /// 輸入尾端的 @xxx / !xxx token（標記補完用）
    private var markerToken: (range: Range<String.Index>, text: String)? {
        guard let r = input.range(of: #"[@!][^\s()]*$"#, options: .regularExpression)
        else { return nil }
        return (r, String(input[r]).lowercased())
    }

    private var suggestions: [Suggestion] {
        switch stage {
        case .command:
            if input.hasPrefix("/"), !input.contains(" ") {
                let q = input.lowercased()
                return Self.commands.enumerated()
                    .filter { q == "/" || $0.element.name.hasPrefix(q) }
                    .map { (.cmd($0.offset),
                            $0.element.name
                                + ($0.element.arg.isEmpty ? "" : " \($0.element.arg)"),
                            $0.element.desc) }
            }
            return markerSuggestions
        case .subContent, .editContent:
            return markerSuggestions
        case .pickBlock:
            let q = input.lowercased()
            return parseBlocks()
                .filter { q.isEmpty || $0.title.lowercased().contains(q) }
                .map { (.block($0.index), $0.title, "") }
        case .pickAction:
            return [
                (.action(.move), "移動", "↑↓ 調整這個區塊的順序"),
                (.action(.sub), "加子項目", "在底下連續加縮排子項目"),
                (.action(.edit), "改內容", "編輯這個區塊的第一行原文"),
                (.action(.delete), "刪除", "整塊刪掉（含子項目）；@due 行請走 /list"),
            ]
        case .moving:
            return []
        }
    }

    private var markerSuggestions: [Suggestion] {
        guard let token = markerToken?.text else { return [] }
        return Self.markers.enumerated()
            .filter { (_, m) in
                let ins = m.insert.lowercased()
                // 已補完的（token 本身已含 insert）就不再列，Enter 才送得出去
                return ins.hasPrefix(token) && !token.hasPrefix(ins)
            }
            .map { (.marker($0.offset), $0.element.display, $0.element.desc) }
    }

    private var prompt: String {
        switch stage {
        case .command: return "指令：/todo /block /go …（輸入 / 看清單，⇧↩ 或 ⌘J 聚焦）"
        case .pickBlock: return "選擇區塊（↑↓ 選、Enter 確定、Esc 取消，可打字過濾）"
        case .pickAction: return "要做什麼？（↑↓ 選、Enter 確定、Esc 返回）"
        case .subContent: return "子項目內容（Enter 送出可連續輸入，空行或 Esc 結束）"
        case .moving: return "↑↓ 移動位置，Enter 完成"
        case .editContent: return "編輯整行內容，Enter 儲存（Esc 取消）"
        }
    }

    /// 已鎖定區塊的提示 chip
    private var contextChip: String? {
        let idx: Int
        switch stage {
        case .pickAction(let i), .subContent(let i), .moving(let i), .editContent(let i):
            idx = i
        default:
            return nil
        }
        let blocks = parseBlocks()
        guard idx < blocks.count else { return nil }
        return blocks[idx].title
    }

    // MARK: - View

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if open {
                if !suggestions.isEmpty {
                    suggestionPanel
                }
                HStack(spacing: 8) {
                    Text("❯")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(stage == .command ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(Color.accentColor))
                    if let chip = contextChip {
                        Text(chip)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                    TextField(prompt, text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($focused)
                        .onSubmit(submit)
                        .onKeyPress(.upArrow) { arrow(-1) }
                        .onKeyPress(.downArrow) { arrow(1) }
                        .onKeyPress(.tab) { tabComplete() }
                        .onKeyPress(.escape) { escape() }
                    if let errorMsg {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Button {
                        open = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("收折命令列")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                Button {
                    open = true
                    focused = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                        Text("❯ 命令列")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("展開命令列（⇧↩ 或 ⌘J）")
            }
        }
        .onChange(of: input) { errorMsg = nil }
        .onChange(of: suggestions.count) { _, n in sel = min(sel, max(0, n - 1)) }
        // ⇧Return 展開並聚焦命令列（焦點在文字輸入時不攔，保留編輯器的軟換行）；
        // ⌘J 則隨時可用（local monitor：編輯器 webview 有焦點時也攔得到）
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let isCmdJ = mods == [.command]
                    && event.charactersIgnoringModifiers?.lowercased() == "j"
                var isShiftReturn = mods == [.shift] && event.keyCode == 36  // Return
                if isShiftReturn {
                    // 正在打字（編輯器 webview 或任何文字欄位）就放行，讓 ⇧Return 維持換行
                    var responder = event.window?.firstResponder
                    while let r = responder {
                        if r is NSTextView || r is WKWebView { isShiftReturn = false; break }
                        responder = (r as? NSView)?.superview
                    }
                }
                guard isCmdJ || isShiftReturn else { return event }
                open = true
                DispatchQueue.main.async { focused = true }
                return nil   // 吃掉事件，不再往下傳
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var suggestionPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                        HStack {
                            Text(s.title)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text(s.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(i == sel ? Color.accentColor.opacity(0.22) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            sel = i
                            submit()
                        }
                        .id(i)
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding(.vertical, 4)
            // 選到的列跟著 ↑↓ 捲進可視範圍
            .onChange(of: sel) { _, i in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(i, anchor: .center)
                }
            }
        }
    }

    // MARK: - 鍵盤

    private func arrow(_ delta: Int) -> KeyPress.Result {
        if case .moving = stage {
            moveBlock(delta)
            return .handled
        }
        guard !suggestions.isEmpty else { return .ignored }
        sel = max(0, min(suggestions.count - 1, sel + delta))
        return .handled
    }

    private func tabComplete() -> KeyPress.Result {
        applyCompletion() ? .handled : .ignored
    }

    private func escape() -> KeyPress.Result {
        if stage != .command {
            stage = .command
            presetAction = nil
            input = ""
            sel = 0
            return .handled
        }
        if !input.isEmpty {
            input = ""
            return .handled
        }
        return .ignored
    }

    /// 補全目前選到的提示（指令名 / 標記）。回傳是否有補全動作。
    private func applyCompletion() -> Bool {
        guard sel < suggestions.count else { return false }
        switch suggestions[sel].sid {
        case .cmd(let i):
            let cmd = Self.commands[i]
            // 已經打完整了就不算補全（讓 Enter 落到執行）
            guard input.lowercased() != cmd.name else { return false }
            input = cmd.name + (cmd.arg.isEmpty ? "" : " ")
            sel = 0
            return true
        case .marker(let i):
            guard let token = markerToken else { return false }
            let m = Self.markers[i]
            input.replaceSubrange(
                token.range, with: m.insert + (m.insert.hasSuffix("(") ? "" : " "))
            sel = 0
            return true
        case .block, .action:
            submit()
            return true
        }
    }

    // MARK: - 執行

    private func submit() {
        errorMsg = nil
        switch stage {
        case .command:
            if !suggestions.isEmpty, applyCompletion() { return }
            submitCommand()
        case .pickBlock:
            guard sel < suggestions.count,
                  case .block(let idx) = suggestions[sel].sid else {
                errorMsg = "沒有可選的區塊"
                return
            }
            input = ""
            sel = 0
            if let action = presetAction {
                presetAction = nil
                enter(action, block: idx)
            } else {
                stage = .pickAction(idx)
            }
        case .pickAction(let idx):
            guard sel < suggestions.count,
                  case .action(let action) = suggestions[sel].sid else { return }
            input = ""
            sel = 0
            enter(action, block: idx)
        case .subContent(let idx):
            if !suggestions.isEmpty, applyCompletion() { return }
            let t = input.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {   // 空行 Enter = 結束
                stage = .command
                return
            }
            insertSub(under: idx, content: t)
            input = ""
        case .moving:
            stage = .command
            input = ""
        case .editContent(let idx):
            if !suggestions.isEmpty, applyCompletion() { return }
            saveEdit(block: idx)
        }
    }

    private func enter(_ action: BlockAction, block idx: Int) {
        switch action {
        case .move:
            stage = .moving(idx)
        case .sub:
            stage = .subContent(idx)
        case .edit:
            let blocks = parseBlocks()
            guard idx < blocks.count else { stage = .command; return }
            let ls = text.components(separatedBy: "\n")
            input = ls[blocks[idx].range.lowerBound]
            stage = .editContent(idx)
        case .delete:
            deleteBlock(idx)
        }
    }

    /// 整塊刪除（含子項目）。含 @due 的行擋下——單日副本刪了明天照樣播回來，請走 /list。
    private func deleteBlock(_ idx: Int) {
        stage = .command
        input = ""
        let blocks = parseBlocks()
        guard idx < blocks.count else { return }
        var ls = text.components(separatedBy: "\n")
        let r = blocks[idx].range
        if ls[r].contains(where: {
            $0.range(of: "@due(", options: .caseInsensitive) != nil
        }) {
            errorMsg = "含 @due 的待辦請從 /list 刪除（不然明天會播種回來）"
            return
        }
        var upper = r.upperBound
        if upper < ls.count, ls[upper].trimmingCharacters(in: .whitespaces).isEmpty {
            upper += 1   // 連同後面的空行，避免留下雙空行
        }
        ls.removeSubrange(r.lowerBound..<upper)
        text = ls.joined(separator: "\n")
    }

    private func submitCommand() {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard t.hasPrefix("/") else {
            errorMsg = "指令要以 / 開頭（輸入 / 看清單）"
            return
        }
        let parts = t.split(separator: " ", maxSplits: 1)
        let cmd = parts[0].lowercased()
        let arg = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch cmd {
        case "/todo":
            guard !arg.isEmpty else { errorMsg = "用法：/todo 內容"; return }
            append("- [ ] \(arg)")
        case "/h1", "/h2", "/h3":
            guard !arg.isEmpty else { errorMsg = "用法：\(cmd) 標題文字"; return }
            let level = Int(String(cmd.dropFirst(2))) ?? 1
            append(String(repeating: "#", count: level) + " " + arg)
        case "/toggle":
            guard !arg.isEmpty else { errorMsg = "用法：/toggle 標題"; return }
            append("> [!toggle] \(arg)")
        case "/bullet":
            guard !arg.isEmpty else { errorMsg = "用法：/bullet 內容"; return }
            append("- \(arg)")
        case "/num":
            guard !arg.isEmpty else { errorMsg = "用法：/num 內容"; return }
            append("1. \(arg)")
        case "/block", "/sel":
            presetAction = nil
            stage = .pickBlock
            input = arg
            sel = 0
            return
        case "/sub":     // 捷徑：選完區塊直接進子項目模式
            presetAction = .sub
            stage = .pickBlock
            input = arg
            sel = 0
            return
        case "/move":    // 捷徑：選完區塊直接進移動模式
            presetAction = .move
            stage = .pickBlock
            input = arg
            sel = 0
            return
        case "/go", "/goto", "/day":
            if onJournal?(.go(arg)) == true {
                input = ""
            } else {
                errorMsg = "看不懂日期：\(arg.isEmpty ? "（空）" : arg)（可用 7/10、+3、明天）"
            }
            return
        case "/list", "/tasks":
            input = ""
            _ = onJournal?(.list)
            return
        default:
            errorMsg = "未知指令：\(cmd)（輸入 / 看清單）"
            return
        }
        input = ""
    }

    /// 在文末附加一個區塊（與前一塊之間留一個空行）。
    private func append(_ block: String) {
        var t = text
        if !t.isEmpty {
            while !t.hasSuffix("\n\n") { t += "\n" }
        }
        text = t + block + "\n"
    }

    /// 在父塊（含其既有子項目）末尾插入一行縮排子項目。
    private func insertSub(under blockIndex: Int, content: String) {
        let blocks = parseBlocks()
        guard blockIndex < blocks.count else {
            errorMsg = "找不到那個項目了"
            stage = .command
            return
        }
        var ls = text.components(separatedBy: "\n")
        ls.insert("  - \(content)", at: blocks[blockIndex].range.upperBound)
        text = ls.joined(separator: "\n")
    }

    /// 儲存 editContent：以輸入原文取代區塊第一行。
    private func saveEdit(block idx: Int) {
        let blocks = parseBlocks()
        guard idx < blocks.count else {
            errorMsg = "找不到那個區塊了"
            stage = .command
            return
        }
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMsg = "內容不能是空的（要刪除請在 /list 或編輯器裡處理）"
            return
        }
        var ls = text.components(separatedBy: "\n")
        ls[blocks[idx].range.lowerBound] = input
        text = ls.joined(separator: "\n")
        stage = .command
        input = ""
    }

    /// 移動模式：目前區塊和上/下一塊交換。重組時區塊之間一律隔一個空行。
    private func moveBlock(_ delta: Int) {
        guard case .moving(let idx) = stage else { return }
        let blocks = parseBlocks()
        let j = idx + delta
        guard idx < blocks.count, j >= 0, j < blocks.count else { return }
        let ls = text.components(separatedBy: "\n")
        var chunks = blocks.map { Array(ls[$0.range]) }
        chunks.swapAt(idx, j)
        text = chunks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
        stage = .moving(j)
    }
}

// （WebResources 移到 Services/WebResources.swift，iOS 版共用）

/// Block 編輯器載入狀態覆蓋層：載入中顯示進度、失敗顯示重試。
struct BlockEditorStatusOverlay: View {
    @ObservedObject private var host = BlockEditorHost.shared

    var body: some View {
        if let error = host.loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重試") { host.retry() }
            }
            .padding(20)
        } else if !host.isReady {
            ProgressView("載入編輯器…")
        }
    }
}
#endif
