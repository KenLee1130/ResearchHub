#if os(macOS)
import SwiftUI
import AppKit

struct RootView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(EventStore.self) private var eventStore
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(GeneralTodoStore.self) private var generalTodos
    @AppStorage("settings.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.ambient.rawValue
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    @State private var tab: AppTab? = .home
    @State private var noteTree: [FileSystemStore.TreeNode] = []
    @State private var noteTreeTask: Task<Void, Never>?

    /// 側欄的筆記樹在背景重掃（要逐一看資料夾是不是 LaTeX 專案），掃好、有變才換上。
    /// 使用者自己新增／改名／刪除時仍是立刻重掃（那些地方直接設 noteTree）。
    private func reloadNoteTreeInBackground() {
        let notes = store.notesURL
        noteTreeTask?.cancel()
        noteTreeTask = Task {
            let tree = await Task.detached(priority: .userInitiated) {
                LibraryScan.noteTree(notes: notes)
            }.value
            guard !Task.isCancelled else { return }
            if tree != noteTree { noteTree = tree }
        }
    }
    @State private var notesExpanded = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hostWindow: NSWindow?
    @Environment(\.openWindow) private var openWindow
    /// 側欄筆記樹正在就地改名的項目
    @State private var renamingNode: URL?
    @State private var renameText = ""

    /// 把筆記／LaTeX 專案彈到小視窗時，主視窗的導覽欄就用不到了 → 順手收起來
    static let collapseSidebarNotification = Notification.Name("RootView.collapseSidebar")
    /// 側欄寬度，只由右緣的自訂把手改變（見 SidebarSplitControl）。
    /// 最窄可以縮到只剩圖示。
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 200
    private static let sidebarMin: Double = 68
    private static let sidebarMax: Double = 320
    /// 窄到放不下文字時只顯示圖示
    private var sidebarCompact: Bool { sidebarWidth < 130 }

    /// 側欄項目。窄的時候只拿掉文字，其他（圖示大小、顏色）完全照原本的 Label——
    /// 用 .labelStyle(.iconOnly) 的話側欄不會套用它的圖示樣式，會變成灰色小圖示。
    private func sidebarLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        Label {
            if !sidebarCompact { Text(title) }
        } icon: {
            Image(systemName: icon)
        }
    }

    // MARK: - 側欄筆記樹

    private typealias TreeNode = FileSystemStore.TreeNode

    private func isRenaming(_ node: TreeNode) -> Bool {
        renamingNode?.standardizedFileURL.path == node.url.standardizedFileURL.path
    }

    @ViewBuilder
    private func sidebarRow(_ node: TreeNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isProject ? "curlybraces.square" : node.isFolder ? "folder" : "doc.text")
                .font(.caption)
                .foregroundStyle(node.isFolder ? .secondary : .tertiary)
            if isRenaming(node) {
                InlineRenameField(
                    text: $renameText, placeholder: node.name,
                    onCommit: { commitRename(node) },
                    onCancel: { renamingNode = nil },
                    centered: false)
            } else {
                Text(node.name)
                    .font(.callout)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming(node) else { return }
            if node.isFolder {
                store.reveal(directory: node.url)
            } else {
                store.openNote(node.url)
            }
        }
        .contextMenu { sidebarMenu(node) }
    }

    @ViewBuilder
    private func sidebarMenu(_ node: TreeNode) -> some View {
        if !node.isFolder {   // 筆記或 LaTeX 專案
            Button("在新分頁開啟") { openInNewTab(node) }
            Divider()
        }
        Button("重新命名") {
            renameText = node.name
            renamingNode = node.url
        }
        Button("下載…") { download(node) }
        Button("刪除", role: .destructive) {
            store.trash(fileItem(node))
            noteTree = store.noteTree()
        }
        Divider()
        Button("新增筆記") { createNear(node, folder: false) }
        Button("新增資料夾") { createNear(node, folder: true) }
        Button("上傳檔案…") { upload(near: node) }
    }

    private func fileItem(_ node: TreeNode) -> FileItem {
        // LaTeX 專案在樹裡是葉節點，但實際上是資料夾
        FileItem(url: node.url, isFolder: node.isFolder || node.isProject, modified: .now)
    }

    /// 新東西要放哪：點的是資料夾就放進去，否則放在它旁邊
    private func directory(near node: TreeNode) -> URL {
        node.isFolder ? node.url : node.url.deletingLastPathComponent()
    }

    private func commitRename(_ node: TreeNode) {
        defer { renamingNode = nil }
        store.rename(fileItem(node), to: renameText)
        noteTree = store.noteTree()
    }

    private func createNear(_ node: TreeNode, folder: Bool) {
        let dir = directory(near: node)
        let url = folder
            ? store.createFolder(named: "新資料夾", in: dir)
            : store.createNote(named: "未命名筆記", in: dir)
        noteTree = store.noteTree()
        guard let url else { return }
        // 建好直接進入改名（跟筆記瀏覽器一樣）
        renameText = url.deletingPathExtension().lastPathComponent
        renamingNode = url
    }

    private func upload(near node: TreeNode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "上傳"
        guard panel.runModal() == .OK else { return }
        store.importItems(panel.urls, into: directory(near: node))
        noteTree = store.noteTree()
    }

    private func download(_ node: TreeNode) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = node.url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: node.url, to: dest)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    /// 開成目前視窗的一個新分頁（筆記用 note 視窗、LaTeX 專案用 latex 視窗）
    private func openInNewTab(_ node: TreeNode) {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        openWindow(id: node.isProject ? "latex" : "note", value: node.url)
        attachAsTab(excluding: before, attemptsLeft: 20)
    }

    /// 工具列「＋」／⌘T：開一個新的主視窗分頁。
    /// 系統的 newWindowForTab: 只有在這個視窗是前景主視窗時才會自己併成分頁，
    /// 否則會變成獨立視窗——所以一律等新視窗出現後自己併進來。
    private func openNewTab() {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: hostWindow)
        attachAsTab(excluding: before, attemptsLeft: 20)
    }

    /// 新視窗是非同步建立的，等它出現再併進目前視窗當分頁
    private func attachAsTab(excluding before: Set<ObjectIdentifier>, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let host = hostWindow else { return }
            if let new = NSApp.windows.first(where: {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0 !== host
            }) {
                // 系統已經自己併成分頁就不用再動
                if !(host.tabbedWindows ?? []).contains(where: { $0 === new }) {
                    host.addTabbedWindow(new, ordered: .above)
                }
                new.makeKeyAndOrderFront(nil)
            } else if attemptsLeft > 0 {
                attachAsTab(excluding: before, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// 側欄：清單（含底部番茄鐘／設定）＋右緣的拖曳把手。
    /// 從 body 拆出來——全部寫在一起編譯器型別推斷會超時。
    private var sidebarColumn: some View {
          HStack(spacing: 0) {
            List(selection: $tab) {
                ForEach(AppTab.allCases) { item in
                    if item == .notes && !noteTree.isEmpty && !sidebarCompact {
                        // 筆記列本身可摺疊，展開才顯示檔案樹
                        DisclosureGroup(isExpanded: $notesExpanded) {
                            OutlineGroup(noteTree, children: \.children) { node in
                                sidebarRow(node)
                            }
                        } label: {
                            Label(item.title, systemImage: item.icon)
                                .tag(item)
                        }
                    } else {
                        sidebarLabel(item.title, icon: item.icon)
                            .help(item.title)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            // 不蓋任何自訂背景 → 直接用 NavigationSplitView 內建的原生側欄材質。
            .scrollContentBackground(.hidden)
            // 番茄鐘與設定放在清單欄底部（不放整欄），右邊的把手才能從頂到底一整條
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !sidebarCompact { PomodoroMiniView() }
                    SettingsLink {
                        sidebarLabel("設定", icon: "gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }

            // 把手放在清單「外面」自己佔一條：疊在清單上的話，清單能捲動時右緣是捲軸，
            // 按下去會被捲軸接走。拖曳直接改底層分割視圖的寬度（見 SidebarSplitControl）。
            // 貼齊側欄邊界、從頂到底（藍線要跟邊界重合、一路延伸到底）。
            SidebarResizeHandle(width: $sidebarWidth, minW: Self.sidebarMin, maxW: Self.sidebarMax) {
                SidebarSplitControl.lock(in: hostWindow, width: $0,
                                         min: Self.sidebarMin, max: Self.sidebarMax)
            }
            .ignoresSafeArea()
          }
    }

    /// 收起側欄：先解除「不能收起」的鎖，再交給 NavigationSplitView 收
    private func collapseSidebar() {
        SidebarSplitControl.allowCollapse(in: hostWindow)
        columnVisibility = .detailOnly
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
            .inkSurface(.sidebar)
            .navigationSplitViewColumnWidth(min: Self.sidebarMin, ideal: sidebarWidth, max: Self.sidebarMax)
            // 移除系統自動加在右邊的側欄開關,改放一顆自己的在左上角(navigation 位置)。
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        // 不再自己包 withAnimation:讓 NavigationSplitView 用系統內建的
                        // 側欄開合動畫,比自訂 easeInOut 更順、開隱藏側欄時不會卡頓。
                        if columnVisibility == .detailOnly {
                            columnVisibility = .all
                        } else {
                            collapseSidebar()
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                    }
                    .help("顯示／隱藏側邊欄")
                }
            }
        } detail: {
            ZStack {
                AmbientBackground()
                switch tab ?? .home {
                case .home: HomeView()
                case .notes: NotesBrowserView()
                case .papers: PapersView()
                case .journal: JournalView()
                }
            }
            // 最右邊：開新分頁（跟分頁列右端系統的「＋」同一個動作——
            // 只開一個分頁時分頁列是藏起來的，平常就找不到那顆）。
            // 要掛在 detail 這欄：掛在側欄那欄的話會跑到側欄頂端。
            .toolbar {
                // 沒有這個空白，按鈕會緊貼在側欄開關旁邊（工具列項目由左往右排）
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    Button(action: openNewTab) {
                        Image(systemName: "plus")
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    .help("新分頁（⌘T）")
                }
            }
            .sheet(item: Bindable(pomodoro).completionPrompt) { prompt in
                PomodoroCompletionSheet(prompt: prompt)
                    .environment(pomodoro)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Self.collapseSidebarNotification)) { _ in
            collapseSidebar()
        }
        // 側欄平常鎖住「拖太窄就收起」（見 SidebarSplitControl）；
        // 收起中不鎖，否則按鈕收起後會被鎖回展開狀態
        .background(WindowReader { window in
            hostWindow = window
            if columnVisibility != .detailOnly {
                SidebarSplitControl.lock(in: window, width: sidebarWidth,
                                         min: Self.sidebarMin, max: Self.sidebarMax)
            }
        })
        // 從系統分隔線拖（邊界附近那幾 pt）時，把新寬度寫回來：窄版切換、記住寬度都靠它
        .onReceive(NotificationCenter.default.publisher(
            for: NSSplitView.didResizeSubviewsNotification)) { note in
            guard columnVisibility != .detailOnly,
                  let width = SidebarSplitControl.sidebarWidth(ifSidebarSplit: note.object,
                                                               in: hostWindow),
                  abs(width - sidebarWidth) > 0.5 else { return }
            sidebarWidth = min(Self.sidebarMax, max(Self.sidebarMin, width))
        }
        .preferredColorScheme(AppTheme(rawValue: themeRaw)?.forcedColorScheme
            ?? AppAppearance(rawValue: appearance)?.colorScheme)
        // 即時套用語言到日期/數字格式。
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent)
        // 語言改變時強制整棵重建，讓所有子畫面的字串即時重新解析。
        .id(language)
        // block 編輯器的 template 內含本地化字串且 WebView 常駐 → 語言換了要重載。
        // 先確保 LanguageManager 已套用新語言（不依賴 SettingsView 的觸發順序）。
        .onChange(of: language) {
            LanguageManager.apply(language == AppLanguage.system.rawValue ? nil : language)
            BlockEditorHost.shared.retry()
        }
        .background(WindowMinSizeSetter(minWidth: 700, minHeight: 560))
        .onAppear {
            eventStore.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            LibrarySync.shared.configure(rootURL: store.rootURL) // 開 app：先跟 iCloud 要手機的更新
            BlockEditorHost.shared.preload() // 預載日記編輯器，切分頁即時顯示
            reloadNoteTreeInBackground()
        }
        .onChange(of: store.rootURL) {
            eventStore.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            LibrarySync.shared.configure(rootURL: store.rootURL)
            reloadNoteTreeInBackground()
        }
        // 切回 app：手機可能改過東西 → 跟 iCloud 要最新版，各 store 自己重讀
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            LibrarySync.shared.syncNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rhLibraryDidChange)) { note in
            if LibrarySync.affectsNoteListing(note, notes: store.notesURL) {
                reloadNoteTreeInBackground()
            }
        }
        .onChange(of: store.items) { reloadNoteTreeInBackground() }
        .onChange(of: store.requestedTab) {
            if let requested = store.requestedTab {
                tab = requested
                store.requestedTab = nil
            }
        }
        .sheet(isPresented: Bindable(store).searchPresented) {
            SearchPaletteView()
        }
        // 系統 URL scheme（researchhub://…）：外部工具的入口。
        //   note?path=<相對 Notes/ 的路徑> → 開啟筆記
        //   project?path=<相對 Notes/ 的資料夾> → 開啟 LaTeX 專案
        //   journal?date=YYYY-MM-DD → 開啟該日日記（省略 = 今天）
        .onOpenURL { url in
            guard url.scheme == "researchhub" else { return }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            switch url.host {
            case "note":
                if let rel = comps?.queryItems?.first(where: { $0.name == "path" })?.value,
                   let fileURL = NoteLinkIndex.shared.url(forRelativePath: rel) {
                    store.openNote(fileURL)
                }
            case "project":
                // researchhub://project?path=<相對 Notes/ 的資料夾>
                if let rel = comps?.queryItems?.first(where: { $0.name == "path" })?.value,
                   let notes = store.notesURL {
                    store.openNote(notes.appendingPathComponent(rel, isDirectory: true))
                }
            case "journal":
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                let date = comps?.queryItems?
                    .first(where: { $0.name == "date" })?.value
                    .flatMap { f.date(from: $0) }
                store.pendingJournalDate = date ?? Calendar.current.startOfDay(for: .now)
                store.requestedTab = .journal
            default:
                break
            }
        }
        .alert("發生錯誤", isPresented: errorBinding) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }
}

/// 側欄右緣的拖曳把手：滑上去或正在拖時亮一條藍線，亮的地方就一定拖得動。
struct SidebarResizeHandle: View {
    @Binding var width: Double
    let minW: Double
    let maxW: Double
    /// 寬度變了：交給底層分割視圖套用
    let onResize: (Double) -> Void

    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            // 貼齊右緣＝側欄的邊界
            if hovering || startWidth != nil {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(.columnResize)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = startWidth ?? width
                    if startWidth == nil { startWidth = base }
                    let next = min(maxW, max(minW, base + value.translation.width))
                    width = next
                    onResize(next)
                }
                .onEnded { _ in startWidth = nil }
        )
    }
}

#endif
