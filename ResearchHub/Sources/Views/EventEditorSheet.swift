#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// 新增 / 編輯事件的視窗，含標籤管理（增刪、調色）。欄位本體在 `EventFormFields`（與 iPhone 共用）。
struct EventEditorSheet: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(FileSystemStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State var draft: CalendarEvent
    let isNew: Bool
    /// 刪事件時把日記那一行退回「沒排時段」。日記頁會傳進來（那天開在編輯器時要改編輯器的文字）；
    /// 沒傳就由 store 直接改檔。
    var unscheduleLine: ((CalendarEvent) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "新增事件" : "編輯事件")
                .font(.headline)
                .padding(.top, 14)

            Form {
                EventFormFields(draft: $draft)
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button(role: .destructive) {
                        // 用存著的那份（表單裡的標題可能改到一半），日記那一行是照它寫的
                        let stored = eventStore.events.first { $0.id == draft.id } ?? draft
                        eventStore.delete(draft)
                        unschedule(stored)
                        dismiss()
                    } label: {
                        Text("刪除")
                    }
                    if let planID = draft.planID, let planTitle = draft.planTitle,
                       eventStore.events(inPlan: planID).count > 1 {
                        Button(role: .destructive) {
                            let sessions = eventStore.events(inPlan: planID)
                            eventStore.deletePlan(planID)
                            sessions.forEach(unschedule)
                            dismiss()
                        } label: {
                            Text("刪除整個規劃（\(eventStore.events(inPlan: planID).count) 段）")
                        }
                        .help("刪掉「\(planTitle)」規劃排出來的全部時段")
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "新增" : "儲存") {
                    var event = draft
                    if event.end < event.start { event.end = event.start }
                    if isNew {
                        eventStore.add(event)
                    } else {
                        let old = eventStore.events.first { $0.id == event.id }
                        let fixed = eventStore.applyingSeriesDates(event)
                        eventStore.update(fixed)
                        if let old { store.syncPlannedLine(from: old, to: fixed) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 440, height: 620)
    }

    private func unschedule(_ event: CalendarEvent) {
        if let unscheduleLine { unscheduleLine(event) } else { store.unscheduleLine(for: event) }
    }
}
#endif
