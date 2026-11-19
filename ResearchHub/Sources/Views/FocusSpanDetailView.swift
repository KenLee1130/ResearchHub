#if os(macOS)
import SwiftUI
import HubCore
import HubStore

/// 點時間軸上的蕃茄鐘紅線跳出來的小卡：這段做了什麼（計畫／完成）、
/// 那時排的行程、聽了哪些歌（iPhone 連 Spotify 時記下的）。
/// 正在跑的那段還沒有完成內容與歌單，只顯示計畫跟已經專注多久。
struct FocusSpanDetailView: View {
    let span: FocusSpan
    /// 這條紅線背後的那筆完成紀錄（進行中的沒有）
    let session: PomodoroSession?
    /// 當天的事件：挑出跟這段重疊的
    let events: [CalendarEvent]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            whatSection
            if !overlapping.isEmpty { eventsSection }
            tracksSection
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    // MARK: - 這段的範圍

    private var isFlow: Bool {
        session?.isFlow ?? (span.liveState?.kind == .flow)
    }

    /// 整段（無限模式含中間離開的時間）
    private var range: (start: Date, end: Date) {
        if let session {
            return (session.startedAt ?? session.date.addingTimeInterval(-Double(session.minutes) * 60), session.date)
        }
        if let state = span.liveState, let start = state.startedAt {
            return (start, min(now, state.phaseEndAt ?? now))
        }
        return (span.start, span.end)
    }

    private var workMinutes: Int {
        if let session { return session.minutes }
        let seconds = (span.liveState?.workSpans(at: now) ?? [PomodoroSpan(start: span.start, end: span.end)])
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        return Int(seconds / 60)
    }

    private var awayMinutes: Int {
        let total = Int(range.end.timeIntervalSince(range.start) / 60)
        return max(total - workMinutes, 0)
    }

    private var plan: String {
        (session?.plan ?? span.liveState?.plan ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var done: String {
        (session?.done ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var overlapping: [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.start < range.end && $0.end > range.start }
            .sorted { $0.start < $1.start }
    }

    private var tracks: [String] { session?.tracks ?? [] }

    // MARK: - 區塊

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isFlow ? "infinity" : "timer")
                    .foregroundStyle(.red)
                Text(isFlow ? L("無限模式") : L("蕃茄鐘"))
                    .font(.headline)
                if span.live {
                    Text(deviceText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
                Spacer(minLength: 0)
            }
            Text(DayTimelineView.rangeText(range.start, range.end))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(L("專注 \(DayTimelineView.hoursText(workMinutes))"), systemImage: "brain.head.profile")
                if isFlow, awayMinutes > 0 {
                    Label(L("離開 \(DayTimelineView.hoursText(awayMinutes))"), systemImage: "figure.walk")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
    }

    private var deviceText: String {
        span.liveState?.device == "iphone" ? L("iPhone 進行中") : L("Mac 進行中")
    }

    @ViewBuilder private var whatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("做了什麼"), systemImage: "checklist")
            if plan.isEmpty && done.isEmpty {
                Text(span.live ? L("開始時沒寫要做什麼") : L("這段沒有寫計畫或完成內容"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                if !plan.isEmpty { labeled(L("計畫"), plan) }
                if !done.isEmpty { labeled(L("完成"), done) }
            }
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("當時的行程"), systemImage: "calendar")
            ForEach(overlapping) { event in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DayTimelineView.rangeText(event.start, event.end))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("聽的歌"), systemImage: "music.note")
            if span.live {
                Text(L("結束後會記下這段聽的歌"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if tracks.isEmpty {
                Text(L("沒有聽歌紀錄"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Text(L("在 iPhone 設定連結 Spotify 後，蕃茄鐘結束時會記下這段聽的歌。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                            trackRow(track)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: tracks.count <= 6)
            }
        }
    }

    // MARK: - 小元件

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .leading)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 紀錄格式是「歌名 — 歌手」
    private func trackRow(_ track: String) -> some View {
        let parts = track.components(separatedBy: " — ")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "music.note")
                .font(.caption2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 0) {
                Text(parts.first ?? track)
                    .font(.callout)
                    .lineLimit(1)
                if parts.count > 1 {
                    Text(parts.dropFirst().joined(separator: " — "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(Text(track))
    }
}
#endif
