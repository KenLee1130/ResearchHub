import Foundation

/// LaTeX 筆記專案：跟 Overleaf 一樣，「一個資料夾＝一個專案」。
///
/// 判定方式刻意不靠附檔名或標記檔，而是看「最上層有沒有含 \documentclass 的 .tex」，
/// 所以從 Overleaf 下載的 zip 解開後丟進來就直接是一個專案，不必轉檔。
///
/// 檔案分工（重要，改動時別打破）：
///   • `format.tex`  版面設定。標準 LaTeX（geometry/setspace），Overleaf 排出來一模一樣。
///                   「格式」面板讀寫它，使用者也可以直接編輯。
///   • `latexmkrc`   編譯器選擇（$pdf_mode = 5 → xelatex）。Overleaf 也讀這個檔。
///   • `.researchhub/`  App 自己的東西：project.json（主檔／引擎／檢視模式）與 output.pdf。
///                   匯出 zip 時會排除，Overleaf 不會看到。
nonisolated enum LatexProject {
    static let stateDirName = ".researchhub"
    static let outputName = "output.pdf"
    static let formatName = "format.tex"

    // MARK: - 判定與主檔

    /// 最上層含 \documentclass 的 .tex 就算專案。main.tex 優先。
    static func mainFile(in folder: URL) -> URL? {
        if let saved = settings(of: folder).main {
            let u = folder.appendingPathComponent(saved)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let texs = names.filter { $0.lowercased().hasSuffix(".tex") }
            .sorted { a, b in
                if (a.lowercased() == "main.tex") != (b.lowercased() == "main.tex") {
                    return a.lowercased() == "main.tex"
                }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
        for name in texs {
            let u = folder.appendingPathComponent(name)
            if head(of: u).contains("\\documentclass") { return u }
        }
        return nil
    }

    static func isProject(_ folder: URL) -> Bool { mainFile(in: folder) != nil }

    /// 只讀開頭幾 KB：判定用，不必整份讀進來（也避免 iCloud 大檔卡住）。
    private static func head(of url: URL, bytes: Int = 4096) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - App 自己的設定（.researchhub/project.json）

    struct Settings: Codable, Equatable {
        var main: String?
        /// xelatex / pdflatex / lualatex / auto（auto＝交給專案的 latexmkrc）
        var engine: String?
        /// continuous / paged
        var viewMode: String?
        /// app 從 Zotero 自動寫進 .bib 的條目（key → 寫入時刻）。
        /// 只有這些會在不再被 \cite 時自動移除；你自己貼進 .bib 的不會動。
        var autoBibKeys: [String: Double]?
    }

    static func stateDir(of folder: URL) -> URL {
        folder.appendingPathComponent(stateDirName, isDirectory: true)
    }

    static func settingsURL(of folder: URL) -> URL {
        stateDir(of: folder).appendingPathComponent("project.json")
    }

    static func settings(of folder: URL) -> Settings {
        guard let data = try? Data(contentsOf: settingsURL(of: folder)),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    static func save(_ settings: Settings, to folder: URL) {
        let dir = stateDir(of: folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? data.write(to: settingsURL(of: folder), options: .atomic)
    }

    static func outputPDF(of folder: URL) -> URL {
        stateDir(of: folder).appendingPathComponent(outputName)
    }

    /// 編譯器：設定 > 專案自己的 latexmkrc（交給它決定）> 看主檔用了什麼套件
    static func engine(for folder: URL, main: URL) -> String {
        if let e = settings(of: folder).engine, !e.isEmpty { return e }
        let fm = FileManager.default
        for rc in ["latexmkrc", ".latexmkrc"] where fm.fileExists(atPath: folder.appendingPathComponent(rc).path) {
            return "auto"
        }
        let preamble = head(of: main, bytes: 8192)
        for pkg in ["xeCJK", "fontspec", "ctex", "polyglossia", "unicode-math"] where preamble.contains(pkg) {
            return "xelatex"
        }
        return "pdflatex"     // Overleaf 的預設
    }

    // MARK: - 新專案範本

    /// 範本刻意做成「帶去 Overleaf 也能直接編譯」：
    /// 字型用 \IfFontExistsTF 在 Mac（黑體）與 Overleaf（Noto）之間自動切換，
    /// 並附 latexmkrc 讓 Overleaf 自動選 XeLaTeX。
    static func create(in parent: URL, name: String) throws -> URL {
        let fm = FileManager.default
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try mainTemplate(title: name)
            .write(to: folder.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
        try LatexFormat().render(into: nil)
            .write(to: folder.appendingPathComponent(formatName), atomically: true, encoding: .utf8)
        try "$pdf_mode = 5;  # 5 = xelatex（中文需要）；Overleaf 也會讀這個檔\n"
            .write(to: folder.appendingPathComponent("latexmkrc"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: folder.appendingPathComponent("figures"), withIntermediateDirectories: true)
        save(Settings(main: "main.tex", engine: "auto", viewMode: "continuous"), to: folder)
        return folder
    }

    /// 編譯前呼叫：有用顏色指令（\color、\textcolor、\colorbox…）但主檔沒載入 xcolor／color
    /// → 在 \usepackage{hyperref} 前（沒有就最後一個 \usepackage 後、再沒有就 \begin{document} 前）補上。
    /// 舊範本建的專案沒有 xcolor，顏色指令會變成「未定義的指令」整份編不過。
    static func ensureColorPackage(in root: URL) {
        guard let main = mainFile(in: root),
              let text = FileSystemStore.safeRead(main) else { return }
        func uncommented(_ t: String) -> String {
            t.components(separatedBy: "\n")
                .map { String($0.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
                .joined(separator: "\n")
        }
        let preamble = uncommented(text)
        if preamble.range(of: #"\\(?:usepackage|RequirePackage)(?:\[[^\]]*\])?\{[^}]*\b(?:x?color)\b[^}]*\}"#,
                          options: .regularExpression) != nil { return }
        // 整個專案有沒有用到顏色指令
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        var used = false
        for case let url as URL in walker where url.pathExtension.lowercased() == "tex" {
            guard let t = FileSystemStore.safeRead(url) else { return }
            if uncommented(t).range(of: #"\\(?:color|textcolor|colorbox|fcolorbox|pagecolor|definecolor)\b"#,
                                    options: .regularExpression) != nil { used = true; break }
        }
        guard used else { return }

        var lines = text.components(separatedBy: "\n")
        let code = lines.map { String($0.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        let line = "\\usepackage{xcolor}   % \\textcolor{red}{字}、{\\color{red} 字}"
        // hyperref 習慣放最後，插在它前面
        if let i = code.firstIndex(where: { $0.contains("\\usepackage") && $0.contains("hyperref") }) {
            lines.insert(line, at: i)
        } else if let i = code.lastIndex(where: { $0.contains("\\usepackage") }) {
            lines.insert(line, at: i + 1)
        } else if let i = code.firstIndex(where: { $0.contains("\\begin{document}") }) {
            lines.insert(line, at: i)
        } else {
            return
        }
        try? lines.joined(separator: "\n").write(to: main, atomically: true, encoding: .utf8)
    }

    private static func mainTemplate(title: String) -> String {
        """
        \\documentclass[11pt]{article}
        \\usepackage{xeCJK}
        % 中文字型：Mac 上用黑體；Overleaf 沒有黑體，就換 Noto（兩邊都編得過）
        \\IfFontExistsTF{Heiti TC}{\\setCJKmainfont{Heiti TC}}{\\setCJKmainfont{Noto Serif CJK TC}}
        \\usepackage{amsmath, amssymb}
        \\usepackage{mathtools}
        \\usepackage{physics}   % \\abs \\norm \\dv \\pdv \\bra \\ket …（跟 Markdown 筆記的公式寫法一致）
        \\usepackage{bm}
        \\usepackage{graphicx}
        \\usepackage{xcolor}   % \\textcolor{red}{字}、{\\color{red} 字}
        \\usepackage{hyperref}
        \\input{format}   % 版面設定（app 的「格式」面板會改 format.tex）

        \\title{\(title)}
        \\author{}
        \\date{\\today}

        \\begin{document}
        \\maketitle

        \\section{Introduction}


        \\end{document}

        """
    }

    // MARK: - 專案內的檔案樹

    struct Node: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        var children: [Node]?
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// 列出專案內容（隱藏 .researchhub 與其他點開頭的檔案）。
    static func tree(of folder: URL) -> [Node] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { a, b in
                let da = isDir(folder.appendingPathComponent(a))
                let db = isDir(folder.appendingPathComponent(b))
                if da != db { return da }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { name in
                let u = folder.appendingPathComponent(name)
                let dir = isDir(u)
                return Node(url: u, isFolder: dir, children: dir ? tree(of: u) : nil)
            }
    }

    private static func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// 這個副檔名適合用文字編輯器開嗎？
    static func isTextFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return ["latexmkrc", "makefile"].contains(url.lastPathComponent.lowercased()) }
        return ["tex", "bib", "sty", "cls", "txt", "md", "bst", "cfg", "def", "tikz"].contains(ext)
    }

    static func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "pdf", "eps", "gif", "tiff", "webp"]
            .contains(url.pathExtension.lowercased())
    }
}
