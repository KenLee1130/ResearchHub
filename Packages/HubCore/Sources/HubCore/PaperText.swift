import Foundation

// MARK: - 論文文字（分頁）

/// 論文文字的純邏輯：給 AI 的全文、引文正規化與核對。（從 PDF 抽字的 pages(from:) 用 PDFKit，留在 app。）
public nonisolated enum PaperText {
    /// 給 AI 看的全文：每頁前面標 [p.N]。太長的論文截斷（避免超出模型的上下文）。
    public static func promptText(_ pages: [String], limit: Int = 350_000) -> String {
        var out = ""
        for (i, page) in pages.enumerated() {
            let chunk = "\n\n[p.\(i + 1)]\n" + page
            if out.count + chunk.count > limit {
                out += "\n\n[…論文後面的頁數太長，已省略…]"
                break
            }
            out += chunk
        }
        return out
    }

    /// 比對用的正規化：PDF 抽出的文字常有連字（ﬁ）、斷行連字號、怪空白，
    /// 模型引用時又會把它們寫成正常字。全部攤平再比。
    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        let replacements: [(String, String)] = [
            ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl"),
            ("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("−", "-"),
        ]
        for (a, b) in replacements { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "-\n", with: "")
        return String(t.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(Character.init))
    }

    /// 寬鬆比對用：只留字母與數字。PDF 抽字常把數學符號弄丟（√ 不見、∆ 變怪字），
    /// 而模型引用時會寫回正確的符號——這種不是幻覺，不該被標成找不到。
    public static func loose(_ s: String) -> String {
        String(normalize(s).unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.map(Character.init))
    }

    /// 找引文實際在哪一頁（先看模型說的那頁，再看前後一頁，最後全篇；也看跨頁的接縫）。
    /// 引文用「…」省略中間時，各段都要找得到。太短的引文（< 20 字元）不算數——
    /// 「OPE coefficients」這種到處都有的片語，找得到也證明不了什麼。
    public static func locate(quote: String, claimedPage: Int, in pages: [String],
                       normalized: [String]) -> Int? {
        let raw = quote.components(separatedBy: "…").flatMap { $0.components(separatedBy: "...") }
        let strictParts = raw.map(normalize).filter { $0.count >= 6 }
        let looseParts = raw.map(loose).filter { $0.count >= 6 }
        guard strictParts.reduce(0, { $0 + $1.count }) >= 20 else { return nil }
        let looseText = normalized.map { s in
            String(s.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }.map(Character.init))
        }
        var order = [claimedPage, claimedPage - 1, claimedPage + 1]
        order += Array(1...max(1, pages.count)).filter { !order.contains($0) }
        // 一頁的文字，加上下一頁開頭一小段（引文常常剛好跨頁）
        func window(_ texts: [String], _ p: Int) -> String {
            texts[p - 1] + (p < texts.count ? String(texts[p].prefix(400)) : "")
        }
        for p in order where p >= 1 && p <= normalized.count {
            let w = window(normalized, p)
            if strictParts.allSatisfy({ w.contains($0) }) { return p }
        }
        for p in order where p >= 1 && p <= looseText.count {
            let w = window(looseText, p)
            if !looseParts.isEmpty, looseParts.allSatisfy({ w.contains($0) }) { return p }
        }
        return nil
    }

    /// 解析回答裡的引文標記 [p.3「…」]，逐一核對。
    public static func citations(in answer: String, pages: [String], normalized: [String]) -> [PaperCitation] {
        guard let re = try? NSRegularExpression(pattern: #"\[p\.?\s*(\d+)\s*[「"“](.+?)[」"”]\s*\]"#,
                                                options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = answer as NSString
        return re.matches(in: answer, range: NSRange(location: 0, length: ns.length)).map { m in
            let page = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let quote = ns.substring(with: m.range(at: 2))
            let found = locate(quote: quote, claimedPage: page, in: pages, normalized: normalized)
            return PaperCitation(page: page, quote: quote, verified: found != nil, foundPage: found)
        }
    }
}
