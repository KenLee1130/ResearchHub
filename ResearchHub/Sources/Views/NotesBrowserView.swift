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
    @State private var showFolderPicker = false

    var body: some View {
        Group {
            if store.rootURL == nil {
                ChooseRootView(showPicker: $showFolderPicker)
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
        editingNote = FileItem(url: url, isFolder: false, modified: .now)
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
            }
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

    private func open(_ item: FileItem) {
        if item.isFolder {
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

    private func beginRename(_ item: FileItem) {
        renameText = item.name
        renamingURL = item.url
    }

    private func commitRename(_ item: FileItem) {
        defer { renamingURL = nil }
        guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let newURL = store.rename(item, to: renameText) {
            selection = newURL
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
                    Button(item.isFolder ? "開啟" : "編輯") { onOpen() }
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
            Image(systemName: item.isFolder ? "folder.fill" : "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
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

/// 格子裡的就地改名欄：出現就自動取得焦點。
/// Enter 或點到別處＝確定（跟 Finder 一樣），Esc＝取消。
private struct InlineRenameField: View {
    @Binding var text: String
    let placeholder: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var finished = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .multilineTextAlignment(.center)
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(commit: true) }
            }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        commit ? onCommit() : onCancel()
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
