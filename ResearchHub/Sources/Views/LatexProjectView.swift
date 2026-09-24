#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// LaTeX 專案編輯畫面：左邊檔案樹、中間源碼、右邊編譯出來的 PDF（像 Overleaf）。
/// 編譯是手動的（⌘S／Shift+Return／編譯鈕），不即時渲染；錯誤可以點過去跳到那一行。
struct LatexProjectView: View {
    let projectURL: URL
    var onClose: () -> Void

    @StateObject private var compiler: LatexCompiler
    @State private var tree: [LatexProject.Node] = []
    @State private var selected: URL?
    @State private var editorMode: EditorMode = .source
    @State private var continuous = true
    @State private var showFormat = false
    @State private var showIssues = true
    @State private var lineJump: LineJumpRequest?
    @State private var watcher: DirectoryWatcher?
    @State private var renamingURL: URL?
    @State private var renameText = ""
    @State private var addFiles = false
    @State private var exportError: String?
    @State private var issueHeight: CGFloat = 0
    @EnvironmentObject private var store: FileSystemStore
    @State private var hostWindow: NSWindow?
    @State private var deleteKeyMonitor: Any?
    /// 版面：跟 Overleaf 一樣可以只看原始碼、只看 PDF、或並排
    @AppStorage("latexPaneLayout") private var layoutRaw = Layout.split.rawValue
    @AppStorage("latexShowFileTree") private var showTree = true
    @Environment(\.openWindow) private var openWindow

    /// 這個畫面是不是已經在自己的視窗裡（獨立視窗就不再顯示「彈出視窗」按鈕）
    var isStandaloneWindow = false

    enum Layout: String { case editor, split, pdf }
    private var layout: Layout { Layout(rawValue: layoutRaw) ?? .split }

    init(projectURL: URL, isStandaloneWindow: Bool = false, onClose: @escaping () -> Void) {
        self.projectURL = projectURL
        self.isStandaloneWindow = isStandaloneWindow
        self.onClose = onClose
        _compiler = StateObject(wrappedValue: LatexCompiler(projectURL: projectURL))
    }

    private var mainURL: URL? { LatexProject.mainFile(in: projectURL) }
    private var pdfURL: URL { LatexProject.outputPDF(of: projectURL) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 分隔位置只有使用者拖的時候才會變，而且會記住（見 PersistentSplitView）。
            // 檔案樹的 holdingPriority 比較高：視窗縮放時由編輯區與預覽分攤。
            PersistentSplitView(autosaveName: "LatexProjectPanes", panes: [
                .init(id: "tree", minWidth: 120, initialWidth: 210,
                      holdingPriority: .init(260), isVisible: showTree,
                      content: hosted(fileTree)),
                .init(id: "editor", minWidth: 220,
                      isVisible: layout != .pdf, content: hosted(editorPane)),
                .init(id: "preview", minWidth: 220,
                      isVisible: layout != .editor, content: hosted(previewPane)),
            ])
        }
        .surface(.canvas, ambient: .thickMaterial)
        .background(WindowReader { hostWindow = $0 })
        .onAppear {
            start()
            installDeleteShortcut()
        }
        .onDisappear {
            watcher?.stop()
            if let deleteKeyMonitor { NSEvent.removeMonitor(deleteKeyMonitor) }
            deleteKeyMonitor = nil
        }
        .alert("匯出失敗", isPresented: .constant(exportError != nil)) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// 放進 NSSplitView 的每一欄：撐滿分到的空間，並補上環境物件
    /// （AppKit 容器裡的 SwiftUI 不會繼承外面的 environment）。
    private func hosted<V: View>(_ view: V) -> AnyView {
        AnyView(view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(store))
    }

    // MARK: - 標題列

