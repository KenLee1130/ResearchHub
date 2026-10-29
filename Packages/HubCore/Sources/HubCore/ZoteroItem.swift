import Foundation

// MARK: - Models（對應 Zotero API v3 的 JSON 格式）

public struct ZoteroItem: Codable, Identifiable, Hashable, Sendable {
    public let key: String
    /// 文獻庫版本號（有同步的文獻庫才會增加；沒同步的一律 0）
    public var version: Int?
    public let data: ItemData
    /// API 附的連結；`attachment` 是「唯一的 PDF 附件」捷徑，有它就不用再抓 children
    public var links: Links?

    public init(key: String, data: ItemData, version: Int? = nil, links: Links? = nil) {
        self.key = key
        self.data = data
        self.version = version
        self.links = links
    }

    public struct Links: Codable, Hashable, Sendable {
        public var attachment: AttachmentLink?
        public init(attachment: AttachmentLink? = nil) { self.attachment = attachment }
    }

    public struct AttachmentLink: Codable, Hashable, Sendable {
        public var href: String
        public var attachmentType: String?
        public init(href: String, attachmentType: String? = nil) {
            self.href = href; self.attachmentType = attachmentType
        }
        /// href 最後一段就是附件的 key（…/items/SIRHCPFE）
        public var key: String { href.split(separator: "/").last.map(String.init) ?? "" }
    }

    /// 「這筆有沒有改過」的戳記：全文索引用它判斷快取要不要重抓。
    /// 優先用 dateModified（沒同步的文獻庫 version 永遠是 0，不能當依據）。
    public var changeStamp: String {
        if let d = data.dateModified, !d.isEmpty { return d }
        return "v\(version ?? 0)"
    }

    /// PDF 附件的 key，不用再問 API：獨立 PDF 就是自己；有書目資料的看 links.attachment。
    /// 有多個附件時 Zotero 不給 attachment 連結，這時回 nil（要用 `ZoteroClient.pdfAttachment`）。
    public var pdfAttachmentKey: String? {
        if isStandalonePDF { return key }
        guard let link = links?.attachment, link.attachmentType == "application/pdf",
              !link.key.isEmpty else { return nil }
        return link.key
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
        /// 項目最後修改時間（ISO8601）
        public var dateModified: String?

        public init(itemType: String, title: String? = nil, creators: [Creator]? = nil, date: String? = nil,
                    DOI: String? = nil, url: String? = nil, contentType: String? = nil, filename: String? = nil,
                    tags: [Tag]? = nil, publicationTitle: String? = nil, abstractNote: String? = nil,
                    dateModified: String? = nil) {
            self.itemType = itemType; self.title = title; self.creators = creators; self.date = date
            self.DOI = DOI; self.url = url; self.contentType = contentType; self.filename = filename
            self.tags = tags; self.publicationTitle = publicationTitle; self.abstractNote = abstractNote
            self.dateModified = dateModified
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
