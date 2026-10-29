#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// 日記回顧（docs/ARCHITECTURE.md 5.2 ③）：往年的今天、每月心得精選、心情時間軸。
/// 放在日記分頁編輯器的位置（標題列「回顧」或命令列 /review 打開）；點任一天跳回那天的日記。
struct JournalReviewView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(GeneralTodoStore.self) private var generalStore
    var onOpenDay: (Date) -> Void
    var onClose: () -> Void

    @State private var review = JournalReview()
    @State private var loaded = false
    @State private var task: Task<Void, Never>?
    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if loaded, review.yearsAgo.isEmpty, review.monthly.isEmpty, review.moods.isEmpty {
                    Text("還沒有可回顧的日記。寫滿一個月後這裡會有心得精選；Claude 做 insights 時會補上心情與主題。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    yearsAgoSection
                    moodSection
                    monthlySection
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onChange(of: generalStore.journalMeta) { reload() }
        .onReceive(AppContainer.shared.librarySync.changes) { change in
            if change.affects(store.journalURL) { reload() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("回顧")
                    .font(.title2.weight(.semibold))
                if loaded {
                    Text("最近 12 個月：\(review.reflectiveCount) 天心得、\(review.logCount) 天流水帳")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("整理中…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("回到日記", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - 往年的今天

    @ViewBuilder private var yearsAgoSection: some View {
        section("往年的今天", icon: "clock.arrow.circlepath") {
            if review.yearsAgo.isEmpty {
                hint("往年的這一天沒有日記。")
            } else {
                ForEach(review.yearsAgo) { item in
                    dayRow(item, title: yearsAgoTitle(item.day))
                }
            }
        }
    }

    private func yearsAgoTitle(_ day: Date) -> String {
        let years = calendar.dateComponents([.year], from: day, to: calendar.startOfDay(for: .now)).year ?? 0
        let when = years == 1 ? L("一年前") : L("\(years) 年前")
        return when + "・" + day.formatted(.dateTime.year().month().day())
    }

    // MARK: - 心情時間軸

    @ViewBuilder private var moodSection: some View {
        section("心情時間軸", icon: "waveform.path.ecg") {
            if review.moods.isEmpty {
                hint("還沒有心情資料。Claude 做 insights 時會把每天的 mood（-2…2）與主題寫進 .hub/journal-meta.json。")
            } else {
                let points = Array(review.moods.suffix(90))
                HStack(alignment: .center, spacing: 2) {
                    ForEach(points) { p in
                        Button {
                            onOpenDay(p.day)
                        } label: {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(moodColor(p.mood))
                                .frame(height: 8 + CGFloat(p.mood + 2) * 6)
                                .frame(height: 34, alignment: .center)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .help(p.day.formatted(.dateTime.month().day()) + "・" + moodLabel(p.mood))
                    }
                }
                .frame(height: 34)
                HStack {
                    Text(verbatim: points.first?.day.formatted(.dateTime.month().day()) ?? "")
                    Spacer()
                    Text("共 \(review.moods.count) 天有紀錄")
                    Spacer()
                    Text(verbatim: points.last?.day.formatted(.dateTime.month().day()) ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func moodColor(_ mood: Int) -> Color {
        switch mood {
        case ...(-2): return .red
        case -1: return .orange
        case 0: return .gray
        case 1: return .teal
        default: return .green
        }
    }

    private func moodLabel(_ mood: Int) -> String {
        switch mood {
        case ...(-2): return L("很糟")
        case -1: return L("偏低")
        case 0: return L("平平")
        case 1: return L("不錯")
        default: return L("很好")
        }
    }

    // MARK: - 每月心得精選

    @ViewBuilder private var monthlySection: some View {
        section("每月心得精選", icon: "sparkles") {
            if review.monthly.isEmpty {
                hint("最近 12 個月沒有被判為心得的日記（散文多、有感受的那種）。")
            } else {
                ForEach(review.monthly) { month in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: month.month.formatted(.dateTime.year().month()))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(month.items) { item in
                            dayRow(item, title: item.day.formatted(.dateTime.month().day().weekday()))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 共用

    private func section<Content: View>(_ title: LocalizedStringKey, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func dayRow(_ item: JournalReview.DayItem, title: String) -> some View {
        Button {
            onOpenDay(item.day)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.medium))
                    if let mood = item.mood {
                        Circle().fill(moodColor(mood)).frame(width: 7, height: 7)
                            .help(moodLabel(mood))
                    }
                    Text(item.kind == .reflective ? "心得" : "流水帳")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
                        .foregroundStyle(.secondary)
                    ForEach(item.themes.prefix(4), id: \.self) { theme in
                        Text(verbatim: "#" + theme)
                            .font(.caption2)
                            .foregroundStyle(.teal)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !item.excerpt.isEmpty {
                    Text(item.excerpt)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverRow())
    }

    private func reload() {
        let journal = store.journalURL
        let meta = generalStore.journalMeta
        task?.cancel()
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                LibraryScan.journalReview(journal: journal, meta: meta)
            }.value
            guard !Task.isCancelled else { return }
            review = result
            loaded = true
        }
    }
}
#endif
