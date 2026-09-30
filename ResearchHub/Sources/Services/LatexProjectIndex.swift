import Foundation

/// LaTeX 專案的補全索引：專案裡有哪些檔案、自己定義了哪些指令、有哪些 \label。
///
/// 打字時每個按鍵都會被問一次，所以結果依專案快取幾秒鐘，
/// 過期才重新掃（專案通常只有幾十個檔案，掃一次很便宜）。
@MainActor
enum LatexProjectIndex {
    nonisolated struct Snapshot: Sendable {
        /// .tex 檔（相對專案根目錄、不含副檔名）——給 \input{ \include{
        var texFiles: [String] = []
        /// 圖片（相對路徑、含副檔名）——給 \includegraphics{
        var images: [String] = []
        /// .bib 檔（相對路徑；\bibliography 不含副檔名、\addbibresource 含）
        var bibFiles: [String] = []
        /// 專案裡 \newcommand／\DeclareMathOperator／\def 定義的指令
        var macros: [LatexCommand] = []
        /// 所有檔案裡的 \label
        var labels: [String] = []
    }

    private static var cache: [String: (at: Date, snapshot: Snapshot)] = [:]
    private static var scanning = Set<String>()
    private static let ttl: TimeInterval = 3

    /// 立刻回傳手上這份（可能是幾秒前的），過期了就在背景重掃、掃完換上。
    /// 每個按鍵都會問一次，所以這裡絕不讀檔——以前過期時會在主執行緒把整個專案
    /// 的 .tex 從 iCloud 讀一遍，打字就頓一下。
    static func snapshot(for root: URL) -> Snapshot {
        let key = root.standardizedFileURL.path
        let hit = cache[key]
        if hit == nil || Date().timeIntervalSince(hit!.at) >= ttl { rescan(root, key: key) }
        return hit?.snapshot ?? Snapshot()
    }

    /// 開專案時先掃一次，第一次跳補全清單就有內容。
    static func prewarm(_ root: URL) {
        rescan(root, key: root.standardizedFileURL.path)
    }

    private static func rescan(_ root: URL, key: String) {
        guard scanning.insert(key).inserted else { return }
        Task {
            let snap = await Task.detached(priority: .utility) { scan(root) }.value
            cache[key] = (Date(), snap)
            scanning.remove(key)
        }
    }

    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf", "eps", "svg", "gif"]

    nonisolated(unsafe) private static let macroPattern = try! NSRegularExpression(
        pattern: #"\\(?:newcommand|renewcommand|providecommand)\*?\s*\{?\\([A-Za-z@]+)\}?\s*(?:\[(\d)\])?"#)
    nonisolated(unsafe) private static let operatorPattern = try! NSRegularExpression(
        pattern: #"\\DeclareMathOperator\*?\s*\{\\([A-Za-z]+)\}"#)
    nonisolated(unsafe) private static let defPattern = try! NSRegularExpression(
        pattern: #"\\def\s*\\([A-Za-z@]+)"#)
    nonisolated(unsafe) private static let labelPattern = try! NSRegularExpression(
        pattern: #"\\label\{([^}]+)\}"#)

    nonisolated private static func scan(_ root: URL) -> Snapshot {
        var snap = Snapshot()
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return snap }

        var macroNames = Set<String>()
        var labelSet = Set<String>()

        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            let ext = url.pathExtension.lowercased()

            if imageExtensions.contains(ext) {
                snap.images.append(rel)
            } else if ext == "bib" {
                snap.bibFiles.append(rel)
            } else if ext == "tex" || ext == "sty" || ext == "cls" {
                if ext == "tex" { snap.texFiles.append(String(rel.dropLast(4))) }
                // 太大的檔案（例如貼進來的資料表）就不掃內容
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size < 1_000_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                collect(text, macros: &snap.macros, names: &macroNames,
                        labels: &snap.labels, labelSet: &labelSet)
            }
        }
        snap.texFiles.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        snap.images.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        snap.bibFiles.sort()
        return snap
    }

    nonisolated private static func collect(_ text: String,
                                macros: inout [LatexCommand], names: inout Set<String>,
                                labels: inout [String], labelSet: inout Set<String>) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func addMacro(_ name: String, args: Int, detail: String) {
            guard names.insert(name).inserted else { return }
            let insert = "\\" + name + String(repeating: "{}", count: args)
            macros.append(LatexCommand(insert: insert, detail: detail, projectOnly: true))
        }

        macroPattern.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let name = ns.substring(with: m.range(at: 1))
            let args = m.range(at: 2).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 2))) ?? 0
            addMacro(name, args: args, detail: "本專案定義")
        }
        operatorPattern.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            addMacro(ns.substring(with: m.range(at: 1)), args: 0, detail: "本專案定義的運算子")
        }
        defPattern.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            addMacro(ns.substring(with: m.range(at: 1)), args: 0, detail: "本專案定義（\\def）")
        }
        labelPattern.enumerateMatches(in: text, range: full) { m, _, _ in
            guard let m else { return }
            let key = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, labelSet.insert(key).inserted { labels.append(key) }
        }
    }
}
