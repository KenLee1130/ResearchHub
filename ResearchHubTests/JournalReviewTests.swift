// 守日記回顧（docs/ARCHITECTURE.md 5.2；JournalReview.swift／JournalReviewScan.swift）：
// 旁車檔格式容錯、本地分類啟發式、旁車檔 kind 覆寫、回顧快照（往年今天／月精選／心情）。
import XCTest
@testable import ResearchHub
@testable import HubStore
@testable import HubCore

final class JournalReviewTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: 旁車檔

    func testMetaFileDecodesTolerantlyAndClampsMood() throws {
        let json = """
        {
          "2026-10-11": { "kind": "reflective", "mood": 5, "themes": ["研究", "家人"] },
          "2026-10-12": { "kind": "weird", "mood": -9 },
          "2026-10-13": {}
        }
        """
        let meta = try XCTUnwrap(JournalMetaFile.decode(Data(json.utf8)))
        XCTAssertEqual(meta["2026-10-11"]?.kind, .reflective)
        XCTAssertEqual(meta["2026-10-11"]?.mood, 2)
        XCTAssertEqual(meta["2026-10-11"]?.themes, ["研究", "家人"])
        XCTAssertNil(meta["2026-10-12"]?.kind)
        XCTAssertEqual(meta["2026-10-12"]?.mood, -2)
        XCTAssertEqual(meta["2026-10-13"]?.isEmpty, true)
        XCTAssertEqual(JournalMetaFile.key(for: day(2026, 3, 7), calendar: calendar), "2026-03-07")
        XCTAssertEqual(JournalMetaFile.day(from: "2026-03-07", calendar: calendar), day(2026, 3, 7))
        // 來回編碼
        let data = try XCTUnwrap(JournalMetaFile.encode(meta))
        XCTAssertEqual(JournalMetaFile.decode(data), meta)
    }

    // MARK: 分類

    func testTodoHeavyShortDayIsLog() {
        let content = """
        # 10/11
        - [ ] 讀 CFT @est(2h)
        - [x] 跑 bootstrap
        - [ ] 回信
        接下來要做的事：
        1. 整理圖
        """
        let a = JournalClassifier.analyze(content)
        XCTAssertEqual(a.kind, .log)
        XCTAssertGreaterThan(a.listRatio, 0.5)
        XCTAssertLessThan(a.proseChars, 120)
    }

    func testProseWithFeelingsIsReflective() {
        let content = """
        今天把 modular bootstrap 的那張圖重跑了一次，結果跟上週差不多，不過我覺得整個流程終於順了。
        下午跟老師討論的時候有點焦慮，因為我還沒把 Virasoro 那段推完，但他說方向沒錯，心裡安心不少。
        晚上散步回來想了很久，研究這件事大概就是這樣，一直在不確定裡面找一點點確定。
        - [ ] 明天把圖丟進 overleaf
        """
        let a = JournalClassifier.analyze(content)
        XCTAssertEqual(a.kind, .reflective)
        XCTAssertGreaterThanOrEqual(a.emotionHits, 2)
        XCTAssertLessThan(a.listRatio, 0.7)
    }

    func testLongProseWithoutEmotionWordsStillReflectiveAndShortProseIsLog() {
        let long = String(repeating: "推導了 crossing equation 的展開式，把每一項的係數都重新對了一遍。", count: 14)
        XCTAssertEqual(JournalClassifier.classify(long), .reflective)
        XCTAssertEqual(JournalClassifier.classify("今天很累。\n- [ ] 睡覺"), .log)
        XCTAssertEqual(JournalClassifier.classify(""), .log)
    }

    func testExcerptPrefersProseAndTruncates() {
        let content = "# 標題\n---\n- [ ] 待辦\n第一段散文。\n> 引用的第二段。\n***\n"
        XCTAssertEqual(JournalClassifier.excerpt(content), "第一段散文。 引用的第二段。")
        XCTAssertEqual(JournalClassifier.excerpt("- [ ] 只有待辦 @due(7/1)\n- 一個清單"), "只有待辦 @due(7/1) 一個清單")
        let long = String(repeating: "字", count: 300)
        let e = JournalClassifier.excerpt(long, limit: 50)
        XCTAssertEqual(e.count, 51)
        XCTAssertTrue(e.hasSuffix("…"))
    }

    // MARK: 回顧快照

    func testReviewCollectsYearsAgoMonthlyPicksAndMoodsWithMetaOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ y: Int, _ m: Int, _ d: Int, _ text: String) throws {
            let dir = journal.appendingPathComponent(String(format: "%04d/%02d", y, m), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = String(format: "%04d-%02d-%02d.md", y, m, d)
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let reflective = "今天想了很久，我覺得研究就是在不確定裡找確定。" + String(repeating: "散文散文散文散文散文散文。", count: 10)
        let log = "- [ ] 讀論文\n- [x] 回信\n"

        try write(2025, 10, 29, reflective)          // 一年前的今天
        try write(2024, 10, 29, log)                 // 兩年前的今天
        try write(2026, 10, 29, log)                 // 今天本身不算往年
        try write(2026, 10, 20, reflective)          // 本月心得
        try write(2026, 10, 18, log)                 // 流水帳，但旁車檔說是心得
        try write(2026, 9, 5, reflective)            // 上月心得
        try write(2026, 9, 6, reflective)            // 旁車檔說是流水帳 → 不入精選
        try write(2025, 6, 1, reflective)            // 超過 12 個月 → 不入精選

        let today = day(2026, 10, 29)
        let meta: JournalMetaFile.Contents = [
            "2026-10-18": JournalDayMeta(kind: .reflective, mood: 1, themes: ["家人"]),
            "2026-09-06": JournalDayMeta(kind: .log),
            "2026-10-20": JournalDayMeta(mood: -1),
            "2026-09-05": JournalDayMeta(mood: 2),
        ]
        let r = LibraryScan.journalReview(journal: journal, meta: meta, today: today, calendar: calendar)

        XCTAssertEqual(r.yearsAgo.map { calendar.component(.year, from: $0.day) }, [2025, 2024])
        XCTAssertEqual(r.yearsAgo.map(\.kind), [.reflective, .log])
        XCTAssertTrue(r.yearsAgo[0].excerpt.hasPrefix("今天想了很久"))

        XCTAssertEqual(r.monthly.map { calendar.component(.month, from: $0.month) }, [10, 9])
        XCTAssertEqual(r.monthly[0].items.map { calendar.component(.day, from: $0.day) }, [20, 18])
        XCTAssertEqual(r.monthly[0].items[1].themes, ["家人"])
        XCTAssertEqual(r.monthly[0].items[1].mood, 1)
        XCTAssertEqual(r.monthly[1].items.map { calendar.component(.day, from: $0.day) }, [5])

        // 舊→新：9/5、10/18、10/20
        XCTAssertEqual(r.moods.map { calendar.component(.day, from: $0.day) }, [5, 18, 20])
        XCTAssertEqual(r.moods.map(\.mood), [2, 1, -1])

        // 視窗內（2025-11 起）：心得 = 10/20、10/18（覆寫）、9/5；流水帳 = 10/29（今天）、9/6（覆寫）
        XCTAssertEqual(r.reflectiveCount, 3)
        XCTAssertEqual(r.logCount, 2)
    }

    func testJournalKindUsesMetaOverrideThenClassifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("2026-10-01.md")
        try "- [ ] a\n- [ ] b\n".write(to: url, atomically: true, encoding: .utf8)
        let d = day(2026, 10, 1)
        XCTAssertEqual(LibraryScan.journalKind(url: url, day: d, meta: [:], calendar: calendar), .log)
        XCTAssertEqual(LibraryScan.journalKind(url: url, day: d,
                                               meta: ["2026-10-01": JournalDayMeta(kind: .reflective)],
                                               calendar: calendar), .reflective)
        XCTAssertNil(LibraryScan.journalKind(url: root.appendingPathComponent("missing.md"), day: d,
                                             meta: [:], calendar: calendar))
    }
}
