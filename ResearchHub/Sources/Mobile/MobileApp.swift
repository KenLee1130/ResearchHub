#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// iPhone 版入口：與 macOS 版共用全部 Models/Services（純檔案資料層），
/// 把資料夾放 iCloud Drive 即可跨裝置同步。定位是 companion：捕捉與瀏覽，不是全功能編輯。
@main
struct ResearchHubMobileApp: App {
    @StateObject private var store = FileSystemStore()
    @StateObject private var eventStore = EventStore()
    @StateObject private var generalTodos = GeneralTodoStore()
    @StateObject private var pomodoro = PomodoroModel()

    init() {
        LanguageManager.activate()
        LanguageManager.apply(UserDefaults.standard.string(forKey: "settings.language"))
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(store)
                .environmentObject(eventStore)
                .environmentObject(generalTodos)
                .environmentObject(pomodoro)
        }
    }
}

struct MobileRootView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var generalTodos: GeneralTodoStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    var body: some View {
        Group {
            if store.rootURL == nil {
                MobileOnboardingView()
            } else {
                TabView {
                    MobileTodayView()
                        .tabItem { Label("今天", systemImage: "sun.max") }
                    MobileNotesView()
                        .tabItem { Label("筆記", systemImage: "folder") }
                    MobilePomodoroView()
                        .tabItem { Label("蕃茄鐘", systemImage: "timer") }
                    MobileInboxView()
                        .tabItem { Label("一般待辦", systemImage: "tray.full") }
                    MobileSettingsView()
                        .tabItem { Label("設定", systemImage: "gearshape") }
                }
            }
        }
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent)
        .id(language)
        .onAppear {
            eventStore.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
        }
        .onChange(of: store.rootURL) {
            eventStore.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
        }
    }
}

// MARK: - Onboarding：選 iCloud Drive 的資料夾

struct MobileOnboardingView: View {
    @EnvironmentObject private var store: FileSystemStore
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("ResearchHub")
                .font(.largeTitle.weight(.semibold))
            Text("選擇你的資料夾（建議放在 iCloud 雲碟，與 Mac 版共用同一份）")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("選擇資料夾…") { showPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.setRoot(url)
            }
        }
    }
}

// MARK: - 今天：日記快速記錄 + 今日事件 + Claude 觀察

