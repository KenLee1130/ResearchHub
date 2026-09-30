import Foundation

/// LaTeX 專案的參考文獻檔：在 \cite{ 補全選了 Zotero 的文獻時，
/// 把那筆的 BibTeX 寫進專案的 .bib，並回傳要填進 \cite{} 的 key。
///
/// 以前補全插入的是 Zotero 的內部 key（像 I4UT4SMS），專案的 .bib 裡沒有這個 key，
/// 編出來永遠是 [?]；要自己去 Zotero 匯出、貼進 .bib、再手打 key。
nonisolated enum LatexBibliography {
    /// 這個專案的文獻要寫進哪個 .bib：
    /// 主檔 \bibliography{}／\addbibresource{} 指到的那個 > 專案裡現有的第一個 > references.bib
    static func targetBib(in root: URL) -> URL {
        if let main = LatexProject.mainFile(in: root),
           let text = FileSystemStore.safeRead(main),
           let re = try? NSRegularExpression(
               pattern: #"^[^%\n]*\\(?:bibliography|addbibresource)\{([^}]+)\}"#,
               options: [.anchorsMatchLines]),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let first = (text as NSString).substring(with: m.range(at: 1))
                .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !first.isEmpty {
                return root.appendingPathComponent(first.lowercased().hasSuffix(".bib") ? first : first + ".bib")
            }
        }
        // 專案裡現有的 .bib（直接列檔案，不靠補全索引——這裡可能在背景執行緒）
        if let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            var found: [URL] = []
            for case let url as URL in walker where url.pathExtension.lowercased() == "bib" {
                found.append(url)
            }
            if let first = found.sorted(by: { $0.path < $1.path }).first { return first }
        }
        return root.appendingPathComponent("references.bib")
    }

    /// 確保 `item` 在專案的 .bib 裡，回傳它的 cite key。
    /// Zotero 沒開（拿不到匯出）時用手上的欄位自己組一筆。
    @MainActor
    static func cite(_ item: ZoteroItem, in root: URL) async -> String {
        let exported = await ZoteroStore.shared.bibtex(for: item).flatMap(parse)
        let (key, entry) = exported ?? fallbackEntry(for: item)

        let bib = targetBib(in: root)
        let fm = FileManager.default
        let existing = FileSystemStore.safeRead(bib) ?? ""
        // 檔案在 iCloud 上還沒下載到：不能當成空的寫回去（會蓋掉雲端那份），這次先只回 key
        if existing.isEmpty, fm.fileExists(atPath: bib.path),
           ((try? bib.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 {
            return key
        }
        guard !contains(key: key, in: existing) else { return key }
        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        text += entry + "\n"
        try? fm.createDirectory(at: bib.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? text.write(to: bib, atomically: true, encoding: .utf8)) != nil {
            track(key, in: root)
        }
        return key
    }

    // MARK: - 沒人引用的條目自動移除

    /// 剛加進來的條目先不動：\cite{key} 可能還沒存到磁碟上
    private static let pruneGrace: TimeInterval = 30

    private static func track(_ key: String, in root: URL) {
        var s = LatexProject.settings(of: root)
        var keys = s.autoBibKeys ?? [:]
        keys[key] = Date().timeIntervalSince1970
        s.autoBibKeys = keys
        LatexProject.save(s, to: root)
    }

    /// 被移除的條目先收在這裡（.researchhub/removed.bib）。
    /// 之後又 \cite 同一個 key（例如剪下再貼上、復原）就從這裡放回去，不必再找一次。
    private static func stashURL(of root: URL) -> URL {
        LatexProject.stateDir(of: root).appendingPathComponent("removed.bib")
    }

    /// 編譯前呼叫：app 自動加的條目若整個專案都沒有 \cite 它了，就從 .bib 拿掉；
    /// 反過來，被拿掉的條目又被引用時放回去。你自己寫進 .bib 的條目不會被動到。
    static func reconcile(in root: URL) {
        var settings = LatexProject.settings(of: root)
        var tracked = settings.autoBibKeys ?? [:]
        let stashFile = stashURL(of: root)
        var stash = (try? String(contentsOf: stashFile, encoding: .utf8)) ?? ""
        guard !tracked.isEmpty || !stash.isEmpty else { return }

        // 全專案的 .tex 都要讀得到才敢判斷「沒人引用」
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles]) else { return }
        var source = ""
        for case let url as URL in walker where url.pathExtension.lowercased() == "tex" {
            guard let text = FileSystemStore.safeRead(url) else { return }
            source += text + "\n"
        }
        let cited = citedKeys(in: source)

        let bib = targetBib(in: root)
        guard let original = FileSystemStore.safeRead(bib) else { return }
        var text = original
        let now = Date().timeIntervalSince1970

        // 1. 又被引用了 → 從暫存放回 .bib
        for key in cited where !contains(key: key, in: text) {
            guard let entry = extract(key: key, from: &stash) else { continue }
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            if !text.isEmpty { text += "\n" }
            text += entry + "\n"
            tracked[key] = now
        }

        // 2. 沒人引用了 → 移到暫存（\nocite{*} 表示「全部列出」，這時一筆都不拿）
        if !cited.contains("*") {
            for (key, addedAt) in tracked where !cited.contains(key) && now - addedAt > pruneGrace {
                if let entry = extract(key: key, from: &text) {
                    if !contains(key: key, in: stash) { stash += entry + "\n\n" }
                }
                tracked[key] = nil
            }
        }

        if text != original {
            try? text.write(to: bib, atomically: true, encoding: .utf8)
        }
        try? fm.createDirectory(at: LatexProject.stateDir(of: root), withIntermediateDirectories: true)
        try? stash.write(to: stashFile, atomically: true, encoding: .utf8)
        if tracked != (settings.autoBibKeys ?? [:]) {
            settings.autoBibKeys = tracked.isEmpty ? nil : tracked
            LatexProject.save(settings, to: root)
        }
    }

    /// 所有 \cite{a,b}、\citep[..]{c}、\nocite{*} 裡的 key。
    /// 註解掉的 \cite 也算（寧可多留，不要誤刪）。
    static func citedKeys(in source: String) -> Set<String> {
        guard let re = try? NSRegularExpression(
            pattern: #"\\[a-zA-Z]*cite[a-zA-Z]*\*?(?:\[[^\]]*\])*\{([^}]*)\}"#) else { return [] }
        let ns = source as NSString
        var keys = Set<String>()
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            for part in ns.substring(with: m.range(at: 1)).split(separator: ",") {
                let k = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { keys.insert(k) }
            }
        }
        return keys
    }

    /// 把 key 那一筆（@type{key, … } 整段，用大括號配對找結尾）從 bibText 拿出來。
    static func extract(key: String, from bibText: inout String) -> String? {
        let pattern = #"@\w+\s*\{\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*,"#
        guard let head = bibText.range(of: pattern, options: .regularExpression),
              let open = bibText[head].firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = open
        while i < bibText.endIndex {
            let c = bibText[i]
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1; if depth == 0 { end = bibText.index(after: i); break } }
            i = bibText.index(after: i)
        }
        guard var stop = end else { return nil }   // 括號沒配對：檔案怪怪的，別動
        let entry = String(bibText[head.lowerBound..<stop])
        // 連同後面的空行一起拿掉，不留一堆空白
        while stop < bibText.endIndex, bibText[stop] == "\n" || bibText[stop] == "\r" {
            stop = bibText.index(after: stop)
        }
        bibText.removeSubrange(head.lowerBound..<stop)
        return entry
    }

    static func contains(key: String, in bibText: String) -> Bool {
        let pattern = #"@\w+\s*\{\s*"# + NSRegularExpression.escapedPattern(for: key) + #"\s*,"#
        return bibText.range(of: pattern, options: .regularExpression) != nil
    }

    /// 這些欄位不進專案的 .bib：摘要很長、file 是這台 Mac 的絕對路徑（丟上 Overleaf 沒意義）
    private static let droppedFields: Set<String> = ["abstract", "file", "annote", "keywords", "urldate"]

    /// 從 Zotero 匯出的 BibTeX 拿出 key，並拿掉用不到的欄位。
    static func parse(_ bibtex: String) -> (key: String, entry: String)? {
        let trimmed = bibtex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = trimmed.range(of: #"^@\w+\s*\{\s*([^,\s]+)\s*,"#, options: .regularExpression)
        else { return nil }
        let head = String(trimmed[m])
        guard let brace = head.firstIndex(of: "{") else { return nil }
        let key = head[head.index(after: brace)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ", \t\n"))
        guard !key.isEmpty else { return nil }

        // Zotero 的匯出一個欄位一行（tab 開頭）；值可能跨行，所以用「下一個欄位開頭」當界線
        var kept: [String] = []
        var dropping = false
        for line in trimmed.components(separatedBy: "\n") {
            if let f = line.range(of: #"^\s+([A-Za-z]+)\s*="#, options: .regularExpression) {
                let name = line[f].trimmingCharacters(in: CharacterSet(charactersIn: " \t=")).lowercased()
                dropping = droppedFields.contains(name)
            } else if line.hasPrefix("}") {
                dropping = false
            }
            if !dropping { kept.append(line) }
        }
        return (key, kept.joined(separator: "\n"))
    }

    /// Zotero 匯出失敗時的備援：用快取裡的欄位組一筆夠用的條目。
    static func fallbackEntry(for item: ZoteroItem) -> (key: String, entry: String) {
        let creators = item.data.creators ?? []
        let last = creators.first.map { $0.lastName ?? $0.name ?? "" } ?? ""
        let firstWord = item.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first(where: { $0.count > 3 }).map(String.init) ?? ""
        let raw = (last + item.year + firstWord.capitalized)
        let key = String(raw.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        let safeKey = key.isEmpty ? item.key : key
        let authors = creators.map { c -> String in
            if let l = c.lastName, let f = c.firstName, !l.isEmpty { return "\(l), \(f)" }
            return c.display
        }.joined(separator: " and ")
        var fields: [(String, String)] = [("title", "{\(item.title)}"), ("author", authors)]
        if let j = item.data.publicationTitle, !j.isEmpty { fields.append(("journal", j)) }
        if !item.year.isEmpty { fields.append(("year", item.year)) }
        if let d = item.data.DOI, !d.isEmpty { fields.append(("doi", d)) }
        if let u = item.data.url, !u.isEmpty { fields.append(("url", u)) }
        let body = fields.map { "\t\($0.0) = {\($0.1)}," }.joined(separator: "\n")
        let type = item.data.itemType == "book" ? "book" : (item.data.publicationTitle == nil ? "misc" : "article")
        return (safeKey, "@\(type){\(safeKey),\n\(body)\n}")
    }
}
