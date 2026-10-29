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
                PlanPreviewSummary(placed: preview.count, unplaced: unplaced)
            }
            if preview.isEmpty {
                Text("一段都排不進去。回去改目標日、每段長度或每天上限。")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach($preview) { $event in
                        PlanSessionRow(
                            event: $event,
                            conflict: PlanDraft.conflicts(event, existing: eventStore.events),
                            onDelete: { remove(event.id) })
                    }
                    .onDelete { offsets in
                        var events = preview
                        events.remove(atOffsets: offsets)
                        PlanDraft.renumber(&events, draft: draft)
                        preview = events
                    }
                } header: {
                    Text(draft.goal.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        .navigationTitle("預覽")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("加入行事曆") {
                    eventStore.add(contentsOf: preview)
                    dismiss()
                }
                .disabled(preview.isEmpty)
            }
        }
    }

    private func remove(_ id: UUID) {
        var events = preview
        events.removeAll { $0.id == id }
        PlanDraft.renumber(&events, draft: draft)
        preview = events
    }
}
#endif
