#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// 新增 / 編輯事件的視窗，含標籤管理（增刪、調色）。欄位本體在 `EventFormFields`（與 iPhone 共用）。
struct EventEditorSheet: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(\.dismiss) private var dismiss

    @State var draft: CalendarEvent
    let isNew: Bool

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
                        eventStore.delete(draft)
                        dismiss()
                    } label: {
                        Text("刪除")
                    }
                    if let planID = draft.planID, let planTitle = draft.planTitle,
                       eventStore.events(inPlan: planID).count > 1 {
                        Button(role: .destructive) {
                            eventStore.deletePlan(planID)
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
                        eventStore.update(event)
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
}
#endif
