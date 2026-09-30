import SwiftUI

/// /list 任務總覽：集中檢視、修改、刪除、新增所有帶日期標記的待辦。
/// 列內直接改原文（含 @ 標記）按 Enter 儲存；清空文字 = 刪除該行。
/// Mac 與 iPhone 共用（由編輯器命令列 /list 開啟）。
struct TaskManagerSheet: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(GeneralTodoStore.self) private var generalStore
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

        /// 已完成的每日副本數
        var doneCount: Int { copies.filter(\.done).count }

        /// 逐日完成明細（tooltip 用）
        var dayBreakdown: String {
            copies.sorted { $0.noteName < $1.noteName }
                .map { "\($0.noteName)  \($0.done ? "✓" : "—")" }
                .joined(separator: "\n")
        }
    }

    @State private var groups: [TaskGroup] = []
    @State private var drafts: [String: String] = [:]
    @State private var generalDrafts: [UUID: String] = [:]
    @State private var newText = ""
    @State private var searchText = ""
    /// est 直接輸入：正在編輯哪一列（group.id 或 "g-<uuid>"）與草稿字串
    @State private var estEditingID: String?
    @State private var estDraft = ""

    /// 一般待辦中帶日期類標記的
    private var generalItems: [GeneralTodo] {
        generalStore.todos.filter { todo in
            guard !todo.done else { return false }
            let meta = TodoMeta.parse(todo.text)
            return meta.due != nil || meta.from != nil || meta.everyWeekdays != nil
                || meta.onDates != nil || meta.remind != nil || meta.estMinutes != nil
        }
    }

    /// 關鍵字搜尋結果：同名條目歸一組（含已完成），看得到哪幾天做完。
    private struct SearchGroup: Identifiable {
        let key: String
        let items: [FileSystemStore.TodoItem]
        var id: String { key }
    }

    private var searchGroups: [SearchGroup] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var byKey: [String: [FileSystemStore.TodoItem]] = [:]
        for item in store.searchTodos(keyword: searchText) {
            byKey[item.meta.cleanText, default: []].append(item)
        }
        return byKey
            .map { SearchGroup(key: $0.key, items: $0.value.sorted { $0.noteName < $1.noteName }) }
            .sorted { ($0.items.last?.noteName ?? "") > ($1.items.last?.noteName ?? "") }
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
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                        TextField("搜尋所有待辦（含已完成，看哪幾天做完）", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                }

                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("搜尋結果") {
                        if searchGroups.isEmpty {
                            Text("沒有符合的條目。")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(searchGroups) { g in
                            searchRow(g)
                        }
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

    // MARK: - est 調整（一步 = 一顆蕃茄的分鐘數，跟蕃茄鐘設定連動）

    private static var pomoMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: PomodoroModel.SettingsKey.workMinutes)
        return v > 0 ? v : 25
    }

    private static func estLabel(_ m: Int?) -> String {
        guard let m, m > 0 else { return "🍅 —" }
        return "🍅 " + (m % 60 == 0 ? "\(m / 60)h" : "\(m)m")
    }

    /// 把 text 裡的 @est(...) 換成新值（0 = 移除；原本沒有就補在尾端）。
    private static func replacingEst(in text: String, minutes: Int) -> String {
        let hasEst = text.range(
            of: #"(?i)@est\([^)]*\)"#, options: .regularExpression) != nil
        if minutes <= 0 {
            guard hasEst else { return text }
            return text
                .replacingOccurrences(
                    of: #"(?i)\s*@est\([^)]*\)"#, with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let label = minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
        if hasEst {
            return text.replacingOccurrences(
                of: #"(?i)@est\([^)]*\)"#, with: "@est(\(label))", options: .regularExpression)
        }
        return text + " @est(\(label))"
    }

    /// est 控制：± 步進（一步 = 一顆蕃茄），點數值直接輸入 2h / 90m / 120。
    /// onSet 收到「絕對分鐘數」；0 = 移除 @est。
    private func estControl(
        id: String, minutes: Int?, onSet: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Button {
                onSet(max(0, (minutes ?? 0) - Self.pomoMinutes))
            } label: { Image(systemName: "minus") }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .disabled((minutes ?? 0) <= 0)
            if estEditingID == id {
                estField(onSet: onSet)
            } else {
                Button {
                    estEditingID = id
                    estDraft = (minutes ?? 0) > 0
                        ? (minutes! % 60 == 0 ? "\(minutes! / 60)h" : "\(minutes!)m") : ""
                } label: {
                    Text(Self.estLabel(minutes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
            }
            Button {
                onSet((minutes ?? 0) + Self.pomoMinutes)
            } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .help("預估時長 @est：± 一步 = \(Self.pomoMinutes) 分鐘；點數值直接輸入 2h / 90m / 120")
    }

    @ViewBuilder
    private func estField(onSet: @escaping (Int) -> Void) -> some View {
        let tf = TextField("2h", text: $estDraft)
            .textFieldStyle(.plain)
            .font(.caption2)
            .frame(width: 44)
            .onSubmit {
                if let m = TodoMeta.parseDuration(estDraft) {
                    onSet(max(0, m))
                }
                estEditingID = nil
            }
        #if os(macOS)
        tf.onExitCommand { estEditingID = nil }
        #else
        tf
        #endif
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
            estControl(id: group.id, minutes: group.rep.meta.estMinutes) { newVal in
                // 逐副本改自己的原文（保住各天不同的 @pomo 進度）
                for copy in group.copies {
                    let newText = Self.replacingEst(in: copy.text, minutes: newVal)
                    guard !newText.isEmpty else { continue }   // 只剩 est 的行：別誤刪
                    store.updateTodoLine(copy, newText: newText)
                }
                rescan()
            }
            Text(verbatim: group.sourceLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            // 多日播種的任務：顯示完成進度，滑鼠停留看逐日明細
            if group.copies.count > 1 {
                Text("✓\(group.doneCount)/\(group.copies.count)")
                    .font(.caption2)
                    .foregroundStyle(group.doneCount > 0 ? Color.green : Color.secondary)
                    .help(group.dayBreakdown)
            }
            Button {
                if let url = store.archiveTask(named: group.key, copies: group.copies) {
                    store.openNote(url)
                    dismiss()
                }
            } label: {
                Image(systemName: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("歸檔：把所有每日副本（含子項目）彙整成 Notes/Archive 筆記；日記不動")
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

    /// 搜尋結果列：條目 + 逐日 chips（✓ = 那天完成；點日期跳到那天的日記）。
    private func searchRow(_ g: SearchGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(g.key)
                .font(.callout)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(g.items) { item in
                        Button {
                            openItem(item)
                        } label: {
                            Text("\(item.noteName) \(item.done ? "✓" : "—")")
                                .font(.caption2)
                                .monospacedDigit()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    item.done
                                        ? Color.green.opacity(0.14)
                                        : Color.secondary.opacity(0.12),
                                    in: Capsule())
                                .foregroundStyle(item.done ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 點搜尋結果的某一天：日記日期就跳日記，筆記就開筆記。
    private func openItem(_ item: FileSystemStore.TodoItem) {
        let name = item.noteName
        if name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let date = df.date(from: name) {
                store.pendingJournalDate = Calendar.current.startOfDay(for: date)
                store.requestedTab = .journal
            }
        } else {
            store.openNote(item.noteURL)
        }
        dismiss()
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
            estControl(id: "g-\(todo.id)", minutes: TodoMeta.parse(todo.text).estMinutes) { newVal in
                let newText = Self.replacingEst(in: todo.text, minutes: newVal)
                guard !newText.isEmpty else { return }
                generalStore.updateText(todo, to: newText)
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
        // 同 cleanText 的每日副本歸一組（含已完成副本，才能顯示各天完成度）
        var byKey: [String: [FileSystemStore.TodoItem]] = [:]
        for item in store.markerTodos(includeDone: true) {
            byKey[item.meta.cleanText, default: []].append(item)
        }
        groups = byKey.map { key, copies in
            TaskGroup(key: key, copies: copies.sorted { $0.noteName > $1.noteName })
        }
        // 全部副本都完成的任務不再列出（維持「總覽 = 進行中」的語意）
        .filter { $0.copies.contains { !$0.done } }
        .sorted { ($0.rep.meta.due ?? .distantFuture) < ($1.rep.meta.due ?? .distantFuture) }
        drafts = [:]
    }
}
