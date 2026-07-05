#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// 設定視窗（Cmd+, 或側欄齒輪開啟）。
struct SettingsView: View {
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("一般", systemImage: "gearshape") }
            PomodoroSettingsView()
                .tabItem { Label("蕃茄鐘", systemImage: "timer") }
        }
        .frame(width: 440)
        .environment(\.locale, AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent)
        // 語言改變時整個重建，讓兩個分頁的字串都即時更新。
        .id(language)
    }
}

// MARK: - 一般
// （AppAppearance / AppLanguage 移到 Models/AppEnums.swift，iOS 版共用）

struct GeneralSettingsView: View {
    @EnvironmentObject private var store: FileSystemStore
    @AppStorage("settings.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("settings.editorFontSize") private var editorFontSize = 14.0
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    @AppStorage("settings.userName") private var userName = ""
    @AppStorage(ZoteroStore.portKey) private var zoteroPort = ZoteroStore.defaultPort
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Picker("外觀", selection: $appearance) {
                ForEach(AppAppearance.allCases) { a in
                    Text(a.label).tag(a.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("語言", selection: $language) {
                ForEach(AppLanguage.allCases) { l in
                    Text(l.label).tag(l.rawValue)
                }
            }
            .onChange(of: language) { _, newValue in
                (AppLanguage(rawValue: newValue) ?? .system).apply()
            }

            Text("語言切換會即時套用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("你的名字") {
                TextField("", text: $userName)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 200)
            }

            LabeledContent("編輯器字級") {
                HStack {
                    Slider(value: $editorFontSize, in: 11...20, step: 1)
                        .frame(width: 180)
                    Text("\(Int(editorFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }

            LabeledContent("筆記根資料夾") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("變更…") { showFolderPicker = true }
                    Text(store.rootURL?.path ?? "尚未選擇")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }

            Section("整合") {
                LabeledContent("Zotero 本地 API 埠") {
                    TextField(
                        "", value: $zoteroPort,
                        format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                Text("預設 23119。需在 Zotero 設定 → 進階 啟用本地 API；改埠後重新整理論文分頁即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("外部工具可用 researchhub://note?path=… 或 researchhub://journal?date=YYYY-MM-DD 開啟本 app；資料接口說明在根資料夾的 .hub/README.md。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                store.setRoot(url)
            }
        }
    }
}

// MARK: - 蕃茄鐘

struct PomodoroSettingsView: View {
    @AppStorage(PomodoroModel.SettingsKey.workMinutes) private var work = 25
    @AppStorage(PomodoroModel.SettingsKey.shortBreakMinutes) private var shortBreak = 5
    @AppStorage(PomodoroModel.SettingsKey.longBreakMinutes) private var longBreak = 15
    @AppStorage(PomodoroModel.SettingsKey.cycleLength) private var cycle = 4

    // 完成小視窗各欄位是否必填
    @AppStorage(PomodoroModel.SettingsKey.requireContinueWorkMinutes) private var reqContinueWork = false
    @AppStorage(PomodoroModel.SettingsKey.requireLastWorkNote) private var reqLastWork = false
    @AppStorage(PomodoroModel.SettingsKey.requirePlannedNote) private var reqPlanned = false
    @AppStorage(PomodoroModel.SettingsKey.requireExtendBreakMinutes) private var reqExtendBreak = true

    var body: some View {
        Form {
            Section {
                Stepper("專注時長：\(work) 分鐘", value: $work, in: 5...90, step: 5)
                Stepper("短休息：\(shortBreak) 分鐘", value: $shortBreak, in: 1...30)
                Stepper("長休息：\(longBreak) 分鐘", value: $longBreak, in: 5...60, step: 5)
                Stepper("一輪顆數：\(cycle) 顆", value: $cycle, in: 1...12)
                Text("完成一輪 \(cycle) 顆後進入長休息。設定在目前的鐘尚未開始時立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("完成時的輸入欄位（必填／可留空）") {
                Toggle("工作結束 → 繼續工作：還要工作多久", isOn: $reqContinueWork)
                Toggle("工作結束 → 開始休息：上一輪做了什麼", isOn: $reqLastWork)
                Toggle("休息結束 → 繼續工作：預計做什麼", isOn: $reqPlanned)
                Toggle("休息結束 → 繼續休息：還要休息多久", isOn: $reqExtendBreak)
                Text("打開＝該欄位必填（沒填就不能按該按鈕）；關閉＝可留空。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
#endif
