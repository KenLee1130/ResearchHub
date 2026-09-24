import Foundation

/// LaTeX 專案的補全索引：專案裡有哪些檔案、自己定義了哪些指令、有哪些 \label。
///
/// 打字時每個按鍵都會被問一次，所以結果依專案快取幾秒鐘，
/// 過期才重新掃（專案通常只有幾十個檔案，掃一次很便宜）。
@MainActor
enum LatexProjectIndex {
    struct Snapshot {
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
    private static let ttl: TimeInterval = 3

    static func snapshot(for root: URL) -> Snapshot {
        let key = root.standardizedFileURL.path
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < ttl {
            return hit.snapshot
        }
        let snap = scan(root)
        cache[key] = (Date(), snap)
        return snap
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf", "eps", "svg", "gif"]

    private static let macroPattern = try! NSRegularExpression(
        pattern: #"\\(?:newcommand|renewcommand|providecommand)\*?\s*\{?\\([A-Za-z@]+)\}?\s*(?:\[(\d)\])?"#)
    private static let operatorPattern = try! NSRegularExpression(
        pattern: #"\\DeclareMathOperator\*?\s*\{\\([A-Za-z]+)\}"#)
    private static let defPattern = try! NSRegularExpression(
        pattern: #"\\def\s*\\([A-Za-z@]+)"#)
    private static let labelPattern = try! NSRegularExpression(
        pattern: #"\\label\{([^}]+)\}"#)

    private static func scan(_ root: URL) -> Snapshot {
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

    private static func collect(_ text: String,
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
