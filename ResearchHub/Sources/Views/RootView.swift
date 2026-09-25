#if os(macOS)
import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @EnvironmentObject private var generalTodos: GeneralTodoStore
    @AppStorage("settings.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.ambient.rawValue
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    @State private var tab: AppTab? = .home
    @State private var noteTree: [FileSystemStore.TreeNode] = []
    @State private var notesExpanded = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hostWindow: NSWindow?

    /// 把筆記／LaTeX 專案彈到小視窗時，主視窗的導覽欄就用不到了 → 順手收起來
    static let collapseSidebarNotification = Notification.Name("RootView.collapseSidebar")
    /// 側欄寬度，只由右緣的自訂把手改變（見 SidebarSplitControl）。
    /// 最窄可以縮到只剩圖示。
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 200
    private static let sidebarMin: Double = 68
    private static let sidebarMax: Double = 320
    /// 窄到放不下文字時只顯示圖示
    private var sidebarCompact: Bool { sidebarWidth < 130 }

    /// 收起側欄：先解除「不能收起」的鎖，再交給 NavigationSplitView 收
    private func collapseSidebar() {
        SidebarSplitControl.allowCollapse(in: hostWindow)
        columnVisibility = .detailOnly
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
          HStack(spacing: 0) {
            List(selection: $tab) {
                ForEach(AppTab.allCases) { item in
                    if item == .notes && !noteTree.isEmpty && !sidebarCompact {
                        // 筆記列本身可摺疊，展開才顯示檔案樹
                        DisclosureGroup(isExpanded: $notesExpanded) {
                            OutlineGroup(noteTree, children: \.children) { node in
                                HStack(spacing: 6) {
                                    Image(systemName: node.isFolder ? "folder" : "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(node.isFolder ? .secondary : .tertiary)
                                    Text(node.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if node.isFolder {
                                        store.reveal(directory: node.url)
                                    } else {
                                        store.openNote(node.url)
                                    }
                                }
                            }
                        } label: {
                            Label(item.title, systemImage: item.icon)
                                .tag(item)
                        }
                    } else {
                        Label(item.title, systemImage: item.icon)
                            .iconOnly(sidebarCompact)
                            .help(item.title)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            // 不蓋任何自訂背景 → 直接用 NavigationSplitView 內建的原生側欄材質。
            .scrollContentBackground(.hidden)

            // 把手放在清單「外面」自己佔一條：疊在清單上的話，清單能捲動時右緣是捲軸，
            // 按下去會被捲軸接走。拖曳直接改底層分割視圖的寬度（見 SidebarSplitControl）。
            SidebarResizeHandle(width: $sidebarWidth, minW: Self.sidebarMin, maxW: Self.sidebarMax) {
                SidebarSplitControl.lock(in: hostWindow, width: $0)
            }
            // 最右邊留白：系統分隔線會把邊緣幾 pt 的點擊攔走（雖然它已經被鎖住不能拖），
            // 把手放在攔截範圍外，才能保證「藍線亮的地方就拖得動」
            Color.clear.frame(width: 8)
          }
            .inkSurface(.sidebar)
            .navigationSplitViewColumnWidth(min: Self.sidebarMin, ideal: sidebarWidth, max: Self.sidebarMax)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if !sidebarCompact { PomodoroMiniView() }
                    SettingsLink {
                        Label("設定", systemImage: "gearshape")
                            .iconOnly(sidebarCompact)
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
            .sheet(item: $pomodoro.completionPrompt) { prompt in
                PomodoroCompletionSheet(prompt: prompt)
                    .environmentObject(pomodoro)
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
                SidebarSplitControl.lock(in: window, width: sidebarWidth)
            }
        })
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
            BlockEditorHost.shared.preload() // 預載日記編輯器，切分頁即時顯示
            noteTree = store.noteTree()
        }
        .onChange(of: store.rootURL) {
            eventStore.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            noteTree = store.noteTree()
        }
        .onChange(of: store.items) { noteTree = store.noteTree() }
        .onChange(of: store.requestedTab) {
            if let requested = store.requestedTab {
                tab = requested
                store.requestedTab = nil
            }
        }
        .sheet(isPresented: $store.searchPresented) {
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
        ZStack {
            Color.clear
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

extension View {
    /// 側欄窄的時候只顯示圖示
    @ViewBuilder
    func iconOnly(_ on: Bool) -> some View {
        if on { labelStyle(.iconOnly) } else { self }
    }
}
#endif
