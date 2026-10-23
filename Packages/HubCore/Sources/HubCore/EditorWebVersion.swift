import Foundation

/// 網頁編輯器（EditorWeb bundle）的版本契約：bundle 帶 `version.json`，app 載入前比對支援區間，
/// 不相容就明確報錯而不是渲染成一片空白（docs/ARCHITECTURE.md 第 2 節）。
public nonisolated enum EditorWebVersion {
    /// 這版 app 看得懂的 editor 版本區間（JS ↔ Swift 的訊息格式改了就往上加）
    public static let supported: ClosedRange<Int> = 1...1

    /// `{"editor": 1}` → 1；格式不對回 nil
    public static func parse(_ data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["editor"] as? Int else { return nil }
        return v
    }

    /// 不相容時回一句給使用者看的說明；相容回 nil。
    public static func problem(with data: Data?, supported: ClosedRange<Int> = supported) -> String? {
        guard let data else { return "找不到編輯器的 version.json（EditorWeb bundle 不完整）" }
        guard let v = parse(data) else { return "編輯器的 version.json 格式不對" }
        guard supported.contains(v) else {
            return "編輯器版本 \(v) 不在這版 app 支援的範圍（\(supported.lowerBound)–\(supported.upperBound)），請重新安裝"
        }
        return nil
    }
}
