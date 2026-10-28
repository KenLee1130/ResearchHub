#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// 全 app 搜尋面板（⌘F／⌘K）：日記、筆記、LaTeX 專案、論文、一般待辦一起搜，點結果跳過去。
/// 搜尋在背景跑（SearchEngine），打字停 0.15 秒才搜、新的一輪會取消舊的。
struct SearchPaletteView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(GeneralTodoStore.self) private var generalTodos
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SearchEngine.Hit] = []
    @State private var searching = false
    @State private var selection = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜尋日記、筆記、LaTeX、論文、待辦…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if searching {
                    ProgressView().controlSize(.small)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("關閉（Esc）")
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultList
            }
        }
        .frame(width: 640, height: 460)
        .onAppear { fieldFocused = true }
        // 論文清單只有開過論文頁才會載入：還沒載就在這裡載，載好後重搜一次
        .task {
            let zotero = AppContainer.shared.zotero
            guard zotero.items.isEmpty else { return }
            zotero.restoreZoteroDir()
            await zotero.refresh()
            if !query.trimmingCharacters(in: .whitespaces).isEmpty { scheduleSearch() }
        }
        .onChange(of: query) { scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
        .onExitCommand { dismiss() }
    }

    private var placeholder: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "輸入關鍵字（空白分開＝全部都要出現）"
        }
        return searching ? "搜尋中…" : "沒有結果"
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(SearchEngine.Kind.allCases, id: \.self) { kind in
                        let group = results.enumerated().filter { $0.element.kind == kind }
                        if !group.isEmpty {
                            Label("\(kind.title)（\(group.count)）", systemImage: kind.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                            ForEach(group, id: \.element.id) { index, hit in
                                Button { open(hit) } label: {
                                    row(hit, selected: index == selection)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: selection) { _, i in proxy.scrollTo(i, anchor: .center) }
        }
    }

    private func row(_ hit: SearchEngine.Hit, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if let snippet = hit.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
        )
    }

    // MARK: - 搜尋

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = []
            searching = false
            return
        }
        // 論文、待辦在主執行緒先抽成純資料，再丟到背景
        let papers = AppContainer.shared.zotero.items.map {
            SearchEngine.PaperEntry(
                key: $0.key, title: $0.data.title ?? "", authors: $0.authors, year: $0.year,
                venue: $0.data.publicationTitle ?? "", abstract: $0.data.abstractNote ?? "",
                tags: ($0.data.tags ?? []).map(\.tag))
        }
        let todos = generalTodos.todos.filter { !$0.done }.map(\.text)
        let root = store.rootURL
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)   // 打字停一下才搜
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                SearchEngine.search(q, scope: .all, root: root, papers: papers, todos: todos)
            }.value
            guard !Task.isCancelled else { return }
            // 跟畫面上的分組順序一致，上下鍵才不會亂跳
            results = hits.sorted { $0.kind.rawValue < $1.kind.rawValue }
            selection = 0
            searching = false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func openSelected() {
        guard results.indices.contains(selection) else { return }
        open(results[selection])
    }

    private func open(_ hit: SearchEngine.Hit) {
        dismiss()
        switch hit.target {
        case .journal(let date):
            store.pendingJournalDate = Calendar.current.startOfDay(for: date)
            store.requestedTab = .journal
        case .note(let url):
            store.openNote(url)
        case .latex(let project):
            store.openNote(project)
        case .paper(let key):
            store.requestedPaperKey = key
            store.requestedTab = .papers
        case .home:
            store.requestedTab = .home
        }
    }
}
#endif
