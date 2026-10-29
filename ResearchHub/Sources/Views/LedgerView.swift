#if os(macOS)
import SwiftUI
import AppKit
import HubStore
import HubCore

/// 記帳分頁（docs/ARCHITECTURE.md 5.1 ③）：按月看支出——總額與上月比、類別排行（點了過濾明細）、
/// 12 個月趨勢（點了切月）、當月明細依天分組（點了跳到那天的日記改金額）。
/// 資料來源只有日記裡的 `@spend`；這頁不寫檔，要改就回日記改。
struct LedgerView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(GeneralTodoStore.self) private var generalStore

    @State private var month: Date = Calendar.current.startOfMonth(for: .now)
    @State private var category: String?
    @State private var entries: [LedgerEntry] = []
    @State private var loaded = false
    @State private var task: Task<Void, Never>?
    @State private var animateBars = false
    private let calendar = Calendar.current

    private var summary: LedgerMonthSummary {
        LedgerStats.summarize(entries, month: month, categories: generalStore.ledgerCategories,
                              trendMonths: 12, calendar: calendar)
    }

    var body: some View {
        Group {
            if store.rootURL == nil {
                Text("請先在「筆記」分頁選擇根資料夾")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle("記帳")
        .onAppear {
            reload()
            animateBars = false
            withAnimation(.spring(duration: 0.6).delay(0.1)) { animateBars = true }
        }
        .onChange(of: month) { category = nil }
        .onReceive(AppContainer.shared.librarySync.changes) { change in
            let relevant = change.urls.isEmpty || change.urls.contains {
                $0.pathExtension.lowercased() == "md" || $0.lastPathComponent == "ledger-categories.json"
            }
            if relevant { reload() }
        }
    }

    private var content: some View {
        let s = summary
        return VStack(spacing: 0) {
            header(s)
            Divider()
            if loaded && entries.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            categoriesPanel(s)
                            trendPanel(s)
                            if !s.unknownCategories.isEmpty { unknownPanel(s) }
                        }
                        .padding(16)
                    }
                    .frame(width: 300)
                    Divider()
                    entriesList(s)
                }
            }
        }
    }

    // MARK: - 標題列

    private func header(_ s: LedgerMonthSummary) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").padding(6).contentShape(Rectangle()) }
                    .help("上個月")
                Text(verbatim: month.formatted(.dateTime.year().month()))
                    .font(.headline)
                    .frame(minWidth: 110)
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").padding(6).contentShape(Rectangle()) }
                    .help("下個月")
                    .disabled(month >= calendar.startOfMonth(for: .now))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if month != calendar.startOfMonth(for: .now) {
                Button("本月") { month = calendar.startOfMonth(for: .now) }
                    .font(.caption)
                    .buttonStyle(.link)
            }

            Spacer()

            stat("總額", Self.money(s.total), .primary)
            stat("筆數", "\(s.count)", .secondary)
            if let ratio = s.changeRatio {
                let up = ratio > 0
                stat("上月比", (up ? "+" : "−") + Self.percent(abs(ratio)), up ? .orange : .green)
            } else if s.previousTotal == 0, s.total > 0 {
                stat("上月", "—", .secondary)
            }
            if s.count > 0 {
                stat("日均", Self.money(s.total / Double(daysElapsed())), .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func stat(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 本月已過的天數（看舊月份 = 整月天數），日均用
    private func daysElapsed() -> Int {
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        guard calendar.isDate(month, equalTo: .now, toGranularity: .month) else { return days }
        return max(1, calendar.component(.day, from: .now))
    }

    private func shiftMonth(_ delta: Int) {
        if let m = calendar.date(byAdding: .month, value: delta, to: month) { month = m }
    }

    // MARK: - 左欄

    private func categoriesPanel(_ s: LedgerMonthSummary) -> some View {
        panel("類別", icon: "tag") {
            if s.byCategory.isEmpty {
                hint("這個月沒有支出紀錄。")
            } else {
                let maxTotal = s.byCategory.first?.total ?? 1
                VStack(spacing: 2) {
                    categoryRow(nil, title: L("全部"), total: s.total, count: s.count, maxTotal: s.total)
                    ForEach(s.byCategory, id: \.category) { c in
                        categoryRow(c.category, title: c.category, total: c.total, count: c.count, maxTotal: maxTotal)
                    }
                }
            }
        }
    }

    private func categoryRow(_ key: String?, title: String, total: Double, count: Int, maxTotal: Double) -> some View {
        let selected = category == key
        return Button {
            category = key
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    Text("\(count) 筆")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(Self.money(total))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    Capsule()
                        .fill(selected ? Color.accentColor : Color.accentColor.opacity(0.35))
                        .frame(width: animateBars ? max(4, geo.size.width * total / max(maxTotal, 1)) : 4)
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverRow())
    }

    private func trendPanel(_ s: LedgerMonthSummary) -> some View {
        panel("最近 12 個月", icon: "chart.bar") {
            let maxTotal = max(s.trend.map(\.total).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(s.trend.enumerated()), id: \.offset) { i, m in
                    let isCurrent = i == s.trend.count - 1
                    Button {
                        month = m.month
                    } label: {
                        VStack(spacing: 3) {
                            Capsule()
                                .fill(isCurrent ? Color.accentColor : Color.gray.opacity(0.3))
                                .frame(width: 10, height: animateBars ? max(3, 60 * m.total / maxTotal) : 3)
                                .frame(height: 60, alignment: .bottom)
                            // 只放月份數字：欄位很窄，「11月」會折行
                            Text(verbatim: String(calendar.component(.month, from: m.month)))
                                .font(.caption2)
                                .foregroundStyle(isCurrent ? .primary : .tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(m.month.formatted(.dateTime.year().month()) + "・" + Self.money(m.total))
                }
            }
        }
    }

    private func unknownPanel(_ s: LedgerMonthSummary) -> some View {
        panel("清單外的類別", icon: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.unknownCategories.joined(separator: "、"))
                    .font(.callout)
                Text("照樣計數；想固定下來就加進類別清單。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("打開 ledger-categories.json") {
                    if let root = store.rootURL {
                        NSWorkspace.shared.open(root.appendingPathComponent(".hub/ledger-categories.json"))
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
        }
    }

    private func panel<Content: View>(_ title: LocalizedStringKey, icon: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
    }

    // MARK: - 明細

    private func entriesList(_ s: LedgerMonthSummary) -> some View {
        let cats = generalStore.ledgerCategories
        let monthEntries = LedgerStats.entries(entries, in: month, calendar: calendar)
            .filter { category == nil || cats.canonical($0.category) == category }
        let days = LedgerStats.groupedByDay(monthEntries)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                if let category {
                    HStack {
                        Text("只看「\(category)」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("清除") { self.category = nil }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                    .padding(.horizontal, 4)
                }
                if days.isEmpty {
                    hint("這個月沒有符合的紀錄。")
                        .padding(.top, 8)
                }
                ForEach(days, id: \.day) { group in
                    Section {
                        VStack(spacing: 1) {
                            ForEach(group.entries) { e in
                                entryRow(e, canonical: cats.canonical(e.category))
                            }
                        }
                    } header: {
                        HStack {
                            Text(verbatim: group.day.formatted(.dateTime.month().day().weekday()))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.money(group.total))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                    }
                }
                Text("要改金額或類別，點那一筆回日記改；這頁只彙總不寫檔。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entryRow(_ e: LedgerEntry, canonical: String) -> some View {
        Button {
            store.pendingJournalDate = e.day
            store.requestedTab = .journal
        } label: {
            HStack(spacing: 10) {
                Text(e.note.isEmpty ? L("（沒有說明）") : e.note)
                    .font(.callout)
                    .foregroundStyle(e.note.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                Spacer()
                Text(canonical)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(.secondary)
                Text(Self.money(e.amount))
                    .font(.callout.monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverRow())
        .help("打開 \(e.day.formatted(.dateTime.month().day())) 的日記")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "creditcard")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("還沒有支出紀錄")
                .font(.headline)
            Text("在日記任一行寫 @spend(金額, 類別)，或在日記命令列打 /spend 120 餐費 午餐。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(verbatim: "- 午餐 @spend(120, 餐費)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Button("去寫今天的日記") {
                store.pendingJournalDate = calendar.startOfDay(for: .now)
                store.requestedTab = .journal
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 資料

    private func reload() {
        let journal = store.journalURL
        task?.cancel()
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                LibraryScan.ledgerEntries(journal: journal)
            }.value
            guard !Task.isCancelled else { return }
            if entries != result { entries = result }
            loaded = true
        }
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = v.rounded() == v ? 0 : 2
        f.minimumFractionDigits = 0
        return "$" + (f.string(from: NSNumber(value: v)) ?? String(v))
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}
#endif
