#if os(iOS)
import SwiftUI
import UIKit
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
    @ObservedObject private var gate = ReadingGateStore.shared
    @State private var gateRequest: GateRequest?
    @Environment(\.scenePhase) private var scenePhase

    /// 一次關卡請求（fullScreenCover(item:) 需要 Identifiable）
    struct GateRequest: Identifiable {
        let id = UUID()
        let app: GateApp?
    }

    /// researchhub://gate?app=instagram
    /// 不需要攔（沒在專注／還在寬限期）就立刻跳回原本的 app，畫面只會閃一下。
    private func handleGateURL(_ url: URL) {
        guard url.scheme == "researchhub", url.host == "gate" else { return }
        gate.configure(rootURL: store.rootURL)
        gate.reload()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = comps?.queryItems?.first { $0.name == "app" }?.value
        let target = scheme.flatMap { gate.app(forScheme: $0) }
        // 黑名單沒勾這個 app，或現在不必攔 → 直接放行
        let listed = scheme.map { gate.isBlacklisted($0) } ?? false
        if !listed || gate.shouldPassThrough() {
            if let u = target?.openURL { UIApplication.shared.open(u) }
            return
        }
        gateRequest = GateRequest(app: target)
    }

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
            gate.configure(rootURL: store.rootURL)
            LibrarySync.shared.configure(rootURL: store.rootURL) // 開 app：先跟 iCloud 要 Mac 的更新
        }
        // 回到前景：Mac 可能改過東西 → 跟 iCloud 要最新版；進背景就停止監看
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                LibrarySync.shared.resume()
                LibrarySync.shared.syncNow()
            case .background:
                LibrarySync.shared.suspend()
            default:
                break
            }
        }
        // 閱讀關卡：捷徑自動化在打開黑名單 app 時導到 researchhub://gate?app=<scheme>
        .onOpenURL { url in handleGateURL(url) }
        .fullScreenCover(item: $gateRequest) { req in
            ReadingGateView(target: req.app) { gateRequest = nil }
        }
        .onChange(of: store.rootURL) {
            eventStore.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
            gate.configure(rootURL: store.rootURL)
            LibrarySync.shared.configure(rootURL: store.rootURL)
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
    /// 監看當天日記被 Mac（經 iCloud）改動
    @State private var watcher: FileWatcher?
    /// 檔案在 iCloud 上但還沒下載：這時不能存檔，否則會用空內容蓋掉雲端那份
    @State private var awaitingDownload = false
    @Environment(\.scenePhase) private var scenePhase

    private let calendar = Calendar.current
    private var isToday: Bool { calendar.isDateInToday(selectedDate) }
    private var journalURL: URL? { store.journalURL(for: selectedDate) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    dateNavigationBar
                    LibrarySyncBanner()

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
                                } else if awaitingDownload {
                                    VStack(spacing: 8) {
                                        ProgressView()
                                        Text("正在從 iCloud 下載…")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(16)
                                    .background(.regularMaterial,
                                                in: RoundedRectangle(cornerRadius: 12))
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
            .onDisappear {
                saveNow()
                watcher?.stop()
            }
            .onChange(of: journalText) { scheduleSave() }
            .onChange(of: scenePhase) { _, phase in
                // 從背景回來：Mac 可能改過今天的日記 → 請 iCloud 抓最新版，沒有未存修改就重讀
                if phase == .active {
                    watcher?.requestLatest()
                    reloadIfClean()
                } else if phase == .background {
                    saveNow()
                }
            }
            .refreshable {
                LibrarySync.shared.syncNow()
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

    private func load() {
        // @due/@from/@every 播進當天 + @remind 排通知（冪等；要在讀檔之前；
        // seedTodos 內部只對今天以後的日期生效，翻舊日記不會被改動）
        store.seedTodos(
            for: selectedDate,
            generalTexts: generalTodos.todos.filter { !$0.done }.map(\.text))

        watcher?.stop()
        guard let url = journalURL else {
            watcher = nil
            journalText = ""
            loadedText = ""
            awaitingDownload = false
            return
        }
        let w = FileWatcher(url: url) { reloadIfClean() }
        watcher = w
        if let content = FileSystemStore.safeRead(url) {
            journalText = content
            loadedText = content
            awaitingDownload = false
            w.requestLatest()           // 本機這份可能是舊的：背景跟 iCloud 要最新版
        } else if (try? url.checkResourceIsReachable()) == true {
            // 在 iCloud 上但還沒下載：顯示下載中，下載完 watcher 會通知 → reloadIfClean。
            // 以前這裡重試 5 次後就當成空檔，使用者一打字就把雲端那份蓋掉了。
            awaitingDownload = true
            w.requestLatest()
        } else {
            journalText = ""
            loadedText = ""
            awaitingDownload = false
        }
    }

    /// 檔案被外部改動（Mac 經 iCloud 同步進來）時重讀；本機有未存修改就以本機為準。
    private func reloadIfClean() {
        guard journalText == loadedText, let w = watcher else { return }
        w.read { content in
            guard let content, w === watcher else { return }  // 讀檔期間換了日期
            guard journalText == loadedText else { return }   // 讀檔期間又打字了
            awaitingDownload = false
            if content != journalText {
                journalText = content
                loadedText = content
            }
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
        guard !awaitingDownload, journalText != loadedText,
              !journalText.isEmpty || !loadedText.isEmpty else { return }
        let snapshot = journalText
        let w = watcher
        w?.write(snapshot) { ok in
            // 換日時同一個畫面會換檔：回呼晚到就別把前一天的狀態套到新的一天
            if ok, w === watcher { loadedText = snapshot }
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
            .refreshable {
                LibrarySync.shared.syncNow()
                generalTodos.reload()
            }
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

                Section {
                    NavigationLink {
                        ReadingGateSettingsView()
                    } label: {
                        Label("閱讀關卡", systemImage: "lock.doc")
                    }
                } footer: {
                    Text("專注時打開 IG／YouTube 等 app，先讀一篇 paper 的 abstract 並答對問題才放行。")
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
