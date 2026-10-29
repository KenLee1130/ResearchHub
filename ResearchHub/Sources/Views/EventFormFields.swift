import SwiftUI
import HubStore

/// 事件表單的欄位（名稱、內容、全天、起訖、標籤、標籤管理）。
/// Mac 的 `EventEditorSheet` 與 iPhone 的 `MobileEventEditor` 共用；
/// 外殼（視窗／sheet、取消與儲存鈕）各平台自己排。放在 `Form` 裡用。
struct EventFormFields: View {
    @Environment(EventStore.self) private var eventStore
    @Binding var draft: CalendarEvent

    @State private var newTagName = ""
    @State private var newTagColor = Color(hex: "#378ADD")
    @State private var showTagManager = false

    var body: some View {
        Section {
            TextField("事件名稱", text: $draft.title)
        }

        Section("內容") {
            #if os(macOS)
            TextEditor(text: $draft.notes)
                .font(.body)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if draft.notes.isEmpty {
                        Text("這件事具體要做什麼？")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            #else
            TextField("這件事具體要做什麼？", text: $draft.notes, axis: .vertical)
                .lineLimit(3...8)
            #endif
        }

        Section {
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
        }
        // 改開始時間：結束跟著平移，維持原本的長度（手機上不用再調一次結束）
        .onChange(of: draft.start) { old, new in
            let duration = draft.end.timeIntervalSince(old)
            draft.end = new.addingTimeInterval(max(duration, 0))
        }

        Section {
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
                ForEach(Bindable(eventStore).tags) { $tag in
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
    }

    /// EventTag.colorHex ↔ ColorPicker 的 Color 轉接
    private func colorBinding(_ tag: Binding<EventTag>) -> Binding<Color> {
        Binding(
            get: { Color(hex: tag.wrappedValue.colorHex) },
            set: { tag.wrappedValue.colorHex = $0.hexString }
        )
    }
}
