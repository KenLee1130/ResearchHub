#if os(macOS)
import SwiftUI
import HubStore
import HubCore

/// Mac 的「規劃」視窗：第一步填目標、目標日、總時數、每段長度（欄位在 `PlanFormFields`，與 iPhone 共用），
/// 第二步預覽排出的時段（可逐段調時間或刪掉），確認後一次寫進 `.hub/events.json`。
/// 開在可拖曳的獨立浮動視窗（`PlanWindowController`），規劃時還能看得到後面的時間軸。
struct PlanSheet: View {
    @Environment(EventStore.self) private var eventStore
    @Environment(FileSystemStore.self) private var store
    @Environment(PomodoroModel.self) private var pomodoro
    @Environment(\.dismiss) private var dismiss
    /// 開在獨立視窗（`PlanWindowController`）時由它關窗；當 sheet 用時留 nil
    var onClose: (() -> Void)? = nil
    /// 加入行事曆時同時寫進各天日記最上面
    @AppStorage("plan.writeToJournal") private var writeToJournal = true

    @State var draft: PlanDraft
    @State private var preview: [CalendarEvent]?
    @State private var unplaced = 0
    /// 每段自己取的名稱（空白＝自動編號）
    @State private var titles: [UUID: String] = [:]

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
                Button("取消") { close() }
                if let events = preview {
                    Toggle("也寫進日記", isOn: $writeToJournal)
                        .toggleStyle(.checkbox)
                        .help("每一段寫成當天日記最上面的待辦（- [ ] 10:00–12:00 …），用 --- 跟下面隔開")
                    Button("加入行事曆（\(events.count) 段）") {
                        let final = PlanDraft.finalize(events, titles: titles, draft: draft)
                        eventStore.add(contentsOf: final)
                        if writeToJournal { store.addPlannedEvents(final) }
                        close()
                    }
                    .disabled(events.isEmpty)
                } else {
                    Button("預覽時段") { runSchedule() }
                        .disabled(!draft.isValid)
                }
            }
            .padding(14)
        }
        .frame(width: 480, height: 640)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func previewList(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanPreviewSummary(placed: events.count, unplaced: unplaced, custom: draft.mode == .custom)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            List {
                if events.isEmpty && draft.mode != .custom {
                    Text("一段都排不進去。回去改目標日、每段長度或每天上限，或直接「加一段」。")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(events.enumerated()), id: \.element.id) { i, event in
                    PlanSessionRow(
                        index: i + 1,
                        event: binding(for: event.id),
                        title: titleBinding(for: event),
                        conflict: PlanDraft.conflicts(event, existing: eventStore.events),
                        onDelete: { remove(event.id) })
                    .padding(.vertical, 4)
                }
                Button {
                    addSession()
                } label: {
                    Label("加一段", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
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
        titles[id] = nil
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

    /// 欄位裡顯示的是自動編號的標題，使用者直接在上面改；
    /// 改回跟自動編號一模一樣（或清空）就當沒改，之後刪段重編號時標題才會跟著變。
    private func titleBinding(for event: CalendarEvent) -> Binding<String> {
        Binding(
            get: { titles[event.id] ?? event.title },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                titles[event.id] = (trimmed.isEmpty || trimmed == event.title) ? nil : new
            })
    }
}

/// 「規劃時段」的獨立視窗：可拖曳（整片背景都能拖）、浮在主視窗上面、不擋主視窗操作。
/// 已經開著就帶到前面，不另開一個。
@MainActor
final class PlanWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func show(draft: PlanDraft, eventStore: EventStore, store: FileSystemStore,
              pomodoro: PomodoroModel, locale: Locale, over parent: NSWindow?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = L("規劃時段")
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView:
            PlanSheet(onClose: { [weak self] in self?.window?.close() }, draft: draft)
                .environment(eventStore)
                .environment(store)
                .environment(pomodoro)
                .environment(\.locale, locale))
        if let parent {
            let p = parent.frame
            panel.setFrameOrigin(NSPoint(x: p.midX - 240, y: p.midY - 320))
        } else {
            panel.center()
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
#endif
