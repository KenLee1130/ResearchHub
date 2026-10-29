#if os(iOS)
import SwiftUI
import HubStore
import HubCore

/// iPhone 的「規劃」sheet：第一頁填表單（欄位在 `PlanFormFields`，與 Mac 共用），
/// 「預覽」推到第二頁看排出的時段（可調時間、左滑刪除），「加入行事曆」一次寫進 events.json。
struct MobilePlanSheet: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(\.dismiss) private var dismiss

    @State var draft: PlanDraft
    @State private var preview: [CalendarEvent] = []
    @State private var unplaced = 0
    @State private var showPreview = false
    /// 每段自己取的名稱（空白＝自動編號）
    @State private var titles: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                PlanFormFields(draft: $draft)
            }
            .navigationTitle("規劃時段")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("預覽") {
                        let result = draft.schedule(eventStore: eventStore, pomodoro: pomodoro)
                        preview = result.events
                        unplaced = result.unplacedCount
                        showPreview = true
                    }
                    .disabled(!draft.isValid)
                }
            }
            .navigationDestination(isPresented: $showPreview) {
                previewPage
            }
        }
    }

    private var previewPage: some View {
        List {
            Section {
                PlanPreviewSummary(placed: preview.count, unplaced: unplaced, custom: draft.mode == .custom)
            }
            Section {
                if preview.isEmpty && draft.mode != .custom {
                    Text("一段都排不進去。回去改目標日、每段長度或每天上限，或直接「加一段」。")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(preview.enumerated()), id: \.element.id) { i, event in
                    PlanSessionRow(
                        index: i + 1,
                        event: $preview[i],
                        title: titleBinding(for: event.id),
                        conflict: PlanDraft.conflicts(event, existing: eventStore.events),
                        onDelete: { remove(event.id) })
                }
                .onDelete { offsets in
                    var events = preview
                    for i in offsets { titles[events[i].id] = nil }
                    events.remove(atOffsets: offsets)
                    PlanDraft.renumber(&events, draft: draft)
                    preview = events
                }
                Button {
                    addSession()
                } label: {
                    Label("加一段", systemImage: "plus")
                }
            } header: {
                Text(draft.goal.trimmingCharacters(in: .whitespaces))
            }
        }
        .navigationTitle("預覽")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("加入行事曆") {
                    eventStore.add(contentsOf: PlanDraft.finalize(preview, titles: titles, draft: draft))
                    dismiss()
                }
                .disabled(preview.isEmpty)
            }
        }
    }

    private func remove(_ id: UUID) {
        var events = preview
        events.removeAll { $0.id == id }
        titles[id] = nil
        PlanDraft.renumber(&events, draft: draft)
        preview = events
    }

    private func addSession() {
        var events = preview
        let peak = pomodoro.productivityProfile(days: 60).peakWindowStart
        events.append(draft.newSession(after: events, existing: eventStore.events, peakHour: peak))
        PlanDraft.renumber(&events, draft: draft)
        preview = events
    }

    private func titleBinding(for id: UUID) -> Binding<String> {
        Binding(get: { titles[id] ?? "" }, set: { titles[id] = $0 })
    }
}
#endif
