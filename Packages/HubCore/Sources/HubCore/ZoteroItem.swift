import Foundation

// MARK: - Models（對應 Zotero API v3 的 JSON 格式）

public struct ZoteroItem: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    public let data: ItemData

    public init(key: String, data: ItemData) {
        self.key = key
        self.data = data
    }

    public var id: String { key }

    public struct ItemData: Codable, Hashable, Sendable {
        public var itemType: String
        public var title: String?
        public var creators: [Creator]?
        public var date: String?
        public var DOI: String?
        public var url: String?
        public var contentType: String?
        public var filename: String?
        public var tags: [Tag]?
        public var publicationTitle: String?
        public var abstractNote: String?

        public init(itemType: String, title: String? = nil, creators: [Creator]? = nil, date: String? = nil,
                    DOI: String? = nil, url: String? = nil, contentType: String? = nil, filename: String? = nil,
                    tags: [Tag]? = nil, publicationTitle: String? = nil, abstractNote: String? = nil) {
            self.itemType = itemType; self.title = title; self.creators = creators; self.date = date
            self.DOI = DOI; self.url = url; self.contentType = contentType; self.filename = filename
            self.tags = tags; self.publicationTitle = publicationTitle; self.abstractNote = abstractNote
        }
    }

    public struct Creator: Codable, Hashable, Sendable {
        public var name: String?
        public var firstName: String?
        public var lastName: String?

        public init(name: String? = nil, firstName: String? = nil, lastName: String? = nil) {
            self.name = name; self.firstName = firstName; self.lastName = lastName
        }

        public var display: String {
            if let name, !name.isEmpty { return name }
            return [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        }
    }

    public struct Tag: Codable, Hashable, Sendable {
        public var tag: String
        public init(tag: String) { self.tag = tag }
    }

    public var title: String { data.title ?? "（無標題）" }

    /// 直接拖進 Zotero、沒有書目資料的 PDF（最上層就是附件本身，例如掃描的書）。
    /// 論文頁要列出來讀，但它沒有作者、年份，不適合拿來 \cite。
    public var isStandalonePDF: Bool {
        data.itemType == "attachment"
            && (data.contentType == "application/pdf"
                || (data.filename?.lowercased().hasSuffix(".pdf") ?? false))
    }

    public var authors: String {
        (data.creators ?? []).map(\.display).joined(separator: ", ")
    }

    public var year: String {
        guard let date = data.date else { return "" }
        // 取最先出現的四位數年份
        if let match = date.range(of: #"\d{4}"#, options: .regularExpression) {
            return String(date[match])
        }
        return ""
    }
}
