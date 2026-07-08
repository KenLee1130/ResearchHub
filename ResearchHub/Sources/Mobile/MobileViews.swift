#if os(iOS)
import SwiftUI

// MARK: - 筆記瀏覽（唯讀：手機上翻筆記、看公式；編輯在 Mac 版）

struct MobileNotesView: View {
    @EnvironmentObject private var store: FileSystemStore
    @State private var tree: [FileSystemStore.TreeNode] = []
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    List(tree, children: \.children) { node in
                        row(node)
                    }
                } else {
                    // 搜尋：攤平所有筆記照名稱過濾
                    List(flatMatches()) { node in
                        row(node)
                    }
                }
            }
            .navigationTitle("筆記")
            .searchable(text: $query, prompt: Text("搜尋筆記名稱…"))
            .navigationDestination(for: URL.self) { url in
                MobileNotePreview(noteURL: url)
            }
            .onAppear { tree = store.noteTree() }
            .refreshable { tree = store.noteTree() }
        }
    }

    @ViewBuilder
    private func row(_ node: FileSystemStore.TreeNode) -> some View {
        if node.isFolder {
            Label(node.name, systemImage: "folder")
        } else {
            NavigationLink(value: node.url) {
                Label(node.name, systemImage: "doc.text")
            }
        }
    }

    private func flatMatches() -> [FileSystemStore.TreeNode] {
        var result: [FileSystemStore.TreeNode] = []
        func walk(_ nodes: [FileSystemStore.TreeNode]) {
            for n in nodes {
                if let children = n.children {
                    walk(children)
                } else if n.name.localizedCaseInsensitiveContains(query) {
                    result.append(FileSystemStore.TreeNode(
                        url: n.url, isFolder: false, children: nil))
                }
            }
        }
        walk(tree)
        return result
    }
}

/// 單篇筆記的渲染（KaTeX 數學、圖片、[[筆記]] 連結可點擊跳轉）。
struct MobileNotePreview: View {
    let noteURL: URL
    @State private var content = ""
    @State private var pushedNote: URL?

    var body: some View {
        MarkdownPreviewView(
            text: content,
            baseDir: noteURL.deletingLastPathComponent(),
            onOpenNote: { pushedNote = $0 })
            .navigationTitle(noteURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                content = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
            }
            .navigationDestination(item: $pushedNote) { url in
                MobileNotePreview(noteURL: url)
            }
    }
}

// MARK: - 蕃茄鐘

struct MobilePomodoroView: View {
    @EnvironmentObject private var pomodoro: PomodoroModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text(pomodoro.timeString)
                    .font(.system(size: 76, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                Text(LocalizedStringKey(pomodoro.phase.label))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                // 這顆要做什麼（沒開始倒數前可改）
                TextField("這顆要做什麼…", text: $pomodoro.currentPlan)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                    .disabled(pomodoro.isRunning)

                HStack(spacing: 28) {
                    Button {
                        pomodoro.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title2)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        pomodoro.toggle()
                    } label: {
                        Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                            .font(.title)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                }

                Text("今天 \(pomodoro.todayCount) 顆 · 本輪第 \(min(pomodoro.cyclePosition + 1, pomodoro.cycleLength)) / \(pomodoro.cycleLength) 顆")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text("倒數以結束時刻計算——鎖屏、切出去都不會停，時間到會推播通知。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()
            }
            .navigationTitle("蕃茄鐘")
            .sheet(item: completionBinding) { prompt in
                MobileCompletionSheet(prompt: prompt)
            }
        }
    }

    /// completionPrompt 是 @Published var，包一層 Binding 給 sheet(item:) 用。
    private var completionBinding: Binding<PomodoroModel.CompletionPrompt?> {
        Binding(
            get: { pomodoro.completionPrompt },
            set: { pomodoro.completionPrompt = $0 })
    }
}

/// 一顆結束後的動作小卡（手機版精簡版：記錄完成內容＋選下一步）。
struct MobileCompletionSheet: View {
    let prompt: PomodoroModel.CompletionPrompt
    @EnvironmentObject private var pomodoro: PomodoroModel
    @State private var doneNote = ""
    @State private var nextPlan = ""

