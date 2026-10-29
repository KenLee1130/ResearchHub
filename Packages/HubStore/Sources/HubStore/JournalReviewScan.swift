import Foundation
import HubCore

/// 回顧頁需要的全部資料（docs/ARCHITECTURE.md 5.2 ③），一次在背景算好。
public nonisolated struct JournalReview: Sendable, Hashable {
    public struct DayItem: Sendable, Hashable, Identifiable {
        public let day: Date
        public let kind: JournalKind
        public let excerpt: String
        public let mood: Int?
        public let themes: [String]
        public var id: Date { day }
    }
    public struct MonthPicks: Sendable, Hashable, Identifiable {
        /// 該月 1 號
        public let month: Date
        public let items: [DayItem]
        public var id: Date { month }
    }
    public struct MoodPoint: Sendable, Hashable, Identifiable {
        public let day: Date
        public let mood: Int
        public var id: Date { day }
    }

    /// 往年的今天（一年前、兩年前…，新到舊）
    public var yearsAgo: [DayItem] = []
    /// 最近幾個月的心得精選（新月在前；每月最多 3 天）
    public var monthly: [MonthPicks] = []
    /// 心情時間軸（旁車檔有 mood 的天，舊→新）
    public var moods: [MoodPoint] = []
    public var reflectiveCount = 0
    public var logCount = 0

    public init() {}
}

extension LibraryScan {
    /// 一天的有效分類：旁車檔的 kind 優先，否則本地啟發式。讀不到檔回 nil。
    public static func journalKind(url: URL, day: Date, meta: JournalMetaFile.Contents,
                                   calendar: Calendar = .current) -> JournalKind? {
        if let k = meta[JournalMetaFile.key(for: day, calendar: calendar)]?.kind { return k }
        return LibraryIndex.shared.journalKind(in: url)
    }

    public static func journalReview(journal: URL?, meta: JournalMetaFile.Contents,
                                     today: Date = .now, months: Int = 12,
                                     calendar: Calendar = .current) -> JournalReview {
        var review = JournalReview()
        let todayDay = calendar.startOfDay(for: today)
        let files = journalFiles(journal: journal).sorted { $0.1 > $1.1 }
        let todayComps = calendar.dateComponents([.month, .day], from: todayDay)
        let earliestMonth = calendar.date(byAdding: .month, value: -(months - 1),
                                          to: startOfMonth(todayDay, calendar)) ?? .distantPast

        var byMonth: [Date: [JournalReview.DayItem]] = [:]
        var moods: [JournalReview.MoodPoint] = []

        for (url, day) in files {
            let dayStart = calendar.startOfDay(for: day)
            let key = JournalMetaFile.key(for: dayStart, calendar: calendar)
            let m = meta[key]
            if let mood = m?.mood { moods.append(.init(day: dayStart, mood: mood)) }

            let comps = calendar.dateComponents([.month, .day], from: dayStart)
            let sameDate = comps.month == todayComps.month && comps.day == todayComps.day && dayStart < todayDay
            let inWindow = dayStart >= earliestMonth && dayStart <= todayDay
            guard sameDate || inWindow else { continue }

            guard let kind = journalKind(url: url, day: dayStart, meta: meta, calendar: calendar)
            else { continue }
            // 摘錄要讀內文（分類已快取，這裡只讀進回顧範圍內的檔）
            let content = ICloudFile.safeRead(url) ?? ""
            let item = JournalReview.DayItem(
                day: dayStart, kind: kind,
                excerpt: JournalClassifier.excerpt(content),
                mood: m?.mood, themes: m?.themes ?? [])

            if sameDate { review.yearsAgo.append(item) }
            guard inWindow else { continue }
            if kind == .reflective { review.reflectiveCount += 1 } else { review.logCount += 1 }
            if kind == .reflective {
                byMonth[startOfMonth(dayStart, calendar), default: []].append(item)
            }
        }

        review.monthly = byMonth.keys.sorted(by: >).map { month in
            let items = byMonth[month] ?? []
            // 精選：Claude 標過的（有 mood／themes）優先，其次摘錄長的；最多 3 天
            let picked = items.sorted { a, b in
                let am = a.mood != nil || !a.themes.isEmpty
                let bm = b.mood != nil || !b.themes.isEmpty
                if am != bm { return am }
                if a.excerpt.count != b.excerpt.count { return a.excerpt.count > b.excerpt.count }
                return a.day > b.day
            }.prefix(3).sorted { $0.day > $1.day }
            return JournalReview.MonthPicks(month: month, items: Array(picked))
        }
        review.moods = moods.sorted { $0.day < $1.day }
        return review
    }

    static func startOfMonth(_ date: Date, _ calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}
