import Foundation

/// 四個分頁（macOS 側欄與 iOS 分頁都用得到）。rawValue 是中文，當字串目錄的 key；
/// 顯示用的 `title: LocalizedStringKey` 在 app 的 AppEnums.swift（SwiftUI 不進 HubCore）。
public enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case home = "首頁"
    case notes = "筆記"
    case papers = "論文"
    case journal = "日記"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .home: return "house"
        case .notes: return "folder"
        case .papers: return "books.vertical"
        case .journal: return "book"
        }
    }
}
