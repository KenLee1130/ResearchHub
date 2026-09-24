#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct NotesBrowserView: View {
    @EnvironmentObject private var store: FileSystemStore

    @State private var selection: URL?
    /// 正在就地改名的項目（新建後自動進入；右鍵「重新命名」也走這裡）
    @State private var renamingURL: URL?
    @State private var renameText = ""
    @State private var editingNote: FileItem?
    /// 正在開啟的 LaTeX 專案（資料夾）
    @State private var editingProject: URL?
    @State private var importing = false
    @State private var showFolderPicker = false

    var body: some View {
        Group {
            if store.rootURL == nil {
                ChooseRootView(showPicker: $showFolderPicker)
            } else if let project = editingProject {
                LatexProjectView(projectURL: project) {
                    editingProject = nil
                    store.refresh()
                }
                .id(project)
            } else if let note = editingNote {
                NoteEditorView(noteURL: note.url) {
                    editingNote = nil
                    store.refresh()
                }
            } else {
                browser
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                store.setRoot(url)
            }
        }
        .navigationTitle("筆記")
        .onAppear(perform: consumePendingOpen)
        .onChange(of: store.pendingOpenNote) { consumePendingOpen() }
    }

    /// 處理跨分頁「開啟筆記」請求（首頁最近筆記 / TODO / Cmd+K 搜尋）
    private func consumePendingOpen() {
        guard let url = store.pendingOpenNote else { return }
        store.pendingOpenNote = nil
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            if LatexProject.isProject(url) { editingProject = url }
        } else {
            editingNote = FileItem(url: url, isFolder: false, modified: .now)
        }
    }

    // MARK: - Browser

    private var browser: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(store.items) { item in
                        FileIconCell(
                            item: item,
                            isSelected: selection == item.url,
                            onSelect: { selection = item.url },
                            onOpen: { open(item) },
                            onRename: { beginRename(item) },
                            onTrash: { store.trash(item) },
                            isRenaming: renamingURL == item.url,
                            renameText: $renameText,
                            onCommitRename: { commitRename(item) },
                            onCancelRename: { renamingURL = nil }
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
            .contextMenu {
                Button("新增資料夾") { createAndRename(folder: true) }
                Button("新增筆記") { createAndRename(folder: false) }
                Button("新增 LaTeX 專案") { createProject() }
                Divider()
                Button("匯入 Overleaf 專案…") { importing = true }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.zip, .folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { importProject(url) }
        }
        // ⌘⌫ 丟垃圾桶（跟 Finder 一樣）。正在改名時不作用——
        // 那時候 ⌘⌫ 是文字欄位的「刪到行首」。
        .background {
            Button("") { trashSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .disabled(renamingURL != nil || selection == nil)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    createAndRename(folder: true)
                } label: {
                    Label("新增資料夾", systemImage: "folder.badge.plus")
                }
                Button {
                    createAndRename(folder: false)
                } label: {
                    Label("新增筆記", systemImage: "doc.badge.plus")
                }
                Menu {
                    Button("新增 LaTeX 專案") { createProject() }
                    Button("匯入 Overleaf 專案…（.zip 或資料夾）") { importing = true }
                } label: {
                    Label("LaTeX 專案", systemImage: "curlybraces.square")
                }
            }
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            ForEach(store.breadcrumb, id: \.index) { crumb in
                if crumb.index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                BreadcrumbButton(
                    name: crumb.name,
                    isLast: crumb.index == store.breadcrumb.count - 1,
                    targetURL: store.stack[crumb.index],
                    onTap: { store.navigate(toBreadcrumbIndex: crumb.index) }
                )
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    /// ⌘⌫：把選到的檔案／資料夾／專案丟到垃圾桶（可從垃圾桶救回來，所以不另外問）
    private func trashSelected() {
        guard renamingURL == nil, let url = selection,
              let item = store.items.first(where: { $0.url == url }) else { return }
        selection = nil
        store.trash(item)
    }

    private func open(_ item: FileItem) {
        if item.isProject {
            editingProject = item.url
        } else if item.isFolder {
            store.open(item)
            selection = nil
        } else {
            editingNote = item
        }
    }

    /// 新建後名稱直接進入編輯：欄位留空、預設名稱當提示字，直接打字就是新名字；
    /// 按 Enter 或點別處＝確定，Esc 或留空＝保留預設名稱。
    private func createAndRename(folder: Bool) {
        let url = folder
            ? store.createFolder(named: "新資料夾")
            : store.createNote(named: "未命名筆記")
        guard let url else { return }
        selection = url
        renameText = ""
        renamingURL = url
    }

    /// 新增 LaTeX 專案：建好範本（可直接帶去 Overleaf 編譯）後，名稱進入就地編輯。
    private func createProject() {
        guard let current = store.currentURL else { return }
        do {
            let url = try LatexProject.create(in: current, name: "新專案")
            store.refresh()
            selection = url
            renameText = ""
            renamingURL = url
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// 匯入 Overleaf 下載的 zip 或整個資料夾。
    private func importProject(_ url: URL) {
        guard let current = store.currentURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "zip" {
            // 小幫手碰不到 iCloud（見 LatexStaging）：zip 先複製進容器、在容器裡解開，
            // 再由 app 把內容搬進筆記資料夾。
            let scratch: URL
            let localZip: URL
            do {
                scratch = try LatexStaging.scratchDir()
                localZip = scratch.appendingPathComponent("import.zip")
                try FileManager.default.copyItem(at: url, to: localZip)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                store.errorMessage = error.localizedDescription
                return
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            let unpacked = scratch.appendingPathComponent("out", isDirectory: true)
            try? FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            LatexCompiler.runHelper(["unzip", localZip.path, unpacked.path, name]) { output, error in
                defer { try? FileManager.default.removeItem(at: scratch) }
                if let error {
                    store.errorMessage = error.localizedDescription
                    return
                }
                let fields = LatexCompiler.parseFields(output)
                guard fields["RC"] == "0", let dest = fields["DEST"] else {
                    store.errorMessage = "解壓縮失敗：\(output)"
                    return
                }
                var folder = current.appendingPathComponent(name, isDirectory: true)
                var n = 2
                while FileManager.default.fileExists(atPath: folder.path) {
                    folder = current.appendingPathComponent("\(name) \(n)", isDirectory: true)
                    n += 1
                }
                do {
                    try LatexStaging.copyTree(from: URL(fileURLWithPath: dest), to: folder)
                } catch {
                    store.errorMessage = error.localizedDescription
                    return
                }
                store.refresh()
                if LatexProject.isProject(folder) {
                    editingProject = folder
                } else {
                    store.errorMessage = "匯入完成，但裡面找不到含 \\documentclass 的 .tex，"
                        + "所以不會當成 LaTeX 專案開啟。"
                }
            }
        } else {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var dest = current.appendingPathComponent(name, isDirectory: true)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = current.appendingPathComponent("\(name) \(n)", isDirectory: true)
                n += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                store.refresh()
                if LatexProject.isProject(dest) { editingProject = dest }
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    private func beginRename(_ item: FileItem) {
        renameText = item.name
        renamingURL = item.url
    }

    /// 專案改名後，如果主檔的 \title 還是舊名稱就一起更新。
    private func renameProjectTitle(in folder: URL, from old: String, to new: String) {
        guard let main = LatexProject.mainFile(in: folder),
              let text = try? String(contentsOf: main, encoding: .utf8),
              text.contains("\\title{\(old)}") else { return }
        try? text.replacingOccurrences(of: "\\title{\(old)}", with: "\\title{\(new.trimmingCharacters(in: .whitespaces))}")
            .write(to: main, atomically: true, encoding: .utf8)
    }

    private func commitRename(_ item: FileItem) {
        defer { renamingURL = nil }
        guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let newURL = store.rename(item, to: renameText) {
            selection = newURL
            if item.isProject { renameProjectTitle(in: newURL, from: item.name, to: renameText) }
        }
    }
}

// MARK: - Breadcrumb（可點擊導航，也是拖放目標：拖筆記上來 = 移到該層）

struct BreadcrumbButton: View {
    @EnvironmentObject private var store: FileSystemStore

    let name: String
    let isLast: Bool
    let targetURL: URL
    let onTap: () -> Void

    @State private var isDropTarget = false

    var body: some View {
        Button(action: onTap) {
            Text(name)
                .font(.callout)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.2) : .clear)
        )
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls {
                store.move(url, intoDirectory: targetURL)
            }
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
    }
}

// MARK: - Icon cell

struct FileIconCell: View {
    @EnvironmentObject private var store: FileSystemStore

    let item: FileItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onTrash: () -> Void
    var isRenaming = false
    var renameText: Binding<String> = .constant("")
    var onCommitRename: () -> Void = {}
    var onCancelRename: () -> Void = {}

    @State private var isDropTarget = false

    var body: some View {
        if isRenaming {
            tile   // 改名中：不掛點擊／拖曳手勢，免得搶走輸入框的點擊與選字
        } else {
            tile
                .onTapGesture(count: 2) { onOpen() }
                .simultaneousGesture(TapGesture().onEnded { onSelect() })
                .contextMenu {
                    Button(item.isProject ? "開啟專案" : (item.isFolder ? "開啟" : "編輯")) { onOpen() }
                    Button("重新命名") { onRename() }
                    Divider()
                    Button("移到垃圾桶", role: .destructive) { onTrash() }
                }
                .draggable(item.url)
                .modifier(FolderDropModifier(item: item, isTargeted: $isDropTarget))
        }
    }

    private var tile: some View {
        VStack(spacing: 6) {
            Image(systemName: item.isProject
                  ? "curlybraces.square.fill"
                  : (item.isFolder ? "folder.fill" : "doc.text"))
                .font(.system(size: 40))
                .foregroundStyle(item.isProject
                                 ? Color.teal
                                 : (item.isFolder ? Color.accentColor : Color.secondary))
                .frame(height: 48)
            if isRenaming {
                InlineRenameField(
                    text: renameText, placeholder: item.name,
                    onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(8)
        .frame(width: 110)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTarget ? Color.accentColor : .clear,
                    lineWidth: 2
                )
        )
    }

    private var backgroundColor: Color {
        if isSelected { return Color.secondary.opacity(0.18) }
        if isDropTarget { return Color.accentColor.opacity(0.08) }
        return .clear
    }
}

/// 只有資料夾接受拖放。
private struct FolderDropModifier: ViewModifier {
    @EnvironmentObject private var store: FileSystemStore
    let item: FileItem
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if item.isFolder {
            content.dropDestination(for: URL.self) { urls, _ in
                for url in urls {
                    store.move(url, into: item)
                }
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}

// MARK: - First-launch root picker

struct ChooseRootView: View {
    @Binding var showPicker: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("選擇 Research Hub 的根資料夾")
                .font(.title3)
            Text("筆記會以真實檔案存放在這個資料夾內，\n會自動建立 Notes/ 與 Journal/ 兩個子目錄。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("選擇資料夾…") { showPicker = true }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
