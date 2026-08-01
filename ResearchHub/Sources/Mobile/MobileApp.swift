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
    @State private var showTaskManager = false
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var showDatePicker = false

    private let calendar = Calendar.current
    private var isToday: Bool { calendar.isDateInToday(selectedDate) }
    private var journalURL: URL? { store.journalURL(for: selectedDate) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dateNavigationBar

                    // Claude 觀察（.hub/claude/insights.json，Mac 端或 AI 更新後同步過來）
                    if isToday, let insights = generalTodos.insights, !insights.message.isEmpty {
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

                    // 當日事件
                    let todayEvents = eventStore.events(on: selectedDate)
                    if !todayEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(isToday ? "今日事件" : "當日事件",
                                  systemImage: "calendar.badge.clock")
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

                    // 當日日記：與 Mac 版同一套 block 編輯器（tiptap，離線 bundle）
                    VStack(alignment: .leading, spacing: 6) {
                        Label(isToday ? "今日日記" : "當日日記", systemImage: "book")
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
            .navigationTitle(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
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
            .sheet(isPresented: $showDatePicker) {
                DatePicker(
                    "選擇日期",
                    selection: Binding(
                        get: { selectedDate },
                        set: { date in
                            showDatePicker = false
                            switchTo(date)
                        }),
                    displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .presentationDetents([.medium])
            }
            .onReceive(NotificationCenter.default.publisher(for: .rhEditorCommand)) { note in
                if note.userInfo?["command"] as? String == "list" {
                    saveNow()   // 讓總覽能安全改今天的檔
                    showTaskManager = true
                }
            }
            .sheet(isPresented: $showTaskManager, onDismiss: load) {
                TaskManagerSheet()
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

    /// 日期導覽列：← 前一天｜點日期開月曆｜回今天｜後一天 →
    private var dateNavigationBar: some View {
        HStack(spacing: 12) {
            Button { shiftDay(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 32)
            }
            Spacer()
            Button { showDatePicker = true } label: {
                Label(selectedDate.formatted(.dateTime.month().day().weekday(.abbreviated)),
                      systemImage: "calendar")
                    .font(.callout.weight(.medium))
            }
            if !isToday {
                Button("今天") { switchTo(.now) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            Spacer()
            Button { shiftDay(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 32)
            }
        }
    }

    private func shiftDay(_ delta: Int) {
        guard let d = calendar.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        switchTo(d)
    }

    /// 換日：先把目前這天存好，再切日期重載（編輯器由 documentID 換檔）。
    private func switchTo(_ date: Date) {
        saveNow()
        selectedDate = calendar.startOfDay(for: date)
        load()
    }

    private func load() { load(retriesLeft: 5) }

    private func load(retriesLeft: Int) {
        // @due/@from/@every 播進當天 + @remind 排通知（冪等；要在讀檔之前；
        // seedTodos 內部只對今天以後的日期生效，翻舊日記不會被改動）
        store.seedTodos(
            for: selectedDate,
            generalTexts: generalTodos.todos.filter { !$0.done }.map(\.text))

        guard let url = journalURL else {
            journalText = ""
            loadedText = ""
            return
        }
        if let content = FileSystemStore.safeRead(url) {
            journalText = content
            loadedText = content
        } else if (try? url.checkResourceIsReachable()) == true, retriesLeft > 0 {
            // 檔案在 iCloud 還沒下載完（safeRead 已觸發下載）：稍後重試。
            // 別當成空檔——使用者一打字存檔會蓋掉雲端那份
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if journalText == loadedText { load(retriesLeft: retriesLeft - 1) }
            }
        } else {
            journalText = ""
            loadedText = ""
        }
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
