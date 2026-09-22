import Foundation

/// 版面設定。真相在專案裡的 `format.tex`——它是標準 LaTeX，Overleaf 排出來一模一樣；
/// 「格式」面板只是它的圖形介面，兩邊改都可以。
///
/// 寫回時只換掉自己管的那幾行（\geometry / \setstretch / \parskip），
/// 使用者自己加的內容原樣保留。
struct LatexFormat: Equatable {
    var paper: String = "a4paper"          // a4paper / letterpaper / b5paper / a5paper
    var top: Double = 25                   // mm
    var bottom: Double = 25
    var left: Double = 25
    var right: Double = 25
    var lineStretch: Double = 1.2          // \setstretch
    var parSkip: Double = 0.5              // em
    /// 字級不在 format.tex，而是主檔的 \documentclass[11pt]；由面板另外改。
    var fontSize: Int = 11

    static let papers = ["a4paper", "letterpaper", "b5paper", "a5paper"]

    // MARK: - 解析

    static func parse(_ text: String, fontSize: Int = 11) -> LatexFormat {
        var f = LatexFormat()
        f.fontSize = fontSize
        if let geo = firstMatch(#"\\geometry\{([^}]*)\}"#, in: text)
            ?? firstMatch(#"\\usepackage\[([^\]]*)\]\{geometry\}"#, in: text) {
            for raw in geo.split(separator: ",") {
                let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if papers.contains(part) { f.paper = part; continue }
                let kv = part.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard kv.count == 2, let mm = millimetres(kv[1]) else { continue }
                switch kv[0] {
                case "top": f.top = mm
                case "bottom": f.bottom = mm
                case "left", "lmargin": f.left = mm
                case "right", "rmargin": f.right = mm
                case "margin": f.top = mm; f.bottom = mm; f.left = mm; f.right = mm
                default: break
                }
            }
        }
        if let s = firstMatch(#"\\setstretch\{([0-9.]+)\}"#, in: text), let v = Double(s) {
            f.lineStretch = v
        } else if let s = firstMatch(#"\\linespread\{([0-9.]+)\}"#, in: text), let v = Double(s) {
            f.lineStretch = v
        }
        if let s = firstMatch(#"\\setlength\{\\parskip\}\{([0-9.]+)\s*em\}"#, in: text),
           let v = Double(s) {
            f.parSkip = v
        }
        return f
    }

    /// 長度轉 mm（geometry 接受 mm/cm/in/pt）。
    private static func millimetres(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4), ("pt", 25.4 / 72.27)]
        for (u, k) in units where t.hasSuffix(u) {
            return Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)).map { $0 * k }
        }
        return Double(t)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - 寫出

    private var geometryLine: String {
        let n = { (v: Double) in String(format: "%g", (v * 10).rounded() / 10) }
        return "\\geometry{\(paper), top=\(n(top))mm, bottom=\(n(bottom))mm, "
            + "left=\(n(left))mm, right=\(n(right))mm}"
    }
    private var stretchLine: String { String(format: "\\setstretch{%.2f}", lineStretch) }
    private var parSkipLine: String { String(format: "\\setlength{\\parskip}{%.2fem}", parSkip) }

    /// 產生新的 format.tex；existing 有給就只換掉自己管的行，其餘保留。
    func render(into existing: String?) -> String {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return """
            % ResearchHub 版面設定
            % 這個檔是標準 LaTeX：可以直接改，也可以用 app 的「格式」面板改，兩邊同步。
            % 主檔的導言區要有 \\input{format} 才會生效；Overleaf 也吃得懂。
            \\usepackage{geometry}
            \(geometryLine)
            \\usepackage{setspace}
            \(stretchLine)
            \(parSkipLine)

            """
        }
        var lines = existing.components(separatedBy: "\n")
        func replaceOrAppend(_ pattern: String, _ line: String) {
            if let idx = lines.firstIndex(where: {
                $0.range(of: pattern, options: .regularExpression) != nil
            }) {
                lines[idx] = line
            } else {
                if let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.insert(line, at: lines.count - 1)
                } else {
                    lines.append(line)
                }
            }
        }
        if lines.first(where: { $0.contains("\\usepackage{geometry}") || $0.contains("{geometry}") }) == nil {
            lines.append("\\usepackage{geometry}")
        }
        replaceOrAppend(#"^\s*\\geometry\{"#, geometryLine)
        if lines.first(where: { $0.contains("{setspace}") }) == nil {
            lines.append("\\usepackage{setspace}")
        }
        replaceOrAppend(#"^\s*\\(setstretch|linespread)\{"#, stretchLine)
        replaceOrAppend(#"^\s*\\setlength\{\\parskip\}"#, parSkipLine)
        return lines.joined(separator: "\n")
    }

    // MARK: - 主檔：字級與 \input{format}

    /// 從 \documentclass[11pt]{article} 讀字級。
    static func fontSize(inMain text: String) -> Int {
        guard let opts = firstMatch(#"\\documentclass\[([^\]]*)\]"#, in: text),
              let pt = firstMatch(#"(\d+)pt"#, in: opts), let v = Int(pt) else { return 10 }
        return v
    }

    /// 改寫主檔的字級選項；沒有選項就加上。
    static func setFontSize(_ size: Int, inMain text: String) -> String {
        if let opts = firstMatch(#"\\documentclass\[([^\]]*)\]"#, in: text) {
            let newOpts: String
            if opts.range(of: #"\d+pt"#, options: .regularExpression) != nil {
                newOpts = opts.replacingOccurrences(
                    of: #"\d+pt"#, with: "\(size)pt", options: .regularExpression)
            } else {
                newOpts = "\(size)pt, " + opts
            }
            return text.replacingOccurrences(of: "[\(opts)]", with: "[\(newOpts)]")
        }
        return text.replacingOccurrences(
            of: #"\\documentclass\{"#, with: "\\\\documentclass[\(size)pt]{",
            options: .regularExpression)
    }

    static func hasFormatInput(_ text: String) -> Bool {
        text.range(of: #"\\(input|include)\{format(\.tex)?\}"#, options: .regularExpression) != nil
    }

    /// 在 \begin{document} 前插入 \input{format}。
    static func insertFormatInput(_ text: String) -> String {
        guard !hasFormatInput(text), let r = text.range(of: "\\begin{document}") else { return text }
        return text.replacingCharacters(
            in: r.lowerBound..<r.lowerBound,
            with: "\\input{format}   % 版面設定（ResearchHub 的「格式」面板會改它）\n\n")
    }
}
