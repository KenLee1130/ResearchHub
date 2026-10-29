#if os(iOS)
import SwiftUI
import HubStore
import HubCore

/// 一次 sheet 的設定（sheet(item:) 需要 Identifiable）。
struct MobileEventSheet: Identifiable {
    let id = UUID()
    var draft: CalendarEvent
    var isNew: Bool

    /// 某天的新事件：今天從下一個整點起，其他天從 09:00 起，長一小時。
    static func new(on day: Date, tag: EventTag?, calendar: Calendar = .current) -> MobileEventSheet {
        let base: Date
        if calendar.isDateInToday(day) {
            let hour = calendar.component(.hour, from: .now) + 1
            base = calendar.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: day) ?? day
        } else {
            base = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        }
        let end = calendar.date(byAdding: .hour, value: 1, to: base) ?? base
        return MobileEventSheet(
            draft: CalendarEvent(title: "", isAllDay: false, start: base, end: end, tagID: tag?.id),
            isNew: true)
    }
}

/// 手機版的事件表單：欄位與 Mac 共用（EventFormFields），外殼是 NavigationStack + 取消／儲存。
struct MobileEventEditor: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(\.dismiss) private var dismiss

    @State var draft: CalendarEvent
    let isNew: Bool
    @State private var confirmDelete = false
    @State private var confirmDeletePlan = false

    /// 這個事件所屬規劃的全部時段（含自己）
    private var planEvents: [CalendarEvent] {
        draft.planID.map { eventStore.events(inPlan: $0) } ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                EventFormFields(draft: $draft)
                if !isNew {
                    Section {
                        Button("刪除事件", role: .destructive) { confirmDelete = true }
                            .frame(maxWidth: .infinity)
                        if let planTitle = draft.planTitle, planEvents.count > 1 {
                            Button("刪除整個規劃「\(planTitle)」（\(planEvents.count) 段）", role: .destructive) {
                                confirmDeletePlan = true
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        if let planTitle = draft.planTitle {
                            Text("這一段是「\(planTitle)」規劃排出來的。")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新增事件" : "編輯事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "新增" : "儲存") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("刪除這個事件？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("刪除", role: .destructive) {
                    eventStore.delete(draft)
                    dismiss()
                }
            }
            .confirmationDialog("刪除這個規劃的全部 \(planEvents.count) 段？", isPresented: $confirmDeletePlan,
                                titleVisibility: .visible) {
                Button("全部刪除", role: .destructive) {
                    if let planID = draft.planID { eventStore.deletePlan(planID) }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        var event = draft
        event.title = event.title.trimmingCharacters(in: .whitespaces)
        if event.end < event.start { event.end = event.start }
        if isNew { eventStore.add(event) } else { eventStore.update(eventStore.applyingSeriesDates(event)) }
        dismiss()
    }
}

// MARK: - 共用的事件列

/// 事件一列：標籤色條、標題、時間（全天／跨日都講清楚）。今天與行事曆分頁共用。
struct MobileEventRow: View {
    let event: CalendarEvent
    let tag: EventTag?
    var showNotes = false

    private var calendar: Calendar { .current }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tag?.color ?? .gray)
                .frame(width: 4)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body)
                if let planTitle = event.planTitle {
                    PlanBadge(title: planTitle, color: tag?.color ?? .gray)
                }
                HStack(spacing: 6) {
                    Text(verbatim: timeString)
                    if let rule = event.repeatRule {
                        Label(rule.label, systemImage: "repeat")
                            .labelStyle(.titleAndIcon)
                    }
                    if let tag {
                        Text(verbatim: "· \(tag.name)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showNotes, !event.notes.isEmpty {
                    Text(event.notes)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var timeString: String {
        let sameDay = calendar.isDate(event.start, inSameDayAs: event.end)
        // 與 Mac 版同一種寫法：24 小時制、M/d
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.dateFormat = "M/d"
        if event.isAllDay {
            let allDay = L("全天")
            return sameDay ? allDay
                : "\(day.string(from: event.start))–\(day.string(from: event.end)) \(allDay)"
        }
        if sameDay {
            return "\(time.string(from: event.start))–\(time.string(from: event.end))"
        }
        return "\(day.string(from: event.start)) \(time.string(from: event.start)) – "
            + "\(day.string(from: event.end)) \(time.string(from: event.end))"
    }
}
#endif
