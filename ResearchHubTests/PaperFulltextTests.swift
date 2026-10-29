import XCTest
import HubCore
import HubStore

/// 論文全文搜尋（docs/ARCHITECTURE.md 第 4 節）：附件 key 的捷徑、全文命中的排序、索引的快取規則。
final class PaperFulltextTests: XCTestCase {

    // MARK: - ZoteroItem：links.attachment 捷徑

    func testPDFAttachmentKeyFromLinks() throws {
        let json = """
        [{"key":"INLIMQTY","version":47,
          "links":{"attachment":{"href":"http://localhost:23119/api/users/1/items/SIRHCPFE",
                                 "type":"application/json","attachmentType":"application/pdf"}},
          "data":{"itemType":"journalArticle","title":"Three Point Amplitudes"}},
         {"key":"NOATT","version":3,"data":{"itemType":"journalArticle","title":"x"}},
         {"key":"SNAP","version":5,
          "links":{"attachment":{"href":"http://localhost:23119/api/users/1/items/HTML1",
                                 "attachmentType":"text/html"}},
          "data":{"itemType":"webpage","title":"y"}},
         {"key":"PDFONLY","version":9,"data":{"itemType":"attachment","contentType":"application/pdf"}}]
        """
        let items = try JSONDecoder().decode([ZoteroItem].self, from: Data(json.utf8))
        XCTAssertEqual(items[0].pdfAttachmentKey, "SIRHCPFE")
        XCTAssertEqual(items[0].version, 47)
        XCTAssertEqual(items[0].changeStamp, "v47", "沒有 dateModified 時退回 version")
        XCTAssertEqual(ZoteroItem(key: "x", data: .init(itemType: "a", dateModified: "2026-10-15T06:00:29Z"),
                                  version: 0).changeStamp, "2026-10-15T06:00:29Z",
                       "沒同步的文獻庫 version 永遠 0，要看 dateModified")
        XCTAssertNil(items[1].pdfAttachmentKey, "沒有附件捷徑 → nil，交給 pdfAttachment(for:) 去問")
        XCTAssertNil(items[2].pdfAttachmentKey, "網頁快照不是 PDF")
        XCTAssertEqual(items[3].pdfAttachmentKey, "PDFONLY", "獨立 PDF 的附件就是自己")
    }

    func testDecodeFulltext() {
        let data = Data(#"{"content":"hello world","indexedPages":23,"totalPages":23}"#.utf8)
        let ft = ZoteroClient.decodeFulltext(data)
        XCTAssertEqual(ft?.content, "hello world")
        XCTAssertEqual(ft?.indexedPages, 23)
        XCTAssertNil(ZoteroClient.decodeFulltext(Data("{}".utf8)))
    }

    // MARK: - SearchEngine：全文命中

    func testFullTextHitsComeAfterBibliographicHits() {
        let papers = [
            SearchEngine.PaperEntry(key: "FT", title: "Matrix Theory", authors: "Maldacena", year: "2025",
                                    venue: "", abstract: "", tags: [],
                                    fullText: "intro\nWe use the conformal bootstrap to bound the gap.\nend"),
            SearchEngine.PaperEntry(key: "TITLE", title: "Bootstrap methods", authors: "Kos", year: "2014",
                                    venue: "", abstract: "", tags: [], fullText: "nothing here"),
            SearchEngine.PaperEntry(key: "ABS", title: "Other", authors: "", year: "",
                                    venue: "", abstract: "a bootstrap approach", tags: [],
                                    fullText: "bootstrap again"),
            SearchEngine.PaperEntry(key: "NONE", title: "Unrelated", authors: "", year: "",
                                    venue: "", abstract: "", tags: [], fullText: nil),
        ]
        let hits = SearchEngine.search("bootstrap", scope: .papersAndNotes, root: nil, papers: papers)
        XCTAssertEqual(hits.map { $0.target }, [.paper(key: "TITLE"), .paper(key: "ABS"), .paper(key: "FT")],
                       "標題 → 摘要 → 全文")
        XCTAssertEqual(hits.map(\.field), [.title, .body, .fullText])
        let ft = hits[2]
        XCTAssertEqual(ft.fields, [.fullText])
        XCTAssertEqual(ft.line, 1)
        XCTAssertTrue(ft.snippet?.contains("conformal bootstrap") ?? false)
        XCTAssertFalse(hits.contains { $0.target == .paper(key: "NONE") })
    }

    func testFullTextRequiresAllTerms() {
        let papers = [SearchEngine.PaperEntry(key: "A", title: "t", authors: "", year: "", venue: "",
                                              abstract: "", tags: [], fullText: "alpha beta")]
        XCTAssertEqual(SearchEngine.search("alpha beta", scope: .papersAndNotes, root: nil, papers: papers).count, 1)
        XCTAssertTrue(SearchEngine.search("alpha gamma", scope: .papersAndNotes, root: nil, papers: papers).isEmpty)
    }

    // MARK: - PaperFulltextIndex：快取

    private func item(_ key: String, attachment: String, version: Int) -> ZoteroItem {
        ZoteroItem(key: key, data: .init(itemType: "journalArticle", title: key), version: version,
                   links: .init(attachment: .init(href: "http://x/items/\(attachment)",
                                                  attachmentType: "application/pdf")))
    }

    @MainActor
    func testIndexFetchesOncePerVersionAndReusesDiskCache() async throws {
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        final class Counter: @unchecked Sendable { var calls: [String] = []; let lock = NSLock() }
        let counter = Counter()
        let fetch: PaperFulltextIndex.Fetcher = { key in
            counter.lock.lock(); counter.calls.append(key); counter.lock.unlock()
            return key == "MISSING" ? nil : "text of \(key)"
        }
        let items = [item("P1", attachment: "A1", version: 1), item("P2", attachment: "MISSING", version: 1)]

        let index = PaperFulltextIndex(cacheDir: dir, fetch: fetch)
        index.ensureIndexed(items)
        XCTAssertTrue(index.isIndexing)
        await index.waitUntilIdle()
        XCTAssertFalse(index.isIndexing)
        XCTAssertEqual(index.texts, ["P1": "text of A1"], "拿不到的不進索引")
        XCTAssertEqual(index.generation, 1)
        XCTAssertEqual(counter.calls, ["A1", "MISSING"])

        // 同 version 再來一次：有的跳過，沒拿到的再試
        index.ensureIndexed(items)
        await index.waitUntilIdle()
        XCTAssertEqual(counter.calls, ["A1", "MISSING", "MISSING"])

        // 新的實例（模擬重開 app）：從 Caches 讀，不再抓
        let reopened = PaperFulltextIndex(cacheDir: dir, fetch: fetch)
        reopened.ensureIndexed([items[0]])
        await reopened.waitUntilIdle()
        XCTAssertEqual(reopened.texts["P1"], "text of A1")
        XCTAssertEqual(counter.calls.filter { $0 == "A1" }.count, 1)

        // version 變了 → 重抓
        reopened.ensureIndexed([item("P1", attachment: "A1", version: 2)])
        await reopened.waitUntilIdle()
        XCTAssertEqual(counter.calls.filter { $0 == "A1" }.count, 2)
    }

    @MainActor
    func testIndexSkipsItemsWithoutPDF() async throws {
        let dir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = PaperFulltextIndex(cacheDir: dir, fetch: { _ in XCTFail("不該抓"); return nil })
        index.ensureIndexed([ZoteroItem(key: "N", data: .init(itemType: "journalArticle"), version: 1)])
        await index.waitUntilIdle()
        XCTAssertTrue(index.texts.isEmpty)
        XCTAssertEqual(index.done, 1)
    }
}
