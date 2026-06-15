import SwiftUI

/// 新增 / 編輯事件的表單，含標籤管理（增刪、調色）。
struct EventEditorSheet: View {
    @EnvironmentObject private var eventStore: EventStore
    @Environment(\.dismiss) private var dismiss

    @State var draft: CalendarEvent
    let isNew: Bool

    @State private var newTagName = ""
    @State private var newTagColor = Color(hex: "#378ADD")
    @State private var showTagManager = false

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "新增事件" : "編輯事件")
                .font(.headline)
                .padding(.top, 14)

            Form {
                TextField("事件名稱", text: $draft.title)

                Toggle("全天", isOn: $draft.isAllDay)

                DatePicker(
                    "開始",
                    selection: $draft.start,
                    displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                DatePicker(
                    "結束",
                    selection: $draft.end,
                    in: draft.start...,
                    displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute]
                )

                Picker("標籤", selection: $draft.tagID) {
                    Text("無").tag(UUID?.none)
                    ForEach(eventStore.tags) { tag in
                        HStack {
                            Circle().fill(tag.color).frame(width: 8, height: 8)
                            Text(tag.name)
                        }
                        .tag(Optional(tag.id))
                    }
                }

                DisclosureGroup("管理標籤", isExpanded: $showTagManager) {
                    ForEach($eventStore.tags) { $tag in
                        HStack {
                            ColorPicker("", selection: colorBinding($tag))
                                .labelsHidden()
                                .frame(width: 36)
                            TextField("名稱", text: $tag.name)
                            Button(role: .destructive) {
                                eventStore.deleteTag(tag)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        ColorPicker("", selection: $newTagColor)
                            .labelsHidden()
                            .frame(width: 36)
                        TextField("新標籤名稱", text: $newTagName)
                        Button("新增") {
                            eventStore.addTag(name: newTagName, color: newTagColor)
                            newTagName = ""
                        }
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
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
        .frame(width: 380)
    }

    /// EventTag.colorHex ↔ ColorPicker 的 Color 轉接
    private func colorBinding(_ tag: Binding<EventTag>) -> Binding<Color> {
        Binding(
            get: { Color(hex: tag.wrappedValue.colorHex) },
            set: { tag.wrappedValue.colorHex = $0.hexString }
        )
    }
}
