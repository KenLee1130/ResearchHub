#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct NotesBrowserView: View {
    @EnvironmentObject private var store: FileSystemStore

    @State private var selection: URL?
    @State private var renamingItem: FileItem?
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
                            onTrash: { store.trash(item) }
                        )
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
            .contextMenu {
                Button("新增資料夾") { store.createFolder(named: "新資料夾") }
                Button("新增筆記") { store.createNote(named: "未命名筆記") }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.createFolder(named: "新資料夾")
                } label: {
                    Label("新增資料夾", systemImage: "folder.badge.plus")
                }
                Button {
                    store.createNote(named: "未命名筆記")
                } label: {
                    Label("新增筆記", systemImage: "doc.badge.plus")
                }
            }
        }
        .alert("重新命名", isPresented: renameAlertShown) {
            TextField("名稱", text: $renameText)
            Button("確定") {
                if let item = renamingItem {
                    store.rename(item, to: renameText)
                }
                renamingItem = nil
            }
            Button("取消", role: .cancel) { renamingItem = nil }
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

    private func beginRename(_ item: FileItem) {
        renameText = item.name
        renamingItem = item
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )
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

    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: item.isFolder ? "folder.fill" : "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                .frame(height: 48)
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
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