    var body: some View {
        NavigationStack {
            Form {
                switch prompt {
                case .workDone:
                    Section("這顆完成了什麼？") {
                        TextField("寫一句就好", text: $doneNote, axis: .vertical)
                    }
                    Section {
                        Button {
                            pomodoro.startBreakAfterWork(doneNote: doneNote)
                        } label: {
                            Label("開始休息", systemImage: "cup.and.saucer")
                        }
                        Button {
                            pomodoro.continueWorkAfterWork(
                                doneNote: doneNote, extraMinutes: nil, nextPlan: nextPlan)
                        } label: {
                            Label("繼續工作", systemImage: "play")
                        }
                        Button("稍後再說") {
                            pomodoro.dismissAfterWork(doneNote: doneNote)
                        }
                        .foregroundStyle(.secondary)
                    }
                    Section("下一顆要做什麼（繼續工作時）") {
                        TextField("可留空", text: $nextPlan)
                    }

                case .breakDone(let wasLong):
                    Section("休息結束") {
                        TextField("下一顆要做什麼…", text: $nextPlan)
                    }
                    Section {
                        Button {
                            pomodoro.continueWorkAfterBreak(
                                nextPlan: nextPlan, extraMinutes: nil, wasLong: wasLong)
                        } label: {
                            Label("開始工作", systemImage: "play")
                        }
                        Button {
                            pomodoro.extendBreak(minutes: nil)
                        } label: {
                            Label("再休息一下", systemImage: "cup.and.saucer")
                        }
                        Button("稍後再說") {
                            pomodoro.dismissAfterBreak(wasLong: wasLong)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(prompt == .workDone ? "🍅 完成一顆" : "休息結束")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

// MARK: - 規劃明天（手機版晚間儀式）

struct MobilePlanningSheet: View {
    @EnvironmentObject private var store: FileSystemStore
    @EnvironmentObject private var pomodoro: PomodoroModel
    @EnvironmentObject private var generalTodos: GeneralTodoStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.language") private var language = AppLanguage.system.rawValue

    @State private var journalText = ""
    @State private var loadedText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var leftovers: [String] = []
    @State private var moved: Set<String> = []

    private let calendar = Calendar.current

    private var tomorrow: Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
    }
    private var tomorrowURL: URL? { store.journalURL(for: tomorrow) }

    private var appLocale: Locale {
        AppLanguage(rawValue: language)?.locale ?? .autoupdatingCurrent
    }

    /// 週一開頭的短星期名，跟隨 App 語言。
    private var dayLabels: [String] {
        var cal = Calendar.current
        cal.locale = appLocale
        let s = cal.shortWeekdaySymbols
        return (0..<7).map { s[($0 + 1) % 7] }
    }

    private var tomorrowWeekdayIndex: Int {
        (calendar.component(.weekday, from: tomorrow) + 5) % 7
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    rhythmCard
                    leftoverCard
                    if let insights = generalTodos.insights, !insights.message.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Claude 建議", systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.purple)
                            Text(insights.message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.purple.opacity(0.08)))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("明天的日記", systemImage: "book")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        BlockEditorView(
                            text: $journalText,
                            baseDir: tomorrowURL?.deletingLastPathComponent(),
                            documentID: tomorrowURL)
                            .frame(minHeight: 340)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.08)))
                }
                .padding(16)
            }
            .navigationTitle("規劃明天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        saveNow()
                        dismiss()
                    }
                }
            }
            .onAppear {
                load()
                leftovers = store.unfinishedJournalTodos(on: .now)
            }
            .onDisappear(perform: saveNow)
            .onChange(of: journalText) { scheduleSave() }
        }
    }

    private var rhythmCard: some View {
        let profile = pomodoro.productivityProfile(days: 60)
        return VStack(alignment: .leading, spacing: 6) {
            Label("你的節奏", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if profile.sampleCount >= 10 {
                if let h = profile.peakWindowStart {
                    Text("最專注時段：\(h):00–\(h + 2):00")
                        .font(.callout)
                }
                let count = profile.weekdayCounts[tomorrowWeekdayIndex]
                Group {
                    if tomorrowWeekdayIndex == profile.peakWeekday {
                        Text("明天是\(dayLabels[tomorrowWeekdayIndex])——你最高產的一天（近 60 天 \(count) 顆），可以排重的。")
                    } else {
                        Text("\(dayLabels[tomorrowWeekdayIndex])近 60 天完成 \(count) 顆。")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text("蕃茄鐘紀錄還不夠，先累積幾天吧。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.08)))
    }

    private var leftoverCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("今天沒做完的", systemImage: "arrow.uturn.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if leftovers.contains(where: { !moved.contains($0) }) {
                    Button("全部搬過去") {
                        for item in leftovers where !moved.contains(item) {
                            moveToTomorrow(item)
                        }
                    }
                    .font(.caption)
                }
            }
            if leftovers.isEmpty {
                Text("今天全部做完了 🎉")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(leftovers, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            moveToTomorrow(item)
                        } label: {
                            Image(systemName: moved.contains(item)
                                  ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(moved.contains(item)
                                                 ? AnyShapeStyle(.green)
                                                 : AnyShapeStyle(.secondary))
                        }
                        .disabled(moved.contains(item))
                        Text(TodoMeta.parse(item).cleanText)
                            .font(.callout)
                            .strikethrough(moved.contains(item))
                            .foregroundStyle(moved.contains(item) ? .tertiary : .primary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.08)))
    }

    /// 手機版直接改編輯器的 binding（編輯器內容就是唯一狀態，不會打架）。
    private func moveToTomorrow(_ item: String) {
        guard !moved.contains(item) else { return }
        if !journalText.isEmpty && !journalText.hasSuffix("\n") { journalText += "\n" }
        journalText += "- [ ] \(item)\n"
        moved.insert(item)
    }

    private func load() {
        // 先把明天該出現的副本播好（在讀檔之前）
        store.seedTodos(
            for: tomorrow,
            generalTexts: generalTodos.todos.filter { !$0.done }.map(\.text))
        guard let url = tomorrowURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            journalText = ""
            loadedText = ""
            return
        }
        journalText = content
        loadedText = content
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard let url = tomorrowURL, journalText != loadedText,
              !journalText.isEmpty || !loadedText.isEmpty else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? journalText.write(to: url, atomically: true, encoding: .utf8)) != nil {
            loadedText = journalText
        }
    }
}
#endif
