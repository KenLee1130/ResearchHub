#if os(iOS)
import SwiftUI
import HubEditor
import HubStore
import HubCore
import UIKit
import UniformTypeIdentifiers

/// iPhone 版入口：與 macOS 版共用全部 Models/Services（純檔案資料層），
/// 把資料夾放 iCloud Drive 即可跨裝置同步。定位是 companion：捕捉與瀏覽，不是全功能編輯。
@main
struct ResearchHubMobileApp: App {
    @State private var store = FileSystemStore(noteLinks: AppContainer.shared.noteLinks,
                                               librarySync: AppContainer.shared.librarySync)
    @State private var eventStore = EventStore(librarySync: AppContainer.shared.librarySync)
    @State private var generalTodos = GeneralTodoStore(librarySync: AppContainer.shared.librarySync)
    @State private var pomodoro = PomodoroModel(librarySync: AppContainer.shared.librarySync,
                                                readingGate: AppContainer.shared.readingGate,
                                                system: AppPomodoroSystem())

    init() {
        LanguageManager.activate()
        ReminderScheduler.install()   // @remind 推播由 app 排程（HubStore 不碰 UserNotifications）
        EditorLocalization.L = { L($0) }   // 套件裡的字串跟隨 app 的語言設定
        LanguageManager.apply(UserDefaults.standard.string(forKey: "settings.language"))
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(store)
                .environment(eventStore)
                .environment(generalTodos)
                .environment(pomodoro)
        }
    }
}

/// 分頁之間的導覽請求（行事曆「n 件待辦」→ 今天分頁看那一天；researchhub://journal?date= 也走這裡）。
/// 用獨立物件而不是借 store.pendingJournalDate：兩個 onChange 搶同一個欄位會互相吃掉。
@Observable
final class MobileNavigation {
    var tab: MobileTab = .today
    /// 今天分頁該切去看的日期；看完由它清掉
    var requestedDate: Date?

    func showDay(_ date: Date) {
        requestedDate = date
        tab = .today
    }
}

enum MobileTab: Hashable { case today, calendar, notes, pomodoro, settings }

struct MobileRootView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(EventStore.self) private var eventStore
    @Environment(GeneralTodoStore.self) private var generalTodos
    @Environment(PomodoroModel.self) private var pomodoro
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    private var gate = AppContainer.shared.readingGate
    @State private var gateRequest: GateRequest?
    @State private var nav = MobileNavigation()
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
                TabView(selection: Bindable(nav).tab) {
                    Tab("今天", systemImage: "sun.max", value: .today) {
                        MobileTodayView()
                    }
                    Tab("行事曆", systemImage: "calendar", value: .calendar) {
                        MobileCalendarView()
                    }
                    Tab("筆記", systemImage: "folder", value: .notes) {
                        MobileNotesView()
                    }
                    Tab("蕃茄鐘", systemImage: "timer", value: .pomodoro) {
                        MobilePomodoroView()
                    }
                    Tab("設定", systemImage: "gearshape", value: .settings) {
                        MobileSettingsView()
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .environment(nav)
                // researchhub://journal?date=… → 今天分頁看那一天
                .onChange(of: store.pendingJournalDate) {
                    if let date = store.pendingJournalDate {
                        store.pendingJournalDate = nil
                        nav.showDay(date)
                    }
                }
            }
        }
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent)
        .id(language)
        .onAppear {
            #if DEBUG
            // 模擬器／UI 測試用：`-HubRoot <path>` 直接指定根資料夾，免走檔案選擇器
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-HubRoot"),
               i + 1 < ProcessInfo.processInfo.arguments.count, store.rootURL == nil {
                store.setRoot(URL(fileURLWithPath: ProcessInfo.processInfo.arguments[i + 1], isDirectory: true))
            }
            #endif
            eventStore.configure(rootURL: store.rootURL)
            generalTodos.configure(rootURL: store.rootURL)
            pomodoro.configure(rootURL: store.rootURL)
            gate.configure(rootURL: store.rootURL)
            AppContainer.shared.librarySync.configure(rootURL: store.rootURL) // 開 app：先跟 iCloud 要 Mac 的更新
        }
        // 回到前景：Mac 可能改過東西 → 跟 iCloud 要最新版；進背景就停止監看
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                AppContainer.shared.librarySync.resume()
                AppContainer.shared.librarySync.syncNow()
            case .background:
                AppContainer.shared.librarySync.suspend()
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
            AppContainer.shared.librarySync.configure(rootURL: store.rootURL)
        }
    }
}

// MARK: - Onboarding：選 iCloud Drive 的資料夾

struct MobileOnboardingView: View {
    @Environment(FileSystemStore.self) private var store
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

// MARK: - 一般待辦

/// 一般待辦（不綁日期的收件匣），從「今天」分頁推進來。
struct MobileInboxList: View {
    @Environment(GeneralTodoStore.self) private var generalTodos
    @State private var newTodo = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("想到但還沒排時間的事…", text: $newTodo)
                        .submitLabel(.done)
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
                                .font(.title3)
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
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            AppContainer.shared.librarySync.syncNow()
            generalTodos.reload()
        }
    }

    private func add() {
        generalTodos.add(newTodo)
        newTodo = ""
    }
}

// MARK: - 設定

struct MobileSettingsView: View {
    @Environment(FileSystemStore.self) private var store
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
