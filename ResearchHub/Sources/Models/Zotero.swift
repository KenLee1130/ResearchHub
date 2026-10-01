import SwiftUI
import Observation
import Combine

// MARK: - Models（對應 Zotero API v3 的 JSON 格式）

struct ZoteroItem: Codable, Identifiable, Hashable {
    let key: String
    let data: ItemData

    var id: String { key }

    struct ItemData: Codable, Hashable {
        var itemType: String
        var title: String?
        var creators: [Creator]?
        var date: String?
        var DOI: String?
        var url: String?
        var contentType: String?
        var filename: String?
        var tags: [Tag]?
        var publicationTitle: String?
        var abstractNote: String?
    }

    struct Creator: Codable, Hashable {
        var name: String?
        var firstName: String?
        var lastName: String?

        var display: String {
            if let name, !name.isEmpty { return name }
            return [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        }
    }

    struct Tag: Codable, Hashable {
        var tag: String
    }

    var title: String { data.title ?? "（無標題）" }

    /// 直接拖進 Zotero、沒有書目資料的 PDF（最上層就是附件本身，例如掃描的書）。
    /// 論文頁要列出來讀，但它沒有作者、年份，不適合拿來 \cite。
    var isStandalonePDF: Bool {
        data.itemType == "attachment"
            && (data.contentType == "application/pdf"
                || (data.filename?.lowercased().hasSuffix(".pdf") ?? false))
    }

    var authors: String {
        (data.creators ?? []).map(\.display).joined(separator: ", ")
    }

    var year: String {
        guard let date = data.date else { return "" }
        // 取最先出現的四位數年份
        if let match = date.range(of: #"\d{4}"#, options: .regularExpression) {
            return String(date[match])
        }
        return ""
    }
}

// MARK: - Store（Zotero 7 本地 API：localhost:23119）

@MainActor
@Observable
final class ZoteroStore {
    /// 全 app 共用的實例：論文分頁與筆記引用（\cite）都讀同一份快取。
    static let shared = ZoteroStore()

    private(set) var items: [ZoteroItem] = []
    private(set) var isLoading = false
    var errorMessage: String?

    static let portKey = "settings.zoteroPort"
    static let defaultPort = 23119

    /// Zotero 7 本地 API 端點；port 可在設定調整（預設 23119）。
    private var base: URL {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        let port = stored > 0 ? stored : Self.defaultPort
        return URL(string: "http://localhost:\(port)/api/users/0")!
    }

    @ObservationIgnored private var lastRefreshed: Date?

    /// 上次抓超過 maxAge 秒就重抓一次；有重抓且內容變了回 true。
    /// \cite 補全每次跳出來都會呼叫：剛在 Zotero 加的文獻幾秒內就搜得到，
    /// 連打時又不會每個按鍵都去問 Zotero。
    @discardableResult
    func refreshIfStale(maxAge: TimeInterval = 10) async -> Bool {
        if isLoading { return false }
        if let last = lastRefreshed, Date().timeIntervalSince(last) < maxAge { return false }
        let before = items.map(\.key)
        await refresh()
        return items.map(\.key) != before
    }

    func refresh() async {
        lastRefreshed = Date()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // 整個文獻庫都抓（分頁）：以前只抓最近改過的 200 筆，舊文獻在 \cite 裡搜不到
            var decoded: [ZoteroItem] = []
            let pageSize = 200
            for page in 0..<25 {
                var components = URLComponents(
                    url: base.appendingPathComponent("items/top"),
                    resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    URLQueryItem(name: "format", value: "json"),
                    URLQueryItem(name: "limit", value: String(pageSize)),
                    URLQueryItem(name: "start", value: String(page * pageSize)),
                    URLQueryItem(name: "sort", value: "dateModified")
                ]
                let (data, _) = try await URLSession.shared.data(from: components.url!)
                let batch = try JSONDecoder().decode([ZoteroItem].self, from: data)
                decoded += batch
                if batch.count < pageSize { break }
            }
            let fresh = decoded.filter {
                ($0.data.itemType != "attachment" && $0.data.itemType != "note") || $0.isStandalonePDF
            }
            if fresh != items { items = fresh }
        } catch {
            errorMessage = "無法連線 Zotero。請確認 Zotero 已開啟，"
                + "且在 Zotero 設定 → 進階 中啟用了本地 API。"
        }
    }

    // MARK: - BibTeX

    /// 這筆文獻的 BibTeX（Zotero 自己的匯出，欄位最完整）。Zotero 沒開就回 nil。
    func bibtex(for item: ZoteroItem) async -> String? {
        var components = URLComponents(
            url: base.appendingPathComponent("items/\(item.key)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "bibtex")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 4
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              text.contains("@") else { return nil }
        return text
    }

    // MARK: - PDF 附件

    struct Attachment {
        let key: String
        let filename: String?
    }

    /// 找出某筆文獻的 PDF 附件
    func pdfAttachment(for item: ZoteroItem) async -> Attachment? {
        // 獨立的 PDF：PDF 就是它自己，沒有子項目
        if item.isStandalonePDF { return Attachment(key: item.key, filename: item.data.filename) }
        let url = base.appendingPathComponent("items/\(item.key)/children")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let children = try? JSONDecoder().decode([ZoteroItem].self, from: data)
        else { return nil }
        let pdf = children.first {
            $0.data.itemType == "attachment" && (
                $0.data.contentType == "application/pdf"
                || ($0.data.filename?.lowercased().hasSuffix(".pdf") ?? false)
            )
        }
        guard let pdf else { return nil }
        return Attachment(key: pdf.key, filename: pdf.data.filename)
    }

    /// 取得 PDF：優先讀本地 Zotero/storage（需一次性授權資料夾），HTTP /file 當備援。
    /// 回傳 fileURL 供註記寫回（HTTP 來源無法寫回）。
    func pdfData(attachment: Attachment) async -> (data: Data, fileURL: URL?)? {
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
        let url = base.appendingPathComponent("items/\(attachment.key)/file")
        if let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           !data.isEmpty {
            return (data, nil)
        }
        return nil
    }

    // MARK: - Zotero 資料夾授權（讀取 storage/ 裡的 PDF）

    private static let dirBookmarkKey = "zotero.dirBookmark"
    private(set) var hasZoteroDir = false
    private var zoteroDir: URL?

    // Zotero storage/ 授權只在 macOS 有意義（手機連不到桌機的 Zotero 資料夾）。
    func restoreZoteroDir() {
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

    func setZoteroDir(_ url: URL) {
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
