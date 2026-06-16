import SwiftUI

@main
struct ResearchHubApp: App {
    @StateObject private var store = FileSystemStore()
    @StateObject private var pomodoro = PomodoroModel()
    @StateObject private var eventStore = EventStore()

    init() {
        // 啟用即時語系切換，並套用上次選擇的語言。
        LanguageManager.activate()
        LanguageManager.apply(UserDefaults.standard.string(forKey: "settings.language"))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(pomodoro)
                .environmentObject(eventStore)
                .frame(minWidth: 700, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // 視窗最小尺寸改由 RootView 裡的 WindowMinSizeSetter 直接設 NSWindow.contentMinSize
        // 處理 —— 比 .windowResizability(.contentMinSize) 在 .hiddenTitleBar 下可靠。
        .commands {
            CommandGroup(after: .textEditing) {
                Button("快速搜尋…") {
                    store.searchPresented = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        // 把單一筆記彈到獨立視窗：方便同時編輯兩份筆記。
        // 以筆記 URL 為值，重複開同一份會聚焦既有視窗、不會重複開。
        WindowGroup(id: "note", for: URL.self) { $url in
            NoteWindowView(noteURL: url)
                .environmentObject(store)
                .environmentObject(pomodoro)
                .environmentObject(eventStore)
                .frame(minWidth: 460, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(pomodoro)
        }
    }
}
