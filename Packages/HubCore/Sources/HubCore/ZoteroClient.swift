import Foundation

/// Zotero 7 本地 API（http://localhost:<port>/api/users/0）的純 URLSession client。
/// 沒有狀態、沒有快取；要觀察的狀態（items、isLoading、錯誤訊息）由 app 的 ZoteroStore 管。
public nonisolated struct ZoteroClient: Sendable {
    public static let defaultPort = 23119

    public let port: Int

    public init(port: Int = ZoteroClient.defaultPort) {
        self.port = port > 0 ? port : Self.defaultPort
    }

    public var base: URL { URL(string: "http://localhost:\(port)/api/users/0")! }

    /// 整個文獻庫的最上層項目（分頁抓完；以前只抓最近改過的 200 筆，舊文獻在 \cite 裡搜不到）。
    /// 回傳未過濾的原始清單，過濾用 `isLibraryEntry`。
    public func fetchTopItems(pageSize: Int = 200, maxPages: Int = 25) async throws -> [ZoteroItem] {
        var decoded: [ZoteroItem] = []
        for page in 0..<maxPages {
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
        return decoded
    }

    /// 論文頁要列的：書目項目，加上直接拖進 Zotero 的獨立 PDF；附件與筆記不列。
    public static func isLibraryEntry(_ item: ZoteroItem) -> Bool {
        (item.data.itemType != "attachment" && item.data.itemType != "note") || item.isStandalonePDF
    }

    /// 這筆文獻的 BibTeX（Zotero 自己的匯出，欄位最完整）。Zotero 沒開就回 nil。
    public func bibtex(for item: ZoteroItem) async -> String? {
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

    public struct Attachment: Sendable {
        public let key: String
        public let filename: String?
        public init(key: String, filename: String?) {
            self.key = key
            self.filename = filename
        }
    }

    /// 找出某筆文獻的 PDF 附件
    public func pdfAttachment(for item: ZoteroItem) async -> Attachment? {
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

    // MARK: - 全文

    /// Zotero 自己索引好的 PDF 全文（/items/<附件 key>/fulltext）
    public struct Fulltext: Sendable, Hashable {
        public let content: String
        public let indexedPages: Int
        public let totalPages: Int
        public init(content: String, indexedPages: Int, totalPages: Int) {
            self.content = content; self.indexedPages = indexedPages; self.totalPages = totalPages
        }
    }

    /// 這個附件的全文。Zotero 沒索引過（或沒開）就回 nil。
    public func fulltext(attachmentKey: String) async -> Fulltext? {
        let url = base.appendingPathComponent("items/\(attachmentKey)/fulltext")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.decodeFulltext(data)
    }

    public static func decodeFulltext(_ data: Data) -> Fulltext? {
        struct Raw: Decodable { var content: String; var indexedPages: Int?; var totalPages: Int? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return Fulltext(content: raw.content, indexedPages: raw.indexedPages ?? 0,
                        totalPages: raw.totalPages ?? 0)
    }

    /// 透過 HTTP 拿附件的檔案內容（本地 storage/ 讀不到時的備援）。
    public func fileData(attachmentKey: String) async -> Data? {
        let url = base.appendingPathComponent("items/\(attachmentKey)/file")
        if let (data, response) = try? await URLSession.shared.data(from: url),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           !data.isEmpty {
            return data
        }
        return nil
    }
}
