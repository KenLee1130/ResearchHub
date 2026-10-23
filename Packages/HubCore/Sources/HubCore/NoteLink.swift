import Foundation

/// 一筆「可被引用的筆記」。供 [[...]] 自動補全、預覽解析與插入挑選器共用。
/// 只含值型別，方便傳進非主執行緒隔離的 NotePreprocessor。
public struct NoteLink: Hashable, Sendable {
    public let url: URL
    /// 相對於 Notes/ 的路徑（含 .md）
    public let relativePath: String

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }

    /// 檔名（不含副檔名）
    public var name: String { url.deletingPathExtension().lastPathComponent }

    /// 顯示用：相對路徑去掉 .md，便於分辨不同資料夾下的同名筆記。
    public var displayPath: String {
        relativePath.lowercased().hasSuffix(".md")
            ? String(relativePath.dropLast(3))
            : relativePath
    }
}

/// 解析 `[[target]]` 指到哪一筆筆記（純函式，只看傳入的 links）。
public nonisolated enum NoteLinkResolver {
    /// 解析 `[[target]]` 的目標：先比對相對路徑／顯示路徑，再比對檔名（皆不分大小寫）。
    public static func resolve(_ target: String, in links: [NoteLink]) -> NoteLink? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let tl = t.lowercased()
        let tlMd = tl.hasSuffix(".md") ? tl : tl + ".md"
        if let e = links.first(where: {
            $0.relativePath.lowercased() == tlMd || $0.displayPath.lowercased() == tl
        }) { return e }
        if let e = links.first(where: { $0.name.lowercased() == tl }) { return e }
        return nil
    }
}
