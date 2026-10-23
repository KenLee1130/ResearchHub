import Foundation
import Observation
import Combine
import HubCore

// MARK: - Store（Zotero 7 本地 API：localhost:23119）

@MainActor
@Observable
public final class ZoteroStore {
    /// 全 app 共用的實例：論文分頁與筆記引用（\cite）都讀同一份快取。
    public static let shared = ZoteroStore()

    public private(set) var items: [ZoteroItem] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    public static let portKey = "settings.zoteroPort"
    public static let defaultPort = ZoteroClient.defaultPort

    /// Zotero 7 本地 API；port 可在設定調整（預設 23119）。請求本體在 HubCore 的 ZoteroClient。
    private var client: ZoteroClient {
        ZoteroClient(port: UserDefaults.standard.integer(forKey: Self.portKey))
    }

    @ObservationIgnored private var lastRefreshed: Date?

    /// 上次抓超過 maxAge 秒就重抓一次；有重抓且內容變了回 true。
    /// \cite 補全每次跳出來都會呼叫：剛在 Zotero 加的文獻幾秒內就搜得到，
    /// 連打時又不會每個按鍵都去問 Zotero。
    @discardableResult
    public func refreshIfStale(maxAge: TimeInterval = 10) async -> Bool {
        if isLoading { return false }
        if let last = lastRefreshed, Date().timeIntervalSince(last) < maxAge { return false }
        let before = items.map(\.key)
        await refresh()
        return items.map(\.key) != before
    }

    public func refresh() async {
        lastRefreshed = Date()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let decoded = try await client.fetchTopItems()
            let fresh = decoded.filter(ZoteroClient.isLibraryEntry)
            if fresh != items { items = fresh }
        } catch {
            errorMessage = "無法連線 Zotero。請確認 Zotero 已開啟，"
                + "且在 Zotero 設定 → 進階 中啟用了本地 API。"
        }
    }

    // MARK: - BibTeX

    /// 這筆文獻的 BibTeX（Zotero 自己的匯出，欄位最完整）。Zotero 沒開就回 nil。
    public func bibtex(for item: ZoteroItem) async -> String? {
        await client.bibtex(for: item)
    }

    // MARK: - PDF 附件

    public typealias Attachment = ZoteroClient.Attachment

    /// 找出某筆文獻的 PDF 附件
    public func pdfAttachment(for item: ZoteroItem) async -> Attachment? {
        await client.pdfAttachment(for: item)
    }

    /// 取得 PDF：優先讀本地 Zotero/storage（需一次性授權資料夾），HTTP /file 當備援。
    /// 回傳 fileURL 供註記寫回（HTTP 來源無法寫回）。
    public func pdfData(attachment: Attachment) async -> (data: Data, fileURL: URL?)? {
        if let dir = zoteroDir {
            let folder = dir.appendingPathComponent("storage/\(attachment.key)", isDirectory: true)
            if let filename = attachment.filename {
                let file = folder.appendingPathComponent(filename)
                if let data = try? Data(contentsOf: file) { return (data, file) }
            }
            // filename 不準時掃資料夾內第一個 pdf
            if let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil),
               let pdf = files.first(where: { $0.pathExtension.lowercased() == "pdf" }),
               let data = try? Data(contentsOf: pdf) {
                return (data, pdf)
            }
        }
        // HTTP 備援
        if let data = await client.fileData(attachmentKey: attachment.key) { return (data, nil) }
        return nil
    }

    // MARK: - Zotero 資料夾授權（讀取 storage/ 裡的 PDF）

    private static let dirBookmarkKey = "zotero.dirBookmark"
    public private(set) var hasZoteroDir = false
    private var zoteroDir: URL?

    // Zotero storage/ 授權只在 macOS 有意義（手機連不到桌機的 Zotero 資料夾）。
    public func restoreZoteroDir() {
        #if os(macOS)
        guard zoteroDir == nil,
              let data = UserDefaults.standard.data(forKey: Self.dirBookmarkKey)
        else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
            _ = url.startAccessingSecurityScopedResource()
            zoteroDir = url
            hasZoteroDir = true
        }
        #endif
    }

    public func setZoteroDir(_ url: URL) {
        #if os(macOS)
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.dirBookmarkKey)
        }
        zoteroDir = url
        hasZoteroDir = true
        #endif
    }
}
