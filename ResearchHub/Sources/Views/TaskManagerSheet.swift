import SwiftUI

/// /list 任務總覽：集中檢視、修改、刪除、新增所有帶日期標記的待辦。
/// 列內直接改原文（含 @ 標記）按 Enter 儲存；清空文字 = 刪除該行。
/// Mac 與 iPhone 共用（由編輯器命令列 /list 開啟）。
struct TaskManagerSheet: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var generalStore: GeneralTodoStore
    @Environment(\.dismiss) private var dismiss

    /// 同一任務的每日副本歸成一組：改／刪一次套用到所有副本。
    struct TaskGroup: Identifiable {
        let key: String                          // cleanText
        let copies: [FileSystemStore.TodoItem]   // 依來源檔名排序
        var rep: FileSystemStore.TodoItem { copies[0] }
        var id: String { key }

        /// 來源標示：單一來源顯示檔名；多副本顯示範圍 ×N
        var sourceLabel: String {
            let names = copies.map(\.noteName).sorted()
            if names.count == 1 { return names[0] }
            return "\(names.first!) ~ \(names.last!) ×\(names.count)"
        }
    }

    @State private var groups: [TaskGroup] = []
    @State private var drafts: [String: String] = [:]
    @State private var generalDrafts: [UUID: String] = [:]
    @State private var newText = ""

    /// 一般待辦中帶日期類標記的
    private var generalItems: [GeneralTodo] {
        generalStore.todos.filter { todo in
            guard !todo.done else { return false }
            let meta = TodoMeta.parse(todo.text)
            return meta.due != nil || meta.from != nil || meta.everyWeekdays != nil
                || meta.remind != nil || meta.estMinutes != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("任務總覽", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("新增到今天：讀 CFT @due(7/20) @est(2h)", text: $newText)
                            .textFieldStyle(.plain)
                            .onSubmit(addNew)
                        Button(action: addNew) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !groups.isEmpty {
                    Section("日記與筆記") {
                        ForEach(groups) { group in
                            fileRow(group)
                        }
                    }
                }

                if !generalItems.isEmpty {
                    Section("一般待辦") {
                        ForEach(generalItems) { todo in
                            generalRow(todo)
                        }
                    }
                }

                if groups.isEmpty && generalItems.isEmpty {
                    Text("還沒有帶日期標記的任務。")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            Text("直接改文字後按 Enter 儲存；清空文字＝刪除該行。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(8)
        }
        #if os(macOS)
        .frame(width: 640, height: 520)
        #endif
        .onAppear(perform: rescan)
    }

    // MARK: - Rows

    private func fileRow(_ group: TaskGroup) -> some View {
        HStack(spacing: 8) {
            TextField("", text: Binding(
                get: { drafts[group.id] ?? group.rep.text },
                set: { drafts[group.id] = $0 }))
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit {
                    // 一次套用到所有每日副本
                    for copy in group.copies {
                        store.updateTodoLine(copy, newText: drafts[group.id])
                    }
                    rescan()
                }
            Text(verbatim: group.sourceLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button {
                for copy in group.copies {
                    store.updateTodoLine(copy, newText: nil)
                }
                rescan()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("刪除（所有副本一起）")
        }
    }

    private func generalRow(_ todo: GeneralTodo) -> some View {
        HStack(spacing: 8) {
            TextField("", text: Binding(
                get: { generalDrafts[todo.id] ?? todo.text },
                set: { generalDrafts[todo.id] = $0 }))
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit {
                    generalStore.updateText(todo, to: generalDrafts[todo.id] ?? todo.text)
                    generalDrafts[todo.id] = nil
                }
            Text("一般待辦")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                generalStore.updateText(todo, to: "")
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("刪除")
        }
    }

    // MARK: - Actions

    private func addNew() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.appendTodoLine(t, on: .now)
        newText = ""
        rescan()
    }

    private func rescan() {
        // 同 cleanText 的每日副本歸一組
        var byKey: [String: [FileSystemStore.TodoItem]] = [:]
        for item in store.markerTodos() {
            byKey[item.meta.cleanText, default: []].append(item)
        }
        groups = byKey.map { key, copies in
            TaskGroup(key: key, copies: copies.sorted { $0.noteName > $1.noteName })
        }
        .sorted { ($0.rep.meta.due ?? .distantFuture) < ($1.rep.meta.due ?? .distantFuture) }
        drafts = [:]
    }
}
