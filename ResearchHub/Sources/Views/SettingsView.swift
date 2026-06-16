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

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "跟隨系統"
        case .light: return "淺色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 介面語言。寫進 UserDefaults 的 AppleLanguages，下次啟動套用；
/// 同時提供 Locale 供日期/數字格式即時切換。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHant = "zh-Hant"
    case en
    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: return "跟隨系統"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }

    /// 要寫進 AppleLanguages 的語言碼；system → nil（清掉設定 = 跟隨系統）。
    var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .zhHant: return ["zh-Hant"]
        case .en: return ["en"]
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .zhHant: return Locale(identifier: "zh-Hant")
        case .en: return Locale(identifier: "en")
        }
    }

    /// 套用語言：即時切換介面字串（LanguageManager），並寫入 AppleLanguages 以利下次啟動一致。
    func apply() {
        LanguageManager.apply(self == .system ? nil : rawValue)
        if let codes = appleLanguages {
            UserDefaults.standard.set(codes, forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var store: FileSystemStore
    @AppStorage("settings.appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("settings.editorFontSize") private var editorFontSize = 14.0
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    @AppStorage("settings.userName") private var userName = ""
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
