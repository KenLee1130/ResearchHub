#if os(iOS)
import SwiftUI
import HubEditor
import HubStore
import HubCore

/// 「今天」分頁：手機優先的原生畫面——當天待辦（打勾、快速新增、滑動放棄／搬到明天）、
/// 當天事件、Claude 觀察與排程建議、日記摘要；完整的日記編輯器另開一頁。
/// 資料都直接讀寫當天的日記檔（與 Mac 同一份），不經過網頁編輯器。
struct MobileTodayView: View {
    @Environment(FileSystemStore.self) private var store
    @Environment(EventStore.self) private var eventStore
    @Environment(GeneralTodoStore.self) private var generalTodos
    @Environment(MobileNavigation.self) private var nav
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var todos: [LibraryTodoItem] = []
    @State private var excerpt = ""
    @State private var newTodo = ""
    @State private var showPlanning = false
    @State private var showTaskManager = false
    @State private var showDatePicker = false
    @State private var eventSheet: MobileEventSheet?
    @State private var showPlanSheet = false
    @State private var path = NavigationPath()
    @FocusState private var quickAddFocused: Bool

    private let calendar = Calendar.current
    private var isToday: Bool { calendar.isDateInToday(selectedDate) }
    private var journalURL: URL? { store.journalURL(for: selectedDate) }
    private var appLocale: Locale { AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if AppContainer.shared.librarySync.pendingCount > 0 {
                    Section { LibrarySyncBanner() }
                }
                if isToday { insightsSection }
                todoSection
                eventSection
                journalSection
                inboxSection
            }
            .listSectionSpacing(14)
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                    Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isToday {
                        Button("今天") { switchTo(.now) }
                    }
                    Menu {
                        Button { showDatePicker = true } label: {
                            Label("選擇日期…", systemImage: "calendar")
                        }
                        Button { showTaskManager = true } label: {
                            Label("任務總覽", systemImage: "list.bullet.rectangle")
                        }
                        Button { showPlanning = true } label: {
                            Label("規劃明天", systemImage: "moon.stars")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .navigationDestination(for: Date.self) { date in
                MobileJournalEditorView(date: date)
            }
            .navigationDestination(for: String.self) { key in
                if key == "inbox" { MobileInboxList() }
            }
            .sheet(isPresented: $showPlanning, onDismiss: reload) {
                MobilePlanningSheet()
            }
            .sheet(isPresented: $showTaskManager, onDismiss: reload) {
                TaskManagerSheet()
            }
            .sheet(isPresented: $showPlanSheet) {
                MobilePlanSheet(draft: PlanDraft.initial(near: selectedDate, tag: eventStore.tags.first))
            }
            .sheet(item: $eventSheet) { config in
                MobileEventEditor(draft: config.draft, isNew: config.isNew)
            }
            .sheet(isPresented: $showDatePicker) {
                DatePicker(
                    "選擇日期",
                    selection: Binding(
                        get: { selectedDate },
                        set: { date in
                            showDatePicker = false
                            switchTo(date)
                        }),
                    displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .presentationDetents([.medium])
            }
            .onAppear {
                consumePendingDate()
                reload()
            }
            .onChange(of: nav.requestedDate) { consumePendingDate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { reload() }
            }
            // Mac 經 iCloud 改了這天的日記 → 列表跟著更新
            .onReceive(AppContainer.shared.librarySync.changes) { change in
                if change.affects(journalURL) { reload() }
            }
            .refreshable {
                AppContainer.shared.librarySync.syncNow()
                generalTodos.reload()
                reload()
            }
        }
    }

    // MARK: - 區塊

    @ViewBuilder
    private var insightsSection: some View {
        if let insights = generalTodos.insights, !insights.message.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Claude 觀察", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                    Text(insights.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let schedule = insights.schedule?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !schedule.isEmpty {
                        Divider()
                        Label("今日排程建議", systemImage: "clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                        Text(schedule)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.purple.opacity(0.08))
        }
    }

    private var openTodos: [LibraryTodoItem] { todos.filter { !$0.done } }
    private var doneTodos: [LibraryTodoItem] { todos.filter(\.done) }

    private var todoSection: some View {
        Section {
            ForEach(openTodos) { todo in
                todoRow(todo)
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                TextField("新增待辦…", text: $newTodo)
                    .focused($quickAddFocused)
                    .submitLabel(.done)
                    .onSubmit(addTodo)
            }
            ForEach(doneTodos) { todo in
                todoRow(todo)
            }
        } header: {
            HStack {
                Text(isToday ? "今天要做的" : "那天要做的")
                Spacer()
                if !todos.isEmpty {
                    Text(verbatim: "\(doneTodos.count)/\(todos.count)")
                        .monospacedDigit()
                }
            }
        } footer: {
            if openTodos.isEmpty, doneTodos.isEmpty {
                Text("還沒有待辦。打一句就加進這天的日記。")
            }
        }
    }

    private func todoRow(_ todo: LibraryTodoItem) -> some View {
        let m = todo.meta
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { toggle(todo) }
            } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.done ? AnyShapeStyle(.green)
                                     : m.priority == .high ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(m.cleanText)
                    .strikethrough(todo.done)
                    .foregroundStyle(todo.done ? .secondary : .primary)
                if !todo.done, hasBadges(m) {
                    HStack(spacing: 6) {
                        if m.priority == .high {
                            badge(L("重要"), .red)
                        }
                        if let due = m.due {
                            badge(dueLabel(due), m.isOverdue ? .red : .orange)
                        }
                        if let est = m.estMinutes {
                            badge(estLabel(est), .secondary)
                        }
                        if let line = m.line {
                            badge("@\(line)", .blue)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { toggle(todo) } }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !todo.done {
                Button {
                    abandon(todo)
                } label: {
                    Label("放棄", systemImage: "xmark.circle")
                }
                .tint(.orange)
                Button {
                    moveToTomorrow(todo)
                } label: {
                    Label("明天", systemImage: "arrow.turn.down.right")
                }
                .tint(.blue)
            }
        }
    }

    private func hasBadges(_ m: TodoMeta) -> Bool {
        m.priority == .high || m.due != nil || m.estMinutes != nil || m.line != nil
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func dueLabel(_ due: Date) -> String {
        if calendar.isDate(due, inSameDayAs: selectedDate) { return L("今天到期") }
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("Md")
        return L("到期") + " " + f.string(from: due)
    }

    private func estLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes > 60 { return String(format: "%.1fh", Double(minutes) / 60) }
        return "\(minutes)m"
    }

    private var eventSection: some View {
        Section {
            let events = eventStore.events(on: selectedDate)
            ForEach(events) { event in
                Button {
                    eventSheet = MobileEventSheet(draft: event, isNew: false)
                } label: {
                    MobileEventRow(event: event, tag: eventStore.tag(for: event.tagID),
                                   done: store.isPlannedEventDone(event))
                }
                .buttonStyle(.plain)
            }
            Button {
                showPlanSheet = true
            } label: {
                Label("新增", systemImage: "calendar.badge.plus")
            }
        } header: {
            Text(isToday ? "今日事件" : "當日事件")
        }
    }

    private var journalSection: some View {
        Section {
            NavigationLink(value: selectedDate) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(isToday ? "今日日記" : "當日日記", systemImage: "book")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(excerpt.isEmpty ? L("點一下開始寫…") : excerpt)
                        .font(.callout)
                        .foregroundStyle(excerpt.isEmpty ? .tertiary : .primary)
                        .lineLimit(4)
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text("待辦與事件在上面直接改；長一點的內容進日記寫。")
        }
    }

    private var inboxSection: some View {
        Section {
            NavigationLink(value: "inbox") {
                HStack {
                    Label("一般待辦", systemImage: "tray.full")
                    Spacer()
                    let n = generalTodos.todos.filter { !$0.done }.count
                    if n > 0 {
                        Text(verbatim: "\(n)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        } footer: {
            Text("想到但還沒排時間的事放這裡，不綁日期。")
        }
    }

    // MARK: - 動作

    private func toggle(_ todo: LibraryTodoItem) {
        store.toggleTodo(todo)
        reload()
    }

    private func abandon(_ todo: LibraryTodoItem) {
        withAnimation(.easeOut(duration: 0.2)) {
            store.abandonTodo(todo)
            reload()
        }
    }

    /// 搬到明天：明天的日記加一行副本，這天的改成已放棄（不算拖延）
    private func moveToTomorrow(_ todo: LibraryTodoItem) {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: selectedDate) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            store.appendTodoLine(todo.text, on: tomorrow)
            store.abandonTodo(todo)
            reload()
        }
    }

    private func addTodo() {
        let text = newTodo.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        store.appendTodoLine(text, on: selectedDate)
        newTodo = ""
        reload()
        quickAddFocused = true
    }

    private func shiftDay(_ delta: Int) {
        guard let d = calendar.date(byAdding: .day, value: delta, to: selectedDate) else { return }
        switchTo(d)
    }

    private func switchTo(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        reload()
    }

    /// 行事曆分頁（或 researchhub://journal?date=）要求看某一天
    private func consumePendingDate() {
        guard let date = nav.requestedDate else { return }
        nav.requestedDate = nil
        path = NavigationPath()   // 正在看日記編輯器也先退回列表
        switchTo(date)
    }

    /// 重讀這天：先播種（@due/@every 副本，只對今天以後生效），再從檔案取待辦與摘要。
    private func reload() {
        store.seedTodos(
            for: selectedDate,
            generalTexts: generalTodos.todos.filter { !$0.done }.map(\.text))
        guard let url = journalURL else {
            todos = []
            excerpt = ""
            return
        }
        let lines = LibraryIndex.shared.todoLines(in: url) ?? []
        todos = lines.map {
            LibraryTodoItem(noteURL: url, lineIndex: $0.lineIndex, text: $0.text,
                            done: $0.done, meta: $0.meta)
        }
        let content = FileSystemStore.safeRead(url) ?? ""
        // 只拿真正的散文行：剩一個編號的空清單項（「4.」）不算
        let prose = JournalClassifier.analyze(content).proseLines.filter {
            $0.range(of: #"^\d+\.?$"#, options: .regularExpression) == nil && $0.count > 1
        }
        var text = prose.prefix(3).joined(separator: " ")
        if text.count > 160 { text = String(text.prefix(160)) + "…" }
        excerpt = text
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate("MdEEE")
        return f.string(from: selectedDate)
    }
}

// MARK: - 日記編輯器（整頁）

/// 當天日記的完整編輯器（與 Mac 共用 block 編輯器與 EditorDocument），從「今天」分頁推進來。
struct MobileJournalEditorView: View {
    let date: Date

    @Environment(FileSystemStore.self) private var store
    @Environment(GeneralTodoStore.self) private var generalTodos
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var editorHost = AppContainer.shared.blockEditor
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    @State private var doc = EditorDocument()
    @State private var showTaskManager = false

    private var journalURL: URL? { store.journalURL(for: date) }

    var body: some View {
        BlockEditorView(
            host: AppContainer.shared.blockEditor,
            text: $doc.text,
            baseDir: journalURL?.deletingLastPathComponent(),
            documentID: journalURL,
            onCommand: { cmd in
                guard cmd == "list" else { return }
                doc.saveNow()   // 讓總覽能安全改這天的檔
                showTaskManager = true
            })
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay {
                if let error = editorHost.loadError {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重試") { editorHost.retry() }
                    }
                    .padding(16)
                } else if !editorHost.isReady {
                    ProgressView()
                } else if doc.awaitingDownload {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在從 iCloud 下載…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        doc.saveNow()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showTaskManager, onDismiss: { doc.refreshFromDisk() }) {
                TaskManagerSheet()
            }
            .onAppear {
                store.seedTodos(
                    for: date,
                    generalTexts: generalTodos.todos.filter { !$0.done }.map(\.text))
                doc.open(journalURL)
            }
            .onDisappear { doc.close() }
            .onChange(of: doc.text) { doc.scheduleAutosave() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    doc.refreshFromDisk()
                } else if phase == .background {
                    doc.saveNow()
                }
            }
    }

    private var title: String {
        let f = DateFormatter()
        f.locale = AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MdEEE")
        return f.string(from: date) + " " + L("日記")
    }
}
#endif
