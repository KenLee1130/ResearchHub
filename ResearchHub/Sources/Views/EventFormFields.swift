import SwiftUI
import HubStore
import HubCore

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
            Picker("重複", selection: frequencyBinding) {
                Text("不重複").tag(EventRepeat.Frequency?.none)
                ForEach(EventRepeat.Frequency.allCases, id: \.self) { f in
                    Text(f.everyLabel).tag(Optional(f))
                }
            }
            if let rule = draft.repeatRule {
                Stepper(value: intervalBinding, in: 1...99) {
                    HStack {
                        Text("間隔")
                        Spacer()
                        Text(rule.label).foregroundStyle(.secondary)
                    }
                }
                Toggle("有結束日", isOn: untilEnabledBinding)
                if let until = rule.until {
                    DatePicker("最後一次不晚於", selection: untilBinding(until), in: draft.start..., displayedComponents: [.date])
                }
            }
        } footer: {
            if draft.repeatRule != nil {
                Text("修改或刪除會套用整個系列。")
            }
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

    // MARK: 重複規則的 binding

    private var frequencyBinding: Binding<EventRepeat.Frequency?> {
        Binding(
            get: { draft.repeatRule?.frequency },
            set: { f in
                if let f {
                    if draft.repeatRule != nil { draft.repeatRule?.frequency = f }
                    else { draft.repeatRule = EventRepeat(frequency: f) }
                } else {
                    draft.repeatRule = nil
                }
            })
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { draft.repeatRule?.interval ?? 1 },
                set: { draft.repeatRule?.interval = max($0, 1) })
    }

    private var untilEnabledBinding: Binding<Bool> {
        Binding(
            get: { draft.repeatRule?.until != nil },
            set: { on in
                draft.repeatRule?.until = on
                    ? Calendar.current.date(byAdding: .month, value: 3, to: draft.start)
                    : nil
            })
    }

    private func untilBinding(_ current: Date) -> Binding<Date> {
        Binding(get: { draft.repeatRule?.until ?? current }, set: { draft.repeatRule?.until = $0 })
    }

    /// EventTag.colorHex ↔ ColorPicker 的 Color 轉接
    private func colorBinding(_ tag: Binding<EventTag>) -> Binding<Color> {
        Binding(
            get: { Color(hex: tag.wrappedValue.colorHex) },
            set: { tag.wrappedValue.colorHex = $0.hexString }
        )
    }
}

// MARK: - 重複規則的文字

extension EventRepeat.Frequency {
    /// 「每天」「每週」…（間隔 1）
    var everyLabel: String {
        switch self {
        case .daily: L("每天")
        case .weekly: L("每週")
        case .monthly: L("每月")
        case .yearly: L("每年")
        }
    }

    /// 「天」「週」「月」「年」（給「每 N 週」用）
    var unitLabel: String {
        switch self {
        case .daily: L("天")
        case .weekly: L("週")
        case .monthly: L("月")
        case .yearly: L("年")
        }
    }
}

extension EventRepeat {
    /// 「每週」或「每 2 週」；有結束日加「到 M/d」。
    var label: String {
        var text = interval == 1 ? frequency.everyLabel : String(localized: "每 \(interval) \(frequency.unitLabel)")
        if let until {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("Md")
            text += String(localized: "，到 \(f.string(from: until))")
        }
        return text
    }
}
