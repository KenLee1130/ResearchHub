import Foundation
import ObjectiveC

private var associatedLanguageBundleKey: UInt8 = 0

/// 讓 `Text`／`LocalizedStringKey`／`NSLocalizedString` 能在**執行期即時切換語系**（不必重啟 App）。
///
/// 作法：把 `Bundle.main` 換成這個子類別，字串查找時轉送到指定語系的 `.lproj`。
/// 選「跟隨系統」時關聯路徑為 nil，行為與一般 `Bundle.main` 相同。
final class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let path = objc_getAssociatedObject(self, &associatedLanguageBundleKey) as? String,
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

enum LanguageManager {
    /// App 啟動時呼叫一次：把 `Bundle.main` 換成可切換語系的子類別。
    static func activate() {
        object_setClass(Bundle.main, LanguageBundle.self)
    }

    /// 設定目前語系；`nil` 或 "system" = 跟隨系統。
    static func apply(_ code: String?) {
        var path: String?
        if let code, code != "system",
           let p = Bundle.main.path(forResource: code, ofType: "lproj") {
            path = p
        }
        objc_setAssociatedObject(
            Bundle.main, &associatedLanguageBundleKey, path, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
