import SwiftUI

/// 晚間規劃儀式：左邊直接寫明天的日記，右邊是你的生產力節奏、
/// 今天沒做完的待辦（一鍵搬到明天）、以及 Claude 的建議。
struct PlanningSheet: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @EnvironmentObject private var generalStore: GeneralTodoStore
    @Environment(\.dismiss) private var dismiss

    @State private var mode: EditorMode = .blocks
    /// 今天還沒完成的日記待辦（原始文字）
    @State private var leftovers: [String] = []
    /// 已搬到明天的項目（避免重複搬）
    @State private var moved: Set<String> = []

    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue
    private let calendar = Calendar.current

    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    /// 週一開頭的短星期名（中：週一…；英：Mon…），跟隨 App 語言。
    private var dayLabels: [String] {
        var cal = Calendar.current
        cal.locale = appLocale
        let s = cal.shortWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    private var tomorrow: Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
    }

    /// 明天是週幾（0 = 週一）
    private var tomorrowWeekdayIndex: Int {
        (calendar.component(.weekday, from: tomorrow) + 5) % 7
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                editorPane
                Divider()
                sidePane
                    .frame(width: 300)
            }
        }
        .frame(width: 880, height: 640)
        .onAppear { leftovers = store.unfinishedJournalTodos(on: .now) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Label {
                Text("規劃明天 — \(tomorrowTitle)")
                    .font(.headline)
            } icon: {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(.indigo)
            }
            Spacer()
            EditorModePicker(mode: $mode, available: [.blocks, .source])
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tomorrowTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return f.string(from: tomorrow)
    }

    // MARK: - 左：明天的日記

    @ViewBuilder
    private var editorPane: some View {
        if let url = store.journalURL(for: tomorrow) {
            EditorCore(fileURL: url, mode: $mode)
                .id(url)
        } else {
            Text("請先在「筆記」分頁選擇根資料夾")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 右：節奏 + 沒做完的 + Claude

    private var sidePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                rhythmSection
                Divider()
                leftoverSection
                Divider()
                claudeSection
            }
            .padding(14)
        }
    }

    /// 你的節奏：高峰時段 + 明天那個星期幾的歷史表現。
    private var rhythmSection: some View {
        let profile = pomodoro.productivityProfile(days: 60)
        return VStack(alignment: .leading, spacing: 6) {
            Label("你的節奏", systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if profile.sampleCount >= 10 {
                if let h = profile.peakWindowStart {
                    Text("最專注時段：\(h):00–\(h + 2):00")
                        .font(.callout)
                }
                let count = profile.weekdayCounts[tomorrowWeekdayIndex]
                let maxCount = max(profile.weekdayCounts.max() ?? 1, 1)
                Group {
                    if tomorrowWeekdayIndex == profile.peakWeekday {
                        Text("明天是\(dayLabels[tomorrowWeekdayIndex])——你最高產的一天（近 60 天 \(count) 顆），可以排重的。")
                    } else if count <= maxCount / 4 {
                        Text("明天是\(dayLabels[tomorrowWeekdayIndex])，歷史上偏低產（近 60 天 \(count) 顆），排 2–3 件就好。")
                    } else {
                        Text("\(dayLabels[tomorrowWeekdayIndex])近 60 天完成 \(count) 顆。")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("訣竅：最難的排進高峰時段，雜務排低谷。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("蕃茄鐘紀錄還不夠，先累積幾天吧。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 今天沒做完的待辦：一鍵搬進明天的日記（左邊編輯器即時出現）。
    private var leftoverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("今天沒做完的", systemImage: "arrow.uturn.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if leftovers.contains(where: { !moved.contains($0) }) {
                    Button("全部搬過去") {
                        for item in leftovers where !moved.contains(item) {
                            moveToTomorrow(item)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
            }

            if leftovers.isEmpty {
                Text("今天全部做完了 🎉")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(leftovers, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button {
                            moveToTomorrow(item)
                        } label: {
                            Image(systemName: moved.contains(item)
                                  ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(moved.contains(item)
                                                 ? AnyShapeStyle(.green)
                                                 : AnyShapeStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                        .disabled(moved.contains(item))
                        .help("搬到明天的日記")

                        Text(TodoMeta.parse(item).cleanText)
                            .font(.callout)
                            .strikethrough(moved.contains(item), color: .secondary)
                            .foregroundStyle(moved.contains(item) ? .tertiary : .primary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func moveToTomorrow(_ item: String) {
        guard let url = store.journalURL(for: tomorrow), !moved.contains(item) else { return }
        EditorCore.requestAppend(to: url, text: "- [ ] \(item)\n")
        moved.insert(item)
    }

    /// Claude 的觀察與排程建議（來自 .hub/claude/insights.json）。
    @ViewBuilder
    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude 建議", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)

            if let insights = generalStore.insights {
                if !insights.message.isEmpty {
                    Text(insights.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let schedule = insights.schedule, !schedule.isEmpty {
                    Text(schedule)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.teal.opacity(0.08)))
                }
            } else {
                Text("還沒有 Claude 的建議。到 Claude 那邊說一聲「幫我排明天」就會出現。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
