import AppKit

/// 用「本機的 LaTeX 工具鏈」輸出 PDF：pandoc 把筆記 Markdown（含數學與原生 LaTeX 指令）
/// 轉成 LaTeX，再用 xelatex/lualatex/pdflatex 編譯成 PDF。
///
/// 與 PDFExporter（WebView + KaTeX）並存、不取代它：
///   • PDFExporter：快、所見即所得，數學用 KaTeX（LaTeX 子集）。
///   • 這支：道地 LaTeX 排版（原生 \section / \footnote / equation / \label / \eqref、
///     可用完整數學），適合最終輸出。需本機安裝 pandoc 與 LaTeX（MacTeX）。
///
/// 找不到 pandoc 或 LaTeX 引擎時，會跳出說明，不會默默失敗。
///
/// 注意：執行外部程式（Process）在 App Sandbox 下會被擋；此功能適用於
/// 非沙箱（Developer ID 直接散布）的版本。
@MainActor
final class LaTeXPDFExporter {
    static let shared = LaTeXPDFExporter()

    enum ExportError: Error {
        case pandocMissing
        case latexMissing
        case readFailed
        case compileFailed(String)
    }

    /// 輸出指定筆記為 PDF（用本機 LaTeX）。
    func export(noteURL: URL) {
        guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else {
            showError(Self.message(for: .readFailed))
            return
        }
        // 只把 \cite 轉成編號 + 文末「參考文獻」（沿用 Zotero 資料）；其餘 \section、
        // \footnote、equation、\label、\eqref、數學等保留原樣，交給 LaTeX 原生處理。
        let prepared = Self.resolveCitations(content, items: ZoteroStore.shared.items)
        let noteDir = noteURL.deletingLastPathComponent()
        let name = noteURL.deletingPathExtension().lastPathComponent

        Task.detached(priority: .userInitiated) {
            do {
                let pdf = try Self.compile(markdown: prepared, resourceDir: noteDir)
                await MainActor.run { Self.shared.savePDF(pdf, suggestedName: name) }
            } catch let error as ExportError {
                await MainActor.run { Self.shared.showError(Self.message(for: error)) }
            } catch {
                await MainActor.run { Self.shared.showError(error.localizedDescription) }
            }
        }
    }

    // MARK: - 編譯（背景執行）

    nonisolated private static func compile(markdown: String, resourceDir: URL) throws -> Data {
        guard let pandoc = findExecutable("pandoc") else { throw ExportError.pandocMissing }
        guard let engine = findLatexEngine() else { throw ExportError.latexMissing }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("rh-tex-" + UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let mdURL = tmp.appendingPathComponent("note.md")
        let outURL = tmp.appendingPathComponent("note.pdf")
        try markdown.write(to: mdURL, atomically: true, encoding: .utf8)

        let engineName = engine.deletingPathExtension().lastPathComponent
        let isUnicodeEngine = (engineName == "xelatex" || engineName == "lualatex")

        var args = [
            mdURL.path,
            "-o", outURL.path,
            "--pdf-engine=\(engine.path)",
            "--resource-path", resourceDir.path,
            "--from", "markdown",
            "-V", "geometry:margin=1in",
        ]
        // 筆記常含中文：xelatex/lualatex 搭配 CJK 字型才印得出來（pandoc 模板會據此載入 xeCJK）。
        if isUnicodeEngine {
            args += ["-V", "CJKmainfont=PingFang TC"]
        }

        let proc = Process()
        proc.executableURL = pandoc
        proc.arguments = args
        proc.currentDirectoryURL = resourceDir
        // 讓 pandoc 找得到 LaTeX 引擎與其它工具。
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            engine.deletingLastPathComponent().path,
            "/Library/TeX/texbin", "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin",
        ]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        proc.environment = env

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, let data = try? Data(contentsOf: outURL) else {
            let log = String(data: errData, encoding: .utf8) ?? ""
            throw ExportError.compileFailed(String(log.suffix(1500)))
        }
        return data
    }

    // MARK: - 找執行檔

    nonisolated private static func findExecutable(_ name: String) -> URL? {
        let dirs = [
            "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin",
            "/Library/TeX/texbin",
        ]
        let fm = FileManager.default
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return whichViaShell(name)
    }

    nonisolated private static func findLatexEngine() -> URL? {
        // 優先支援系統字型/中文的引擎。
        for engine in ["xelatex", "lualatex", "tectonic", "pdflatex"] {
            if let url = findExecutable(engine) { return url }
        }
        return nil
    }

    /// 透過登入 shell 的 PATH 找（涵蓋 Homebrew 等自訂安裝位置）。
    nonisolated private static func whichViaShell(_ name: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - \cite → 編號 + 參考文獻（沿用 NotePreprocessor 的語意）

    nonisolated private static func resolveCitations(_ markdown: String, items: [ZoteroItem]) -> String {
        let byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var num: [String: Int] = [:]

        guard let re = try? NSRegularExpression(pattern: #"\\cite\{([^}]*)\}"#) else { return markdown }
        let ns = markdown as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: markdown, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let keys = ns.substring(with: m.range(at: 1))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let markers = keys.map { key -> String in
                if num[key] == nil { order.append(key); num[key] = order.count }
                return "[\(num[key]!)]"
            }.joined()
            result += markers
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)

        if !order.isEmpty {
            result += "\n\n---\n\n## 參考文獻\n\n"
            for (i, key) in order.enumerated() {
                if let item = byKey[key] {
                    result += "\(i + 1). \(reference(for: item))\n"
                } else {
                    result += "\(i + 1). （在 Zotero 找不到：\(key)）\n"
                }
            }
        }
        return result
    }

    nonisolated private static func reference(for item: ZoteroItem) -> String {
        var parts: [String] = []
        if !item.authors.isEmpty { parts.append(item.authors) }
        parts.append("*\(item.title)*")
        if let venue = item.data.publicationTitle, !venue.isEmpty { parts.append(venue) }
        if !item.year.isEmpty { parts.append(item.year) }
        var ref = parts.joined(separator: ". ")
        if let doi = item.data.DOI, !doi.isEmpty {
            ref += ". https://doi.org/\(doi)"
        }
        return ref
    }

    // MARK: - 儲存 / 錯誤

    private func savePDF(_ data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(suggestedName).pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "本機 LaTeX 輸出 PDF 失敗"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    nonisolated private static func message(for error: ExportError) -> String {
        switch error {
        case .pandocMissing:
            return "找不到 pandoc。請先安裝（例如 `brew install pandoc`），再試一次。"
        case .latexMissing:
            return "找不到 LaTeX 引擎（xelatex／pdflatex…）。請安裝 MacTeX（https://tug.org/mactex）後再試。"
        case .readFailed:
            return "讀不到筆記內容。"
        case .compileFailed(let log):
            return "LaTeX 編譯失敗：\n\n\(log)"
        }
    }
}
