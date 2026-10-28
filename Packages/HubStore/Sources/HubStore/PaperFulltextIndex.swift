import Foundation
import Observation
import HubCore

/// 論文 PDF 全文索引（docs/ARCHITECTURE.md 第 4 節：論文頁的全文搜尋）。
///
/// 文字不自己抽，用 Zotero 已經索引好的：app 端的 fetcher 先讀 `storage/<附件>/.zotero-ft-cache`，
/// 沒授權資料夾就問本地 API `/items/<附件>/fulltext`。拿到的文字存在 Caches 目錄，
/// 下次開 app 直接讀檔；項目的 `changeStamp`（dateModified）變了才重抓。畫面只看 `texts`／進度，不用管來源。
@MainActor
@Observable
public final class PaperFulltextIndex {
    /// 項目 key → 全文（還沒索引到的不在裡面）
    public private(set) var texts: [String: String] = [:]
    public private(set) var isIndexing = false
    /// 這一輪已處理／要處理的篇數（含讀快取的）
    public private(set) var done = 0
    public private(set) var total = 0
    /// 有新文字進來就加一；搜尋畫面用它重搜一次
    public private(set) var generation = 0

    /// 這篇的 PDF 附件 key（`ZoteroItem.pdfAttachmentKey` 拿不到時 app 可去問 API）
    public typealias AttachmentResolver = @Sendable (ZoteroItem) async -> String?
    /// 附件 key → 全文（nil＝Zotero 沒索引或連不上，這次先跳過、下次再試）
    public typealias Fetcher = @Sendable (String) async -> String?

    @ObservationIgnored private let cacheDir: URL
    @ObservationIgnored private let resolve: AttachmentResolver
    @ObservationIgnored private let fetch: Fetcher
    /// 附件 key → 抓到時項目的 changeStamp（存成 versions.json）
    @ObservationIgnored private var versions: [String: String] = [:]
    /// 項目 key → 已載入的 changeStamp（記憶體內，判斷要不要重做）
    @ObservationIgnored private var loadedVersion: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(cacheDir: URL? = nil,
                resolve: @escaping AttachmentResolver = { $0.pdfAttachmentKey },
                fetch: @escaping Fetcher) {
        self.cacheDir = cacheDir ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaperFulltext", isDirectory: true)
        self.resolve = resolve
        self.fetch = fetch
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.cacheDir.appendingPathComponent("versions.json")),
           let v = try? JSONDecoder().decode([String: String].self, from: data) {
            versions = v
        }
    }

    /// 把這些項目的全文補齊（已經有、而且沒改過的跳過）。上一輪還在跑就先取消。
    public func ensureIndexed(_ items: [ZoteroItem]) {
        let pending = items.filter { loadedVersion[$0.key] != $0.changeStamp }
        guard !pending.isEmpty else { return }
        task?.cancel()
        isIndexing = true
        total = pending.count
        done = 0
        task = Task { [weak self] in
            for item in pending {
                if Task.isCancelled { return }
                await self?.index(item)
                guard let self else { return }
                self.done += 1
            }
            guard let self else { return }
            self.isIndexing = false
            self.saveVersions()
            self.generation += 1
        }
    }

    /// 等索引跑完（測試用）
    public func waitUntilIdle() async {
        await task?.value
    }

    private func index(_ item: ZoteroItem) async {
        let version = item.changeStamp
        guard let attachment = await resolve(item) else {
            loadedVersion[item.key] = version
            return
        }
        let file = cacheDir.appendingPathComponent(attachment + ".txt")
        if versions[attachment] == version, let text = try? String(contentsOf: file, encoding: .utf8) {
            texts[item.key] = text
            loadedVersion[item.key] = version
            return
        }
        guard let text = await fetch(attachment) else { return }   // 這次拿不到，下次再試
        texts[item.key] = text
        loadedVersion[item.key] = version
        versions[attachment] = version
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func saveVersions() {
        if let data = try? JSONEncoder().encode(versions) {
            try? data.write(to: cacheDir.appendingPathComponent("versions.json"), options: .atomic)
        }
    }
}
