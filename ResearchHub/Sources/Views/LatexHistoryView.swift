#if os(macOS)
import SwiftUI

/// LaTeX 專案的歷史紀錄面板：左＝快照時間軸、中＝這一版改了哪些檔、右＝差異＋還原。
struct LatexHistoryView: View {
    let projectURL: URL
    /// 還原前先叫編輯器把還沒存的寫出去（還原前的快照才會包含它，編輯器也才會接受外部改動）
    var beforeRestore: (() -> Void)? = nil
    /// 在編輯器打開某個檔（相對路徑、行號）
    var onOpen: (String, Int?) -> Void
    /// 還原寫回檔案之後（重新編譯、更新檔案樹）
    var onRestored: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 一個快照在清單上要顯示的東西（背景算好）
    struct Entry: Identifiable, Hashable {
        let snap: LatexHistory.Snapshot
        /// 跟前一份比，有變的檔
        let changed: [String]
        let added: Int
        let removed: Int
        var id: Date { snap.date }
    }

    enum Compare: String, CaseIterable { case current = "跟現在比較", previous = "跟前一版比較" }

    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var selected: Entry?
    @State private var selectedFile: String?
    @State private var compare: Compare = .current
    @State private var diff: [LatexHistory.DiffLine] = []
    @State private var confirmRestoreAll = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text("還沒有歷史紀錄。每次編譯、編輯中每 10 分鐘會自動存一份。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    timeline.frame(width: 210)
                    Divider()
                    fileList.frame(width: 220)
                    Divider()
                    diffPane
                }
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .task { await load() }
        .onChange(of: selected) { selectedFile = selected?.changed.first ?? selected?.snap.files.keys.sorted().first }
        .onChange(of: selectedFile) { Task { await recomputeDiff() } }
        .onChange(of: compare) { Task { await recomputeDiff() } }
        .confirmationDialog("把整個專案的文字檔還原到 \(selected.map { Self.time($0.snap.date) } ?? "")？",
                            isPresented: $confirmRestoreAll) {
            Button("還原整個專案") { restoreAll() }
        } message: {
            Text("會先存一份「還原前」的版本，之後還可以再救回來。這個時間點之後才新增的檔案不會被刪除。")
        }
    }

    // MARK: - 版面

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text("歷史紀錄 · \(projectURL.lastPathComponent)").font(.headline).lineLimit(1)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $compare) {
                ForEach(Compare.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var timeline: some View {
        List(selection: $selected) {
            ForEach(groupedByDay, id: \.0) { day, items in
                Section(day) {
                    ForEach(items) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(Self.clock(entry.snap.date)).monospacedDigit()
                                Text(entry.snap.trigger.label)
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(entry.snap.trigger == .compile
                                                ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 4))
                            }
                            HStack(spacing: 4) {
                                if entry.changed.isEmpty {
                                    Text("第一份紀錄 · \(entry.snap.files.count) 個檔案")
                                } else {
                                    Text("\(entry.changed.count) 個檔案")
                                    Text("+\(entry.added)").foregroundStyle(.green)
                                    Text("−\(entry.removed)").foregroundStyle(.red)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(entry)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selected.map { $0.changed.isEmpty ? "這一版的檔案" : "這一版改了" } ?? "")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
            List(selection: $selectedFile) {
                ForEach(filesForSelection, id: \.self) { path in
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                        .help(path)
                        .tag(path)
                }
            }
            .listStyle(.plain)
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(diffTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if diff.isEmpty {
                        Text(selectedFile == nil ? "" : "沒有差異")
                            .foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                        diffRow(line)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 8) {
                Button("還原這個檔案到 \(selected.map { Self.clock($0.snap.date) } ?? "")") { restoreFile() }
                    .disabled(selectedFile == nil || selected?.snap.files[selectedFile ?? ""] == nil)
                Button("整個專案還原到 \(selected.map { Self.clock($0.snap.date) } ?? "")") {
                    confirmRestoreAll = true
                }
                .disabled(selected == nil)
                Spacer()
                Button("在編輯器打開") {
                    guard let selectedFile else { return }
                    onOpen(selectedFile, diff.first { $0.kind != .same && $0.kind != .gap }?.number)
                    dismiss()
                }
                .disabled(selectedFile == nil
                          || !FileManager.default.fileExists(
                              atPath: projectURL.appendingPathComponent(selectedFile ?? "").path))
            }
            .padding(10)
        }
    }

    private func diffRow(_ line: LatexHistory.DiffLine) -> some View {
        let (bg, fg, sign): (Color, Color, String) = switch line.kind {
        case .added: (Color.green.opacity(0.18), .primary, "+")
        case .removed: (Color.red.opacity(0.18), .primary, "−")
        case .same: (.clear, .secondary, " ")
        case .gap: (.clear, .secondary, "")
        }
        return HStack(spacing: 6) {
            if line.kind == .gap {
                Text("⋯ \(line.number ?? 0) 行相同").foregroundStyle(.tertiary)
            } else {
                Text(line.number.map(String.init) ?? "")
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
                Text(sign + " " + line.text).foregroundStyle(fg)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(bg)
        .textSelection(.enabled)
    }

    // MARK: - 資料

    private var groupedByDay: [(String, [Entry])] {
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for entry in entries {
            let key = Self.day(entry.snap.date)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { ($0, groups[$0]!) }
    }

    private var filesForSelection: [String] {
        guard let selected else { return [] }
        return selected.changed.isEmpty ? selected.snap.files.keys.sorted() : selected.changed
    }

    private var diffTitle: String {
        guard let selectedFile, let selected else { return "" }
        let name = (selectedFile as NSString).lastPathComponent
        return compare == .current
            ? "\(name) · \(Self.clock(selected.snap.date)) → 現在"
            : "\(name) · 前一版 → \(Self.clock(selected.snap.date))"
    }

    private func load() async {
        let project = projectURL
        let built = await Task.detached(priority: .userInitiated) { () -> [Entry] in
            let snaps = LatexHistory.snapshots(of: project)   // 新的在前
            var result: [Entry] = []
            for (k, snap) in snaps.enumerated() {
                // 第一份紀錄沒有「前一版」：不算加減行數（整個專案都算新增，數字沒有意義）
                guard k + 1 < snaps.count else {
                    result.append(Entry(snap: snap, changed: [], added: 0, removed: 0))
                    continue
                }
                let prev: LatexHistory.Snapshot? = snaps[k + 1]
                let paths = Set(snap.files.keys).union(prev.map { Array($0.files.keys) } ?? [])
                let changed = paths.filter { snap.files[$0] != prev?.files[$0] }.sorted()
                var added = 0, removed = 0
                for path in changed {
                    let old = prev?.files[path].flatMap { LatexHistory.content($0, in: project) }
                    let new = snap.files[path].flatMap { LatexHistory.content($0, in: project) }
                    let c = LatexHistory.lineCounts(old: old, new: new)
                    added += c.added; removed += c.removed
                }
                result.append(Entry(snap: snap, changed: changed, added: added, removed: removed))
            }
            return result
        }.value
        entries = built
        loading = false
        if selected == nil { selected = built.first }
    }

    private func recomputeDiff() async {
        guard let selected, let path = selectedFile else { diff = []; return }
        let project = projectURL
        let older = entries.first { $0.snap.date < selected.snap.date }
        let mode = compare
        diff = await Task.detached(priority: .userInitiated) {
            let atSnap = selected.snap.files[path].flatMap { LatexHistory.content($0, in: project) } ?? ""
            switch mode {
            case .current:
                let now = FileSystemStore.safeRead(project.appendingPathComponent(path)) ?? ""
                return LatexHistory.diff(old: atSnap, new: now)
            case .previous:
                let before = older?.snap.files[path].flatMap { LatexHistory.content($0, in: project) } ?? ""
                return LatexHistory.diff(old: before, new: atSnap)
            }
        }.value
    }

    private func restoreFile() {
        guard let selected, let path = selectedFile else { return }
        let project = projectURL
        beforeRestore?()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let ok = await Task.detached { LatexHistory.restore(file: path, from: selected.snap, in: project) }.value
            message = ok ? "已還原 \((path as NSString).lastPathComponent)" : "還原失敗"
            onRestored()
            await load()
            await recomputeDiff()
        }
    }

    private func restoreAll() {
        guard let selected else { return }
        let project = projectURL
        beforeRestore?()
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let n = await Task.detached { LatexHistory.restoreAll(from: selected.snap, in: project) }.value
            message = "已還原 \(n) 個檔案"
            onRestored()
            await load()
            await recomputeDiff()
        }
    }

    // MARK: - 日期字串

    private static func day(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "M/d"
        if cal.isDateInToday(date) { return "今天 \(f.string(from: date))" }
        if cal.isDateInYesterday(date) { return "昨天 \(f.string(from: date))" }
        return f.string(from: date)
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private static func time(_ date: Date) -> String { day(date) + " " + clock(date) }
}
#endif
