import SwiftUI
import AppKit

enum AppTab: String, CaseIterable, Identifiable {
    case home = "首頁"
    case notes = "筆記"
    case papers = "論文"
    case journal = "日記"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house"
        case .notes: return "folder"
        case .papers: return "books.vertical"
        case .journal: return "book"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @AppStorage("settings.appearance") private var appearance = AppAppearance.system.rawValue
    @State private var tab: AppTab? = .home
    @State private var noteTree: [FileSystemStore.TreeNode] = []
    @State private var notesExpanded = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // 側欄寬度完全由這個 state 控制(夾在 170...260)。給固定值 → 系統的分隔線不可拖,
    // 改用右緣自訂把手調整,確保最大鎖得住、最小停得住、永不自動收合。
    @State private var sidebarWidth: CGFloat = 200

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $tab) {
                ForEach(AppTab.allCases) { item in
                    if item == .notes && !noteTree.isEmpty {
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
                            Label(item.rawValue, systemImage: item.icon)
                                .tag(item)
                        }
                    } else {
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            // 不蓋任何自訂背景 → 直接用 NavigationSplitView 內建的原生側欄材質。
            .scrollContentBackground(.hidden)
            // 右緣自訂拖曳把手:更新 sidebarWidth,夾在 170...260。
            // 因為欄寬給的是「單一固定值」,系統的分隔線不能拖,所以拖曳完全走這個把手,
            // 永遠不會因為拖太窄而自動收合(要隱藏請按左上角按鈕)。
            .overlay(alignment: .trailing) {
                SidebarResizeHandle(width: $sidebarWidth, minW: 170, maxW: 260)
            }
            .navigationSplitViewColumnWidth(sidebarWidth)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    PomodoroMiniView()
                    SettingsLink {
                        Label("設定", systemImage: "gearshape")
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
                        columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
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
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
        .background(WindowMinSizeSetter(minWidth: 700, minHeight: 560))
        .onAppear {
            eventStore.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
            BlockEditorHost.shared.preload() // 預載日記編輯器，切分頁即時顯示
            noteTree = store.noteTree()
        }
        .onChange(of: store.rootURL) {
            eventStore.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
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

/// 側欄右緣的拖曳把手:一條透明的窄條,拖它即可調整側欄寬度,夾在 minW...maxW。
/// 用全域座標算位移 → 側欄變寬時把手跟著移動也不會抖動;到上下限就停,絕不收合。
struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minW: CGFloat
    let maxW: CGFloat

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                // 滑到把手上時顯示左右拉伸游標,離開還原。
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = width }
                        let base = startWidth ?? width
                        width = min(maxW, max(minW, base + value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}
