import Foundation

/// 資料夾的資料契約版本（`.hub/contract-version`）：`.hub/*.json` 與日記標記語法的格式版本。
/// HubStore 開啟資料夾時寫入／比對；外部工具讀 `.hub/README.md` 得知格式（docs/ARCHITECTURE.md 第 2 節）。
/// 暫定：遇到比這版 app 新的契約只警告、照開（第 7 節未決事項）。
public nonisolated enum DataContract {
    /// 這版 app 寫出的契約版本
    public static let current = 1
    /// 這版 app 看得懂的區間
    public static let supported: ClosedRange<Int> = 1...1

    public static func parse(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 不相容時回一句給使用者看的說明；相容回 nil。
    public static func problem(with text: String, supported: ClosedRange<Int> = supported) -> String? {
        guard let v = parse(text) else { return "資料夾的 .hub/contract-version 格式不對（應該是一個整數）" }
        guard supported.contains(v) else {
            return "這個資料夾的資料契約是第 \(v) 版，這版 app 只認得 \(supported.lowerBound)–\(supported.upperBound) 版：請更新 app，否則新格式的欄位可能被忽略"
        }
        return nil
    }
}
