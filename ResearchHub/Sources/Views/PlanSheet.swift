#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// Mac 的「規劃」視窗：第一步填目標、目標日、總時數、每段長度（欄位在 `PlanFormFields`，與 iPhone 共用），
/// 第二步預覽排出的時段（可逐段調時間或刪掉），確認後一次寫進 `.hub/events.json`。
struct PlanSheet: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(\.dismiss) private var dismiss

    @State var draft: PlanDraft
    @State private var preview: [CalendarEvent]?
    @State private var unplaced = 0
    /// 每段自己寫的「要做什麼」
    @State private var details: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Text(preview == nil ? "規劃時段" : "預覽：\(draft.goal.trimmingCharacters(in: .whitespaces))")
                .font(.headline)
                .padding(.top, 14)

            if let events = preview {
                previewList(events)
            } else {
                Form {
                    PlanFormFields(draft: $draft)
                }
                .formStyle(.grouped)
            }

            HStack {
                if preview != nil {
                    Button("返回修改") { preview = nil }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let events = preview {
                    if draft.mode == .custom {
                        Button("加一段") { addSession() }
                    }
                    Button("加入行事曆（\(events.count) 段）") {
                        eventStore.add(contentsOf: PlanDraft.finalize(events, details: details))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(events.isEmpty)
                } else {
                    Button("預覽時段") { runSchedule() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isValid)
                }
            }
            .padding(14)
        }
        .frame(width: 480, height: 640)
    }

    private func previewList(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanPreviewSummary(placed: events.count, unplaced: unplaced, custom: draft.mode == .custom)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            if events.isEmpty {
                Spacer()
                Text("一段都排不進去。回去改目標日、每段長度或每天上限。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(events) { event in
                        PlanSessionRow(
                            event: binding(for: event.id),
                            detail: detailBinding(for: event.id),
                            conflict: PlanDraft.conflicts(event, existing: eventStore.events),
                            onDelete: { remove(event.id) })
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func runSchedule() {
        let result = draft.schedule(eventStore: eventStore, pomodoro: pomodoro)
        preview = result.events
        unplaced = result.unplacedCount
    }

    private func binding(for id: UUID) -> Binding<CalendarEvent> {
        Binding(
            get: { preview?.first { $0.id == id } ?? CalendarEvent(title: "", isAllDay: false, start: .now, end: .now) },
            set: { new in
                guard var events = preview, let i = events.firstIndex(where: { $0.id == id }) else { return }
                events[i] = new
                preview = events
            })
    }

    private func remove(_ id: UUID) {
        guard var events = preview else { return }
        events.removeAll { $0.id == id }
        details[id] = nil
        PlanDraft.renumber(&events, draft: draft)
        preview = events
    }

    private func addSession() {
        var events = preview ?? []
        let peak = pomodoro.productivityProfile(days: 60).peakWindowStart
        events.append(draft.newSession(after: events, existing: eventStore.events, peakHour: peak))
        PlanDraft.renumber(&events, draft: draft)
        preview = events
    }

    private func detailBinding(for id: UUID) -> Binding<String> {
        Binding(get: { details[id] ?? "" }, set: { details[id] = $0 })
    }
}
#endif
