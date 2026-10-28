import SwiftUI
import HubStore
import HubCore

// 跨平台共用的 app 層 enum（macOS 側欄與 iOS 分頁都用得到）。

// AppTab 本體在 HubCore（FileSystemStore 的導覽請求要用），這裡只補 SwiftUI 的顯示名稱
extension AppTab {
    /// 顯示名稱（會走本地化；rawValue 仍是中文，作為字串目錄的 key）。
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

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
