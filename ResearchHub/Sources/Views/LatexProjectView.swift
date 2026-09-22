#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// LaTeX 專案編輯畫面：左邊檔案樹、中間源碼、右邊編譯出來的 PDF（像 Overleaf）。
/// 存檔後自動重新編譯；錯誤可以點過去跳到那一行。
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

    init(projectURL: URL, onClose: @escaping () -> Void) {
        self.projectURL = projectURL
        self.onClose = onClose
        _compiler = StateObject(wrappedValue: LatexCompiler(projectURL: projectURL))
    }

    private var mainURL: URL? { LatexProject.mainFile(in: projectURL) }
    private var pdfURL: URL { LatexProject.outputPDF(of: projectURL) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileTree
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 320)
                editorPane
                    .frame(minWidth: 280)
                previewPane
                    .frame(minWidth: 300)
            }
        }
        .background(.thickMaterial)
        .onAppear(perform: start)
        .onDisappear { watcher?.stop() }
        .alert("匯出失敗", isPresented: .constant(exportError != nil)) {
            Button("好") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - 標題列

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)

            Text(projectURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)

            statusView

            Spacer(minLength: 8)

            Button {
                compiler.compileNow()
            } label: {
                Label("編譯", systemImage: "hammer")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("重新編譯（⌘S）")

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

            Picker("", selection: $continuous) {
                Text("連續").tag(true)
                Text("分頁").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 96)
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
        .padding(.horizontal, 14)
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
            if case .success(let urls) = result { copyIn(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            copyIn(urls)
            return true
        }
    }

    @ViewBuilder
    private func row(for node: LatexProject.Node) -> some View {
        let isMain = node.url == mainURL
        HStack(spacing: 6) {
            Image(systemName: icon(for: node))
                .foregroundStyle(isMain ? Color.accentColor : .secondary)
            if renamingURL == node.url {
                InlineRenameField(
                    text: $renameText, placeholder: node.name,
                    onCommit: { commitRename(node) },
                    onCancel: { renamingURL = nil })
            } else {
                Text(node.name)
                    .fontWeight(isMain ? .semibold : .regular)
                    .lineLimit(1)
            }
        }
        .tag(node.url)
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
            Button("移到垃圾桶", role: .destructive) {
                try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                if selected == node.url { selected = mainURL }
                refreshTree()
                compiler.requestCompile()
            }
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
                    onSaved: { compiler.requestCompile() },
                    lineJump: lineJump)
                    .id(selected)
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
                }
                .frame(maxHeight: 160)
            }
        }
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - 動作

    private func start() {
        continuous = LatexProject.settings(of: projectURL).viewMode != "paged"
        refreshTree()
        selected = mainURL
        watcher = DirectoryWatcher(url: projectURL) { changed in
            refreshTree()
            if let changed, LatexProject.isTextFile(changed) || LatexProject.isImageFile(changed) {
                compiler.requestCompile(after: 1.2)
            }
        }
        compiler.compileNow()
    }

    private func refreshTree() {
        tree = LatexProject.tree(of: projectURL)
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

    private func newFile(folder: Bool) {
        let fm = FileManager.default
        let base = folder ? "新資料夾" : "untitled.tex"
        var url = projectURL.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = projectURL.appendingPathComponent(
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
        if selected == node.url { selected = dest }
        var s = LatexProject.settings(of: projectURL)
        if s.main == relativePath(node.url) {
            s.main = relativePath(dest)
            LatexProject.save(s, to: projectURL)
        }
        refreshTree()
        compiler.requestCompile()
    }

    private func copyIn(_ urls: [URL]) {
        let fm = FileManager.default
        for src in urls {
            let needsScope = src.startAccessingSecurityScopedResource()
            defer { if needsScope { src.stopAccessingSecurityScopedResource() } }
            var dest = projectURL.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                dest = projectURL.appendingPathComponent(
                    ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try? fm.copyItem(at: src, to: dest)
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
#endif
