// 守記帳契約（docs/ARCHITECTURE.md 5.1；LedgerParser.swift）：
// 日記任一行的 @spend(金額, 類別)、類別白名單、按月／按類別彙總、首頁快照帶條目。
import XCTest
@testable import ResearchHub
@testable import HubStore
@testable import HubCore

final class LedgerTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: 解析

    func testParsesSpendOnPlainBulletTodoAndBareLines() {
        let content = """
        # 10/11
        - 午餐 @spend(120, 餐費)
        - [x] 買書 @spend(450.5, 書籍)
        @Spend(80)
        - 沒有記帳的行
        - 信箱 me@spend.com 不是標記
        """
        let entries = LedgerParser.entries(in: content, day: day(2026, 10, 11))
        XCTAssertEqual(entries.map(\.amount), [120, 450.5, 80])
        XCTAssertEqual(entries.map(\.category), ["餐費", "書籍", LedgerParser.uncategorized])
        XCTAssertEqual(entries.map(\.note), ["午餐", "買書", ""])
        XCTAssertEqual(entries.map(\.lineIndex), [1, 2, 3])
        XCTAssertTrue(entries.allSatisfy { $0.day == day(2026, 10, 11) })
    }

    func testSeveralSpendsOnOneLineAndBadAmountsIgnored() {
        let spends = LedgerParser.spends(inLine: "早餐 @spend(60, 餐費) 咖啡 @spend( 90 ,餐費 ) @spend(abc, 餐費)")
        XCTAssertEqual(spends.map(\.amount), [60, 90])
        XCTAssertEqual(spends.map(\.category), ["餐費", "餐費"])
        XCTAssertEqual(LedgerParser.strippingSpends("午餐 @spend(120, 餐費) 好吃"), "午餐  好吃")
    }

    func testTodoMetaHidesSpendMarkerFromCleanText() {
        let m = TodoMeta.parse("買書 @spend(450, 書籍) !high", calendar: calendar)
        XCTAssertEqual(m.cleanText, "買書")
        XCTAssertEqual(m.priority, .high)
        XCTAssertEqual(m.dedupKey, "買書")
    }

    // MARK: 類別白名單

    func testCategoriesMatchCaseInsensitivelyAndKeepUnknown() throws {
        let cats = try JSONDecoder().decode(
            LedgerCategories.self, from: Data(#"{"categories": ["餐費", "Books"]}"#.utf8))
        XCTAssertEqual(cats.canonical(" books "), "Books")
        XCTAssertEqual(cats.canonical("交通"), "交通")
        XCTAssertTrue(cats.contains("BOOKS"))
        XCTAssertFalse(cats.contains("交通"))
        // 空物件也要能解
        let empty = try JSONDecoder().decode(LedgerCategories.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.categories, [])
    }

    // MARK: 彙總

    func testMonthSummaryTotalsCategoriesPreviousMonthAndTrend() {
        let entries: [LedgerEntry] = [
            .init(day: day(2026, 10, 1), amount: 120, category: "餐費", note: "", lineIndex: 0),
            .init(day: day(2026, 10, 2), amount: 80, category: "餐費", note: "", lineIndex: 0),
            .init(day: day(2026, 10, 3), amount: 500, category: "books", note: "", lineIndex: 0),
            .init(day: day(2026, 10, 4), amount: 300, category: "交通", note: "", lineIndex: 0),
            .init(day: day(2026, 10, 5), amount: 50, category: LedgerParser.uncategorized, note: "", lineIndex: 0),
            .init(day: day(2026, 9, 20), amount: 400, category: "餐費", note: "", lineIndex: 0),
            .init(day: day(2026, 7, 1), amount: 1000, category: "居住", note: "", lineIndex: 0),
            .init(day: day(2026, 11, 1), amount: 999, category: "餐費", note: "", lineIndex: 0), // 下個月不算
        ]
        let cats = LedgerCategories(categories: ["餐費", "Books", "居住"])
        let s = LedgerStats.summarize(entries, month: day(2026, 10, 15), categories: cats,
                                      trendMonths: 4, calendar: calendar)
        XCTAssertEqual(s.month, day(2026, 10, 1))
        XCTAssertEqual(s.total, 1050)
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.byCategory.map(\.category), ["Books", "交通", "餐費", LedgerParser.uncategorized])
        XCTAssertEqual(s.byCategory.map(\.total), [500, 300, 200, 50])
        XCTAssertEqual(s.byCategory.first { $0.category == "餐費" }?.count, 2)
        XCTAssertEqual(s.previousTotal, 400)
        XCTAssertEqual(s.changeRatio.map { ($0 * 100).rounded() }, 163)
        XCTAssertEqual(s.trend.map { calendar.component(.month, from: $0.month) }, [7, 8, 9, 10])
        XCTAssertEqual(s.trend.map(\.total), [1000, 0, 400, 1050])
        XCTAssertEqual(s.unknownCategories, ["交通"])
    }

    func testMonthEntriesAndDayGroupsForLedgerTab() {
        let entries: [LedgerEntry] = [
            .init(day: day(2026, 10, 3), amount: 30, category: "交通", note: "捷運", lineIndex: 7),
            .init(day: day(2026, 10, 3), amount: 120, category: "餐費", note: "午餐", lineIndex: 2),
            .init(day: day(2026, 10, 1), amount: 500, category: "書籍", note: "書", lineIndex: 0),
            .init(day: day(2026, 9, 30), amount: 999, category: "餐費", note: "上月", lineIndex: 0),
        ]
        let inMonth = LedgerStats.entries(entries, in: day(2026, 10, 15), calendar: calendar)
        XCTAssertEqual(inMonth.map(\.note), ["書", "午餐", "捷運"])
        let groups = LedgerStats.groupedByDay(inMonth)
        XCTAssertEqual(groups.map { calendar.component(.day, from: $0.day) }, [3, 1])
        XCTAssertEqual(groups[0].entries.map(\.note), ["午餐", "捷運"])
        XCTAssertEqual(groups[0].total, 150)
        XCTAssertEqual(groups[1].total, 500)
    }

    func testEmptyMonthHasNoChangeRatio() {
        let s = LedgerStats.summarize([], month: day(2026, 10, 1), calendar: calendar)
        XCTAssertEqual(s.total, 0)
        XCTAssertNil(s.changeRatio)
        XCTAssertEqual(s.trend.count, 6)
        XCTAssertTrue(s.byCategory.isEmpty)
    }

    // MARK: 掃日記

    func testLibraryScanCollectsEntriesAcrossJournalDays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ text: String) throws {
            let dir = journal.appendingPathComponent("2026/10", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("2026-10-02.md", "- 晚餐 @spend(200, 餐費)\n")
        try write("2026-10-01.md", "- [ ] 讀 CFT\n- 早餐 @spend(60, 餐費)\n- 捷運 @spend(30, 交通)\n")
        try write("notes.md", "- 不是日記 @spend(999)\n")

        let entries = LibraryScan.ledgerEntries(journal: journal)
        XCTAssertEqual(entries.map(\.amount), [60, 30, 200])
        XCTAssertEqual(entries.map { Calendar.current.component(.day, from: $0.day) }, [1, 1, 2])

        let snap = LibraryScan.homeSnapshot(notes: nil, journal: journal, generalTexts: [])
        XCTAssertEqual(snap.ledger.map(\.amount), [60, 30, 200])
        // 同一個檔的待辦索引也照常
        XCTAssertEqual(LibraryIndex.shared.todoLines(in: journal.appendingPathComponent("2026/10/2026-10-01.md"))?.count, 1)
    }
}
