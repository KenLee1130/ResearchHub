import SwiftUI

@main
struct ResearchHubApp: App {
    @StateObject private var store = FileSystemStore()
    @StateObject private var pomodoro = PomodoroModel()
    @StateObject private var eventStore = EventStore()

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

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(pomodoro)
        }
    }
}
