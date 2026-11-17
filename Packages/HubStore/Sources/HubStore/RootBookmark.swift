import Foundation

/// 根資料夾的書籤：存進 UserDefaults 的那筆 `Data` 怎麼製作、怎麼還原。
///
/// 只做分類，不碰 UserDefaults 也不改 store 狀態，`FileSystemStore.restoreRoot` 負責套用。
/// 這樣三種結果（有效／失效但可用／真的找不到）可以直接單元測試，
/// 不必在測試裡偽造 iOS 的 stale 書籤。
public enum RootBookmark {
    /// 還原的結果。
    public enum Outcome: Equatable {
        /// 書籤有效，直接用這個 URL。
        case ready(URL)
        /// 解析得出 URL，但系統標成 stale。iOS 對 iCloud 雲碟資料夾很常這樣
        /// （系統更新、iCloud 重新同步、app 被「卸載」釋放空間之後）；
        /// URL 本身仍然有效，照用，並用新書籤蓋掉舊的。
        case stale(URL)
        /// 連 URL 都解不出來（資料夾被刪、搬走，或書籤資料壞了）：要使用者重選。
        case lost(reason: String)
    }

    /// 書籤的解析與重製。抽成可注入的介面，測試可以餵假的 stale／失敗結果。
    public struct Resolver: Sendable {
        public var resolve: @Sendable (Data) throws -> (url: URL, stale: Bool)
        public var mint: @Sendable (URL) throws -> Data

        public init(resolve: @escaping @Sendable (Data) throws -> (url: URL, stale: Bool),
                    mint: @escaping @Sendable (URL) throws -> Data) {
            self.resolve = resolve
            self.mint = mint
        }

        /// 真的走 Foundation。security-scoped 選項是 macOS 專屬；
        /// iOS 用預設選項（文件挑選器給的 URL 同樣要 startAccessingSecurityScopedResource）。
        public static let system = Resolver(
            resolve: { data in
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: resolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                return (url, stale)
            },
            mint: { url in
                try url.bookmarkData(
                    options: creationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
            })

        #if os(macOS)
        private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
        private static let resolutionOptions: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        private static let creationOptions: URL.BookmarkCreationOptions = []
        private static let resolutionOptions: URL.BookmarkResolutionOptions = []
        #endif
    }

    /// 把一筆書籤資料分類成三種結果之一。
    public static func classify(_ data: Data, using resolver: Resolver = .system) -> Outcome {
        do {
            let (url, stale) = try resolver.resolve(data)
            return stale ? .stale(url) : .ready(url)
        } catch {
            return .lost(reason: error.localizedDescription)
        }
    }
}
