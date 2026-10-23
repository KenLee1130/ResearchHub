#if os(macOS)
import Foundation
import HubStore
import HubCore
import Combine
import CryptoKit

/// 一則編譯訊息（錯誤或警告）。
struct LatexIssue: Identifiable, Hashable {
    let id = UUID()
    var file: String?
    var line: Int?
    var message: String
    var isError: Bool

    var location: String? {
        guard let file else { return nil }
        let name = (file as NSString).lastPathComponent
        return line.map { "\(name):\($0)" } ?? name
    }
}

/// 編譯 LaTeX 專案。
///
/// Mac 版是沙盒 app，不能直接執行 /Library/TeX 底下的編譯器，所以透過 Apple 給沙盒 app 的
/// NSUserUnixTask 呼叫 ~/Library/Application Scripts/com.ken.ResearchHub/researchhub-helper.sh
/// （由 scripts/install-mac.sh 安裝，在沙盒外執行）。
///
/// 中間檔放在 app 自己的 Caches（不會污染專案、也不會被 iCloud 同步）；
/// 只有成品 PDF 會被複製回 <專案>/.researchhub/output.pdf，這樣 iPhone 也看得到。
@MainActor
final class LatexCompiler: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case succeeded(Date)
        case failed(errors: Int)
        case unavailable(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var issues: [LatexIssue] = []
    /// PDF 更新時 +1，讓預覽知道要重讀
    @Published private(set) var pdfVersion = 0
    @Published private(set) var lastLogTail = ""

    let projectURL: URL
    private var isRunning = false
    private var queued = false
    private var debounce: Task<Void, Never>?
    /// 每次編譯 +1，讓看門狗知道自己等的是不是還在跑的那一輪
    private var generation = 0

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    static var helperURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationScriptsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        let url = dir.appendingPathComponent("researchhub-helper.sh")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 編譯工作區：app Caches 底下，用專案路徑的雜湊當資料夾名。
    /// 小幫手不能碰 iCloud，所以原始檔會先鏡射到這裡（見 LatexStaging）。
    private var buildDir: URL { LatexStaging.workDir(for: projectURL) }

    /// 存檔後呼叫：停手一下再編譯，連打時不會每次都跑。
    func requestCompile(after seconds: Double = 0.8) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.compileNow()
        }
    }

    private enum Prep: Sendable {
        case noMain
        case failed(String)
        case ready(main: URL, engine: String)
    }

    func compileNow() {
        guard !isRunning else { queued = true; return }
        guard let helper = Self.helperURL else {
            status = .unavailable("找不到 LaTeX 小幫手。請在專案資料夾執行 scripts/install-mac.sh 安裝。")
            return
        }
        isRunning = true
        status = .running
        generation += 1
        let round = generation
        let project = projectURL
        let build = buildDir
        // 準備工作全在背景：找主檔、整理 .bib、把原始檔從 iCloud 鏡射到容器工作區。
        // 這些都要讀寫專案裡的每個檔，以前在主執行緒做，按下編譯畫面會卡一下。
        Task { [weak self] in
            let prep = await Task.detached(priority: .userInitiated) { () -> Prep in
                guard let main = LatexProject.mainFile(in: project) else { return .noMain }
                let engine = LatexProject.engine(for: project, main: main)
                // 沒人 \cite 的自動條目從 .bib 拿掉（又被引用的放回來），再開始編譯
                LatexBibliography.reconcile(in: project)
                LatexBibliography.ensureBibliographyCommand(in: project)
                LatexProject.ensureColorPackage(in: project)
                // 編輯歷史：每次編譯存一份（內容沒變就不存）
                LatexHistory.snapshot(project, trigger: .compile)
                do {
                    try LatexStaging.sync(project: project, to: build)
                } catch {
                    return .failed(error.localizedDescription)
                }
                return .ready(main: main, engine: engine)
            }.value
            guard let self, self.generation == round, self.isRunning else { return }
            switch prep {
            case .noMain:
                self.isRunning = false
                self.status = .unavailable("找不到主檔（含 \\documentclass 的 .tex）")
            case .failed(let message):
                self.isRunning = false
                self.status = .unavailable("無法準備編譯暫存檔：\(message)")
            case .ready(let main, let engine):
                // 主檔可以在子資料夾（例如 Overleaf 專案整包放在「First Draft/」）：
                // 跟 Overleaf 一樣在主檔所在的資料夾編譯，相對路徑（圖、.bib、latexmkrc）才對；
                // 專案根目錄另外交給小幫手加進搜尋路徑，從根目錄算的路徑也找得到。
                let subdir = LatexProject.mainSubdirectory(of: main, in: project)
                let work = subdir.isEmpty ? build : build.appendingPathComponent(subdir)
                let args = ["compile", work.path, main.lastPathComponent, engine, build.path]
                self.run(helper: helper, args: args) { [weak self] output in
                    guard let self else { return }
                    self.finish(output: output,
                                mainName: main.deletingPathExtension().lastPathComponent,
                                engine: engine, workDir: work, subdir: subdir)
                }
            }
        }
        // 小幫手本身掛住的話（例如環境有問題），別讓畫面一直停在「編譯中…」
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000_000)
            guard let self, self.isRunning, self.generation == round else { return }
            self.isRunning = false
            self.issues = [LatexIssue(file: nil, line: nil,
                                      message: "LaTeX 小幫手沒有回應（超過 150 秒）。"
                                          + "請執行 scripts/install-mac.sh 重新安裝小幫手。",
                                      isError: true)]
            self.status = .failed(errors: 1)
        }
    }

    private func run(helper: URL, args: [String],
                     completion: @escaping @MainActor (String) -> Void) {
        Self.runHelper(args) { [weak self] output, error in
            guard let self else { return }
            if let error {
                self.status = .unavailable("無法執行 LaTeX 小幫手：\(error.localizedDescription)")
                self.isRunning = false
                return
            }
            completion(output)
        }
    }

    /// 執行沙盒外的小幫手（compile / zip / unzip 共用）。
    static func runHelper(_ args: [String],
                          completion: @escaping @MainActor (String, Error?) -> Void) {
        guard let helper = helperURL else {
            Task { @MainActor in
                completion("", NSError(domain: "ResearchHub", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "找不到 LaTeX 小幫手，請執行 scripts/install-mac.sh 安裝"]))
            }
            return
        }
        do {
            let task = try NSUserUnixTask(url: helper)
            let pipe = Pipe()
            task.standardOutput = pipe.fileHandleForWriting
            task.standardError = pipe.fileHandleForWriting
            task.execute(withArguments: args) { error in
                try? pipe.fileHandleForWriting.close()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                Task { @MainActor in completion(text, error) }
            }
        } catch {
            Task { @MainActor in completion("", error) }
        }
    }

    /// 解析小幫手輸出的 KEY=VALUE。
    static func parseFields(_ output: String) -> [String: String] { fields(in: output) }

    private func finish(output: String, mainName: String, engine: String,
                        workDir: URL, subdir: String) {
        isRunning = false
        let fields = Self.fields(in: output)
        let rc = Int(fields["RC"] ?? "") ?? -1
        let logURL = fields["LOG"].map { URL(fileURLWithPath: $0) }
            ?? workDir.appendingPathComponent("\(mainName).log")
        // log 夾著字型的二進位片段，不是完整的 UTF-8；用寬鬆解碼保住中文／全形字
        //（以前退回 Latin-1，錯誤訊息裡的「，」會變成亂碼）
        let log = (try? Data(contentsOf: logURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        issues = Self.parseLog(log).map { issue in
            var issue = issue
            issue.file = issue.file.map { Self.projectRelative($0, subdir: subdir, buildRoot: buildDir) }
            return issue
        }
        lastLogTail = String(log.suffix(4000))

        // pdflatex 不吃中文，會噴一整排看不懂的 Unicode 錯誤 → 直接講重點。
        // 只是混進幾個全形標點（英文論文裡的「，」）就指出是哪幾行，不要叫人整份換引擎。
        let unicodeIssues = issues.filter { $0.message.contains("Unicode character") }
        if engine != "xelatex", engine != "lualatex",
           !unicodeIssues.isEmpty, unicodeIssues.allSatisfy({ Self.isFullWidthPunctuation(in: $0.message) }) {
            let places = Set(unicodeIssues.compactMap { issue in
                issue.line.map { "\(issue.file.map { ($0 as NSString).lastPathComponent } ?? "")第 \($0) 行" }
            }).sorted()
            issues.insert(LatexIssue(
                file: nil, line: nil,
                message: "有全形標點（例如「，」）混進文字裡，\(engine) 不支援："
                    + places.joined(separator: "、") + "。改成半形標點就好。",
                isError: true), at: 0)
        } else if engine != "xelatex", engine != "lualatex", !unicodeIssues.isEmpty {
            issues.insert(LatexIssue(
                file: nil, line: nil,
                message: "這份專案目前用 \(engine) 編譯，不支援中文。"
                    + "請在「格式 → 編譯器」改成 XeLaTeX，並在導言區加上 \\usepackage{xeCJK}。",
                isError: true), at: 0)
        }
        if fields["TIMEOUT"] == "1" {
            issues.insert(LatexIssue(file: nil, line: nil,
                                     message: "編譯逾時（超過 120 秒）已中止", isError: true), at: 0)
        }
        // 成品 PDF 從容器工作區搬回專案（小幫手碰不到 iCloud，這步一定得 app 自己做）
        if let pdf = fields["PDF"], FileManager.default.fileExists(atPath: pdf),
           deliverPDF(from: URL(fileURLWithPath: pdf)) {
            pdfVersion += 1
        }
        let errorCount = issues.filter(\.isError).count
        if rc == 0 && errorCount == 0 {
            status = .succeeded(Date())
        } else {
            if errorCount == 0 && rc != 0 {
                issues.insert(LatexIssue(file: nil, line: nil,
                                         message: "編譯失敗（結束碼 \(rc)）", isError: true), at: 0)
            }
            status = .failed(errors: max(errorCount, 1))
        }
        if queued {
            queued = false
            requestCompile(after: 0.1)
        }
    }

    /// 把編譯好的 PDF 放進 <專案>/.researchhub/output.pdf（先寫暫存再置換，
    /// 免得 iPhone 正好同步到寫到一半的檔案）。
    private func deliverPDF(from source: URL) -> Bool {
        let fm = FileManager.default
        let dest = LatexProject.outputPDF(of: projectURL)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let tmp = dest.deletingLastPathComponent()
                .appendingPathComponent("output.pdf.tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            return true
        } catch {
            issues.insert(LatexIssue(file: nil, line: nil,
                                     message: "PDF 編譯好了，但寫回專案失敗：\(error.localizedDescription)",
                                     isError: true), at: 0)
            return false
        }
    }

    /// SyncTeX 反向搜尋：PDF 上的一點 → 原始碼的檔案（相對專案根目錄）與行號。
    /// point 是 PDF 點座標、原點在頁面左上（SyncTeX 的慣例）；page 從 0 算。
    /// 用的是暫存區裡最近一次編譯留下的 .synctex.gz（編譯本來就帶 -synctex=1）。
    func inverseSearch(page: Int, point: CGPoint) async -> (file: String, line: Int)? {
        let project = projectURL
        let build = buildDir
        let target = await Task.detached(priority: .userInitiated) { () -> (URL, String, String)? in
            guard let main = LatexProject.mainFile(in: project) else { return nil }
            let subdir = LatexProject.mainSubdirectory(of: main, in: project)
            let work = subdir.isEmpty ? build : build.appendingPathComponent(subdir)
            let name = main.deletingPathExtension().lastPathComponent
            guard FileManager.default.fileExists(
                atPath: work.appendingPathComponent("\(name).synctex.gz").path) else { return nil }
            return (work, "\(name).pdf", subdir)
        }.value
        guard let (work, pdf, subdir) = target else { return nil }
        let args = ["synctex", work.path, pdf, "\(page + 1)",
                    String(format: "%.1f", point.x), String(format: "%.1f", point.y)]
        let output: String = await withCheckedContinuation { continuation in
            Self.runHelper(args) { out, _ in continuation.resume(returning: out) }
        }
        let fields = Self.fields(in: output)
        guard let input = fields["INPUT"], let line = Int(fields["LINE"] ?? ""), line > 0
        else { return nil }
        return (Self.projectRelative(input, subdir: subdir, buildRoot: build), line)
    }

    /// log 裡的檔名換成「相對於專案根目錄」，點錯誤才跳得到正確的檔：
    /// 相對路徑是從主檔所在資料夾算的（補上子資料夾）；暫存區的絕對路徑換回專案內的路徑；
    /// 其他絕對路徑（TeX 系統的 .sty）不動。
    static func projectRelative(_ file: String, subdir: String, buildRoot: URL) -> String {
        if file.hasPrefix("/") {
            let root = buildRoot.standardizedFileURL.path + "/"
            let path = URL(fileURLWithPath: file).standardizedFileURL.path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : file
        }
        let clean = file.hasPrefix("./") ? String(file.dropFirst(2)) : file
        guard !subdir.isEmpty else { return clean }
        // 用 standardized 消掉 "../"（主檔在子資料夾、\input{../x} 的情形）
        let base = URL(fileURLWithPath: "/" + subdir, isDirectory: true)
        return String(base.appendingPathComponent(clean).standardizedFileURL.path.dropFirst())
    }

    /// 「Unicode character ， (U+FF0C)」的字是不是全形標點（CJK 標點 U+3000–303F、全形 U+FF00–FF65）
    static func isFullWidthPunctuation(in message: String) -> Bool {
        guard let r = message.range(of: #"\(U\+([0-9A-F]{4,6})\)"#, options: .regularExpression),
              let code = UInt32(message[r].dropFirst(3).dropLast(), radix: 16) else { return false }
        return (0x3000...0x303F).contains(code) || (0xFF00...0xFF65).contains(code)
    }

    /// 小幫手輸出的 KEY=VALUE 行。
    private static func fields(in output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "="), line.first?.isUppercase == true else { continue }
            let key = String(line[line.startIndex..<eq])
            guard key.allSatisfy({ $0.isUppercase || $0.isNumber }) else { continue }
            result[key] = String(line[line.index(after: eq)...])
        }
        return result
    }

    // MARK: - log 解析

    /// 從 .log 取出錯誤與警告。用 -file-line-error，所以錯誤長這樣：
    ///   ./main.tex:12: Undefined control sequence.
    static func parseLog(_ log: String) -> [LatexIssue] {
        var out: [LatexIssue] = []
        var seen = Set<String>()
        func add(_ issue: LatexIssue) {
            let key = "\(issue.isError)|\(issue.file ?? "")|\(issue.line ?? -1)|\(issue.message)"
            if seen.insert(key).inserted { out.append(issue) }
        }
        let lines = log.components(separatedBy: "\n")
        let fileLine = try? NSRegularExpression(
            pattern: #"^(.+?\.(?:tex|sty|cls|bib|def|cfg)):(\d+):\s*(.+)$"#)
        let warnLine = try? NSRegularExpression(
            pattern: #"^(?:LaTeX|Package(?: \w+)?|Class(?: \w+)?) Warning: (.+?)(?: on input line (\d+))?\.?$"#)
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = fileLine?.firstMatch(in: line, range: full), m.numberOfRanges == 4 {
                var msg = ns.substring(with: m.range(at: 3))
                // 錯誤說明常常接在下一行
                if msg.hasSuffix(".") || msg.hasPrefix("LaTeX Error") {
                    let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
                    if !next.isEmpty, !next.hasPrefix("l."), next.count < 120, !next.hasPrefix("./") {
                        msg += " " + next
                    }
                }
                add(LatexIssue(file: ns.substring(with: m.range(at: 1)),
                               line: Int(ns.substring(with: m.range(at: 2))),
                               message: msg, isError: true))
            } else if line.hasPrefix("! ") {
                add(LatexIssue(file: nil, line: nil,
                               message: String(line.dropFirst(2)), isError: true))
            } else if let m = warnLine?.firstMatch(in: line, range: full) {
                let msg = ns.substring(with: m.range(at: 1))
                let lineNo = m.range(at: 2).location == NSNotFound
                    ? nil : Int(ns.substring(with: m.range(at: 2)))
                add(LatexIssue(file: nil, line: lineNo, message: msg, isError: false))
            }
        }
        return out
    }
}
#endif
