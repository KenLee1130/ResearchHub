import Foundation
import CryptoKit

/// LaTeX 專案的編輯歷史：整個專案的文字檔快照。
///
/// 存在 `<專案>/.researchhub/history/`（跟著 iCloud 走，手機也看得到）：
///   • `blobs/<sha256>`         檔案內容，同內容只存一份
///   • `snapshots/<時間>.json`  一個快照＝當時每個文字檔對應哪個 blob
/// 什麼時候存：每次編譯、編輯中每 10 分鐘（內容沒變就不存）、還原前。
/// 保留：最近 7 天全部；更早的每天只留最後一份；沒人用的 blob 順手清掉。
/// 只記文字檔（.tex/.bib/.sty/.cls…），圖片和 PDF 不記。
nonisolated enum LatexHistory {
    enum Trigger: String, Codable, Sendable {
        case compile, auto, beforeRestore
        var label: String {
            switch self {
            case .compile: "編譯"
            case .auto: "自動"
            case .beforeRestore: "還原前"
            }
        }
    }

    struct Snapshot: Codable, Identifiable, Hashable, Sendable {
        var date: Date
        var trigger: Trigger
        /// 相對專案根目錄的路徑 → blob 雜湊
        var files: [String: String]
        /// 存在哪個檔（讀進來時填；不寫進 JSON）。清理時照這個刪，
        /// 不能用日期反推檔名——日期存進 JSON 會少掉毫秒，反推出來的名字對不上
        var fileName = ""
        var id: Date { date }

        enum CodingKeys: String, CodingKey { case date, trigger, files }
    }

    static let keepAllDays = 7
    static let textExtensions: Set<String> = ["tex", "bib", "sty", "cls", "bst", "txt", "md", "bbx", "cbx"]
    private static let maxFileBytes = 2_000_000

    // MARK: - 位置

    private static func historyDir(_ project: URL) -> URL {
        LatexProject.stateDir(of: project).appendingPathComponent("history", isDirectory: true)
    }
    private static func blobsDir(_ project: URL) -> URL {
        historyDir(project).appendingPathComponent("blobs", isDirectory: true)
    }
    private static func snapshotsDir(_ project: URL) -> URL {
        historyDir(project).appendingPathComponent("snapshots", isDirectory: true)
    }

    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return f
    }()

    // MARK: - 存快照

    /// 目前專案裡所有文字檔（相對路徑 → 內容）。讀不到的檔（iCloud 還沒下載）回 nil：
    /// 那次就不存，免得記成「檔案被刪了」。
    static func currentFiles(of project: URL) -> [String: String]? {
        let root = project.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(
            at: project, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var files: [String: String] = [:]
        for case let url as URL in walker {
            guard textExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileBytes else { continue }
            guard let text = FileSystemStore.safeRead(url) else { return nil }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            files[String(path.dropFirst(root.count))] = text
        }
        return files
    }

    /// 存一份快照；跟上一份一模一樣就不存。在背景執行緒呼叫。
    @discardableResult
    static func snapshot(_ project: URL, trigger: Trigger) -> Bool {
        guard let files = currentFiles(of: project), !files.isEmpty else { return false }
        let fm = FileManager.default
        let blobs = blobsDir(project)
        try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: snapshotsDir(project), withIntermediateDirectories: true)

        var manifest: [String: String] = [:]
        for (path, text) in files {
            let data = Data(text.utf8)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            manifest[path] = hash
            let blob = blobs.appendingPathComponent(hash)
            if !fm.fileExists(atPath: blob.path) { try? data.write(to: blob, options: .atomic) }
        }
        if let last = snapshots(of: project).first, last.files == manifest { return false }

        let snap = Snapshot(date: Date(), trigger: trigger, files: manifest)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970   // 保留小數秒，同一秒內的快照順序才對
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snap) else { return false }
        let name = fileNameFormatter.string(from: snap.date) + ".json"
        try? data.write(to: snapshotsDir(project).appendingPathComponent(name), options: .atomic)
        prune(project)
        return true
    }

    /// 全部快照，新的在前
    static func snapshots(of project: URL) -> [Snapshot] {
        let dir = snapshotsDir(project)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      var snap = try? decoder.decode(Snapshot.self, from: data) else { return nil }
                snap.fileName = name
                return snap
            }
            .sorted { $0.date > $1.date }
    }

    static func content(_ hash: String, in project: URL) -> String? {
        FileSystemStore.safeRead(blobsDir(project).appendingPathComponent(hash))
    }

    // MARK: - 清理

    /// 7 天前的快照每天只留最後一份；再把沒有快照用到的 blob 刪掉
    private static func prune(_ project: URL) {
        let fm = FileManager.default
        let all = snapshots(of: project)
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepAllDays, to: Date()) ?? .distantPast
        var keptDays = Set<DateComponents>()
        var kept: [Snapshot] = []
        for snap in all {   // 新的在前 → 每天第一個看到的就是那天最後一份
            if snap.date >= cutoff { kept.append(snap); continue }
            let day = Calendar.current.dateComponents([.year, .month, .day], from: snap.date)
            if keptDays.insert(day).inserted {
                kept.append(snap)
            } else {
                try? fm.removeItem(at: snapshotsDir(project).appendingPathComponent(snap.fileName))
            }
        }
        guard kept.count < all.count else { return }
        let used = Set(kept.flatMap { $0.files.values })
        let blobs = blobsDir(project)
        for name in (try? fm.contentsOfDirectory(atPath: blobs.path)) ?? [] where !used.contains(name) {
            try? fm.removeItem(at: blobs.appendingPathComponent(name))
        }
    }

    // MARK: - 還原

    /// 把一個檔案寫回快照裡的內容（先存一份「還原前」）
    static func restore(file path: String, from snap: Snapshot, in project: URL) -> Bool {
        guard let hash = snap.files[path], let text = content(hash, in: project) else { return false }
        snapshot(project, trigger: .beforeRestore)
        let url = project.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    /// 整個專案的文字檔寫回快照（先存一份「還原前」）。快照之後才新增的檔案不刪，
    /// 免得還原一下就把新寫的東西弄不見；回傳還原了幾個檔。
    static func restoreAll(from snap: Snapshot, in project: URL) -> Int {
        snapshot(project, trigger: .beforeRestore)
        var restored = 0
        for (path, hash) in snap.files {
            guard let text = content(hash, in: project) else { continue }
            let url = project.appendingPathComponent(path)
            if FileSystemStore.safeRead(url) == text { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil { restored += 1 }
        }
        return restored
    }

    // MARK: - 差異

    struct DiffLine: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case same, added, removed, gap }
        var kind: Kind
        var text: String
        /// 新版的行號（刪掉的行沒有）；gap 時是省略的行數
        var number: Int?
    }

    /// 逐行差異，只留改動處前後 3 行，其餘折成「⋯ N 行相同」
    static func diff(old: String, new: String, context: Int = 3) -> [DiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let changes = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var full: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                full.append(DiffLine(kind: .removed, text: a[i], number: nil)); i += 1
            } else if j < b.count, inserted.contains(j) {
                full.append(DiffLine(kind: .added, text: b[j], number: j + 1)); j += 1
            } else {
                if j < b.count { full.append(DiffLine(kind: .same, text: b[j], number: j + 1)) }
                i += 1; j += 1
            }
        }
        // 折疊離改動太遠的相同行
        let changed = full.indices.filter { full[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for k in changed { for d in -context...context { keep.insert(k + d) } }
        var out: [DiffLine] = []
        var skipped = 0
        for (k, line) in full.enumerated() {
            if keep.contains(k) {
                if skipped > 0 { out.append(DiffLine(kind: .gap, text: "", number: skipped)); skipped = 0 }
                out.append(line)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(DiffLine(kind: .gap, text: "", number: skipped)) }
        return out
    }

    /// (加幾行, 刪幾行)
    static func lineCounts(old: String?, new: String?) -> (added: Int, removed: Int) {
        let a = old.map { $0.components(separatedBy: "\n") } ?? []
        let b = new.map { $0.components(separatedBy: "\n") } ?? []
        var added = 0, removed = 0
        for change in b.difference(from: a) {
            if case .insert = change { added += 1 } else { removed += 1 }
        }
        return (added, removed)
    }
}