    /// 標題列。寬度不夠時自動改成只有圖示——標題列的理想寬度會變成整個畫面的最小寬度，
    /// 太寬就會把版面撐爆。
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Button(action: onClose) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)

            Button { showTree.toggle() } label: {
                Image(systemName: showTree ? "sidebar.leading" : "sidebar.left")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("0", modifiers: .command)
            .help("顯示／隱藏檔案列表（⌘0）")

            Text(projectURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(compact ? -1 : 0)

            statusView

            Spacer(minLength: 8)

            Button(action: compile) {
                Label("編譯", systemImage: "hammer")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("重新編譯（⌘S 或 Shift+Return）")

            if !isStandaloneWindow {
                Button {
                    openWindow(id: "latex", value: projectURL)
                    NotificationCenter.default.post(
                        name: RootView.collapseSidebarNotification, object: nil)
                    onClose()   // 已彈到新視窗，關掉內嵌這份，避免同專案兩開
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("在新視窗開啟（⌘⇧N）")
            }

            Button {
                showFormat = true
            } label: {
                Label("格式", systemImage: "textformat.size")
            }
            .popover(isPresented: $showFormat, arrowEdge: .bottom) {
                FormatPanelView(projectURL: projectURL) {
                    refreshTree()
                    compiler.compileNow()
                } openFormatFile: {
                    selected = projectURL.appendingPathComponent(LatexProject.formatName)
                    showFormat = false
                }
            }

            Picker("", selection: $layoutRaw) {
                Image(systemName: "doc.plaintext").tag(Layout.editor.rawValue)
                Image(systemName: "rectangle.split.2x1").tag(Layout.split.rawValue)
                Image(systemName: "doc.richtext").tag(Layout.pdf.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)
            .help("只看原始碼（⌘1）／並排（⌘2）／只看 PDF（⌘3）")

            // 鍵盤捷徑用：segmented picker 本身掛不了快捷鍵
            Group {
                Button("") { layoutRaw = Layout.editor.rawValue }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { layoutRaw = Layout.split.rawValue }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { layoutRaw = Layout.pdf.rawValue }
                    .keyboardShortcut("3", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)

            Picker("", selection: $continuous) {
                Text("連續").tag(true)
                Text("分頁").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
            .disabled(layout == .editor)
            .onChange(of: continuous) { _, v in
                var s = LatexProject.settings(of: projectURL)
                s.viewMode = v ? "continuous" : "paged"
                LatexProject.save(s, to: projectURL)
            }

            Menu {
                Button("匯出 PDF…") { exportPDF() }
                Button("匯出專案（.zip，可上傳 Overleaf）…") { exportZip() }
                Divider()
                Button("在 Finder 顯示") {
                    NSWorkspace.shared.activateFileViewerSelecting([projectURL])
                }
            } label: {
                Label("匯出", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .labelStyle(AdaptiveLabelStyle(compact: compact))
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusView: some View {
        switch compiler.status {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("編譯中…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded(let at):
            Label(at.formatted(date: .omitted, time: .shortened), systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
                .help("最後一次成功編譯的時間")
        case .failed(let n):
            Button {
                showIssues = true
            } label: {
                Label("\(n) 個問題", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        case .unavailable(let msg):
            Label(msg, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(msg)
        }
    }

    // MARK: - 檔案樹

    private var fileTree: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("檔案").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { newFile(folder: false) } label: { Image(systemName: "doc.badge.plus") }
                    .buttonStyle(.plain).help("新增 .tex 檔")
                Button { newFile(folder: true) } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新增資料夾")
                Button { addFiles = true } label: { Image(systemName: "tray.and.arrow.down") }
                    .buttonStyle(.plain).help("加入現有檔案（圖片、.bib…）")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            List(tree, children: \.children, selection: $selected) { node in
                row(for: node)
            }
            .listStyle(.sidebar)
        }
        .fileImporter(isPresented: $addFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { moveIn(urls, to: newItemParent) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            moveIn(urls, to: newItemParent)
            return true
        }
        .inkSurface(.chrome)
    }

    @ViewBuilder
    private func row(for node: LatexProject.Node) -> some View {
        let isMain = node.url == mainURL
        HStack(spacing: 6) {
            Image(systemName: icon(for: node))
                .foregroundStyle(isMain ? Color.accentColor : .secondary)
            if same(renamingURL, node.url) {
                InlineRenameField(
                    text: $renameText, placeholder: node.name,
                    onCommit: { commitRename(node) },
                    onCancel: { renamingURL = nil },
                    centered: false)
            } else {
                Text(node.name)
                    .fontWeight(isMain ? .semibold : .regular)
                    .lineLimit(1)
            }
        }
        .tag(node.url)
        // 用 itemProvider 而不是 .draggable：在 macOS 的 List 裡，列內容掛 .draggable 會讓
        // 按下滑鼠先被拖曳手勢攔走，點在檔名上選不到、只有點列的空白處才選得到。
        // itemProvider 是 List 原生的拖曳介面，跟選取不會打架。
        .itemProvider { NSItemProvider(object: node.url as NSURL) }
        .dropDestination(for: URL.self) { urls, _ in
            // 丟到資料夾＝放進去；丟到檔案＝放到它旁邊那層
            moveIn(urls, to: node.isFolder ? node.url : node.url.deletingLastPathComponent())
            return true
        }
        .contextMenu {
            if node.url.pathExtension.lowercased() == "tex", !isMain {
                Button("設為主檔案") {
                    var s = LatexProject.settings(of: projectURL)
                    s.main = relativePath(node.url)
                    LatexProject.save(s, to: projectURL)
                    compiler.compileNow()
                }
            }
            Button("重新命名") {
                renameText = node.name
                renamingURL = node.url
            }
            Button("在 Finder 顯示") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Divider()
            Button("移到垃圾桶", role: .destructive) { trash(node.url) }
        }
    }

    private func icon(for node: LatexProject.Node) -> String {
        if node.isFolder { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "tex": return "doc.text"
        case "bib": return "text.book.closed"
        case "sty", "cls": return "gearshape"
        case "png", "jpg", "jpeg", "pdf", "eps", "gif": return "photo"
        default: return "doc"
        }
    }

    // MARK: - 編輯區

    @ViewBuilder
    private var editorPane: some View {
        if let selected {
            if LatexProject.isTextFile(selected) {
                EditorCore(
                    fileURL: selected,
                    mode: $editorMode,
                    imageInsertion: .latex(projectRoot: projectURL),
                    onSaved: nil,
                    lineJump: lineJump,
                    onShiftReturn: { compiler.compileNow() })
            } else if LatexProject.isImageFile(selected) {
                imagePreview(selected)
            } else {
                placeholder("這個檔案沒辦法在這裡預覽")
            }
        } else {
            placeholder("從左邊選一個檔案")
        }
    }

    private func imagePreview(_ url: URL) -> some View {
        VStack {
            if url.pathExtension.lowercased() == "pdf" {
                LatexPDFView(url: url, version: 0, continuous: true)
            } else if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                placeholder("讀不到這張圖")
            }
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 預覽區

    private var previewPane: some View {
        VStack(spacing: 0) {
            if FileManager.default.fileExists(atPath: pdfURL.path) {
                LatexPDFView(url: pdfURL, version: compiler.pdfVersion, continuous: continuous)
            } else {
                placeholder(compiler.status == .running ? "編譯中…" : "還沒有編譯結果，按「編譯」試試")
            }
            if !compiler.issues.isEmpty {
                Divider()
                issuesPanel
            }
        }
    }

    private var issuesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showIssues.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showIssues ? "chevron.down" : "chevron.right")
                    let errors = compiler.issues.filter(\.isError).count
                    Text(errors > 0 ? "\(errors) 個錯誤、\(compiler.issues.count - errors) 個警告"
                                    : "\(compiler.issues.count) 個警告")
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if showIssues {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(compiler.issues) { issue in
                            Button { open(issue) } label: {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: issue.isError
                                          ? "xmark.octagon.fill" : "exclamationmark.triangle")
                                        .foregroundStyle(issue.isError ? .red : .orange)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(issue.message)
                                            .font(.caption)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let loc = issue.location {
                                            Text(loc).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // ScrollView 會把提議的高度全吃掉，只有一兩則警告時下面會空一大塊，
                    // 所以量一下內容高度，上限 160
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        issueHeight = $0
                    }
                }
                .frame(height: min(max(issueHeight, 22), 160))
            }
        }
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - 動作

    private func start() {
        continuous = LatexProject.settings(of: projectURL).viewMode != "paged"
        refreshTree()
        selected = mainURL
        // 只更新檔案樹，不自動編譯——編譯一律由使用者按（⌘S／Shift+Return／編譯鈕）
        watcher = DirectoryWatcher(url: projectURL) { _ in
            refreshTree()
        }
    }

    /// 編譯前先叫編輯器存檔：編譯讀的是磁碟上的檔案，沒存會編到舊內容。
    private func compile() {
        NotificationCenter.default.post(name: EditorCore.saveNowNotification, object: nil)
        DispatchQueue.main.async { compiler.compileNow() }
    }

    /// ⌘⌫ 刪檔。只在焦點不在文字編輯器時才接手——在編輯器裡 ⌘⌫ 是「刪到行首」，
    /// 所以那種時候要原封不動把事件放回去。
    private func installDeleteShortcut() {
        guard deleteKeyMonitor == nil else { return }
        deleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 51,                                   // delete（⌫）
                  flags.contains(.command),
                  flags.isDisjoint(with: [.shift, .option, .control]),
                  let window = hostWindow, event.window === window,
                  renamingURL == nil,
                  focusIsInFileTree(of: window),
                  let target = selected
            else { return event }
            trash(target)
            return nil
        }
    }

    /// 焦點是不是真的在檔案樹裡面。
    /// 用「正向確認」而不是「只要不是文字編輯器就算」——後者在焦點不明時也會成立，
    /// 那等於在編輯器旁邊按 ⌘⌫ 就把檔案刪掉了。判斷不出來就放行，讓系統照原本的處理。
    private func focusIsInFileTree(of window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView,
              !(responder is NSTextView)
        else { return false }
        // 這個畫面裡唯一的清單就是檔案樹（SwiftUI List 底層是 NSTableView／NSOutlineView），
        // 編輯器是 NSTextView、預覽是 PDFView，所以「焦點在清單裡」就等於「焦點在檔案樹」。
        var view: NSView? = responder
        while let current = view {
            if current is NSTableView { return true }
            view = current.superview
        }
        return false
    }

    /// 丟垃圾桶（可以從垃圾桶救回來，所以不另外問）。
    private func trash(_ url: URL) {
        guard (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
        else { return }
        if same(selected, url) { selected = mainURL }
        refreshTree()
    }

    private func refreshTree() {
        tree = LatexProject.tree(of: projectURL)
    }

    /// URL 相等比較太脆弱（資料夾會多一條結尾斜線），一律比 path。
    private func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return normalized(a).path == normalized(b).path
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: projectURL.path + "/", with: "")
    }

    private func open(_ issue: LatexIssue) {
        guard let file = issue.file else { return }
        let clean = file.hasPrefix("./") ? String(file.dropFirst(2)) : file
        let url = clean.hasPrefix("/")
            ? URL(fileURLWithPath: clean)
            : projectURL.appendingPathComponent(clean)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        selected = url
        guard let line = issue.line else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            lineJump = LineJumpRequest(line: line)
        }
    }

    /// 新東西要放哪：選到資料夾就放進去，選到檔案就放在它旁邊，什麼都沒選就放專案根目錄。
    private var newItemParent: URL {
        guard let selected else { return projectURL }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDir)
        else { return projectURL }
        return isDir.boolValue ? selected : selected.deletingLastPathComponent()
    }

    private func newFile(folder: Bool) {
        let fm = FileManager.default
        let parent = newItemParent
        let base = folder ? "新資料夾" : "untitled.tex"
        var url = parent.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent(
                folder ? "新資料夾 \(n)" : "untitled-\(n).tex")
            n += 1
        }
        if folder {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        refreshTree()
        selected = folder ? selected : url
        renameText = ""
        renamingURL = url
    }

    private func commitRename(_ node: LatexProject.Node) {
        defer { renamingURL = nil }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != node.name else { return }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        try? FileManager.default.moveItem(at: node.url, to: dest)
        if same(selected, node.url) { selected = dest }
        var s = LatexProject.settings(of: projectURL)
        if s.main == relativePath(node.url) {
            s.main = relativePath(dest)
            LatexProject.save(s, to: projectURL)
        }
        refreshTree()
    }

    /// 把東西放進 dest 資料夾：本來就在專案裡的用搬的，外面來的用複製的。
    /// 拖放傳進來的 URL 可能是 file reference（file:///.file/id=…）或帶著 symlink，
    /// 直接比路徑會認不出「這是專案裡的檔案」，結果被當成外部檔案複製一份。
    private func normalized(_ url: URL) -> URL {
        ((url as NSURL).filePathURL ?? url).standardizedFileURL.resolvingSymlinksInPath()
    }

    private func moveIn(_ urls: [URL], to rawDest: URL) {
        let fm = FileManager.default
        let dest = normalized(rawDest)
        let root = normalized(projectURL).path
        for raw in urls {
            let src = normalized(raw)
            let inProject = src.path.hasPrefix(root + "/")
            // 不能把資料夾丟進自己（或自己的子資料夾）裡
            if dest.path == src.path || dest.path.hasPrefix(src.path + "/") { continue }
            if src.deletingLastPathComponent().path == dest.path { continue }
            let needsScope = inProject ? false : src.startAccessingSecurityScopedResource()
            defer { if needsScope { src.stopAccessingSecurityScopedResource() } }

            var target = dest.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                let base = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                target = dest.appendingPathComponent(
                    ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            if inProject {
                guard (try? fm.moveItem(at: src, to: target)) != nil else { continue }
                if same(selected, src) { selected = target }
                // 主檔案被搬走的話，設定裡的路徑也要跟著改
                var settings = LatexProject.settings(of: projectURL)
                if settings.main == relativePath(src) {
                    settings.main = relativePath(target)
                    LatexProject.save(settings, to: projectURL)
                }
            } else {
                try? fm.copyItem(at: src, to: target)
            }
        }
        refreshTree()
    }

    private func exportPDF() {
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            exportError = "還沒有編譯結果，先按「編譯」。"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = projectURL.lastPathComponent + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: pdfURL, to: dest)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportZip() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = projectURL.lastPathComponent + ".zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        // 小幫手碰不到 iCloud（見 LatexStaging），所以先把專案鏡射到容器裡再打包，
        // 打好的 zip 由 app 自己搬到使用者選的位置。
        let scratch: URL
        let staged: URL
        do {
            scratch = try LatexStaging.scratchDir()
            staged = scratch.appendingPathComponent("project", isDirectory: true)
            try LatexStaging.copyTree(from: projectURL, to: staged)
        } catch {
            exportError = error.localizedDescription
            return
        }
        let zipURL = scratch.appendingPathComponent("export.zip")
        LatexCompiler.runHelper(["zip", staged.path, zipURL.path]) { output, error in
            defer { try? FileManager.default.removeItem(at: scratch) }
            if let error {
                exportError = error.localizedDescription
                return
            }
            guard LatexCompiler.parseFields(output)["RC"] == "0" else {
                exportError = "打包失敗：\(output)"
                return
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipURL, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

/// 把 LaTeX 專案彈到獨立視窗（跟筆記的 NoteWindowView 一樣）。
struct LatexProjectWindowView: View {
    let projectURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AmbientBackground()
            if let projectURL {
                LatexProjectView(projectURL: projectURL, isStandaloneWindow: true) {
                    dismiss()
                }
                .id(projectURL)
                .navigationTitle(projectURL.lastPathComponent)
            } else {
                Text("找不到這個專案").foregroundStyle(.secondary)
            }
        }
    }
}

/// 寬的時候圖示＋文字，窄的時候只剩圖示。
private struct AdaptiveLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}
#endif
