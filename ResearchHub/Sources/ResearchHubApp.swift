#if os(macOS)
import SwiftUI
import HubStore
import HubCore

@main
struct ResearchHubApp: App {
    @State private var store = FileSystemStore(noteLinks: AppContainer.shared.noteLinks,
                                               librarySync: AppContainer.shared.librarySync)
    @State private var pomodoro = PomodoroModel()
    @State private var eventStore = EventStore()
    @State private var generalTodos = GeneralTodoStore()

    init() {
        // 啟用即時語系切換，並套用上次選擇的語言。
        LanguageManager.activate()
        ReminderScheduler.install()   // @remind 推播由 app 排程（HubStore 不碰 UserNotifications）
        LanguageManager.apply(UserDefaults.standard.string(forKey: "settings.language"))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(pomodoro)
                .environment(eventStore)
                .environment(generalTodos)
                .frame(minWidth: 700, minHeight: 560)
                // researchhub:// 網址交給已經開著的主視窗處理。不設的話 SwiftUI 每收到一個網址
                // 就開一個新視窗（捷徑、深連結、Claude 的連結每點一次多一個視窗）。
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // 視窗最小尺寸改由 RootView 裡的 WindowMinSizeSetter 直接設 NSWindow.contentMinSize
        // 處理 —— 比 .windowResizability(.contentMinSize) 在 .hiddenTitleBar 下可靠。
        // 選單與快捷鍵：讀 key window 的路由，頁面決定接不接（見 CommandRouting.swift）
        .commands { AppCommands() }

        // 把單一筆記彈到獨立視窗：方便同時編輯兩份筆記。
        // 以筆記 URL 為值，重複開同一份會聚焦既有視窗、不會重複開。
        WindowGroup(id: "note", for: URL.self) { $url in
            NoteWindowView(noteURL: url)
                .environment(store)
                .environment(pomodoro)
                .environment(eventStore)
                .environment(generalTodos)
                .frame(minWidth: 460, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .handlesExternalEvents(matching: [])   // 網址不會開出這種視窗

        // LaTeX 專案也可以彈到獨立視窗（跟筆記一樣，以專案資料夾 URL 為值）
        WindowGroup(id: "latex", for: URL.self) { $url in
            LatexProjectWindowView(projectURL: url)
                .environment(store)
                .environment(pomodoro)
                .environment(eventStore)
                .environment(generalTodos)
                .frame(minWidth: 640, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .handlesExternalEvents(matching: [])   // 網址不會開出這種視窗

        Settings {
            SettingsView()
                .environment(store)
                .environment(pomodoro)
        }
    }
}
#endif