struct MobileTodayView: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var eventStore: EventStore
    @EnvironmentObject private var generalTodos: GeneralTodoStore
    @ObservedObject private var editorHost = BlockEditorHost.shared

    @State private var journalText = ""
    @State private var loadedText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var showPlanning = false
    @State private var dueItems: [FileSystemStore.TodoItem] = []

    private var journalURL: URL? { store.journalURL(for: .now) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Claude 觀察（.hub/claude/insights.json，Mac 端或 AI 更新後同步過來）
                    if let insights = generalTodos.insights, !insights.message.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Claude 觀察", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.purple)
                            Text(insights.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.purple.opacity(0.08)))
                    }

                    // 今日事件
                    let todayEvents = eventStore.events(on: .now)
                    if !todayEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("今日事件", systemImage: "calendar.badge.clock")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(todayEvents) { event in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(eventStore.tag(for: event.tagID)?.color ?? .gray)
                                        .frame(width: 4, height: 30)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(event.title).font(.callout)
                                        Group {
                                            if event.isAllDay {
                                                Text("全天")
                                            } else {
                                                Text(verbatim: "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.08)))
                    }

                    // 即將到期（@due 的項目，含已過期；打勾寫回原始檔；@from 未到的不列）
                    let dueGeneral = generalTodos.todos.filter { todo in
                        guard !todo.done else { return false }
                        let meta = TodoMeta.parse(todo.text)
                        guard meta.due != nil else { return false }
                        if let from = meta.from,
                           Calendar.current.startOfDay(for: from) > Calendar.current.startOfDay(for: .now) {
                            return false
                        }
                        return true
                    }
                    if !dueItems.isEmpty || !dueGeneral.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("即將到期", systemImage: "hourglass")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            ForEach(dueItems) { item in
                                mobileDueRow(text: item.meta.cleanText, due: item.meta.due!) {
                                    store.toggleTodo(item)
                                    refreshDue()
                                }
                            }
                            ForEach(dueGeneral) { todo in
                                let meta = TodoMeta.parse(todo.text)
                                mobileDueRow(text: meta.cleanText, due: meta.due!) {
                                    generalTodos.toggle(todo)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.orange.opacity(0.08)))
                    }

                    // 今日日記：與 Mac 版同一套 block 編輯器（tiptap，離線 bundle）
                    VStack(alignment: .leading, spacing: 6) {
                        Label("今日日記", systemImage: "book")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        BlockEditorView(
                            text: $journalText,
                            baseDir: journalURL?.deletingLastPathComponent(),
                            documentID: journalURL)
                            .frame(minHeight: 420)
                            .overlay {
                                if let error = editorHost.loadError {
                                    VStack(spacing: 8) {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                        Button("重試") { editorHost.retry() }
                                    }
                                    .padding(16)
                                } else if !editorHost.isReady {
                                    ProgressView()
                                }
                            }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.08)))
                }
                .padding(16)
            }
            .navigationTitle(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        saveNow() // 先存今天的，編輯器要讓給明天的日記
                        showPlanning = true
                    } label: {
                        Label("規劃明天", systemImage: "moon.stars")
                    }
                }
            }
            .sheet(isPresented: $showPlanning, onDismiss: load) {
                MobilePlanningSheet()
            }
            .onAppear(perform: load)
            .onDisappear(perform: saveNow)
            .onChange(of: journalText) { scheduleSave() }
            .refreshable {
                generalTodos.reload()
                load()
            }
        }
    }

    private func mobileDueRow(
        text: String, due: Date, onToggle: @escaping () -> Void
    ) -> some View {
        let overdue = Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: .now)
        return HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(due.formatted(.dateTime.month(.defaultDigits).day()))
                .font(.caption2.weight(.medium))
                .foregroundStyle(overdue ? .red : .orange)
        }
    }

    /// 今天要顯示的到期項目（未完成的都適用：未到期的提醒、過期的催辦）；
    /// 今天日記自己寫的已在編輯器裡、@from 還沒到的也不列。
    private func refreshDue() {
        let today = Calendar.current.startOfDay(for: .now)
        dueItems = store.dueTodos().filter { item in
            guard item.noteURL != journalURL else { return false }
            if let from = item.meta.from, Calendar.current.startOfDay(for: from) > today {
                return false
            }
            return true
        }
    }

    private func load() {
        // 先做每日搬移（把 @due 待辦搬進今天），再讀檔給編輯器
        let dueLines = generalTodos.todos
            .filter { !$0.done && TodoMeta.parse($0.text).due != nil }
            .map(\.text)
        let migrated = store.migrateDueTodos(generalDueLines: dueLines)
        for text in migrated { generalTodos.removeMigrated(text: text) }

        guard let url = journalURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            journalText = ""
            loadedText = ""
            return
        }
        journalText = content
        loadedText = content
        refreshDue()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard let url = journalURL, journalText != loadedText,
              !journalText.isEmpty || !loadedText.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? journalText.write(to: url, atomically: true, encoding: .utf8)) != nil {
            loadedText = journalText
        }
    }
}

// MARK: - 一般待辦

struct MobileInboxView: View {
    @EnvironmentObject private var generalTodos: GeneralTodoStore
    @State private var newTodo = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("想到但還沒排時間的事…", text: $newTodo)
                            .onSubmit(add)
                        Button(action: add) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newTodo.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    ForEach(generalTodos.todos.filter { !$0.done }) { todo in
                        HStack(spacing: 10) {
                            Button {
                                generalTodos.toggle(todo)
                            } label: {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            Text(TodoMeta.parse(todo.text).cleanText)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                generalTodos.moveToTrash(todo, reason: L("手動放棄"))
                            } label: {
                                Label("放棄", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    if !generalTodos.trash.isEmpty {
                        Text("垃圾桶（\(generalTodos.trash.count)）")
                    }
                }
            }
            .navigationTitle("一般待辦")
            .refreshable { generalTodos.reload() }
        }
    }

    private func add() {
        generalTodos.add(newTodo)
        newTodo = ""
    }
}

// MARK: - 設定

struct MobileSettingsView: View {
    @EnvironmentObject private var store: FileSystemStore
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("語言", selection: $language) {
                    ForEach(AppLanguage.allCases) { l in
                        Text(l.label).tag(l.rawValue)
                    }
                }
                .onChange(of: language) { _, newValue in
                    (AppLanguage(rawValue: newValue) ?? .system).apply()
                }

                LabeledContent("筆記根資料夾") {
                    Button("變更…") { showPicker = true }
                }
                Text(store.rootURL?.lastPathComponent ?? "尚未選擇")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("設定")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    store.setRoot(url)
                }
            }
        }
    }
}
#endif
